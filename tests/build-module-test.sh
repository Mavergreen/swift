#!/bin/sh
# platform: macOS-only -- runs a Mavergreen swift-toolchain's compiler and lld, and otool on what they build
# usage: SWIFT_HOST_TOOLCHAIN=/usr/local/mavergreen/swift-toolchain-cross sh tests/build-module-test.sh
#   scripts/build-module.sh compiles one Swift module beside the stdlib, as build.sh's step 5b builds the
#   Darwin and ObjectiveC overlays. With the host toolchain SWIFT_HOST_TOOLCHAIN names (run bare through
#   lib.sh's native_host_shim, as build.sh runs it), its stdlib as the resource dir and the 10.9 SDK, a
#   two-file module Tiny must come out as @rpath/libswiftTiny.dylib, compatibility version 1.0.0, minOS
#   10.9, with its .swiftmodule; the stdlib's -define-availability list must be read from the .def it is
#   given, with each StdlibDeploymentTarget clamped to 10.9 as the stdlib's CMake clamps it; a missing
#   source must fail naming the file; and two build roots must give the same bytes (the prefix maps).
#   SKIPs (77) without SWIFT_HOST_TOOLCHAIN, a shipyard, or a host that can run that toolchain.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BM="$REPO/scripts/build-module.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
HTC="${SWIFT_HOST_TOOLCHAIN:-}"
[ -n "$HTC" ] && [ -x "$HTC/bin/swift-frontend" ] || { echo "no SWIFT_HOST_TOOLCHAIN -- skipping"; exit 77; }
"$HTC/bin/swift-frontend" -version >/dev/null 2>&1 || { echo "this host cannot run $HTC -- skipping"; exit 77; }
. "$REPO/msc.sh" 2>/dev/null || { echo "no shipyard -- skipping"; exit 77; }
[ -f "$BM" ] || fail "no $BM"
T="$(mktemp -d "${TMPDIR:-/tmp}/build-module.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/lib.sh"
SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not fetch the 10.9 SDK"
native_host_shim "$HTC" "$T/host" || fail "no host shim from $HTC"
SWIFTC="$T/host/usr/bin/swiftc"; LLD="$HTC/bin/ld64.lld"; export SWIFTC LLD

# The sources and the availability list live in each build root, as build.sh's do: the root is what
# the prefix maps send to /mavergreen-build.
src() {  # src <root> -- lays out Tiny's two files and a .def under <root>/work
  mkdir -p "$1/work/src"
  printf '%s\n' '@available(SwiftStdlib 5.1, *)' 'public func tinyNew() -> Int { return 2 }' \
    'public func tiny() -> Int { return helper() + 1 }' > "$1/work/src/Tiny.swift"
  printf '%s\n' 'internal func helper() -> Int { return 41 }' > "$1/work/src/Helper.swift"
  printf '%s\n' '# comment' '' 'SwiftStdlib 9999:macOS 9999, iOS 9999' \
    'SwiftStdlib 5.1:macOS 10.15, iOS 13.0' 'SwiftStdlib 6.2:anyAppleOS 26.0' > "$1/work/avail.def"
}
build() {  # build <root> [<extra source>] -- Tiny into <root>/work/out
  r="$1"; shift
  MAVERICKS_BUILD_ROOT="$r" SWIFT_WORK="$r/work" sh "$BM" --name Tiny --link-name swiftTiny --sdk "$SDK" \
    --resource-dir "$HTC/lib/swift" --availability "$r/work/avail.def" --work "$r/work/tmp" --out "$r/work/out" \
    -- "$r/work/src/Tiny.swift" "$r/work/src/Helper.swift" "$@"
}

echo "-- Tiny: @rpath install name, compatibility 1.0.0, minOS 10.9, a .swiftmodule"
src "$T/r1"
build "$T/r1" > "$T/log1" 2>&1 || { cat "$T/log1"; fail "build-module.sh failed"; }
D="$T/r1/work/out/x86_64/libswiftTiny.dylib"
M="$T/r1/work/out/Tiny.swiftmodule/x86_64-apple-macos.swiftmodule"
[ -f "$D" ] || fail "no $D"
[ -f "$M" ] || fail "no $M"
ID="$(otool -D "$D" | sed 1d)"
[ "$ID" = "@rpath/libswiftTiny.dylib" ] || fail "install name is '$ID'"
otool -l "$D" | awk '/LC_ID_DYLIB/ { f = 1 } f && /compatibility version/ { print $3; exit }' > "$T/cv"
[ "$(cat "$T/cv")" = "1.0.0" ] || fail "compatibility version is '$(cat "$T/cv")'"
[ "$(macho_minos "$D")" = 10.9 ] || fail "minOS is '$(macho_minos "$D")'"
[ -z "$(nm -a "$D" | awk '$2 == "-" || $2 == "a"')" ] || { nm -a "$D" | awk '$2 == "-" || $2 == "a"'; fail "debug stabs in Tiny (listed above)"; }
[ ! -e "$T/r1/work/out/Tiny.swiftmodule/x86_64-apple-macos.swiftsourceinfo" ] || fail "a .swiftsourceinfo, which names the sources' paths"
if otool -L "$D" | grep -q 'libc++'; then otool -L "$D"; fail "Tiny links a libc++ (listed above)"; fi

echo "-- the availability list: the .def's SwiftStdlib lines, StdlibDeploymentTarget clamped to 10.9"
RSP="$T/r1/work/tmp/availability-macros.rsp"
[ -f "$RSP" ] || fail "no $RSP"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0"' "$RSP" || fail "no SwiftStdlib 5.1: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.9"' "$RSP" || fail "5.1 not clamped: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 10.9"' "$RSP" || fail "6.2 not clamped: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999"' "$RSP" || fail "9999 changed: $(cat "$RSP")"
[ "$(grep -c . "$RSP")" -eq 6 ] || fail "not six definitions: $(cat "$RSP")"
if grep -q 'disable-availability-checking' "$RSP" "$T/log1"; then fail "availability checking is off"; fi

echo "-- a missing source fails, naming it"
if build "$T/r1" "$T/r1/work/src/Absent.swift" > "$T/log2" 2>&1; then fail "built with a missing source"; fi
grep -q 'Absent.swift' "$T/log2" || fail "did not name the missing file: $(cat "$T/log2")"

echo "-- two build roots, the same bytes"
src "$T/r1"; build "$T/r1" > "$T/log1" 2>&1 || { cat "$T/log1"; fail "rebuild in r1 failed"; }
src "$T/r2-elsewhere"; build "$T/r2-elsewhere" > "$T/log3" 2>&1 || { cat "$T/log3"; fail "build in r2 failed"; }
cmp "$D" "$T/r2-elsewhere/work/out/x86_64/libswiftTiny.dylib" || fail "the dylibs differ between roots"
cmp "$M" "$T/r2-elsewhere/work/out/Tiny.swiftmodule/x86_64-apple-macos.swiftmodule" || fail "the swiftmodules differ between roots"
if strings -a "$D" "$M" | grep -F "$T"; then fail "a build root's path survives (listed above)"; fi
echo PASS
