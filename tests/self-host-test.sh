#!/bin/sh
# platform: host-agnostic
# usage: sh tests/self-host-test.sh
#   self-host.sh must run, in order: build-llvm.sh and build-builtins.sh once, then for each of three
#   stages build-toolchain.sh with the previous stage's toolchain as its host (the seed's for stage 1), a
#   pre toolchain staged from that compiler and the previous stage's stdlib, build.sh with that pre
#   toolchain under a declared release of this checkout's Swift, and the stage's toolchain staged from
#   the stdlib it built; then it must pass only when stage 2 and stage 3 are the same files, and, with
#   --compare, only when stage 2 is the named prefix too. It must refuse cross mode, a seed that is no
#   Swift toolchain, or an installed clang22 whose receipt is not pins.env's CLANG22_VERSION (unless
#   CLANG22_PREFIX is set by hand, which it warns about), before running anything; stop at the first
#   step that fails, naming it; record every step's wall time; and print a gate that tests stage 2's
#   runtime. Every script it runs is a fake that records its environment and arguments, pkgutil too.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/self-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"   # -> SWIFT_VERSION, CLANG22_VERSION

R="$T/repo"; mkdir -p "$R/scripts" "$T/shipyard"
cp "$REPO/self-host.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
W="$T/root/swift/work"
# A Swift toolchain prefix as host_swiftc_stamp, stdlib_layout and toolchain_cmp read it: a frontend that
# runs, swiftc, a staged toolchain's stdlib, builtins. The stdlib files no test varies are the same bytes
# in every prefix, the fake stage-toolchain.sh's included (it writes them as stdlib_files does).
stdlib_files() {  # stdlib_files <lib/swift dir>
  mkdir -p "$1/macosx/SwiftOnoneSupport.swiftmodule" "$1/shims"
  echo onone > "$1/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule"
  echo onone > "$1/macosx/libswiftSwiftOnoneSupport.dylib"
  echo layouts > "$1/macosx/layouts-x86_64.yaml"; echo shims > "$1/shims/module.modulemap"
}
fake_prefix() {  # fake_prefix <prefix> <frontend bytes> <stdlib bytes>
  mkdir -p "$1/bin" "$1/lib/swift/macosx/Swift.swiftmodule" "$1/lib/clang/21/lib/darwin"
  stdlib_files "$1/lib/swift"
  printf '#!/bin/sh\necho "Swift version 6.4 (%s)"\n' "$2" > "$1/bin/swift-frontend"; chmod +x "$1/bin/swift-frontend"
  printf '#!/bin/sh\n' > "$1/bin/swiftc"; chmod +x "$1/bin/swiftc"
  echo "$3" > "$1/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
  echo "$3" > "$1/lib/swift/macosx/libswiftCore.dylib"
  echo builtins > "$1/lib/clang/21/lib/darwin/libclang_rt.osx.a"
}
fake_prefix "$T/seed" seed seed-stdlib
record() {  # the line each fake script logs
  printf 'echo "%s [$*] SWIFT_HOST_TOOLCHAIN=${SWIFT_HOST_TOOLCHAIN:-} SWIFT_HOST_TOOLCHAIN_VERSION=${SWIFT_HOST_TOOLCHAIN_VERSION:-} SWIFT_RUNTIME_OUT=${SWIFT_RUNTIME_OUT:-}" >> "%s/log"\n' "$1" "$T"
}
# Every fake is written by printf and quoted heredocs, never by an echo of a backslash: sh's echo
# (macOS's sh is bash with xpg_echo) and bash's disagree about those, and this file claims either host.
{ echo '#!/bin/sh'; record build-llvm.sh; } > "$R/build-llvm.sh"
{ echo '#!/bin/sh'; record build-builtins.sh; printf "W='%s'\n" "$W"
  cat <<'F'
mkdir -p "$W/builtins-x86/lib/darwin" && echo builtins > "$W/builtins-x86/lib/darwin/libclang_rt.osx.a"
F
} > "$R/build-builtins.sh"
# The compiler a stage builds is the same bytes whatever its host -- a fixed point -- unless FAKE_DRIFT
# names the host whose output differs.
{ echo '#!/bin/sh'; record build-toolchain.sh; printf "W='%s'\n" "$W"
  cat <<'F'
mkdir -p "$W/swift-x86/bin" "$W/swift-x86/share/swift"
f=frontend; case "$SWIFT_HOST_TOOLCHAIN" in *"${FAKE_DRIFT:-none}"*) f=drifted ;; esac
printf '#!/bin/sh\necho "Swift version 6.4 (%s)"\n' "$f" > "$W/swift-x86/bin/swift-frontend"; chmod +x "$W/swift-x86/bin/swift-frontend"
F
} > "$R/build-toolchain.sh"
{ echo '#!/bin/sh'; record build.sh; printf "W='%s'\n" "$W"
  cat <<'F'
[ -z "${FAKE_FAIL_BUILD:-}" ] || exit 3
mkdir -p "$W/stdlib-build/lib/swift/macosx" && echo stdlib > "$W/stdlib-build/lib/swift/macosx/stdlib"
mkdir -p "$SWIFT_RUNTIME_OUT" && echo runtime > "$SWIFT_RUNTIME_OUT/runtime"
F
} > "$R/build.sh"
# stage-toolchain.sh: a prefix whose frontend is --frontend's and whose stdlib is "stdlib" (a stage's own)
# or the seed's (a pre toolchain staged with the seed's lib/swift).
{ echo '#!/bin/sh'; record stage-toolchain.sh
  cat <<'F'
while [ $# -gt 1 ]; do case "$1" in --frontend) fe="$2" ;; --stdlib) sl="$2" ;; --builtins) bi="$2" ;; esac; shift 2; done
p="$1/usr/local/mavergreen/swift-toolchain"; mkdir -p "$p/bin" "$p/lib/swift/macosx/Swift.swiftmodule" "$p/lib/clang/21/lib/darwin"
cp "$fe/bin/swift-frontend" "$p/bin/"; printf '#!/bin/sh\n' > "$p/bin/swiftc"; chmod +x "$p/bin/swiftc"
s=stdlib; [ ! -f "$sl/macosx/libswiftCore.dylib" ] || s="$(cat "$sl/macosx/libswiftCore.dylib")"
echo "$s" > "$p/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"; echo "$s" > "$p/lib/swift/macosx/libswiftCore.dylib"
cp "$bi" "$p/lib/clang/21/lib/darwin/libclang_rt.osx.a"
l="$p/lib/swift"; mkdir -p "$l/macosx/SwiftOnoneSupport.swiftmodule" "$l/shims"
echo onone > "$l/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule"
echo onone > "$l/macosx/libswiftSwiftOnoneSupport.dylib"
echo layouts > "$l/macosx/layouts-x86_64.yaml"; echo shims > "$l/shims/module.modulemap"
F
} > "$R/scripts/stage-toolchain.sh"
chmod +x "$R"/*.sh "$R/scripts/stage-toolchain.sh"
# pkgutil: the installed clang22's receipt, of the release FAKE_CLANG22 names (default: the pinned one;
# none: no receipt), each call logged in $T/pkgutil.log.
mkdir -p "$T/fakebin"
{ echo '#!/bin/sh'; printf 'echo "$*" >> "%s/pkgutil.log"\nv="${FAKE_CLANG22:-%s}"\n' "$T" "$CLANG22_VERSION"
  cat <<'F'
[ "$*" = "--pkg-info dev.mavergreen.clang.clang22" ] || { echo "fake pkgutil: unexpected $*" >&2; exit 64; }
[ "$v" != none ] || { echo "No receipt for 'dev.mavergreen.clang.clang22' found at '/'." >&2; exit 1; }
printf 'package-id: dev.mavergreen.clang.clang22\nversion: %s\nvolume: /\ninstall-time: 1790294636\n' "$v"
F
} > "$T/fakebin/pkgutil"; chmod +x "$T/fakebin/pkgutil"
run() {  # run <name> [self-host.sh args] -- with the environment the fakes need, a fresh log
  _n="$1"; shift; rm -f "$T/log" "$T/pkgutil.log"; : > "$T/log"; _rc=0
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$T/root" SHIPYARD_SCRIPTS="$T/shipyard" \
      MAVERICKS_MODE="${MODE:-native}" SWIFT_HOST_TOOLCHAIN="${SEED:-$T/seed}"
    unset SWIFT_WORK SWIFT_HOST_TOOLCHAIN_VERSION SWIFT_RUNTIME_OUT CLANG22_PREFIX
    if [ -n "${C22:-}" ]; then export CLANG22_PREFIX="$C22"; fi
    sh "$R/self-host.sh" "$@" ) > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
O="<T>/root/swift/self-host"; P=usr/local/mavergreen/swift-toolchain; SW="<T>/root/swift/work"

echo "-- the sequence: LLVM and builtins once, then three stages, each built by the one before"
run seq || fail "self-host.sh failed: $(cat "$T/seq.out")"
cat > "$T/want" <<EOF
build-llvm.sh [] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build-builtins.sh [] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build-toolchain.sh [] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib <T>/seed/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s1/pre] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build.sh [] SWIFT_HOST_TOOLCHAIN=$O/s1/pre/$P SWIFT_HOST_TOOLCHAIN_VERSION=$SWIFT_VERSION-selfhost.s1 SWIFT_RUNTIME_OUT=$O/s1/runtime
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib $SW/stdlib-build/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s1/toolchain] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build-toolchain.sh [] SWIFT_HOST_TOOLCHAIN=$O/s1/toolchain/$P SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib $O/s1/toolchain/$P/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s2/pre] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build.sh [] SWIFT_HOST_TOOLCHAIN=$O/s2/pre/$P SWIFT_HOST_TOOLCHAIN_VERSION=$SWIFT_VERSION-selfhost.s2 SWIFT_RUNTIME_OUT=$O/s2/runtime
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib $SW/stdlib-build/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s2/toolchain] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build-toolchain.sh [] SWIFT_HOST_TOOLCHAIN=$O/s2/toolchain/$P SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib $O/s2/toolchain/$P/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s3/pre] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
build.sh [] SWIFT_HOST_TOOLCHAIN=$O/s3/pre/$P SWIFT_HOST_TOOLCHAIN_VERSION=$SWIFT_VERSION-selfhost.s3 SWIFT_RUNTIME_OUT=$O/s3/runtime
stage-toolchain.sh [--frontend $SW/swift-x86 --stdlib $SW/stdlib-build/lib/swift --builtins $SW/builtins-x86/lib/darwin/libclang_rt.osx.a $O/s3/toolchain] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=
EOF
diff "$T/want" "$T/seq.log" || fail "the sequence differs from the one wanted (above: < wanted, > run)"
grep -qx 'FIXED POINT: stage 2 = stage 3' "$T/seq.out" || fail "no fixed point reported: $(cat "$T/seq.out")"
for n in 1 2 3; do [ ! -e "$T/root/swift/self-host/s$n/pre" ] || fail "left stage $n's pre toolchain"; done
[ "$(wc -l < "$T/root/swift/self-host/times" | tr -d ' ')" = 14 ] || fail "times holds not 14 steps: $(cat "$T/root/swift/self-host/times")"
awk -F '\t' '$1 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$T/root/swift/self-host/times" || fail "a time is not whole seconds: $(cat "$T/root/swift/self-host/times")"
grep -q 'SWIFTC=.*/self-host/s2/toolchain/usr/local/mavergreen/swift-toolchain/bin/swiftc' "$T/seq.out" || fail "did not print the gate's command"
# The gate tests the runtime this run built, never an installed one: both its commands name stage 2's.
RT2="$T/root/swift/self-host/s2/runtime/usr/local/mavergreen/swift-runtime"
grep -q "SWIFT_RUNTIME_PREFIX=$RT2 .*make-selftest.sh" "$T/seq.out" || fail "make-selftest.sh's gate command names no stage-2 runtime: $(cat "$T/seq.out")"
grep -q "SWIFT_RUNTIME_PREFIX=$RT2 sh swift-runtime-selftest/run-selftest.sh --gate" "$T/seq.out" || fail "run-selftest.sh's gate command names no stage-2 runtime: $(cat "$T/seq.out")"
grep -qx -e '--pkg-info dev.mavergreen.clang.clang22' "$T/pkgutil.log" || fail "did not read the installed clang22's receipt"

echo "-- no fixed point: stage 3 differs from stage 2, and that fails, naming the file"
if (FAKE_DRIFT=/s2/ run drift); then fail "passed when stage 3 differs from stage 2"; fi
grep -q 'differ: bin/swift-frontend' "$T/drift.out" || fail "did not name the differing frontend: $(cat "$T/drift.out")"
grep -q 'FAIL: no fixed point' "$T/drift.out" || fail "drift: $(cat "$T/drift.out")"

echo "-- --compare: passes for a prefix that is stage 2's files, fails for one that is not"
fake_prefix "$T/release" frontend stdlib
run same --compare "$T/release" || fail "--compare failed on a prefix that is stage 2's files: $(cat "$T/same.out")"
grep -qx "SAME: $T/release is what this checkout builds" "$T/same.out" || fail "same: $(cat "$T/same.out")"
fake_prefix "$T/other" other-frontend stdlib
if run other --compare "$T/other"; then fail "--compare passed a prefix with another frontend"; fi
grep -q 'differ: bin/swift-frontend' "$T/other.out" || fail "other: $(cat "$T/other.out")"

echo "-- refused before anything runs: cross mode, a seed that is no toolchain, a --compare that is none, bad usage"
refused() {  # refused <name> <exit> <message> -- run <name> exited <exit>, said <message>, and ran nothing
  [ "$rc" -eq "$2" ] && grep -q -e "$3" "$T/$1.out" && [ ! -s "$T/$1.log" ] \
    || fail "$1: exit $rc (wanted $2), ran [$(head -1 "$T/$1.log")]: $(cat "$T/$1.out")"
}
rc=0; (MODE=cross run cross) || rc=$?; refused cross 2 "mode is 'cross'"
rc=0; (SEED="$T/nothing" run noseed) || rc=$?; refused noseed 1 "no Swift toolchain to seed from at $T/nothing"
rc=0; run nocompare --compare "$T/nothing" || rc=$?; refused nocompare 1 "FAIL: --compare names no Swift toolchain: $T/nothing"
# An empty --compare (a --compare "$UNSET") must not run unverified for hours and pass as if none were given.
rc=0; run emptycompare --compare "" || rc=$?; refused emptycompare 2 "usage: self-host.sh"
rc=0; run usage --stages 2 || rc=$?; refused usage 2 "usage: self-host.sh"
# A seed must be one the build can use, all of it: a frontend that runs here (not an arm64 or newer-OS
# one), an executable swiftc (build-toolchain.sh's host compiler), a staged toolchain's stdlib (stage 1's
# pre toolchain is staged with it) -- or build-llvm.sh and build-builtins.sh would run for hours first.
cp -R "$T/seed" "$T/deadseed"; printf '#!/bin/sh\necho "Bad CPU type in executable" >&2; exit 126\n' > "$T/deadseed/bin/swift-frontend"
rc=0; (SEED="$T/deadseed" run deadseed) || rc=$?; refused deadseed 1 "the seed's swift-frontend does not run here: .*Bad CPU type"
cp -R "$T/seed" "$T/noswiftc"; chmod -x "$T/noswiftc/bin/swiftc"
rc=0; (SEED="$T/noswiftc" run noswiftc) || rc=$?; refused noswiftc 1 "no executable $T/noswiftc/bin/swiftc"
cp -R "$T/seed" "$T/nolayout"; rm "$T/nolayout/lib/swift/macosx/layouts-x86_64.yaml"
rc=0; (SEED="$T/nolayout" run nolayout) || rc=$?; refused nolayout 1 "$T/nolayout/lib/swift is no staged toolchain's stdlib"
cp -R "$T/seed" "$T/buildlayout"; mkdir "$T/buildlayout/lib/swift/macosx/x86_64"
cp "$T/buildlayout/lib/swift/macosx/"libswift*.dylib "$T/buildlayout/lib/swift/macosx/x86_64/"   # a stdlib build's
rc=0; (SEED="$T/buildlayout" run buildlayout) || rc=$?; refused buildlayout 1 "$T/buildlayout/lib/swift is no staged toolchain's stdlib"

echo "-- a relative seed is the same seed: build-toolchain.sh, which cds, gets it absolute"
(cd "$T" && SEED=seed run relseed) || fail "relseed: $(cat "$T/relseed.out")"
grep -qx "build-toolchain.sh \[\] SWIFT_HOST_TOOLCHAIN=<T>/seed SWIFT_HOST_TOOLCHAIN_VERSION= SWIFT_RUNTIME_OUT=" "$T/relseed.log" \
  || fail "relseed: build-toolchain.sh got another seed: $(grep '^build-toolchain.sh' "$T/relseed.log" | head -1)"

echo "-- the installed clang22 must be pins.env's: another release, or none, is refused before anything runs"
if (FAKE_CLANG22=22.1.1-mavericks.5 run oldclang); then fail "ran with another clang22 installed"; fi
grep -q "22.1.1-mavericks.5" "$T/oldclang.out" && grep -q "$CLANG22_VERSION" "$T/oldclang.out" && [ ! -s "$T/oldclang.log" ] \
  || fail "oldclang: ran [$(head -1 "$T/oldclang.log")]: $(cat "$T/oldclang.out")"
if (FAKE_CLANG22=none run noclang); then fail "ran with no clang22 receipt"; fi
grep -q "dev.mavergreen.clang.clang22" "$T/noclang.out" && [ ! -s "$T/noclang.log" ] \
  || fail "noclang: ran [$(head -1 "$T/noclang.log")]: $(cat "$T/noclang.out")"

echo "-- a CLANG22_PREFIX set by hand skips the receipt, warning that the bytes may differ"
(FAKE_CLANG22=22.1.1-mavericks.5 C22="$T/my-clang22" run byhand) || fail "refused a hand-set CLANG22_PREFIX: $(cat "$T/byhand.out")"
[ ! -s "$T/pkgutil.log" ] || fail "read a receipt despite a hand-set CLANG22_PREFIX: $(cat "$T/pkgutil.log")"
grep -q "WARNING: CLANG22_PREFIX=$T/my-clang22 .*bytes may differ" "$T/byhand.out" || fail "byhand: no warning: $(cat "$T/byhand.out")"
grep -qx 'FIXED POINT: stage 2 = stage 3' "$T/byhand.out" || fail "byhand: $(cat "$T/byhand.out")"

echo "-- a step that fails stops it there, naming the step"
if (FAKE_FAIL_BUILD=1 run failing); then fail "went on past a failing build.sh"; fi
grep -q 'FAIL: stage 1: its stdlib and runtime (build.sh)' "$T/failing.out" || fail "did not name the failing step: $(cat "$T/failing.out")"
[ "$(grep -c '^build-toolchain.sh' "$T/failing.log")" = 1 ] || fail "ran another stage after the failure"
echo "PASS"
