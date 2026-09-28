#!/bin/sh
# platform: macOS-only -- xcrun finds the modern SDK and dyld_info, and both hosts' compilers run on an arm64 Mac
# build-toolchain.sh [--host x86_64|arm64] — build a Swift toolchain on a modern arm64 Mac: a Swift
# compiler, lld and clang that target OS X 10.9 (x86_64) by default.
#   --host x86_64 (the default): the NATIVE toolchain, which RUNS on OS X 10.9 (x86_64), cross-compiled
#     with mavericks-clang-22. Stages and every fix: docs/superpowers/specs/2026-09-24-t1b-native-toolchain-design.md;
#     the evidence: docs/superpowers/spikes/2026-09-24-t1-cross-build-swift-frontend-FINDINGS.md.
#   --host arm64: the CROSS toolchain, which RUNS on an Apple-silicon Mac (arm64, macOS 11.0 or later),
#     built by Apple's clang against the pinned MacOSX11.3.sdk, with nothing cross-compiled; the evidence:
#     docs/superpowers/spikes/2026-09-27-t3-arm64-toolchain-FINDINGS.md.
# The two share every source, pin and patch but compiler patch 0002 (lib.sh's compiler_patches), and
# each has its own build dirs and compiler checkout (lib.sh's toolchain_host_select). Run after
# build-llvm.sh, mirror-toolchain.sh and build.sh. STAGE_HOST=<host> scripts/stage-toolchain.sh lays
# the results out as that toolchain's pkg payload. MAVERICKS_USE_CCACHE=1 compiles through ccache (CI
# sets it). Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, JOBS, MAVERICKS_USE_CCACHE.
set -eu
HOST=x86_64
while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || { echo "usage: build-toolchain.sh [--host x86_64|arm64]" >&2; exit 2; }
            HOST="$2"; shift 2 ;;
    *) echo "usage: build-toolchain.sh [--host x86_64|arm64]" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, check_release_pin, toolchain_host_select, compiler_patches
toolchain_host_select "$HOST" || exit 2
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
PATCHES="$(compiler_patches "$HOST" "$HERE/patches/compiler")" || { echo "FAIL: no compiler patches for $HOST"; exit 1; }
L="$W/$TH_LLVM"; S="$W/$TH_SWIFT"; CM="$W/$TH_CMARK"; SC="$TH_CHECKOUT"
if [ "$HOST" = x86_64 ]; then
  X="$(sh "$HERE/fetch-clang22.sh")/bin"
  SDK109="$(sh "$SHIPYARD/fetch_sdk.sh")"
  MODERN_SDK="$(xcrun --show-sdk-path)"
else
  SDK113="$(sh "$SHIPYARD/fetch_sdk.sh" --arch arm64)"
fi

cross_cmake() {  # shipyard-cmake with the 10.9-host cross settings every x86_64 stage shares
  shipyard-cmake -G Ninja $LAUNCHER -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$X/clang" -DCMAKE_CXX_COMPILER="$X/clang++" \
    -DCMAKE_CROSSCOMPILING=ON -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_OSX_SYSROOT="$SDK109" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT" -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw" \
    "$@"
}
# The arm64 host: Apple's clang (the runner's Command Line Tools), the pinned MacOSX11.3.sdk, macOS 11.0,
# arm64 alone, and nothing cross-compiled -- the configuration closest to upstream's own.
host_cmake() {
  shipyard-cmake -G Ninja $LAUNCHER -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_OSX_SYSROOT="$SDK113" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw" \
    "$@"
}

if [ "$HOST" = x86_64 ]; then
  echo "==> 1. LLVM + clang + lld for an $ARCH / $DEPLOYMENT host (cross compiler: $X)"
  cross_cmake -S llvm-project/llvm -B "$L" \
    -DLLVM_HOST_TRIPLE=x86_64-apple-macosx10.9 -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DCLANG_TABLEGEN="$NATIVE/bin/clang-tblgen" \
    -DLLVM_NATIVE_TOOL_DIR="$NATIVE/bin" \
    "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_RUNTIMES= -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ONDISK_CAS=OFF
else
  # X86 alone, as in the native toolchain, so the two compilers carry the same code generator: the
  # toolchain emits nothing else, and no part of it needs AArch64 to build or run. TableGen is
  # build-llvm.sh's (an arm64 program either way).
  echo "==> 1. LLVM + clang + lld for an arm64 / macOS 11.0 host (Apple clang, $SDK113)"
  host_cmake -S llvm-project/llvm -B "$L" \
    -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DCLANG_TABLEGEN="$NATIVE/bin/clang-tblgen" \
    -DLLVM_NATIVE_TOOL_DIR="$NATIVE/bin" \
    "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_RUNTIMES= -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ONDISK_CAS=OFF
fi
ninja -C "$L" -j "$JOBS" llvm-libraries clang-libraries clang-resource-headers lld clang

echo "==> 2. swift-cmark"
check_release_pin swift-cmark "$CMARK_SWIFT_RELEASE" "$CMARK_TAG" "$CMARK_SHA" https://github.com/swiftlang/swift-cmark.git
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift-cmark.git "$CMARK_TAG" "$CMARK_SHA" cmark
if [ "$HOST" = x86_64 ]; then
  cross_cmake -S cmark -B "$CM" -DBUILD_TESTING=OFF -DCMARK_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
else
  host_cmake -S cmark -B "$CM" -DBUILD_TESTING=OFF -DCMARK_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
fi
ninja -C "$CM" -j "$JOBS"

echo "==> 3. the compiler's own Swift checkout ($SC), pristine, plus its patches/compiler"
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift.git "$SWIFT_TAG" "$SWIFT_SHA" "$SC"
# platform: some macOS checkouts fail `git apply` with iconv_open(UTF-8, UTF-8-MAC) on unicode paths.
git -C "$SC" config core.precomposeunicode false
git -C "$SC" reset -q --hard "$SWIFT_SHA"
git -C "$SC" clean -q -fdx
# The patch paths hold no newline (they are this checkout's), so newline alone splits them.
_ifs="$IFS"; IFS='
'
for p in $PATCHES; do
  git -C "$SC" apply -p0 --check "$p" && git -C "$SC" apply -p0 "$p" || { echo "FAIL: patch did not apply: $p"; exit 1; }
done
IFS="$_ifs"
grep -q 'any macOS SDK back to 10.9 is accepted' "$SC/lib/Driver/Driver.cpp" || { echo "FAIL: compiler patch 0001 not applied"; exit 1; }
if [ "$HOST" = x86_64 ]; then
  grep -q "host tools run on the toolchain's own bundled runtime" "$SC/cmake/modules/AddSwift.cmake" || { echo "FAIL: compiler patch 0002 not applied"; exit 1; }
elif grep -q "host tools run on the toolchain's own bundled runtime" "$SC/cmake/modules/AddSwift.cmake"; then
  echo "FAIL: compiler patch 0002 is in $SC: an arm64 frontend cannot load the x86_64 stdlib it would point at"; exit 1
fi

if [ "$HOST" = x86_64 ]; then
  echo "==> 4. native helper tools (the builder runs these while building the compiler)"
  shipyard-cmake -G Ninja -S "$HERE/native-helpers" -B "$W/native-helpers" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DLLVM_DIR="$NATIVE/lib/cmake/llvm" -DSWIFT_SOURCE_DIR="$W/$SC"
  ninja -C "$W/native-helpers"
else
  echo "==> 4. no native helper tools: an arm64 build runs the helpers it builds"
fi

if [ "$HOST" = x86_64 ]; then
  echo "==> 5. swift-frontend (HOSTTOOLS: the swift.org compiler builds the Swift-written half)"
  # The Swift half compiles against the modern SDK: the 10.9 SDK's single Darwin module cannot coexist
  # with modular libc++ (spike blocker 3). libc++ ABI v1 is shared by both halves.
  cross_cmake -S "$SC" -B "$S" \
    -DCMAKE_Swift_COMPILER="$TC/bin/swiftc" \
    -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
    -DLLVM_BUILD_LIBRARY_DIR="$L/lib" -DLLVM_BUILD_BINARY_DIR="$L" \
    -DLLVM_BUILD_MAIN_SRC_DIR="$W/llvm-project/llvm" -DLLVM_MAIN_SRC_DIR="$W/llvm-project/llvm" \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$NATIVE/bin" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$TC/bin" -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$W/native-helpers" \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$W/cmark" -DSWIFT_PATH_TO_CMARK_BUILD="$CM" \
    -DSWIFT_CMARK_LIBRARY_DIR="$CM/src" \
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
else
  echo "==> 5. swift-frontend (HOSTTOOLS: the swift.org compiler builds the Swift-written half), for arm64 / macOS 11.0"
  # Both halves compile against the same 11.3 SDK. Its libc++ (2021) marks <filesystem> strict-available
  # from 10.15, and rebuilding the swift.org toolchain's CxxStdlib.swiftinterface (recorded -target
  # arm64-apple-macosx10.9) then fails to build Clang module 'std': -D_LIBCPP_DISABLE_AVAILABILITY turns
  # that markup off (the C++ half, at 11.0, needs nothing), and -strict-implicit-module-context makes
  # the interface sub-build inherit it, which it otherwise drops (spike blocker 2). No
  # -runtime-compatibility-version none: this frontend runs on the OS's /usr/lib/swift, so the swift.org
  # compatibility shims link as upstream intends.
  host_cmake -S "$SC" -B "$S" \
    -DCMAKE_Swift_COMPILER="$TC/bin/swiftc" \
    -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
    -DLLVM_BUILD_LIBRARY_DIR="$L/lib" -DLLVM_BUILD_BINARY_DIR="$L" \
    -DLLVM_BUILD_MAIN_SRC_DIR="$W/llvm-project/llvm" -DLLVM_MAIN_SRC_DIR="$W/llvm-project/llvm" \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$W/cmark" -DSWIFT_PATH_TO_CMARK_BUILD="$CM" \
    -DSWIFT_CMARK_LIBRARY_DIR="$CM/src" \
    -DBOOTSTRAPPING_MODE=HOSTTOOLS \
    -DSWIFT_HOST_VARIANT_SDK=OSX -DSWIFT_HOST_VARIANT_ARCH=arm64 \
    -DSWIFT_PRIMARY_VARIANT_SDK=OSX -DSWIFT_PRIMARY_VARIANT_ARCH=arm64 \
    -DSWIFT_SDKS=OSX -DSWIFT_DARWIN_SUPPORTED_ARCHS=arm64 \
    -DSWIFT_DARWIN_DEPLOYMENT_VERSION_OSX=11.0 -DSWIFT_SDK_OSX_PATH="$SDK113" \
    "-DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;$SDK113;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-strict-implicit-module-context" \
    -DSWIFT_INCLUDE_TOOLS=ON -DSWIFT_BUILD_STDLIB=OFF -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_SDK_OVERLAY=OFF -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
    -DSWIFT_BUILD_REGEX_PARSER_IN_COMPILER=OFF -DSWIFT_ENABLE_BACKTRACING=OFF \
    -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF -DSWIFT_BUILD_PERF_TESTSUITE=OFF -DSWIFT_ENABLE_LIBXML2=OFF
fi
ninja -C "$S" -j "$JOBS" swift-frontend

DI="$(xcrun -f dyld_info)"
if [ "$HOST" = x86_64 ]; then
  echo "==> 6. check: minOS and SDK $DEPLOYMENT, 10.9-safe imports, the frontend's own rpath"
  for b in "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"; do
    vers="$("$DI" -platform "$b" | awk 'NR==4{print $2, $3}')"
    [ "$vers" = "$DEPLOYMENT $DEPLOYMENT" ] || { echo "FAIL: $b records minOS/SDK '$vers', not $DEPLOYMENT/$DEPLOYMENT"; exit 1; }
  done
  MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"
  "$DI" -rpaths "$S/bin/swift-frontend" | grep -q '@loader_path/../lib/swift/macosx' \
    || { echo "FAIL: swift-frontend's rpath is not @loader_path/../lib/swift/macosx"; exit 1; }
  echo "OK: swift-frontend, lld and clang for $ARCH / $DEPLOYMENT"
else
  echo "==> 6. check: arm64 at minOS 11.0 / SDK 11.3, the OS's Swift runtime, and only macOS 11 imports"
  # The guard holds each to arm64 alone and the family's arm64 pin (sdk-pins.sh: minos 11.0, sdk 11.3).
  MAVERICKS_ALLOW_ARCHS=arm64 MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" \
    "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"
  # Captured before any test: a reader that failed must fail the check, not read as "no such load".
  DEPS="$("$DI" -dependents "$S/bin/swift-frontend")" || { echo "FAIL: cannot read swift-frontend's dependents"; exit 1; }
  RPATHS="$("$DI" -rpaths "$S/bin/swift-frontend" | awk 'NR > 2 { print $1 }')"
  printf '%s\n' "$DEPS" | grep -q ' /usr/lib/swift/libswiftCore\.dylib$' \
    || { echo "FAIL: swift-frontend does not load the OS's /usr/lib/swift/libswiftCore.dylib"; exit 1; }
  if printf '%s\n' "$DEPS" | grep -q '@rpath/libswift'; then
    echo "FAIL: swift-frontend loads a Swift library through @rpath, where the package's x86_64 stdlib could answer"; exit 1
  fi
  [ "$RPATHS" = /usr/lib/swift ] || { echo "FAIL: swift-frontend's rpaths are [$RPATHS], not /usr/lib/swift alone"; exit 1; }
  # HOSTTOOLS puts the swift.org toolchain's libswiftCore (built for macOS 13) ahead of the SDK's on the
  # link path, so the link alone proves nothing about macOS 11: every import is audited against the
  # pinned 11.3 SDK instead.
  python3 "$HERE/scripts/audit-imports.py" "$S/bin/swift-frontend" "$SDK113"
  echo "OK: swift-frontend, lld and clang for arm64 / macOS 11.0, targeting x86_64 / OS X 10.9"
fi
