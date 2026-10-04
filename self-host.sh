#!/bin/sh
# platform: macOS-only -- OS X 10.9 only: it builds the toolchain that runs there, natively, with itself
# self-host.sh [--compare <toolchain-prefix>] — rebuild this checkout's Swift toolchain on OS X 10.9 with
# the previous one, three times over, and show that the result no longer changes.
#   The seed is the toolchain SWIFT_HOST_TOOLCHAIN names, by default the installed
#   /usr/local/mavergreen/swift-toolchain: the previous release, the only Swift compiler that runs on
#   10.9. CI never builds with an earlier release (its native compiler is built by the same run's cross
#   toolchain, which the swift.org compiler seeds), so the two chains share no seed, and a 10.9 build equal
#   to CI's is the check that neither seed changed what they built.
#   1. Once: build-llvm.sh (LLVM build support, and the lld the runtime links) and build-builtins.sh
#      (compiler-rt's builtins, natively).
#   2. Stages 1, 2 and 3, each in the same build dirs: build-toolchain.sh with SWIFT_HOST_TOOLCHAIN = the
#      seed, then stage 1's toolchain, then stage 2's. Stage 1 builds LLVM, clang, lld, cmark and the
#      compiler's C++ half, which do not depend on the seed; a later stage reconfigures the compiler for
#      its new host and recompiles only the Swift half. Then the stage's compiler, beside the previous
#      stage's stdlib (the seed's for stage 1), builds its own stdlib and runtime (build.sh), and the
#      stage's toolchain is staged with them.
#   3. The fixed point: stage 2's and stage 3's toolchains are the same files (lib.sh's toolchain_cmp:
#      the compiler, clang, lld, the stdlib, the builtins archive, the helpers' outputs). Seeded by the
#      same release, stage 1 already equals them; stage 3 is what makes the check independent of the seed.
#   4. --compare <prefix>: stage 2's toolchain and <prefix> are the same files. With the installed
#      release as both seed and <prefix>, and this checkout at that release's tag, that verifies the
#      release: what it ships is what its source builds, on this Mac.
# Before anything runs it refuses cross mode, an installed mavericks-clang-22 whose pkg receipt is not
# pins.env's CLANG22_VERSION (a CLANG22_PREFIX set by hand skips that check, warning), and a seed (or a
# --compare) that is no Swift toolchain. Every stage gets its host toolchain as SWIFT_HOST_TOOLCHAIN,
# named explicitly, never a script's own default.
# Out: $SWIFT_BUILD/self-host/s<N>/toolchain (scripts/stage-toolchain.sh's payload) and s<N>/runtime
# (build.sh's); each step's wall time in $SWIFT_BUILD/self-host/times; the gate's commands, last, with
# stage 2's toolchain and runtime. Budget: DEVELOPING.md.
# Env: MAVERICKS_BUILD_ROOT, SWIFT_HOST_TOOLCHAIN (the seed), JOBS, MAVERICKS_MODE, CLANG22_PREFIX,
# MAVERICKS_SDK_CACHE.
set -eu
usage() { echo "usage: self-host.sh [--compare <toolchain-prefix>]" >&2; exit 2; }
COMPARE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --compare) [ $# -ge 2 ] || usage; COMPARE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, host_swiftc_stamp, toolchain_cmp
. "$HERE/msc.sh"    # -> $SHIPYARD (mavericks_mode.sh)
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"
[ "$MODE" = native ] || { echo "FAIL: self-host.sh rebuilds the toolchain that runs on OS X 10.9, on 10.9 (mode is '$MODE'); a modern Mac builds it with build-toolchain.sh, as CI does" >&2; exit 2; }
# The installed clang22 compiles the C++ half and the builtins, so another release of it builds other
# bytes, which only --compare would show, hours later: its pkg receipt must be pins.env's release. A
# CLANG22_PREFIX set by hand names a clang22 no receipt vouches for; that runs, warned.
if [ -n "${CLANG22_PREFIX:-}" ]; then
  echo "WARNING: CLANG22_PREFIX=$CLANG22_PREFIX is set by hand, so its release is not checked against pins.env's $CLANG22_VERSION: if it is another, the bytes may differ from CI's" >&2
else
  C22V="$(pkgutil --pkg-info dev.mavergreen.clang.clang22 2>/dev/null | sed -n 's/^version: //p')" || C22V=""
  [ "$C22V" = "$CLANG22_VERSION" ] || { echo "FAIL: the installed mavericks-clang-22 (pkg dev.mavergreen.clang.clang22) is ${C22V:-not installed}, not pins.env's $CLANG22_VERSION, which builds CI's bytes -- install clang22 $CLANG22_VERSION, or name one with CLANG22_PREFIX" >&2; exit 1; }
fi
SEED="${SWIFT_HOST_TOOLCHAIN:-/usr/local/mavergreen/swift-toolchain}"
host_swiftc_stamp "$SEED" > /dev/null || { echo "FAIL: no Swift toolchain to seed from at $SEED -- install swift-toolchain, or name one with SWIFT_HOST_TOOLCHAIN" >&2; exit 1; }
# Absolute, or build-toolchain.sh, which cds into the build tree, would miss it after build-llvm.sh's hours.
SEED="$(CDPATH='' cd -- "$SEED" && pwd)"
if [ -n "$COMPARE" ]; then
  [ -f "$COMPARE/bin/swift-frontend" ] || { echo "FAIL: --compare names no Swift toolchain: $COMPARE" >&2; exit 1; }
fi
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"
O="$SWIFT_BUILD/self-host"; mkdir -p "$O"; : > "$O/times"
P=usr/local/mavergreen/swift-toolchain
B="$W/builtins-x86/lib/darwin/libclang_rt.osx.a"
timed() {  # timed <label> <command>... -- runs it, recording its wall seconds in $O/times; a failure stops here
  _tl="$1"; shift
  echo "==> $_tl"
  _t0="$(date +%s)"
  "$@" || { echo "FAIL: $_tl ($*)" >&2; exit 1; }
  _t1="$(date +%s)"
  printf '%s\t%s\n' "$((_t1 - _t0))" "$_tl" >> "$O/times"
  echo "    $_tl: $((_t1 - _t0)) s"
}
echo "self-host.sh: seed $SEED"
"$SEED/bin/swift-frontend" -version 2>&1 | sed 's/^/    /'
timed "LLVM build support and lld (build-llvm.sh)" sh "$HERE/build-llvm.sh"
timed "builtins (build-builtins.sh)" sh "$HERE/build-builtins.sh"
prev="$SEED"
for N in 1 2 3; do
  D="$O/s$N"; rm -rf "$D"; mkdir -p "$D"
  timed "stage $N: swift-frontend, its Swift half compiled by $prev" \
    env SWIFT_HOST_TOOLCHAIN="$prev" sh "$HERE/build-toolchain.sh"
  timed "stage $N: its compiler beside the previous stdlib" \
    sh "$HERE/scripts/stage-toolchain.sh" --frontend "$W/swift-x86" --stdlib "$prev/lib/swift" --builtins "$B" "$D/pre"
  # No pkg installed a stage, so its release is declared: this checkout's Swift.
  timed "stage $N: its stdlib and runtime (build.sh)" \
    env SWIFT_HOST_TOOLCHAIN="$D/pre/$P" SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-selfhost.s$N" \
    SWIFT_RUNTIME_OUT="$D/runtime" sh "$HERE/build.sh"
  timed "stage $N: its toolchain" \
    sh "$HERE/scripts/stage-toolchain.sh" --frontend "$W/swift-x86" --stdlib "$W/stdlib-build/lib/swift" --builtins "$B" "$D/toolchain"
  rm -rf "$D/pre"
  prev="$D/toolchain/$P"
done
echo "==> the fixed point: stage 2's toolchain and stage 3's"
toolchain_cmp "$O/s2/toolchain/$P" "$O/s3/toolchain/$P" || { echo "FAIL: no fixed point: stage 3 differs from stage 2 (listed above)" >&2; exit 1; }
echo "FIXED POINT: stage 2 = stage 3"
if [ -n "$COMPARE" ]; then
  echo "==> stage 2's toolchain and $COMPARE"
  toolchain_cmp "$O/s2/toolchain/$P" "$COMPARE" || { echo "FAIL: $COMPARE is not what this checkout builds (listed above)" >&2; exit 1; }
  echo "SAME: $COMPARE is what this checkout builds"
fi
echo "Wall time, in seconds:"; cat "$O/times"
awk -F '\t' '{ s += $1 } END { printf "%s\ttotal\n", s }' "$O/times"
# Both commands name stage 2's runtime, so the gate tests the runtime this run built -- never an installed
# one, and never run-selftest.sh's skip (exit 77) for want of one.
RT2="$O/s2/runtime/usr/local/mavergreen/swift-runtime"
echo "The gate (T1b's acceptance) with stage 2's toolchain and runtime:"
echo "  SWIFTC=$O/s2/toolchain/$P/bin/swiftc SWIFT_RUNTIME_PREFIX=$RT2 DIST=$O/dist sh $HERE/make-selftest.sh"
echo "  then, in $O/dist: tar -xzf swift-runtime-selftest.tar.gz && SWIFT_RUNTIME_PREFIX=$RT2 sh swift-runtime-selftest/run-selftest.sh --gate"
