#!/bin/sh
# platform: macOS-only -- runs the staged x86_64 toolchain under Rosetta
# usage: sh tests/toolchain-smoke-test.sh
#   CI's one run of the toolchain it ships. The STAGED bin/swiftc (scripts/stage-toolchain.sh's payload)
#   compiles and links a hello world whose load commands record minOS 10.9 and SDK 10.9 and whose one
#   rpath is the installed runtime's, then builds the gate corpus through make-selftest.sh's SWIFTC=
#   mode. Nothing it builds is run: the runtime is not installed here, and running them is the real-10.9
#   gate's job. The compiler and linker are x86_64, so on an arm64 host every one of their processes
#   runs translated (INGREDIENTS.md declares it: rosetta:tests/toolchain-smoke-test.sh). SKIPs (77) when
#   nothing is staged or x86_64 code cannot run here; release.yml fails its step on that SKIP. It runs a
#   copy of the staged prefix whose swift-frontend takes the OS's Swift runtime (see below): what the
#   copy compiles and links against -- the staged 10.9 stdlib, SDK defaults and linker -- is unchanged.
#   Env: MAVERICKS_BUILD_ROOT.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"     # -> $SWIFT_BUILD
STAGED="$SWIFT_BUILD/payload/toolchain/usr/local/mavergreen/swift-toolchain/bin/swiftc"
[ -x "$STAGED" ] || {
  echo "no staged toolchain at $STAGED (build-toolchain.sh, then scripts/stage-toolchain.sh) -- skipping"; exit 77; }
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "this host cannot run x86_64 code (no Rosetta) -- skipping"; exit 77; }
. "$REPO/msc.sh"     # -> $SHIPYARD
# The wrapper's own fetch would find the same SDK; naming it once keeps every compile below from asking.
SDKROOT="$(sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
export SDKROOT
T="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT

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
COPY="$T/tc/bin/swiftc"

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
echo "PASS"
