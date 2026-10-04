#!/bin/sh
# platform: macOS-only -- mavericks-clang-22 compiles it: the CROSS toolchain on a modern arm64 Mac, the NATIVE one on OS X 10.9
# build-builtins.sh — compiler-rt's builtins for OS X 10.9: libclang_rt.osx.a (x86_64, minOS 10.9, the
# 10.9 SDK), from the pinned llvm-project that build-llvm.sh checked out and patched. The runtime links
# it (build.sh, through a -resource-dir, so the driver puts it last) for __isPlatformVersionAtLeast,
# which `#available` calls; the toolchain pkgs ship it where their clang looks (scripts/stage-toolchain.sh),
# so C `@available` compiled by that clang links (its clang.cfg passes -Wl,-U,__availability_version_check:
# see toolchain/clang.cfg). Why each knob: docs/superpowers/spikes/2026-09-27-rt-builtins-FINDINGS.md.
# One recipe, two modes (MAVERICKS_MODE, else shipyard's mavericks_mode.sh), the same bytes from both:
#   cross (CI, a modern Mac): mavericks-clang-22's CROSS toolchain (fetch-clang22.sh);
#   native (OS X 10.9, self-host.sh): its NATIVE toolchain (CLANG22_PREFIX, default
#     /usr/local/mavergreen/clang22).
#   Both: that toolchain's llvm-libtool-darwin and llvm-lipo make the archive, and its llvm-nm, llvm-lipo
#   and llvm-ar read it back, so the archive is the same bytes on both hosts (Apple's libtool differs
#   between them: T4 spike Q1).
# Run after build-llvm.sh. Output: $SWIFT_WORK/builtins-x86/lib/darwin/libclang_rt.osx.a.
# Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, MAVERICKS_MODE, CLANG22_PREFIX.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, prefix_map_flags, clang22_prefix
. "$HERE/msc.sh"    # -> $SHIPYARD (mavericks_mode.sh, fetch_sdk.sh)
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$W"; cd "$W"
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"
case "$MODE" in cross|native) ;; *) echo "FAIL: mode '$MODE' is neither cross nor native"; exit 1 ;; esac
test "$(git -C llvm-project rev-parse HEAD 2>/dev/null)" = "$LLVM_SHA" \
  && grep -q "swiftlang's fork refuses every Apple-platform input" llvm-project/lld/MachO/InputFiles.cpp \
  && grep -q 'Mavergreen: extra flags for the Darwin builtins' llvm-project/compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake \
  || { echo "FAIL: no patched llvm-project at $LLVM_SHA in $W -- run ./build-llvm.sh"; exit 1; }
X="$(clang22_prefix "$MODE" "$HERE")/bin" || { echo "FAIL: no usable mavericks-clang-22 ($MODE)"; exit 1; }
SDK109="$(sh "$SHIPYARD/fetch_sdk.sh")"
B="$W/builtins-x86"
A="$B/lib/darwin/libclang_rt.osx.a"
# The build root, by both its spellings, is mapped to /mavergreen-build in every compile: the runtime
# links os_version_check.o, so that member's __FILE__ (an assert's) lands in libswiftCore. An unmapped
# path here is the building machine's path in every runtime.
# The flags go through COMPILER_RT_DARWIN_BUILTIN_EXTRA_CFLAGS (patches/llvm 0004): compiler-rt's
# darwin_add_builtin_libraries clears CMAKE_C_FLAGS and CMAKE_ASM_FLAGS, so those never reach a compile.
PM="$(prefix_map_flags c "$W")" || { echo "FAIL: no prefix maps for $W"; exit 1; }

echo "==> 1. configure compiler-rt's builtins alone, x86_64 / $DEPLOYMENT, against the $DEPLOYMENT SDK ($MODE: $X)"
# Configured from scratch every run: it takes seconds, and a reused cache would hide a changed knob.
rm -rf "$B"
# CMAKE_OSX_ARCHITECTURES: else CMake's probes add this host's -arch arm64. DARWIN_osx_ARCHS and
#   DARWIN_osx_BUILTIN_ARCHS: compiler-rt's two arch probes, which would add arm64 from the host SDK.
# DARWIN_macosx_CACHED_SYSROOT: else compiler-rt asks xcrun for the HOST SDK and appends it as a second,
#   winning -isysroot. CMAKE_OSX_DEPLOYMENT_TARGET: CMake's --target=x86_64-apple-macos10.9 overrides the
#   -mmacosx-version-min=10.7 compiler-rt hard-codes (clang warns -Woverriding-option; minOS 10.9 ships).
# CMAKE_LIBTOOL and CMAKE_LIPO: llvm's UseLibtool.cmake archives each slice with CMAKE_LIBTOOL, and
#   compiler-rt joins the slices with CMAKE_LIPO; without them it takes the host's Apple libtool, whose
#   10.9 version writes each member's owner and date and whose symbol table differs from a modern one's
#   (T4 spike Q1). llvm-libtool-darwin writes every member's owner and date as 0.
# LLVM_ENABLE_LIBXML2=OFF and CMAKE_IGNORE_PREFIX_PATH=/opt/pkg: hygiene, as in build-llvm.sh.
shipyard-cmake -G Ninja -S llvm-project/compiler-rt -B "$B" \
  -DCOMPILER_RT_DARWIN_BUILTIN_EXTRA_CFLAGS="$PM" \
  -DCMAKE_C_COMPILER="$X/clang" -DCMAKE_CXX_COMPILER="$X/clang++" -DCMAKE_ASM_COMPILER="$X/clang" \
  -DCMAKE_LIBTOOL="$X/llvm-libtool-darwin" -DCMAKE_LIPO="$X/llvm-lipo" \
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
SYMS="$("$X/llvm-nm" "$A")" || { echo "FAIL: llvm-nm cannot read $A"; exit 1; }
for s in ___isPlatformVersionAtLeast ___isPlatformOrVariantPlatformVersionAtLeast ___divti3 ___modti3 ___udivti3 ___umodti3; do
  printf '%s\n' "$SYMS" | grep -q " T $s\$" || { echo "FAIL: $A does not define $s"; exit 1; }
done
# platform: the archive is fat (one slice); llvm-ar reads only a thin one.
"$X/llvm-lipo" -thin "$ARCH" "$A" -output "$B/thin.a"
# Every member dated and owned 0 (llvm-libtool-darwin's default): read in UTC, 1970's first minute.
TV="$(TZ=UTC0 "$X/llvm-ar" tv "$B/thin.a")" && [ -n "$TV" ] || { echo "FAIL: llvm-ar cannot list $B/thin.a"; exit 1; }
DATED="$(printf '%s\n' "$TV" | awk '$2 != "0/0" || $7 != "1970"')"
[ -z "$DATED" ] || { printf '%s\n' "$DATED"; echo "FAIL: the members of $A above keep a date or owner, so no two builds are the same bytes"; exit 1; }
# No spelling of the build root survives (the prefix maps above); a leak names its members. An archive
# grep cannot read FAILs (grep's 2), rather than reading as "no paths".
RP="$(CDPATH='' cd -P -- "$W" && pwd -P)"; LP="$(CDPATH='' cd -L -- "$W" && pwd -L)"
N="$(grep -caF -e "$W" -e "$RP" -e "$LP" "$A" || [ $? -eq 1 ])" || { echo "FAIL: could not read $A"; exit 1; }
if [ "$N" -ne 0 ]; then
  for m in $("$X/llvm-ar" t "$B/thin.a"); do
    "$X/llvm-ar" p "$B/thin.a" "$m" | grep -aqF -e "$W" -e "$RP" -e "$LP" && echo "  $m"
  done
  echo "FAIL: $A carries the build root's path, in the members listed above"; exit 1
fi
echo "OK: $A ($(wc -c < "$A" | tr -d ' ') bytes)"
