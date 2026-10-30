#!/usr/bin/env bash
#
# mayhem/build.sh — build tetragon's native Go fuzz targets (FuzzXxx(*testing.F) in *_test.go) as
# sanitized libFuzzer binaries via go-118-fuzz-build + a clang link, plus the project's own test
# binaries (normal flags) that mayhem/test.sh runs.
#
# Runs in the commit image as `mayhem` in /mayhem. GOROOT/GOPATH/GOMODCACHE are pinned by the
# Dockerfile ENV under /opt/toolchains ($HOME-independent).
#
# Air-gapped re-run (SPEC §6.5): the first (online) build fills $GOMODCACHE; the module cache doubles
# as a file proxy, listed first in GOPROXY, so the offline re-run resolves entirely from it.
#
# go-118-fuzz-build needs its `testing` shim on the module graph. Rather than edit upstream's go.mod /
# go.sum we work on copies (-modfile) under mayhem/build/, which is gitignored.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"

GO118_FUZZ_BUILD_VERSION=v0.0.0-20250520111509-a70c2aa677fa

BUILD="$SRC/mayhem/build"
cd "$SRC"
go version
mkdir -p "$BUILD/tests" "$BUILD/bak"

# ── fuzz targets ─────────────────────────────────────────────────────────────
# <binary> <Fuzz function> <package dir>
TARGETS=(
  "glob-get-literals FuzzGlobGetLiterals pkg/glob"
  "glob-build-multi-nfa FuzzGlobBuildMultiNFA pkg/glob"
  "compact-encoder FuzzCompactEncoder pkg/encoder"
  "protojson-compat FuzzProtojsonCompatibility pkg/encoder"
)

# Module graph for the fuzz build: a private copy of go.mod/go.sum + the go-118 testing shim.
cp -f go.mod "$BUILD/go.mod"
cp -f go.sum "$BUILD/go.sum"
chmod u+w "$BUILD/go.mod" "$BUILD/go.sum"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOFLAGS="-mod=mod -modfile=$BUILD/go.mod"
go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_FUZZ_BUILD_VERSION}"

# go-118-fuzz-build rewrites the package's *_test.go in place and puts them back when it succeeds;
# on failure restore them from our backup so an aborted build never leaves the tree modified.
CUR_PKG=""
restore_tests() {
  [ -n "$CUR_PKG" ] || return 0
  rm -f "$SRC/$CUR_PKG"/*_test.go_fuzz.go "$SRC"/main.[0-9]*.go
  if [ -d "$BUILD/bak/$CUR_PKG" ]; then
    cp -f "$BUILD/bak/$CUR_PKG"/*_test.go "$SRC/$CUR_PKG/"
  fi
  CUR_PKG=""
}
trap restore_tests EXIT

# Init-ordering shim (go_runtime_ready.c) and the build-time LeakSanitizer off switch, linked into every target.
SHIM_O="$BUILD/go_runtime_ready.o"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$SHIM_O"
LSAN_O="$BUILD/lsan_off.o"
$CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_O"
STANDALONE_O="$BUILD/standalone_main.o"
$CC $SANITIZER_FLAGS $GO_DEBUG_FLAGS -c "${STANDALONE_FUZZ_MAIN:-/opt/mayhem/StandaloneFuzzTargetMain.c}" -o "$STANDALONE_O"

for t in "${TARGETS[@]}"; do
  read -r name fn pkg <<<"$t"
  echo "=== building $name ($fn in ./$pkg) ==="
  rm -rf "$BUILD/bak/$pkg"; mkdir -p "$BUILD/bak/$pkg"
  cp -f "$SRC/$pkg"/*_test.go "$BUILD/bak/$pkg/"
  CUR_PKG="$pkg"
  go-118-fuzz-build -o "$BUILD/$name.a" -func "$fn" "./$pkg"
  CUR_PKG=""
  # libFuzzer binary (fuzzing) + run-once reproducer.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SHIM_O" "$LSAN_O" "$BUILD/$name.a" -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS "$SHIM_O" "$STANDALONE_O" "$LSAN_O" "$BUILD/$name.a" -o "$SRC/$name-standalone"
  nm "$SRC/$name" | grep ' T LLVMFuzzerInitialize$' >/dev/null \
    || { echo "build.sh: LLVMFuzzerInitialize init-ordering shim missing from $SRC/$name" >&2; exit 1; }
  echo "built $SRC/$name"
done

# ── functional test binaries (normal flags, upstream's vendor/ tree; no network) ────────────
export GOFLAGS=-mod=vendor
TEST_PKGS=(pkg/glob pkg/encoder pkg/filters pkg/eventcache pkg/celbpf)
for p in "${TEST_PKGS[@]}"; do
  go test -c -o "$BUILD/tests/$(basename "$p").test" "./$p"
done

echo "build.sh complete"
