#!/usr/bin/env bash
#
# mayhem/test.sh — RUN tetragon's own Go unit tests for the packages the fuzz targets exercise
# (test binaries pre-built by mayhem/build.sh with normal flags). exit 0 = pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BUILD="$SRC/mayhem/build/tests"
PKGS=(pkg/glob pkg/encoder pkg/filters pkg/eventcache pkg/celbpf)
# Named known-answer tests that must run and pass (a neutered/no-op run prints nothing and fails here).
MUST_PASS=("pkg/glob TestGlobFSM" "pkg/glob TestGlobFSMMulti")

passed=0; failed=0; skipped=0
for p in "${PKGS[@]}"; do
  bin="$BUILD/$(basename "$p").test"
  [ -x "$bin" ] || { echo "test.sh: $bin missing — mayhem/build.sh must build it" >&2; emit_ctrf "go-test" 0 1 0; exit 1; }
  out="$(cd "$SRC/$p" && "$bin" -test.v -test.count=1 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 5
  p_=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*--- PASS:' || true)
  f_=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*--- FAIL:' || true)
  s_=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*--- SKIP:' || true)
  [ "$rc" -eq 0 ] || [ "$f_" -gt 0 ] || f_=1   # runner died without a FAIL line (panic, exit status)
  [ "$p_" -gt 0 ] || { echo "test.sh: $p ran no passing tests" >&2; f_=$((f_+1)); }
  passed=$((passed+p_)); failed=$((failed+f_)); skipped=$((skipped+s_))
  for m in "${MUST_PASS[@]}"; do
    case "$m" in "$p "*) printf '%s\n' "$out" | grep -qE "^--- PASS: ${m#* } " \
      || { echo "test.sh: required test ${m#* } did not pass in $p" >&2; failed=$((failed+1)); } ;; esac
  done
done

emit_ctrf "go-test" "$passed" "$failed" "$skipped"
