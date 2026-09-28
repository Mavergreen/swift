#!/bin/sh
# platform: macOS-only -- runs a staged toolchain: the native one's x86_64 tools under Rosetta, the cross one's arm64 tools natively
# usage: sh tests/toolchain-smoke-test.sh                    (the native toolchain, swift-toolchain)
#        STAGE_HOST=arm64 sh tests/toolchain-smoke-test.sh   (the cross toolchain, swift-toolchain-cross)
#   CI's one run of each toolchain it ships. The STAGED bin/swiftc (scripts/stage-toolchain.sh's payload)
#   compiles and links a hello world whose load commands record minOS 10.9 and SDK 10.9 and whose one
#   rpath is the installed runtime's, then builds the gate corpus through make-selftest.sh's SWIFTC=
#   mode, and its clang links C that uses @available (its builtins archive is where the driver looks).
#   Its bare clang and clang++, given no flags, must build for 10.9 on this modern host too (clang.cfg
#   and clang++.cfg). Nothing it builds is run: the runtime is not installed here, and running them is
#   the real-10.9 gate's job. The native toolchain's compiler and linker are x86_64, so on an arm64 host
#   every one of their processes runs translated (INGREDIENTS.md declares it:
#   rosetta:tests/toolchain-smoke-test.sh); the cross toolchain's are arm64 and run natively. SKIPs (77)
#   when nothing is staged, or when this host cannot run the staged tools (x86_64 without Rosetta, or
#   arm64 on an Intel Mac); release.yml fails its step on that SKIP. For the native toolchain it runs a
#   copy of the staged prefix whose swift-frontend takes the OS's Swift runtime (see below): what the
#   copy compiles and links against -- the staged 10.9 stdlib, SDK defaults and linker -- is unchanged.
#   Env: MAVERICKS_BUILD_ROOT, STAGE_HOST.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"     # -> $SWIFT_BUILD, toolchain_host_select
HOST="${STAGE_HOST:-x86_64}"
toolchain_host_select "$HOST" || exit 2
STAGED="$SWIFT_BUILD/payload/$TH_PAYLOAD/usr/local/mavergreen/$TH_PRODUCT/bin/swiftc"
[ -x "$STAGED" ] || {
  echo "no staged toolchain at $STAGED (build-toolchain.sh --host $HOST, then STAGE_HOST=$HOST scripts/stage-toolchain.sh) -- skipping"; exit 77; }
if [ "$HOST" = x86_64 ]; then
  arch -x86_64 /usr/bin/true 2>/dev/null || { echo "this host cannot run x86_64 code (no Rosetta) -- skipping"; exit 77; }
else
  [ "$(uname -m)" = arm64 ] || { echo "this host is not an Apple-silicon Mac, so it cannot run the cross toolchain -- skipping"; exit 77; }
fi
. "$REPO/msc.sh"     # -> $SHIPYARD
# The wrapper's own fetch would find the same SDK; naming it once keeps every compile below from asking.
SDKROOT="$(sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
export SDKROOT
T="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT

if [ "$HOST" = x86_64 ]; then
  # platform: on a modern macOS, CoreFoundation, Security and CoreServices load the OS's own Swift runtime
  #           (/usr/lib/swift) into every process linking them, so the shipped swift-frontend, whose Swift
  #           code binds @rpath/libswiftCore.dylib to the toolchain's own 10.9 runtime (compiler patch
  #           0002), holds two Swift runtimes there and crashes (CI run 36297440367: a segfault in the SIL
  #           optimizer, after objc's "Class ... is implemented in both" warnings). OS X 10.9 has no OS
  #           Swift runtime, so there the shipped layout runs on one. Here the copy's frontend names
  #           /usr/lib/swift instead, and so runs on one runtime too, the OS's.
  cp -R "$(dirname "$(dirname "$STAGED")")" "$T/tc"
  install_name_tool -rpath @loader_path/../lib/swift/macosx /usr/lib/swift "$T/tc/bin/swift-frontend" \
    || fail "cannot re-point the copied swift-frontend's rpath @loader_path/../lib/swift/macosx at /usr/lib/swift"
  TC="$T/tc"
else
  # The cross toolchain's frontend already runs on the OS's /usr/lib/swift (no compiler patch 0002), so
  # the staged prefix itself runs.
  TC="$(dirname "$(dirname "$STAGED")")"
fi
COPY="$TC/bin/swiftc"

echo "-- the staged swiftc compiles and links a hello world ($STAGED, run as $COPY; SDK $SDKROOT)"
printf 'print("hello from Mavericks Swift")\n' > "$T/hello.swift"
"$COPY" "$T/hello.swift" -o "$T/hello" || fail "the staged swiftc could not compile and link a hello world"
[ -f "$T/hello" ] || fail "the staged swiftc exited 0 but wrote no $T/hello"

echo "-- for OS X 10.9, against the 10.9 SDK"
dyld_info -platform "$T/hello"
plat="$(dyld_info -platform "$T/hello" | awk '$1 == "macOS" { print $2, $3 }')"
[ "$plat" = "10.9 10.9" ] || fail "minOS and SDK are '$plat', not '10.9 10.9'"

echo "-- its one rpath is the installed runtime's"
rp="$(otool -l "$T/hello" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2 }')"
echo "$rp"
[ "$rp" = /usr/local/mavergreen/swift-runtime/lib/swift ] || fail "the rpaths are [$rp], not the runtime's alone"

echo "-- it builds the gate corpus through make-selftest.sh"
SWIFTC="$COPY" DIST="$T/dist" sh "$REPO/make-selftest.sh" || fail "make-selftest.sh could not build the gate corpus"
tar -xzf "$T/dist/swift-runtime-selftest.tar.gz" -C "$T" || fail "cannot unpack the self-test bundle"
ls "$T/swift-runtime-selftest/bin"
for b in thorough_test thorough_test-Onone; do
  [ -f "$T/swift-runtime-selftest/bin/$b" ] || fail "make-selftest.sh built no bin/$b"
done

echo "-- the staged clang links C that uses @available (its builtins archive, where the driver looks)"
printf '%s\n' '#include <stdio.h>' 'int main(void) {' \
  '  if (__builtin_available(macOS 10.12, *)) puts("10.12 or later"); else puts("before 10.12");' \
  '  return 0;' '}' > "$T/avail.c"
# No -Wl,-U here: the staged bin/clang.cfg (toolchain/clang.cfg) lets compiler-rt's weak reference to
# _availability_version_check, which the 10.9 SDK does not declare, stay undefined.
"$TC/bin/clang" -isysroot "$SDKROOT" -fuse-ld=lld "$T/avail.c" -o "$T/avail" \
  || fail "the staged clang could not link C that uses @available"
nm "$T/avail" | grep -q ' [Tt] ___isPlatformVersionAtLeast$' \
  || fail "___isPlatformVersionAtLeast did not come from the staged builtins archive"
plat="$(dyld_info -platform "$T/avail" | awk '$1 == "macOS" { print $2, $3 }')"
[ "$plat" = "10.9 10.9" ] || fail "the C program records minOS and SDK '$plat', not '10.9 10.9'"

echo "-- bare clang and clang++, given no flags, build for OS X 10.9 on this host too (clang.cfg, clang++.cfg)"
printf 'int main(void) { return 0; }\n' > "$T/bare.c"
for d in clang clang++; do
  env -u SDKROOT "$TC/bin/$d" -x c -c "$T/bare.c" -o "$T/bare-$d.o" || fail "bare $d could not compile"
  v="$(otool -l "$T/bare-$d.o" | awk '$1 == "cmd" { c = $2 } c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }')"
  [ "$v" = 10.9 ] || fail "bare $d built for macOS '$v', not 10.9"
done
echo "PASS"
