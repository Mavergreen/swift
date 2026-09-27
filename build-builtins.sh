#!/bin/sh
# platform: macOS-only -- its compiler is mavericks-clang-22's CROSS toolchain, an arm64 macOS program
# build-builtins.sh — compiler-rt's builtins for OS X 10.9: libclang_rt.osx.a (x86_64, minOS 10.9, the
# 10.9 SDK), from the pinned llvm-project that build-llvm.sh checked out and patched. The runtime links
# it (build.sh, through a -resource-dir, so the driver puts it last) for __isPlatformVersionAtLeast,
# which `#available` calls; the toolchain pkg ships it where its clang looks (scripts/stage-toolchain.sh),
# so C `@available` compiled by that clang links, and so build.sh on OS X 10.9 links the runtime with
# the same bytes CI did. Why each knob: docs/superpowers/spikes/2026-09-27-rt-builtins-FINDINGS.md.
# Run after build-llvm.sh, on a modern Mac only. Output: $SWIFT_WORK/builtins-x86/lib/darwin/libclang_rt.osx.a.
# Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, MAVERICKS_MODE.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD
. "$HERE/msc.sh"    # -> $SHIPYARD (mavericks_mode.sh, fetch_sdk.sh)
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$W"; cd "$W"
[ "${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}" = cross ] || {
  echo "FAIL: build-builtins.sh runs on a modern Mac (its compiler is arm64); on OS X 10.9 build.sh links the installed toolchain's archive"; exit 1; }
test "$(git -C llvm-project rev-parse HEAD 2>/dev/null)" = "$LLVM_SHA" \
  && grep -q "swiftlang's fork refuses every Apple-platform input" llvm-project/lld/MachO/InputFiles.cpp \
  || { echo "FAIL: no patched llvm-project at $LLVM_SHA in $W -- run ./build-llvm.sh"; exit 1; }
X="$(sh "$HERE/fetch-clang22.sh")/bin"
SDK109="$(sh "$SHIPYARD/fetch_sdk.sh")"
B="$W/builtins-x86"
A="$B/lib/darwin/libclang_rt.osx.a"

echo "==> 1. configure compiler-rt's builtins alone, x86_64 / $DEPLOYMENT, against the $DEPLOYMENT SDK (cross compiler: $X)"
# Configured from scratch every run: it takes seconds, and a reused cache would hide a changed knob.
rm -rf "$B"
# CMAKE_OSX_ARCHITECTURES: else CMake's probes add this host's -arch arm64. DARWIN_osx_ARCHS and
#   DARWIN_osx_BUILTIN_ARCHS: compiler-rt's two arch probes, which would add arm64 from the host SDK.
# DARWIN_macosx_CACHED_SYSROOT: else compiler-rt asks xcrun for the HOST SDK and appends it as a second,
#   winning -isysroot. CMAKE_OSX_DEPLOYMENT_TARGET: CMake's --target=x86_64-apple-macos10.9 overrides the
#   -mmacosx-version-min=10.7 compiler-rt hard-codes (clang warns -Woverriding-option; minOS 10.9 ships).
# LLVM_ENABLE_LIBXML2=OFF and CMAKE_IGNORE_PREFIX_PATH=/opt/pkg: hygiene, as in build-llvm.sh.
shipyard-cmake -G Ninja -S llvm-project/compiler-rt -B "$B" \
  -DCMAKE_C_COMPILER="$X/clang" -DCMAKE_CXX_COMPILER="$X/clang++" -DCMAKE_ASM_COMPILER="$X/clang" \
  -DCMAKE_OSX_SYSROOT="$SDK109" -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg -DLLVM_ENABLE_LIBXML2=OFF \
  -DDARWIN_macosx_CACHED_SYSROOT="$SDK109" \
  -DDARWIN_osx_ARCHS="$ARCH" -DDARWIN_osx_BUILTIN_ARCHS="$ARCH" -DSANITIZER_MIN_OSX_VERSION="$DEPLOYMENT" \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
  -DCOMPILER_RT_ENABLE_IOS=OFF -DCOMPILER_RT_ENABLE_WATCHOS=OFF -DCOMPILER_RT_ENABLE_TVOS=OFF \
  -DCOMPILER_RT_ENABLE_XROS=OFF -DCOMPILER_RT_ENABLE_MACCATALYST=OFF

echo "==> 2. build"
ninja -C "$B"

echo "==> 3. check: $ARCH only, minOS and SDK per the pin, and the symbols the runtime links"
[ -f "$A" ] || { echo "FAIL: the build made no $A"; exit 1; }
MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" "$A"
# The two entry points #available calls, which the runtime takes from here, and the four 128-bit
# division helpers every complete builtins archive defines (the spike found all six): a build missing
# any of them is broken. (The runtime imports the four from libSystem: the driver puts this archive last.)
for s in ___isPlatformVersionAtLeast ___isPlatformOrVariantPlatformVersionAtLeast ___divti3 ___modti3 ___udivti3 ___umodti3; do
  nm "$A" | grep -q " T $s\$" || { echo "FAIL: $A does not define $s"; exit 1; }
done
echo "OK: $A ($(wc -c < "$A" | tr -d ' ') bytes)"
