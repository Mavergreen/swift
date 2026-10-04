#!/bin/sh
# platform: macOS-only -- a modern arm64 Mac (cross: xcrun, dyld_info) or OS X 10.9 (native: otool), per MAVERICKS_MODE
# build-toolchain.sh [--host x86_64|arm64] — build a Swift toolchain: a Swift compiler, lld and clang that
# target OS X 10.9 (x86_64) by default.
#   --host x86_64 (the default): the NATIVE toolchain, which RUNS on OS X 10.9 (x86_64). One recipe, two
#     modes (MAVERICKS_MODE, else shipyard's mavericks_mode.sh), the same bytes from both:
#       cross (CI, a modern arm64 Mac): mavericks-clang-22's CROSS clang compiles the C++ half, and
#         build-llvm.sh's arm64 TableGen and the native-helpers/ project run what the build cannot;
#       native (OS X 10.9, self-host.sh): its NATIVE clang, nothing cross-compiled: the build makes and
#         runs its own TableGen and helpers.
#     Both: the compiler's Swift half is compiled by the toolchain SWIFT_HOST_TOOLCHAIN names (in CI the
#     same run's cross toolchain, never an earlier release; on 10.9 the installed previous release, the
#     default there, or self-host.sh's previous stage) against the pinned MacOSX11.3.sdk; everything links
#     against the pinned 10.9 SDK in its original stub form (lib.sh's sdk109_stubs); clang22's
#     llvm-libtool-darwin, llvm-ar and llvm-ranlib make every archive; the build root is prefix-mapped.
#     The design and the evidence: docs/superpowers/specs/2026-09-25-t4-self-hosting-design.md and
#     docs/superpowers/spikes/2026-10-03-t4-self-hosting-FINDINGS.md (and, for the cross build's stages,
#     docs/superpowers/specs/2026-09-24-t1b-native-toolchain-design.md).
#   --host arm64: the CROSS toolchain, which RUNS on an Apple-silicon Mac (arm64, macOS 11.0 or later),
#     built by Apple's clang against the pinned MacOSX11.3.sdk, with nothing cross-compiled; its Swift half
#     is compiled by the swift.org compiler (build.sh's), the one seed CI starts from. Cross mode only.
#     The evidence: docs/superpowers/spikes/2026-09-27-t3-arm64-toolchain-FINDINGS.md.
# Both hosts' clang default to the lld beside them, with one pinned host linker version
# (HOST_LINK_VERSION below). They share every source, pin and patch but compiler patch 0002 (lib.sh's
# compiler_patches), and each has its own build dirs and compiler checkout (lib.sh's
# toolchain_host_select). Run after build-llvm.sh (and, for arm64, mirror-toolchain.sh and build.sh).
# STAGE_HOST=<host> scripts/stage-toolchain.sh lays the results out as that toolchain's pkg payload.
# MAVERICKS_USE_CCACHE=1 compiles through ccache (CI sets it). Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, JOBS,
# MAVERICKS_USE_CCACHE, MAVERICKS_MODE, SWIFT_HOST_TOOLCHAIN, SWIFT_INSTALLED_TOOLCHAIN (native mode's default
# host toolchain, /usr/local/mavergreen/swift-toolchain unless set), CLANG22_PREFIX, MAVERICKS_SDK_CACHE.
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
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, check_release_pin, toolchain_host_select, compiler_patches, the T4 helpers
toolchain_host_select "$HOST" || exit 2
. "$HERE/msc.sh"    # -> $SHIPYARD (clone_pinned.sh, fetch_sdk.sh, mavericks_mode.sh)
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"
case "$MODE:$HOST" in
  cross:x86_64|cross:arm64|native:x86_64) ;;
  native:arm64) echo "FAIL: --host arm64 builds the cross toolchain on an Apple-silicon Mac, not on OS X 10.9" >&2; exit 2 ;;
  *) echo "FAIL: mode '$MODE' is neither cross nor native" >&2; exit 2 ;;
esac
# clang's Darwin driver picks some of the flags it passes a linker by that linker's version, which it
# reads, at configure time, from CMAKE_LINKER's -v (clang/CMakeLists.txt) unless CMAKE_LINKER is an lld:
# the runner's Xcode ld gave 1267, so the shipped clang passed -no_deduplicate, which 10.9's ld refuses (T4
# spike Q5). Every build now names the same value: 241.9, OS X 10.9's own ld64, the linker of the platform
# these toolchains build for. Their clang defaults to lld (CLANG_DEFAULT_LINKER), for which the version
# changes nothing, and `-fuse-ld=ld` on 10.9 gets the flags that ld understands.
HOST_LINK_VERSION=241.9
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$W"; cd "$W"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
LAUNCHER=""
if [ "${MAVERICKS_USE_CCACHE:-0}" = 1 ] && command -v ccache >/dev/null 2>&1; then
  LAUNCHER="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
fi
NATIVE="$W/llvm-build"; TC="$W/toolchain/usr"
# What the host must already hold (earlier stages' work, the host swiftc) is checked first, before anything
# is fetched or configured.
grep -q "swiftlang's fork refuses every Apple-platform input" llvm-project/lld/MachO/InputFiles.cpp \
  || { echo "FAIL: llvm-project lacks patches/llvm -- run ./build-llvm.sh"; exit 1; }
if [ "$MODE" = cross ]; then
  [ -x "$NATIVE/bin/llvm-tblgen" ] || { echo "FAIL: no native TableGen -- run ./build-llvm.sh"; exit 1; }
  [ -f "$NATIVE/lib/libLLVMBitstreamReader.a" ] || { echo "FAIL: no native LLVMBitstreamReader -- run ./build-llvm.sh"; exit 1; }
fi
if [ "$HOST" = x86_64 ]; then
  # The Swift half's host compiler: the wrapper by its real path, so HOSTTOOLS finds the host stdlib at
  # <bin>/../lib/swift/macosx, and CMake's test link gets the wrapper's SDK and linker (T4 spike Q2).
  # Natively it defaults to the installed release (SWIFT_INSTALLED_TOOLCHAIN, which tests point elsewhere).
  HTC="${SWIFT_HOST_TOOLCHAIN:-}"
  if [ -z "$HTC" ]; then
    [ "$MODE" = native ] || { echo "FAIL: name the toolchain that compiles the Swift half with SWIFT_HOST_TOOLCHAIN (in CI, the same run's cross toolchain)"; exit 1; }
    HTC="${SWIFT_INSTALLED_TOOLCHAIN:-/usr/local/mavergreen/swift-toolchain}"
  fi
  [ -x "$HTC/bin/swiftc" ] || { echo "FAIL: no $HTC/bin/swiftc -- name the Swift toolchain that compiles the Swift half with SWIFT_HOST_TOOLCHAIN"; exit 1; }
  HOST_STAMP="$(host_swiftc_stamp "$HTC")" || { echo "FAIL: cannot stamp the host toolchain at $HTC"; exit 1; }
else
  [ -x "$TC/bin/swiftc" ] || { echo "FAIL: no host swiftc -- run ./build.sh"; exit 1; }
fi
PATCHES="$(compiler_patches "$HOST" "$HERE/patches/compiler")" || { echo "FAIL: no compiler patches for $HOST"; exit 1; }
L="$W/$TH_LLVM"; S="$W/$TH_SWIFT"; CM="$W/$TH_CMARK"; SC="$TH_CHECKOUT"
SDK113="$(sh "$SHIPYARD/fetch_sdk.sh" --arch arm64)" || { echo "FAIL: could not fetch the pinned MacOSX11.3.sdk"; exit 1; }
if [ "$HOST" = x86_64 ]; then
  X="$(clang22_prefix "$MODE" "$HERE")/bin" || { echo "FAIL: no usable mavericks-clang-22 ($MODE)"; exit 1; }
  SDK109="$(sdk109_stubs)" || { echo "FAIL: could not fetch the pinned 10.9 SDK"; exit 1; }
  PM="$(prefix_map_flags c "$W")" || { echo "FAIL: no prefix maps for $W"; exit 1; }
  # The Swift half imports the 11.3 SDK's Darwin overlay, whose force-load symbol lives in libswiftDarwin,
  # which neither a Mavergreen toolchain's lib/swift/macosx nor the 10.9 SDK has. A dir holding ONLY the
  # 11.3 SDK's libswiftDarwin.tbd: the whole SDK usr/lib/swift would come first on the link line and
  # supply a macOS 11.3 libswiftCore.tbd without the entry points the Swift half calls (spike blocker 1).
  DARWIN_LIB="$W/swiftdarwin-x86"
  rm -rf "$DARWIN_LIB" && mkdir -p "$DARWIN_LIB" && ln -s "$SDK113/usr/lib/swift/libswiftDarwin.tbd" "$DARWIN_LIB/libswiftDarwin.tbd"
fi

# The x86_64 host, in either mode: clang22, its archivers and indexer, the 10.9 SDK's stubs, the prefix
# maps. LLVM archives with CMAKE_LIBTOOL on an Apple host (llvm's UseLibtool.cmake; it would take xcrun's
# libtool), other projects with CMAKE_AR and CMAKE_RANLIB: an archive's symbol table orders what lld
# writes (T4 spike Q5), and Apple's tools differ between 10.9 and a modern Mac, so all three are clang22's.
x86_cmake() {
  if [ "$MODE" = cross ]; then
    set -- -DCMAKE_CROSSCOMPILING=ON -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 "$@"
  fi
  shipyard-cmake -G Ninja $LAUNCHER -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$X/clang" -DCMAKE_CXX_COMPILER="$X/clang++" \
    -DCMAKE_AR="$X/llvm-ar" -DCMAKE_RANLIB="$X/llvm-ranlib" -DCMAKE_LIBTOOL="$X/llvm-libtool-darwin" \
    -DCMAKE_LINKER="$X/ld64.lld" \
    "-DCMAKE_C_FLAGS=$PM" "-DCMAKE_CXX_FLAGS=$PM" \
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
  echo "==> 1. LLVM + clang + lld for an $ARCH / $DEPLOYMENT host ($MODE: $X)"
  TBLGEN=""
  if [ "$MODE" = cross ]; then
    TBLGEN="-DLLVM_TABLEGEN=$NATIVE/bin/llvm-tblgen -DCLANG_TABLEGEN=$NATIVE/bin/clang-tblgen -DLLVM_NATIVE_TOOL_DIR=$NATIVE/bin"
  fi
  x86_cmake -S llvm-project/llvm -B "$L" \
    -DLLVM_HOST_TRIPLE=x86_64-apple-macosx10.9 -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 \
    $TBLGEN \
    "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_RUNTIMES= -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ONDISK_CAS=OFF \
    -DCLANG_DEFAULT_LINKER=lld -DHOST_LINK_VERSION="$HOST_LINK_VERSION"
else
  # X86 alone, as in the native toolchain, so the two compilers carry the same code generator: the
  # toolchain emits nothing else, and no part of it needs AArch64 to build or run. TableGen is
  # build-llvm.sh's (an arm64 program either way). CMAKE_LINKER names an lld only so that clang takes
  # HOST_LINK_VERSION as given: Apple's clang links this build either way.
  echo "==> 1. LLVM + clang + lld for an arm64 / macOS 11.0 host (Apple clang, $SDK113)"
  host_cmake -S llvm-project/llvm -B "$L" \
    -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 \
    -DLLVM_TABLEGEN="$NATIVE/bin/llvm-tblgen" -DCLANG_TABLEGEN="$NATIVE/bin/clang-tblgen" \
    -DLLVM_NATIVE_TOOL_DIR="$NATIVE/bin" \
    "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_RUNTIMES= -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ONDISK_CAS=OFF \
    -DCMAKE_LINKER="$NATIVE/bin/ld64.lld" -DCLANG_DEFAULT_LINKER=lld -DHOST_LINK_VERSION="$HOST_LINK_VERSION"
fi
ninja -C "$L" -j "$JOBS" llvm-libraries clang-libraries clang-resource-headers lld clang

echo "==> 2. swift-cmark"
check_release_pin swift-cmark "$CMARK_SWIFT_RELEASE" "$CMARK_TAG" "$CMARK_SHA" https://github.com/swiftlang/swift-cmark.git
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift-cmark.git "$CMARK_TAG" "$CMARK_SHA" cmark
if [ "$HOST" = x86_64 ]; then
  x86_cmake -S cmark -B "$CM" -DBUILD_TESTING=OFF -DCMARK_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
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

if [ "$HOST:$MODE" = x86_64:cross ]; then
  echo "==> 4. native helper tools (the builder runs these while building the compiler)"
  shipyard-cmake -G Ninja -S "$HERE/native-helpers" -B "$W/native-helpers" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DLLVM_DIR="$NATIVE/lib/cmake/llvm" -DSWIFT_SOURCE_DIR="$W/$SC"
  ninja -C "$W/native-helpers"
else
  echo "==> 4. no native helper tools: this build runs the helpers it builds"
fi

if [ "$HOST" = x86_64 ]; then
  echo "==> 5. swift-frontend (HOSTTOOLS: $HTC compiles the Swift-written half)"
  "$HTC/bin/swift-frontend" -version 2>&1 | sed 's/^/    host: /'
  # A changed host compiler is configured afresh and recompiles the Swift half, and only that (lib.sh).
  swift_half_reset "$S" "$HOST_STAMP" || exit 1
  if [ "$MODE" = cross ]; then
    NATIVE_TOOLS="-DLLVM_TABLEGEN=$NATIVE/bin/llvm-tblgen -DSWIFT_NATIVE_LLVM_TOOLS_PATH=$NATIVE/bin -DSWIFT_NATIVE_CLANG_TOOLS_PATH=$HTC/bin -DSWIFT_NATIVE_SWIFT_TOOLS_PATH=$W/native-helpers"
  else
    NATIVE_TOOLS="-DLLVM_TABLEGEN=$L/bin/llvm-tblgen"
  fi
  # The Swift half compiles against the pinned 11.3 SDK: the 10.9 SDK's single Darwin module cannot
  # coexist with modular libc++ (T1 spike blocker 3), and a Mavergreen host needs the 11.3 SDK's
  # SwiftShims-era overlays (T4 spike Q5). Its module cache stays in the build root. libc++ ABI v1 is
  # shared by both halves.
  x86_cmake -S "$SC" -B "$S" \
    -DCMAKE_Swift_COMPILER="$HTC/bin/swiftc" "-DCMAKE_EXE_LINKER_FLAGS=-L$DARWIN_LIB" \
    -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
    -DLLVM_BUILD_LIBRARY_DIR="$L/lib" -DLLVM_BUILD_BINARY_DIR="$L" \
    -DLLVM_BUILD_MAIN_SRC_DIR="$W/llvm-project/llvm" -DLLVM_MAIN_SRC_DIR="$W/llvm-project/llvm" \
    $NATIVE_TOOLS \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$W/cmark" -DSWIFT_PATH_TO_CMARK_BUILD="$CM" \
    -DSWIFT_CMARK_LIBRARY_DIR="$CM/src" \
    -DBOOTSTRAPPING_MODE=HOSTTOOLS \
    -DSWIFT_HOST_VARIANT_SDK=OSX -DSWIFT_HOST_VARIANT_ARCH="$ARCH" \
    -DSWIFT_PRIMARY_VARIANT_SDK=OSX -DSWIFT_PRIMARY_VARIANT_ARCH="$ARCH" \
    -DSWIFT_SDKS=OSX -DSWIFT_DARWIN_SUPPORTED_ARCHS="$ARCH" \
    -DSWIFT_DARWIN_DEPLOYMENT_VERSION_OSX="$DEPLOYMENT" -DSWIFT_SDK_OSX_PATH="$SDK109" \
    -DSWIFT_THREADING_PACKAGE=OSX:pthreads \
    "-DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;$SDK113;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-disable-availability-checking;-runtime-compatibility-version;none;-module-cache-path;$W/swift-x86-modcache" \
    -DSWIFT_INCLUDE_TOOLS=ON -DSWIFT_BUILD_STDLIB=OFF -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_SDK_OVERLAY=OFF -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
    -DSWIFT_BUILD_REGEX_PARSER_IN_COMPILER=OFF -DSWIFT_ENABLE_BACKTRACING=OFF \
    -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF -DSWIFT_BUILD_PERF_TESTSUITE=OFF -DSWIFT_ENABLE_LIBXML2=OFF
  printf '%s\n' "$HOST_STAMP" > "$S/mavergreen-host.stamp"
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

# platform: OS X 10.9 has no dyld_info; there lib.sh's readers fall back to otool.
DI="$(xcrun -f dyld_info 2>/dev/null || :)"
if [ "$HOST" = x86_64 ]; then
  echo "==> 6. check: minOS and SDK $DEPLOYMENT, 10.9-safe imports, the frontend's own rpath"
  for b in "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"; do
    vers="$(DYLDINFO="$DI" macho_version "$b")" || { echo "FAIL: cannot read $b's minOS and SDK"; exit 1; }
    [ "$vers" = "$DEPLOYMENT $DEPLOYMENT" ] || { echo "FAIL: $b records minOS/SDK '$vers', not $DEPLOYMENT/$DEPLOYMENT"; exit 1; }
  done
  MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"
  RPATHS="$(DYLDINFO="$DI" macho_rpaths "$S/bin/swift-frontend")" || { echo "FAIL: cannot read swift-frontend's rpaths"; exit 1; }
  printf '%s\n' "$RPATHS" | grep -qx '@loader_path/../lib/swift/macosx' \
    || { echo "FAIL: swift-frontend's rpath is not @loader_path/../lib/swift/macosx"; exit 1; }
  echo "OK: swift-frontend, lld and clang for $ARCH / $DEPLOYMENT"
else
  echo "==> 6. check: arm64 at minOS 11.0 / SDK 11.3, the OS's Swift runtime, and only macOS 11 imports"
  # The guard holds each to arm64 alone and the family's arm64 pin (sdk-pins.sh: minos 11.0, sdk 11.3).
  MAVERICKS_ALLOW_ARCHS=arm64 MAVERICKS_DEVIATIONS_ROOT="$HERE" sh "$HERE/scripts/guard.sh" \
    "$S/bin/swift-frontend" "$L/bin/lld" "$L/bin/clang"
  # Captured before any test: a reader that failed must fail the check, not read as "no such load".
  DEPS="$("$DI" -dependents "$S/bin/swift-frontend")" || { echo "FAIL: cannot read swift-frontend's dependents"; exit 1; }
  RPATHS="$(DYLDINFO="$DI" macho_rpaths "$S/bin/swift-frontend")" || { echo "FAIL: cannot read swift-frontend's rpaths"; exit 1; }
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
