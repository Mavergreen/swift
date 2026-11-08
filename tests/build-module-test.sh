#!/bin/sh
# platform: macOS-only -- runs a Mavergreen swift-toolchain's compiler and lld, and otool on what they build
# usage: SWIFT_HOST_TOOLCHAIN=/usr/local/mavergreen/swift-toolchain-cross sh tests/build-module-test.sh
#   scripts/build-module.sh compiles one Swift module beside the stdlib, as build.sh's step 5b builds the
#   Darwin and ObjectiveC overlays. With the host toolchain SWIFT_HOST_TOOLCHAIN names (run bare through
#   lib.sh's native_host_shim, as build.sh runs it), its stdlib as the resource dir and the 10.9 SDK, a
#   two-file module Tiny must come out as @rpath/libswiftTiny.dylib, compatibility version 1.0.0, minOS
#   10.9, with its .swiftmodule; the stdlib's -define-availability list must be read from the .def it is
#   given, each StdlibDeploymentTarget its SwiftStdlib's versions, as the stdlib's CMake writes it with
#   SWIFT_STDLIB_ENABLE_STRICT_AVAILABILITY (build.sh); with --runtime-floor (test support, which runs only
#   on this runtime) every released SwiftStdlib version, and its StdlibDeploymentTarget, is macOS 10.9, so a
#   10.9 client may call its @available(SwiftStdlib 5.1) declarations, and 9999 stays as it is; a missing
#   source must fail naming the file; --flag must hand a word to the compile; and two build roots must give the same bytes (the prefix maps,
#   and compiler patch 0004, without which an escaping-closure check carried the length of the source's path).
#   SKIPs (77) without SWIFT_HOST_TOOLCHAIN, a shipyard, or a host that can run that toolchain. Reads with
#   OTOOL, NM and STRINGS, else otool, nm and strings, unless those are the Command Line Tools' stubs (OS X
#   10.9 without them): then mavericks-clang-22's llvm-otool, llvm-nm and llvm-strings (CLANG22_PREFIX).
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
# platform: OS X 10.9's /usr/bin/otool is a stub that prints nothing without the Command Line Tools, and
#           an empty install name would read as a failure that checked nothing; clang22's readers then.
if [ -z "${OTOOL:-}" ] && ! otool -L "$HTC/bin/swift-frontend" 2>/dev/null | grep -q libSystem; then
  X="${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}/bin"
  [ -x "$X/llvm-otool" ] || fail "otool reads nothing here and there is no $X/llvm-otool"
  OTOOL="$X/llvm-otool"; NM="${NM:-$X/llvm-nm}"; STRINGS="${STRINGS:-$X/llvm-strings}"
fi
OTOOL="${OTOOL:-otool}"; NM="${NM:-nm}"; STRINGS="${STRINGS:-strings}"; export OTOOL NM
"$OTOOL" -L "$HTC/bin/swift-frontend" | grep -q libSystem || fail "$OTOOL reads nothing"
SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not fetch the 10.9 SDK"
native_host_shim "$HTC" "$T/host" || fail "no host shim from $HTC"
SWIFTC="$T/host/usr/bin/swiftc"; LLD="$HTC/bin/ld64.lld"; export SWIFTC LLD

# The sources and the availability list live in each build root, as build.sh's do: the root is what
# the prefix maps send to /mavergreen-build.
src() {  # src <root> -- lays out Tiny's two files and a .def under <root>/work
  mkdir -p "$1/work/src"
  printf '%s\n' '@available(SwiftStdlib 5.1, *)' 'public func tinyNew() -> Int { return 2 }' \
    'public func tiny() -> Int { return helper() + 1 }' > "$1/work/src/Tiny.swift"
  # withoutActuallyEscaping: its escape check names the source file to the runtime (compiler patch 0004).
  printf '%s\n' 'internal func helper() -> Int { return 41 }' \
    'public func tinyRun(_ f: () -> Int) -> Int { return withoutActuallyEscaping(f) { g in g() } }' > "$1/work/src/Helper.swift"
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
ID="$("$OTOOL" -D "$D" | sed 1d)"
[ "$ID" = "@rpath/libswiftTiny.dylib" ] || fail "install name is '$ID'"
"$OTOOL" -l "$D" | awk '/LC_ID_DYLIB/ { f = 1 } f && /compatibility version/ { print $3; exit }' > "$T/cv"
[ "$(cat "$T/cv")" = "1.0.0" ] || fail "compatibility version is '$(cat "$T/cv")'"
[ "$(DYLDINFO='' macho_minos "$D")" = 10.9 ] || fail "minOS is '$(DYLDINFO='' macho_minos "$D")'"
SY="$("$NM" -a "$D")" || fail "$NM could not read $D"
[ -n "$SY" ] || fail "$NM read no symbols from $D"
[ -z "$(printf '%s\n' "$SY" | awk '$2 == "-" || $2 == "a"')" ] || { printf '%s\n' "$SY" | awk '$2 == "-" || $2 == "a"'; fail "debug stabs in Tiny (listed above)"; }
[ ! -e "$T/r1/work/out/Tiny.swiftmodule/x86_64-apple-macos.swiftsourceinfo" ] || fail "a .swiftsourceinfo, which names the sources' paths"
if "$OTOOL" -L "$D" | grep -q 'libc++'; then "$OTOOL" -L "$D"; fail "Tiny links a libc++ (listed above)"; fi

echo "-- the availability list: the .def's SwiftStdlib lines, StdlibDeploymentTarget the same (strict)"
RSP="$T/r1/work/tmp/availability-macros.rsp"
[ -f "$RSP" ] || fail "no $RSP"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0"' "$RSP" || fail "no SwiftStdlib 5.1: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.15, iOS 13.0"' "$RSP" || fail "5.1 clamped, or not SwiftStdlib 5.1's: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:anyAppleOS 26.0"' "$RSP" || fail "6.2 clamped, or not SwiftStdlib 6.2's: $(cat "$RSP")"
grep -qxF -- '-Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999"' "$RSP" || fail "9999 changed: $(cat "$RSP")"
[ "$(grep -c . "$RSP")" -eq 6 ] || fail "not six definitions: $(cat "$RSP")"
if grep -q 'disable-availability-checking' "$RSP" "$T/log1"; then fail "availability checking is off"; fi

echo "-- --runtime-floor: every released SwiftStdlib version is 10.9 (test support); 9999 is not"
cat > "$T/client.swift" <<'EOF2'
import Tiny
print(tinyNew())
EOF2
client() { "$HTC/bin/swiftc" -typecheck -sdk "$SDK" -target x86_64-apple-macosx10.9 -resource-dir "$HTC/lib/swift" -I "$T/r1/work/out" "$T/client.swift"; }
if client > "$T/log5" 2>&1; then fail "a 10.9 client called a strict Tiny's SwiftStdlib 5.1 declaration"; fi
MAVERICKS_BUILD_ROOT="$T/r1" SWIFT_WORK="$T/r1/work" sh "$BM" --name Tiny --link-name swiftTiny --sdk "$SDK" \
  --resource-dir "$HTC/lib/swift" --availability "$T/r1/work/avail.def" --work "$T/r1/work/tmp" --out "$T/r1/work/out" \
  --runtime-floor -- "$T/r1/work/src/Tiny.swift" "$T/r1/work/src/Helper.swift" > "$T/log5" 2>&1 \
  || { cat "$T/log5"; fail "build-module.sh --runtime-floor failed"; }
for d in 'SwiftStdlib 5.1:macOS 10.9' 'StdlibDeploymentTarget 5.1:macOS 10.9' 'SwiftStdlib 6.2:macOS 10.9' \
         'StdlibDeploymentTarget 6.2:macOS 10.9' 'SwiftStdlib 9999:macOS 9999, iOS 9999' 'StdlibDeploymentTarget 9999:macOS 9999, iOS 9999'; do
  grep -qxF -- "-Xfrontend -define-availability -Xfrontend \"$d\"" "$RSP" || fail "--runtime-floor: no \"$d\": $(cat "$RSP")"
done
[ "$(grep -c . "$RSP")" -eq 6 ] || fail "--runtime-floor: not six definitions: $(cat "$RSP")"
client > "$T/log5" 2>&1 || { cat "$T/log5"; fail "a 10.9 client could not call a --runtime-floor Tiny's SwiftStdlib 5.1 declaration"; }

echo "-- a missing source fails, naming it"
if build "$T/r1" "$T/r1/work/src/Absent.swift" > "$T/log2" 2>&1; then fail "built with a missing source"; fi
grep -q 'Absent.swift' "$T/log2" || fail "did not name the missing file: $(cat "$T/log2")"

echo "-- --flag hands one word to the compile (the test-support modules' own flags)"
printf '%s\n' '#if !TINY_FLAG' '#error("TINY_FLAG unset")' '#endif' > "$T/r1/work/src/Flagged.swift"
if build "$T/r1" "$T/r1/work/src/Flagged.swift" > "$T/log4" 2>&1; then fail "built Flagged.swift without its -D"; fi
grep -q 'TINY_FLAG unset' "$T/log4" || fail "Flagged.swift failed for another reason: $(cat "$T/log4")"
MAVERICKS_BUILD_ROOT="$T/r1" SWIFT_WORK="$T/r1/work" sh "$BM" --name Tiny --link-name swiftTiny --sdk "$SDK" \
  --resource-dir "$HTC/lib/swift" --availability "$T/r1/work/avail.def" --work "$T/r1/work/tmp" --out "$T/r1/work/out" \
  --flag -D --flag TINY_FLAG -- "$T/r1/work/src/Tiny.swift" "$T/r1/work/src/Helper.swift" "$T/r1/work/src/Flagged.swift" \
  > "$T/log4" 2>&1 || { cat "$T/log4"; fail "--flag -D --flag TINY_FLAG did not reach the compile"; }

echo "-- two build roots, the same bytes"
src "$T/r1"; build "$T/r1" > "$T/log1" 2>&1 || { cat "$T/log1"; fail "rebuild in r1 failed"; }
src "$T/r2-elsewhere"; build "$T/r2-elsewhere" > "$T/log3" 2>&1 || { cat "$T/log3"; fail "build in r2 failed"; }
cmp "$D" "$T/r2-elsewhere/work/out/x86_64/libswiftTiny.dylib" || fail "the dylibs differ between roots"
cmp "$M" "$T/r2-elsewhere/work/out/Tiny.swiftmodule/x86_64-apple-macos.swiftmodule" || fail "the swiftmodules differ between roots"
SS="$("$STRINGS" -a "$D" && "$STRINGS" -a "$M")" || fail "$STRINGS could not read Tiny"
[ -n "$SS" ] || fail "$STRINGS read nothing from Tiny"
if printf '%s\n' "$SS" | grep -F "$T"; then fail "a build root's path survives (listed above)"; fi
echo PASS
