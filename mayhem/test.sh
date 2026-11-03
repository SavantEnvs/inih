#!/usr/bin/env bash
#
# mayhem/test.sh — RUN inih's own functional suite (built by mayhem/build.sh): each upstream unit-test
# configuration prints its parse results, and the output must match upstream's committed baseline
# byte-for-byte (tests/baseline_*.txt, examples/cpptest*.txt). Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

T="$SRC/mayhem/build/tests"
passed=0; failed=0

# <binary> <baseline> <cwd>
run_case() {
  local bin="$T/$1" baseline="$2" dir="$3"
  if [ ! -x "$bin" ]; then echo "FAIL $1: test binary missing (build.sh should have built it)" >&2; failed=$((failed+1)); return; fi
  if [ ! -s "$baseline" ]; then echo "FAIL $1: baseline $baseline missing/empty" >&2; failed=$((failed+1)); return; fi
  if (cd "$dir" && "$bin" 2>&1 | diff "$baseline" - >/dev/null); then
    echo "PASS $1"; passed=$((passed+1))
  else
    echo "FAIL $1: output differs from $baseline" >&2
    (cd "$dir" && "$bin" 2>&1 | diff "$baseline" - | head -10) >&2
    failed=$((failed+1))
  fi
}

for n in multi multi_max_line single disallow_inline_comments stop_on_first_error handler_lineno string \
         heap heap_max_line heap_realloc heap_realloc_max_line heap_string call_handler_on_new_section \
         allow_no_value alloc file_error; do
  run_case "$n" "$SRC/tests/baseline_$n.txt" "$SRC/tests"
done
run_case cpptest       "$SRC/examples/cpptest.txt"       "$SRC/examples"
run_case cpptesterrors "$SRC/examples/cpptesterrors.txt" "$SRC/examples"

emit_ctrf "diff-baselines" "$passed" "$failed" 0
