#!/bin/sh
# platform: host-agnostic
# usage: sh tests/self-host-lib-test.sh
#   lib.sh's helpers for building the 10.9-hosted toolchain the same way on both hosts, and for
#   self-hosting it: clang22_prefix must name a mavericks-clang-22 with every tool both modes use, and
#   refuse one without; sdk109_stubs must fetch the pinned 10.9 SDK through shipyard's pin and fetcher
#   and leave its files as the tarball holds them, never running tapi, reusing a cached tarball and a
#   fetched SDK; host_swiftc_stamp must hash what a host swiftc compiles the Swift half with, and
#   swift_half_reset must drop a configured build's cache and Swift-half objects, and nothing else, only
#   when that changed; stdlib_layout must tell a stdlib build's lib/swift from a toolchain's; toolchain_cmp
#   must accept only two prefixes whose built files are the same bytes, naming every one that is not.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
REAL_SHIPYARD="$(. "$REPO/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || { echo "no shipyard -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/self-host-lib.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/lib.sh"

echo "-- clang22_prefix: the native prefix with every tool, a refusal naming a missing one, the cross fetch"
C="$T/clang22"; mkdir -p "$C/bin"
for t in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm; do
  printf '#!/bin/sh\n' > "$C/bin/$t"; chmod +x "$C/bin/$t"
done
[ "$(CLANG22_PREFIX="$C" clang22_prefix native "$REPO")" = "$C" ] || fail "native: not $C"
rm "$C/bin/llvm-libtool-darwin"
if CLANG22_PREFIX="$C" clang22_prefix native "$REPO" > /dev/null 2> "$T/err"; then fail "accepted a clang22 without llvm-libtool-darwin"; fi
grep -q "no $C/bin/llvm-libtool-darwin" "$T/err" || fail "did not name the missing tool: $(cat "$T/err")"
printf '#!/bin/sh\n' > "$C/bin/llvm-libtool-darwin"; chmod +x "$C/bin/llvm-libtool-darwin"
mkdir -p "$T/repo"; printf '#!/bin/sh\necho "%s"\n' "$C" > "$T/repo/fetch-clang22.sh"
[ "$(clang22_prefix cross "$T/repo")" = "$C" ] || fail "cross: not what fetch-clang22.sh printed"
rc=0; clang22_prefix both "$REPO" > /dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "mode 'both': exit $rc, not 2"

echo "-- sdk109_stubs: shipyard's pin and fetcher, the tarball's own bytes, no tapi, the caches reused"
mkdir -p "$T/src/MacOSX10.9.sdk/usr/lib" "$T/shipyard" "$T/bin"
printf 'a stub, as the tarball holds it\n' > "$T/src/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib"
( cd "$T/src" && tar -cf "$T/MacOSX10.9.sdk.tar" MacOSX10.9.sdk )
SUM="$(shasum -a 256 < "$T/MacOSX10.9.sdk.tar" | awk '{ print $1 }')"
# shipyard's real fetcher, so this tests what the build runs; a fake pin points it at the tarball above.
cp "$REAL_SHIPYARD/mavericks_fetch.sh" "$T/shipyard/"
printf 'mav_sdk_pin() { [ "$1" = x86_64 ] && echo "file://%s/MacOSX10.9.sdk.tar %s MacOSX10.9.sdk.tar MacOSX10.9.sdk"; }\n' \
  "$T" "$SUM" > "$T/shipyard/sdk-pins.sh"
# tapi runs only through xcrun (fetch_sdk.sh); a fake xcrun records any call.
printf '#!/bin/sh\necho "xcrun $*" >> "%s/xcrun.log"\nexit 1\n' "$T" > "$T/bin/xcrun"; chmod +x "$T/bin/xcrun"
got="$(PATH="$T/bin:$PATH" SHIPYARD="$T/shipyard" MAVERICKS_SDK_CACHE="$T/cache" sdk109_stubs 2> "$T/fetch.log")" || fail "sdk109_stubs failed"
[ "$got" = "$T/cache/stubs/MacOSX10.9.sdk" ] || fail "printed '$got'"
cmp -s "$T/src/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib" "$got/usr/lib/libSystem.B.dylib" || fail "the stub is not the tarball's bytes"
[ ! -f "$T/xcrun.log" ] || fail "ran xcrun: $(cat "$T/xcrun.log")"
mv "$T/MacOSX10.9.sdk.tar" "$T/away.tar"
[ "$(SHIPYARD="$T/shipyard" MAVERICKS_SDK_CACHE="$T/cache" sdk109_stubs)" = "$got" ] || fail "did not reuse the fetched SDK"
mkdir -p "$T/cache2"; cp "$T/away.tar" "$T/cache2/MacOSX10.9.sdk.tar"
[ "$(SHIPYARD="$T/shipyard" MAVERICKS_SDK_CACHE="$T/cache2" sdk109_stubs 2> "$T/fetch.log")" = "$T/cache2/stubs/MacOSX10.9.sdk" ] \
  || fail "did not reuse the tarball fetch_sdk.sh cached"
mkdir -p "$T/cache3"; printf 'not the pinned tarball\n' > "$T/cache3/MacOSX10.9.sdk.tar"
if SHIPYARD="$T/shipyard" MAVERICKS_SDK_CACHE="$T/cache3" sdk109_stubs > /dev/null 2>&1; then fail "accepted a tarball that fails its checksum"; fi
[ ! -d "$T/cache3/stubs/MacOSX10.9.sdk" ] || fail "extracted a tarball that failed its checksum"

echo "-- host_swiftc_stamp and swift_half_reset: a changed host drops the cache and the Swift half, and only that"
H="$T/host"; mkdir -p "$H/bin" "$H/lib/swift/macosx/Swift.swiftmodule"
echo frontend > "$H/bin/swift-frontend"; echo module > "$H/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
echo core > "$H/lib/swift/macosx/libswiftCore.dylib"
s1="$(host_swiftc_stamp "$H")" || fail "host_swiftc_stamp failed"
[ "$(printf '%s\n' "$s1" | awk '{ print $1 }' | tr '\n' ' ')" = "prefix swift-frontend swiftmodule libswiftCore " ] || fail "stamp roles: $s1"
[ "$(printf '%s\n' "$s1" | sed -n 1p)" = "prefix $H" ] || fail "the stamp does not name the host's prefix: $s1"
cp -R "$H" "$T/host-copy"
[ "$(host_swiftc_stamp "$T/host-copy")" != "$s1" ] || fail "the same bytes at another path left the stamp unchanged (CMake would drop its cache itself)"
echo module2 > "$H/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
s2="$(host_swiftc_stamp "$H")"; [ "$s1" != "$s2" ] || fail "a changed stdlib module left the stamp unchanged"
rm "$H/lib/swift/macosx/libswiftCore.dylib"
if host_swiftc_stamp "$H" > /dev/null 2> "$T/err"; then fail "stamped a host with no libswiftCore.dylib"; fi
grep -q 'libswiftCore.dylib' "$T/err" || fail "did not name the missing dylib: $(cat "$T/err")"
S="$T/swift-x86"; mkdir -p "$S/CMakeFiles" "$S/SwiftCompilerSources" "$S/lib"
: > "$S/CMakeCache.txt"; : > "$S/SwiftCompilerSources/AST.o"; : > "$S/lib/Driver.o"
swift_half_reset "$S" "$s1" > "$T/out" || fail "swift_half_reset failed"
[ ! -e "$S/CMakeCache.txt" ] && [ ! -e "$S/CMakeFiles" ] && [ ! -e "$S/SwiftCompilerSources/AST.o" ] \
  || fail "an unrecorded host left the cache or the Swift half"
[ -f "$S/lib/Driver.o" ] || fail "removed a C++ object"
grep -q 'configuring it afresh' "$T/out" || fail "did not say why: $(cat "$T/out")"
: > "$S/CMakeCache.txt"; : > "$S/SwiftCompilerSources/AST.o"; printf '%s\n' "$s1" > "$S/mavergreen-host.stamp"
swift_half_reset "$S" "$s1" > "$T/out"
[ -f "$S/CMakeCache.txt" ] && [ -f "$S/SwiftCompilerSources/AST.o" ] && [ ! -s "$T/out" ] || fail "the same host reset the build"
swift_half_reset "$S" "$s2" > /dev/null
[ ! -e "$S/CMakeCache.txt" ] && [ ! -e "$S/SwiftCompilerSources/AST.o" ] && [ ! -e "$S/mavergreen-host.stamp" ] \
  || fail "a changed host left the cache, the Swift half or the old stamp"
rm -rf "$T/never"; swift_half_reset "$T/never" "$s1" || fail "refused a build dir that does not exist yet"
if swift_half_reset "$S" "" 2> /dev/null; then fail "accepted an empty stamp"; fi

echo "-- stdlib_layout: a stdlib build, a toolchain, and neither"
B="$T/b/lib/swift"; P="$T/p/lib/swift"
for d in "$B" "$P"; do
  mkdir -p "$d/macosx/Swift.swiftmodule" "$d/macosx/SwiftOnoneSupport.swiftmodule" "$d/shims"; : > "$d/macosx/layouts-x86_64.yaml"
done
mkdir -p "$B/macosx/x86_64"; : > "$B/macosx/x86_64/libswiftCore.dylib"; : > "$B/macosx/x86_64/libswiftSwiftOnoneSupport.dylib"
: > "$P/macosx/libswiftCore.dylib"; : > "$P/macosx/libswiftSwiftOnoneSupport.dylib"
[ "$(stdlib_layout "$B")" = build ] || fail "a stdlib build's lib/swift is not 'build'"
[ "$(stdlib_layout "$P")" = toolchain ] || fail "a toolchain's lib/swift is not 'toolchain'"
rm "$P/macosx/libswiftSwiftOnoneSupport.dylib"
if stdlib_layout "$P" > /dev/null 2>&1; then fail "accepted a lib/swift with one dylib"; fi
rm -r "$B/shims"
if stdlib_layout "$B" > /dev/null 2> "$T/err"; then fail "accepted a lib/swift with no shims"; fi
grep -q 'has no shims' "$T/err" || fail "did not name shims: $(cat "$T/err")"

echo "-- toolchain_cmp: the built files, byte for byte, every difference named"
for x in a b; do
  mkdir -p "$T/t$x/bin" "$T/t$x/lib/swift/macosx/Swift.swiftmodule" "$T/t$x/lib/swift/shims" "$T/t$x/lib/clang/21/lib/darwin" \
    "$T/t$x/lib/clang/21/include" "$T/t$x/share/swift/diagnostics" "$T/t$x/share/doc" "$T/t$x/libexec/mavergreen-swift"
  for f in bin/swift-frontend bin/clang bin/ld64.lld lib/swift/macosx/libswiftCore.dylib \
           lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule lib/swift/shims/module.modulemap \
           lib/clang/21/lib/darwin/libclang_rt.osx.a share/swift/diagnostics/en.db; do echo "$f" > "$T/t$x/$f"; done
  echo "$x" > "$T/t$x/share/doc/NOTICE"; echo "$x" > "$T/t$x/libexec/mavergreen-swift/fetch_sdk.sh"; echo "$x" > "$T/t$x/lib/clang/21/include/stdint.h"
done
[ "$(toolchain_release_files "$T/ta" | wc -l | tr -d ' ')" = 8 ] || fail "release files: $(toolchain_release_files "$T/ta")"
[ "$(toolchain_cmp "$T/ta" "$T/tb")" = "same: 8 files" ] || fail "two equal prefixes (docs, wrappers and headers aside): $(toolchain_cmp "$T/ta" "$T/tb")"
echo changed > "$T/tb/lib/clang/21/lib/darwin/libclang_rt.osx.a"; echo extra > "$T/tb/lib/swift/macosx/abi.json"; rm "$T/tb/bin/ld64.lld"
if toolchain_cmp "$T/ta" "$T/tb" > "$T/out"; then fail "accepted two prefixes that differ"; fi
grep -qx 'differ: lib/clang/21/lib/darwin/libclang_rt.osx.a' "$T/out" || fail "did not name the changed archive: $(cat "$T/out")"
grep -qx "only in $T/tb: lib/swift/macosx/abi.json" "$T/out" || fail "did not name the extra file: $(cat "$T/out")"
grep -qx "only in $T/ta: bin/ld64.lld" "$T/out" || fail "did not name the missing ld64.lld: $(cat "$T/out")"
mkdir -p "$T/empty1" "$T/empty2"
if toolchain_cmp "$T/empty1" "$T/empty2" > /dev/null 2>&1; then fail "two empty prefixes compared equal"; fi
echo "PASS"
