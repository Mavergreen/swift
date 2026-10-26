#!/bin/sh
# platform: macOS-only -- runs a toolchain natively: the cross one's arm64 tools on an Apple-silicon Mac, the native one's x86_64 tools on OS X 10.9
# usage: STAGE_HOST=arm64 sh tests/toolchain-smoke-test.sh   (the STAGED cross toolchain, swift-toolchain-cross)
#        sh tests/toolchain-smoke-test.sh                    (the INSTALLED native toolchain, swift-toolchain, on 10.9)
#   CI's one run of each toolchain it ships, where it runs: the cross toolchain in build-cross, on the
#   arm64 runner; the native one in vm-test, on Mac OS X 10.9 (Mavergreen/mavericks-vm), after its pkg is
#   installed. Its bin/swiftc compiles and links a hello world whose load commands record minOS 10.9 and
#   SDK 10.9 and whose one rpath is the installed runtime's, then builds the gate corpus through
#   make-selftest.sh's SWIFTC= mode, and its clang links C that uses @available (its builtins archive is
#   where the driver looks). Its bare clang and clang++, given no flags, must build for 10.9 (clang.cfg and
#   clang++.cfg), and its bare clang, given only the SDK, must link C with the toolchain's own ld64.lld (its
#   default linker) and none of the flags a newer ld64 takes (its pinned host linker version):
#   6.4.0-mavericks.8's clang ran the host's ld, with -no_deduplicate, which OS X 10.9's refuses. Nothing it
#   builds is run here: running them is the gate's job. SKIPs (77) when there is no such toolchain, or when
#   this host cannot run it natively (the cross one off Apple silicon, the native one off x86_64 or
#   translated); release.yml fails its step on that SKIP. Load commands are read with otool and nm (OTOOL
#   and NM), or where those are Command Line Tools stubs (OS X 10.9), mavericks-clang-22's llvm-otool and
#   llvm-nm (CLANG22_PREFIX).
#   Env: MAVERICKS_BUILD_ROOT, STAGE_HOST, SMOKE_TOOLCHAIN (the installed native prefix, default
#   /usr/local/mavergreen/swift-toolchain), OTOOL, NM, CLANG22_PREFIX.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"     # -> $SWIFT_BUILD, toolchain_host_select, macho_version, macho_rpaths
HOST="${STAGE_HOST:-x86_64}"
toolchain_host_select "$HOST" || exit 2
if [ "$HOST" = arm64 ]; then
  STAGED="$SWIFT_BUILD/payload/$TH_PAYLOAD/usr/local/mavergreen/$TH_PRODUCT/bin/swiftc"
  [ -x "$STAGED" ] || {
    echo "no staged toolchain at $STAGED (build-toolchain.sh --host arm64, then STAGE_HOST=arm64 scripts/stage-toolchain.sh) -- skipping"; exit 77; }
  [ "$(uname -m)" = arm64 ] || { echo "this host is not an Apple-silicon Mac, so it cannot run the cross toolchain -- skipping"; exit 77; }
  # The cross toolchain's frontend runs on the OS's /usr/lib/swift (no compiler patch 0002).
  TC="$(dirname "$(dirname "$STAGED")")"
  . "$REPO/msc.sh"     # -> $SHIPYARD
  SDKROOT="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
else
  TC="${SMOKE_TOOLCHAIN:-/usr/local/mavergreen/$TH_PRODUCT}"
  [ -x "$TC/bin/swiftc" ] || { echo "no installed native toolchain at $TC -- skipping"; exit 77; }
  # platform: the native frontend binds its own bundled 10.9 runtime (compiler patch 0002); a modern macOS
  #           loads its own Swift runtime into the same process and crashes it, so it runs on 10.9 only.
  [ "$(uname -m)" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" != 1 ] \
    || { echo "this host does not run x86_64 code natively -- skipping"; exit 77; }
  # The toolchain's own SDK fetch, as its swiftc runs it: no shipyard on the user's Mac.
  SDKROOT="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$TC/libexec/mavergreen-swift/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
fi
export SDKROOT
# platform: OS X 10.9 without the Command Line Tools has only stubs for otool and nm. Never dyld_info for the
#           SDK: it shows the minOS where the SDK is 0 (lib.sh's macho_version).
if [ -z "${OTOOL:-}" ] && ! otool -l /bin/sh >/dev/null 2>&1; then
  C22="${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}/bin"
  OTOOL="$C22/llvm-otool"; NM="${NM:-$C22/llvm-nm}"
  [ -x "$OTOOL" ] && [ -x "$NM" ] || fail "no working otool and nm, and no $OTOOL and $NM (mavericks-clang-22's native pkg has them)"
fi
OTOOL="${OTOOL:-otool}"; NM="${NM:-nm}"; DYLDINFO=""
export DYLDINFO OTOOL NM
T="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT
COPY="$TC/bin/swiftc"
plat() { macho_version "$1" || fail "could not read $1's minOS and SDK"; }

echo "-- its swiftc compiles and links a hello world ($COPY; SDK $SDKROOT)"
printf 'print("hello from Mavericks Swift")\n' > "$T/hello.swift"
"$COPY" "$T/hello.swift" -o "$T/hello" || fail "its swiftc could not compile and link a hello world"
[ -f "$T/hello" ] || fail "its swiftc exited 0 but wrote no $T/hello"

echo "-- for OS X 10.9, against the 10.9 SDK"
p="$(plat "$T/hello")"; echo "$p"
[ "$p" = "10.9 10.9" ] || fail "minOS and SDK are '$p', not '10.9 10.9'"

echo "-- its one rpath is the installed runtime's"
rp="$(macho_rpaths "$T/hello")" || fail "could not read $T/hello's rpaths"
echo "$rp"
[ "$rp" = /usr/local/mavergreen/swift-runtime/lib/swift ] || fail "the rpaths are [$rp], not the runtime's alone"

echo "-- it builds the gate corpus through make-selftest.sh"
SWIFTC="$COPY" DIST="$T/dist" sh "$REPO/make-selftest.sh" || fail "make-selftest.sh could not build the gate corpus"
tar -xzf "$T/dist/swift-runtime-selftest.tar.gz" -C "$T" || fail "cannot unpack the self-test bundle"
ls "$T/swift-runtime-selftest/bin"
for b in thorough_test thorough_test-Onone; do
  [ -f "$T/swift-runtime-selftest/bin/$b" ] || fail "make-selftest.sh built no bin/$b"
done

echo "-- its clang links C that uses @available (its builtins archive, where the driver looks)"
printf '%s\n' '#include <stdio.h>' 'int main(void) {' \
  '  if (__builtin_available(macOS 10.12, *)) puts("10.12 or later"); else puts("before 10.12");' \
  '  return 0;' '}' > "$T/avail.c"
# No -Wl,-U here: its bin/clang.cfg (toolchain/clang.cfg) lets compiler-rt's weak reference to
# _availability_version_check, which the 10.9 SDK does not declare, stay undefined.
"$TC/bin/clang" -isysroot "$SDKROOT" -fuse-ld=lld "$T/avail.c" -o "$T/avail" \
  || fail "its clang could not link C that uses @available"
"${NM:-nm}" "$T/avail" | grep -q ' [Tt] ___isPlatformVersionAtLeast$' \
  || fail "___isPlatformVersionAtLeast did not come from its builtins archive"
p="$(plat "$T/avail")"
[ "$p" = "10.9 10.9" ] || fail "the C program records minOS and SDK '$p', not '10.9 10.9'"

echo "-- bare clang and clang++, given no flags, build for OS X 10.9 (clang.cfg, clang++.cfg)"
printf 'int main(void) { return 0; }\n' > "$T/bare.c"
for d in clang clang++; do
  # platform: 10.9's env has no -u.
  ( unset SDKROOT; "$TC/bin/$d" -x c -c "$T/bare.c" -o "$T/bare-$d.o" ) || fail "bare $d could not compile"
  v="$("${OTOOL:-otool}" -l "$T/bare-$d.o" | awk '$1 == "cmd" { c = $2 } c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }')"
  [ "$v" = 10.9 ] || fail "bare $d built for macOS '$v', not 10.9"
done
echo "-- bare clang links C with the toolchain's own ld64.lld, given only the SDK"
printf 'int main(void) { return 0; }\n' > "$T/hi.c"
LD="$("$TC/bin/clang" -isysroot "$SDKROOT" -### "$T/hi.c" -o "$T/hi" 2>&1 | tail -1 | sed "s/^ *//")" || fail "bare clang -### failed"
echo "$LD" | cut -c1-160
BIN="$(CDPATH='' cd -P -- "$TC/bin" && pwd -P)"
case "$LD" in "\"$BIN/ld64.lld\""*) ;; *) fail "bare clang links with $(echo "$LD" | awk '{ print $1 }'), not $BIN/ld64.lld" ;; esac
case "$LD" in *'"-no_deduplicate"'*) fail "bare clang passes -no_deduplicate, a flag for an ld64 of 262 or later" ;; esac
"$TC/bin/clang" -isysroot "$SDKROOT" "$T/hi.c" -o "$T/hi" || fail "bare clang could not link C"
p="$(plat "$T/hi")"
[ "$p" = "10.9 10.9" ] || fail "bare clang's program records minOS and SDK '$p', not '10.9 10.9'"
echo "PASS"
