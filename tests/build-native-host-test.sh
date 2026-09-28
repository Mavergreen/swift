#!/bin/sh
# platform: macOS-only -- runs build.sh (macOS-only), in native mode, with a fake pkgutil and toolchain
# usage: sh tests/build-native-host-test.sh
#   build.sh's native mode must build with an installed toolchain of this checkout's Swift only: step 1
#   prints the release the toolchain's receipt names, and refuses one of another Swift version, or one no
#   pkg installed unless SWIFT_HOST_TOOLCHAIN_VERSION declares it. Native mode cannot run here (it needs
#   OS X 10.9 and the installed toolchain), so a fake toolchain prefix and a fake pkgutil stand in; NM
#   names no program, so a toolchain step 1 accepts stops there, at the next check, before any SDK fetch.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-native-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"   # -> SWIFT_VERSION
unset SWIFT_HOST_TOOLCHAIN_VERSION

R="$T/root"; mkdir -p "$R/swift/out/llvm/lib/cmake/llvm" "$R/swift/work/llvm-build/bin" "$T/shipyard" "$T/fakebin"
: > "$R/swift/work/llvm-build/bin/ld64.lld"; chmod +x "$R/swift/work/llvm-build/bin/ld64.lld"
H="$T/tc"; mkdir -p "$H/bin" "$H/lib/swift/macosx" "$H/lib/clang/21/include" "$H/lib/clang/21/lib/darwin"
: > "$H/bin/swift-frontend"; : > "$H/bin/clang"; : > "$H/bin/ld64.lld"; : > "$H/lib/clang/21/lib/darwin/libclang_rt.osx.a"
printf '#!/bin/sh\n[ "$1" = --file-info ] || exit 2\necho "$2" >> "%s/pkgutil-args"\ncat "%s/receipt"\n' "$T" "$T" > "$T/fakebin/pkgutil"
chmod +x "$T/fakebin/pkgutil"
receipt() {  # $1 = pkg-version, or nothing for no receipt
  { echo "volume: /"; echo "path: $H/bin/swift-frontend"
    [ -z "${1:-}" ] || printf '\npkgid: dev.mavergreen.swift-toolchain\npkg-version: %s\ninstall-time: 1790384965\n' "$1"; } > "$T/receipt"
}
build() {  # runs build.sh's native mode; its output in $T/out
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=native \
      SWIFT_HOST_TOOLCHAIN="$H" NM="$T/no-nm"
    unset SWIFT_WORK SWIFT_BUILTINS
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
went_past_step_1() { grep -q "FAIL: no $T/no-nm" "$T/out"; }

echo "-- a receipt of this checkout's Swift: printed, and step 1 goes on"
receipt "$SWIFT_VERSION-mavericks.7"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.7 (pkg dev.mavergreen.swift-toolchain)" "$T/out" \
  || fail "did not print the release: $(cat "$T/out")"
went_past_step_1 || fail "stopped before the check after the release's: $(cat "$T/out")"
grep -qxF "$H/bin/swift-frontend" "$T/pkgutil-args" || fail "looked up another file's receipt: $(cat "$T/pkgutil-args")"

echo "-- a receipt of another Swift: refused in step 1"
receipt "0.0.1-mavericks.1"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q "FAIL: the host toolchain at $H is release 0.0.1-mavericks.1" "$T/out" || fail "did not refuse 0.0.1: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain of another Swift: $(cat "$T/out")"; fi

echo "-- no receipt: refused, unless SWIFT_HOST_TOOLCHAIN_VERSION declares this checkout's Swift"
receipt ""
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/out" || fail "did not name the override: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain with no receipt: $(cat "$T/out")"; fi
if ( export SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.7"; build ); then fail "build.sh succeeded with a fake toolchain"; fi
grep -q "release $SWIFT_VERSION-mavericks.7 (declared" "$T/out" || fail "did not print the declared release: $(cat "$T/out")"
went_past_step_1 || fail "stopped at a declared release of this checkout's Swift: $(cat "$T/out")"
echo "PASS"
