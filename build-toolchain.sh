#!/bin/sh
# platform: macOS-only -- xcrun finds the modern SDK and dyld_info, and the cross compiler is an arm64 macOS toolchain
# build-toolchain.sh — cross-build the native Swift toolchain: a Swift compiler, lld and clang that
# RUN on OS X 10.9 (x86_64), built on a modern arm64 Mac. Run after build-llvm.sh, mirror-toolchain.sh
# and build.sh. Stages and every fix: docs/superpowers/specs/2026-09-24-t1b-native-toolchain-design.md;
# the evidence: docs/superpowers/spikes/2026-09-24-t1-cross-build-swift-frontend-FINDINGS.md.
# scripts/stage-toolchain.sh lays the results out as the pkg payload. MAVERICKS_USE_CCACHE=1 compiles
# through ccache (CI sets it).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, check_release_pin
. "$HERE/msc.sh"    # -> $SHIPYARD (clone_pinned.sh, fetch_sdk.sh)
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$W"; cd "$W"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
LAUNCHER=""
if [ "${MAVERICKS_USE_CCACHE:-0}" = 1 ] && command -v ccache >/dev/null 2>&1; then
  LAUNCHER="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
fi
NATIVE="$W/llvm-build"; TC="$W/toolchain/usr"
[ -x "$NATIVE/bin/llvm-tblgen" ] || { echo "FAIL: no native TableGen -- run ./build-llvm.sh"; exit 1; }
[ -f "$NATIVE/lib/libLLVMBitstreamReader.a" ] || { echo "FAIL: no native LLVMBitstreamReader -- run ./build-llvm.sh"; exit 1; }
grep -q "swiftlang's fork refuses every Apple-platform input" llvm-project/lld/MachO/InputFiles.cpp \
  || { echo "FAIL: llvm-project lacks patches/llvm -- run ./build-llvm.sh"; exit 1; }
[ -x "$TC/bin/swiftc" ] || { echo "FAIL: no host swiftc -- run ./build.sh"; exit 1; }
X="$(sh "$HERE/fetch-clang22.sh")/bin"
SDK109="$(sh "$SHIPYARD/fetch_sdk.sh")"
MODERN_SDK="$(xcrun --show-sdk-path)"

cross_cmake() {  # shipyard-cmake with the 10.9-host cross settings every stage shares
  shipyard-cmake -G Ninja $LAUNCHER -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$X/clang" -DCMAKE_CXX_COMPILER="$X/clang++" \
    -DCMAKE_CROSSCOMPILING=ON -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_OSX_SYSROOT="$SDK109" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT" -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw" \
    "$@"
}

echo "==> 1. LLVM + clang + lld for an $ARCH / $DEPLOYMENT host (cross compiler: $X)"
cross_cmake -S llvm-project/llvm -B "$W/llvm-x86" \
  -DLLVM_HOST_TRIPLE=x86_64-apple-macosx10.9 -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 \
  -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DCLANG_TABLEGEN="$NATIVE/bin/clang-tblgen" \
  -DLLVM_NATIVE_TOOL_DIR="$NATIVE/bin" \
  "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_RUNTIMES= -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ONDISK_CAS=OFF
ninja -C "$W/llvm-x86" -j "$JOBS" llvm-libraries clang-libraries clang-resource-headers lld clang

echo "==> 2. swift-cmark"
check_release_pin swift-cmark "$CMARK_SWIFT_RELEASE" "$CMARK_TAG" "$CMARK_SHA" https://github.com/swiftlang/swift-cmark.git
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift-cmark.git "$CMARK_TAG" "$CMARK_SHA" cmark
cross_cmake -S cmark -B "$W/cmark-x86" -DBUILD_TESTING=OFF -DCMARK_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
ninja -C "$W/cmark-x86" -j "$JOBS"

echo "==> 3. the compiler's own Swift checkout, pristine, plus patches/compiler"
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift.git "$SWIFT_TAG" "$SWIFT_SHA" swift-compiler
# platform: some macOS checkouts fail `git apply` with iconv_open(UTF-8, UTF-8-MAC) on unicode paths.
git -C swift-compiler config core.precomposeunicode false
git -C swift-compiler reset -q --hard "$SWIFT_SHA"
git -C swift-compiler clean -q -fdx
for p in "$HERE"/patches/compiler/*.patch; do
  git -C swift-compiler apply -p0 --check "$p" && git -C swift-compiler apply -p0 "$p" || { echo "FAIL: patch did not apply: $p"; exit 1; }
done
grep -q 'any macOS SDK back to 10.9 is accepted' swift-compiler/lib/Driver/Driver.cpp || { echo "FAIL: compiler patch 0001 not applied"; exit 1; }
grep -q "host tools run on the toolchain's own bundled runtime" swift-compiler/cmake/modules/AddSwift.cmake || { echo "FAIL: compiler patch 0002 not applied"; exit 1; }

echo "==> 4. native helper tools (the builder runs these while building the compiler)"
shipyard-cmake -G Ninja -S "$HERE/native-helpers" -B "$W/native-helpers" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DLLVM_DIR="$NATIVE/lib/cmake/llvm" -DSWIFT_SOURCE_DIR="$W/swift-compiler"
ninja -C "$W/native-helpers"

echo "==> 5. swift-frontend (HOSTTOOLS: the swift.org compiler builds the Swift-written half)"
# The Swift half compiles against the modern SDK: the 10.9 SDK's single Darwin module cannot coexist
# with modular libc++ (spike blocker 3). libc++ ABI v1 is shared by both halves.
L="$W/llvm-x86"
cross_cmake -S swift-compiler -B "$W/swift-x86" \
  -DCMAKE_Swift_COMPILER="$TC/bin/swiftc" \
  -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
  -DLLVM_BUILD_LIBRARY_DIR="$L/lib" -DLLVM_BUILD_BINARY_DIR="$L" \
  -DLLVM_BUILD_MAIN_SRC_DIR="$W/llvm-project/llvm" -DLLVM_MAIN_SRC_DIR="$W/llvm-project/llvm" \
  -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$NATIVE/bin" \
  -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$TC/bin" -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$W/native-helpers" \
  -DSWIFT_PATH_TO_CMARK_SOURCE="$W/cmark" -DSWIFT_PATH_TO_CMARK_BUILD="$W/cmark-x86" \
  -DSWIFT_CMARK_LIBRARY_DIR="$W/cmark-x86/src" \
  -DBOOTSTRAPPING_MODE=HOSTTOOLS \
  -DSWIFT_HOST_VARIANT_SDK=OSX -DSWIFT_HOST_VARIANT_ARCH="$ARCH" \
  -DSWIFT_PRIMARY_VARIANT_SDK=OSX -DSWIFT_PRIMARY_VARIANT_ARCH="$ARCH" \
  -DSWIFT_SDKS=OSX -DSWIFT_DARWIN_SUPPORTED_ARCHS="$ARCH" \
  -DSWIFT_DARWIN_DEPLOYMENT_VERSION_OSX="$DEPLOYMENT" -DSWIFT_SDK_OSX_PATH="$SDK109" \
  -DSWIFT_THREADING_PACKAGE=OSX:pthreads \
  "-DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;$MODERN_SDK;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-disable-availability-checking;-runtime-compatibility-version;none" \
  -DSWIFT_INCLUDE_TOOLS=ON -DSWIFT_BUILD_STDLIB=OFF -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF -DSWIFT_BUILD_STATIC_STDLIB=OFF \
  -DSWIFT_BUILD_SDK_OVERLAY=OFF -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
  -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
  -DSWIFT_BUILD_REGEX_PARSER_IN_COMPILER=OFF -DSWIFT_ENABLE_BACKTRACING=OFF \
  -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF -DSWIFT_BUILD_PERF_TESTSUITE=OFF -DSWIFT_ENABLE_LIBXML2=OFF
ninja -C "$W/swift-x86" -j "$JOBS" swift-frontend

echo "==> 6. check: minOS and SDK $DEPLOYMENT, 10.9-safe imports, the frontend's own rpath"
DI="$(xcrun -f dyld_info)"
for b in "$W/swift-x86/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"; do
  vers="$("$DI" -platform "$b" | awk 'NR==4{print $2, $3}')"
  [ "$vers" = "$DEPLOYMENT $DEPLOYMENT" ] || { echo "FAIL: $b records minOS/SDK '$vers', not $DEPLOYMENT/$DEPLOYMENT"; exit 1; }
done
MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" "$W/swift-x86/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"
"$DI" -rpaths "$W/swift-x86/bin/swift-frontend" | grep -q '@loader_path/../lib/swift/macosx' \
  || { echo "FAIL: swift-frontend's rpath is not @loader_path/../lib/swift/macosx"; exit 1; }
echo "OK: swift-frontend, lld and clang for $ARCH / $DEPLOYMENT"
