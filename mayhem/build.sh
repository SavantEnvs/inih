#!/usr/bin/env bash
#
# mayhem/build.sh — build inih's fuzz harnesses (sanitized) and its unit-test variants (normal flags).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized, coverage-instrumented project objects. ini.c is built once for the default config and
#    once for the heap/realloc/lineno/no-value config (the harness is compiled with the same -D flags
#    because the handler signature depends on INI_HANDLER_LINENO).
OUT=/mayhem
B="$SRC/mayhem/build"
mkdir -p "$B/fuzz" "$B/tests"
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
HEAP_DEFS="-DINI_USE_STACK=0 -DINI_ALLOW_REALLOC=1 -DINI_INITIAL_ALLOC=16 -DINI_ALLOW_NO_VALUE=1 -DINI_HANDLER_LINENO=1 -DINI_CALL_HANDLER_ON_NEW_SECTION=1"

$CC $FUZZ_CFLAGS -c "$SRC/ini.c" -o "$B/fuzz/ini.o"
$CC $FUZZ_CFLAGS $HEAP_DEFS -c "$SRC/ini.c" -o "$B/fuzz/ini_heap.o"
$CXX $FUZZ_CFLAGS -I"$SRC" -c "$SRC/cpp/INIReader.cpp" -o "$B/fuzz/INIReader.o"
# LeakSanitizer off at build time (SPEC §6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz/lsan_off.o"
# The standalone driver is C: compile it as C so LLVMFuzzerTestOneInput keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"

# 2) Harnesses: <name>, linked twice (libFuzzer engine + standalone run-once reproducer).
build_harness() { # <name> <src> <compiler> <extra cflags> <objs...>
  local name="$1" src="$2" cc="$3" extra="$4"; shift 4
  $cc $FUZZ_CFLAGS $extra -I"$SRC" -I"$SRC/cpp" -c "$src" -o "$B/fuzz/$name.o"
  $cc $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz/$name.o" "$@" "$B/fuzz/lsan_off.o" -o "$OUT/$name"
  $cc $SANITIZER_FLAGS $DEBUG_FLAGS "$B/fuzz/$name.o" "$@" "$B/fuzz/standalone_main.o" "$B/fuzz/lsan_off.o" -o "$OUT/$name-standalone"
}
build_harness inihfuzz      "$SRC/mayhem/harnesses/inihfuzz.c"      "$CC"  ""            "$B/fuzz/ini.o"
build_harness inihfuzz_file "$SRC/mayhem/harnesses/inihfuzz_file.c" "$CC"  ""            "$B/fuzz/ini.o"
build_harness inihfuzz_heap "$SRC/mayhem/harnesses/inihfuzz.c"      "$CC"  "$HEAP_DEFS"  "$B/fuzz/ini_heap.o"
build_harness inireader_fuzz "$SRC/mayhem/harnesses/inireader_fuzz.cpp" "$CXX" ""        "$B/fuzz/INIReader.o" "$B/fuzz/ini.o"

# 3) Upstream's own test matrix (tests/unittest.sh + examples/cpptest.sh) with NORMAL flags: one binary
#    per configuration, built here so test.sh only runs them and diffs against upstream's baselines.
T="$B/tests"
tc() { # <name> <defs> <sources...>
  local name="$1" defs="$2"; shift 2
  # shellcheck disable=SC2086
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS $CC -Wall $defs "$@" -o "$T/$name"
}
tcpp() { # <name> <sources...>
  local name="$1"; shift
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS $CXX -Wall "$@" -o "$T/$name"
}
U="$SRC/tests"; I="$SRC/ini.c"
tc multi                  ""                                                                   "$I" "$U/unittest.c"
tc multi_max_line         "-DINI_MAX_LINE=20"                                                  "$I" "$U/unittest.c"
tc single                 "-DINI_ALLOW_MULTILINE=0"                                            "$I" "$U/unittest.c"
tc disallow_inline_comments "-DINI_ALLOW_INLINE_COMMENTS=0"                                    "$I" "$U/unittest.c"
tc stop_on_first_error    "-DINI_STOP_ON_FIRST_ERROR=1"                                        "$I" "$U/unittest.c"
tc handler_lineno         "-DINI_HANDLER_LINENO=1"                                             "$I" "$U/unittest.c"
tc string                 "-DINI_MAX_LINE=20"                                                  "$I" "$U/unittest_string.c"
tc heap                   "-DINI_USE_STACK=0"                                                  "$I" "$U/unittest.c"
tc heap_max_line          "-DINI_USE_STACK=0 -DINI_MAX_LINE=20 -DINI_INITIAL_ALLOC=20"         "$I" "$U/unittest.c"
tc heap_realloc           "-DINI_USE_STACK=0 -DINI_ALLOW_REALLOC=1 -DINI_INITIAL_ALLOC=5"      "$I" "$U/unittest.c"
tc heap_realloc_max_line  "-DINI_USE_STACK=0 -DINI_MAX_LINE=20 -DINI_ALLOW_REALLOC=1 -DINI_INITIAL_ALLOC=5" "$I" "$U/unittest.c"
tc heap_string            "-DINI_USE_STACK=0 -DINI_MAX_LINE=20 -DINI_INITIAL_ALLOC=20"         "$I" "$U/unittest_string.c"
tc call_handler_on_new_section "-DINI_CALL_HANDLER_ON_NEW_SECTION=1"                           "$I" "$U/unittest.c"
tc allow_no_value         "-DINI_ALLOW_NO_VALUE=1"                                             "$I" "$U/unittest.c"
tc alloc                  "-DINI_CUSTOM_ALLOCATOR=1 -DINI_USE_STACK=0 -DINI_ALLOW_REALLOC=1 -DINI_INITIAL_ALLOC=12" "$I" "$U/unittest_alloc.c"
tc file_error             ""                                                                   "$I" "$U/unittest_file_error.c"
tcpp cpptest              "$SRC/examples/INIReaderExample.cpp" "$SRC/cpp/INIReader.cpp" "$I"
tcpp cpptesterrors        "$SRC/examples/INIReaderExampleErrors.cpp" "$SRC/cpp/INIReader.cpp" "$I"
