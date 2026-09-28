#!/bin/sh
# platform: macOS-only -- a modern Mac (cross: pkgutil and ditto expand the swift.org compiler) or OS X 10.9 (native)
# build.sh — from-source build of the Swift runtime (libswiftCore + libswiftSwiftOnoneSupport) for
# OS X 10.9 / x86_64, staged as the runtime .pkg's payload. No Apple prebuilt runtime bytes ship.
#
# One recipe, two modes (MAVERICKS_MODE, else shipyard's mavericks_mode.sh), the same bytes from both:
#   cross (CI, a modern Mac): host Swift compiler and clang are the swift.org toolchain's
#     (mirror-toolchain.sh -> $SWIFT_BUILD/cache/<pkg>, signer-verified); builtins archive
#     build-builtins.sh's.
#   native (OS X 10.9): host Swift compiler and clang are the INSTALLED swift-toolchain's
#     (SWIFT_HOST_TOOLCHAIN, default /usr/local/mavergreen/swift-toolchain), run bare through a shim
#     dir; builtins archive the one that toolchain ships (the same release's bytes).
#   Both: LLVM build support and ld64.lld from build-llvm.sh; the pinned modern SDK (shipyard's
#   fetch_sdk.sh --arch arm64, MacOSX11.3.sdk); the runtime linked by that lld with the builtins archive
#   where the driver puts its own; the build root prefix-mapped to /mavergreen-build.
# Env: MAVERICKS_BUILD_ROOT (build root, see lib.sh), SWIFT_WORK (sources and build trees, default
#   $SWIFT_BUILD/work), SWIFT_RUNTIME_OUT (the staged payload, default $SWIFT_BUILD/payload/runtime),
#   MAVERICKS_MODE, SWIFT_HOST_TOOLCHAIN, SWIFT_HOST_TOOLCHAIN_VERSION (the release of a host toolchain no
#   pkg installed, a copy; see lib.sh's host_toolchain_release), SWIFT_BUILTINS (a libclang_rt.osx.a to
#   link instead of the mode's own), NM (native mode's nm), MAVERICKS_SDK_CACHE (fetch_sdk.sh's cache).
# Host: cmake through shipyard-cmake, ninja, git, python3 (gyb). On OS X 10.9 pkgsrc supplies python3
# (gyb, line-directive, LLVM's CMake), ninja, and git (while ~/.gitconfig uses options that git 1.9.5
# rejects); see README's "Developing on OS X 10.9".
# Output: $SWIFT_RUNTIME_OUT, in scripts/stage-runtime.sh's layout, for package.sh.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"   # capture BEFORE the cd below: $0 is relative as ./build.sh
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, verify_toolchain_signature, expand_toolchain, the build helpers
. "$HERE/msc.sh"    # -> $SHIPYARD (clone_pinned.sh, mavericks_mode.sh, fetch_sdk.sh)
ROOT="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$ROOT"; cd "$ROOT"
# platform: OS X 10.9 has no dyld_info; step 7 then reads the runtime with otool and nm (lib.sh).
DYLDINFO="$(xcrun -f dyld_info 2>/dev/null || :)"
LLVMB="$SWIFT_BUILD/out/llvm"
LLD="$ROOT/llvm-build/bin/ld64.lld"
# gyb generates stdlib sources with Python; a fixed hash seed keeps set and dict order, and so those
# sources, the same from run to run (a two-root build once differed by 48 bytes of reordered strings).
PYTHONHASHSEED=0; export PYTHONHASHSEED
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"

echo "==> 1. host build environment ($MODE: LLVM build support and lld built here, the pinned SDK fetched, a host compiler)"
# Reported, not required: CMake finds gyb's python itself (step 4 names the one it found), and 3.14
# (CI), 3.13 (OS X 10.9, pkgsrc) and 3.9 (a modern Mac's Command Line Tools) have built the same runtime.
echo "    python3 on PATH: $(if command -v python3 >/dev/null 2>&1; then python3 --version 2>&1; else echo none; fi)"
[ -d "$LLVMB/lib/cmake/llvm" ] || { echo "FAIL: no LLVM build support at $LLVMB -- run ./build-llvm.sh"; exit 1; }
[ -x "$LLD" ] || { echo "FAIL: no $LLD -- run ./build-llvm.sh"; exit 1; }
# An override that names no file is reported as such; each mode's own message is for its own archive.
[ -z "${SWIFT_BUILTINS:-}" ] || [ -f "$SWIFT_BUILTINS" ] || {
  echo "FAIL: SWIFT_BUILTINS names no file: $SWIFT_BUILTINS"; exit 1; }
case "$MODE" in
  cross)
    PKG="$SWIFT_BUILD/cache/$TOOLCHAIN_ASSET"
    [ -f "$PKG" ] || { echo "FAIL: no swift.org toolchain at $PKG -- run ./mirror-toolchain.sh"; exit 1; }
    verify_toolchain_signature "$PKG"
    expand_toolchain "$PKG" toolchain || { echo "FAIL: could not expand $PKG"; exit 1; }
    TC="$ROOT/toolchain/usr"
    BUILTINS="${SWIFT_BUILTINS:-$ROOT/builtins-x86/lib/darwin/libclang_rt.osx.a}"
    [ -f "$BUILTINS" ] || { echo "FAIL: no builtins archive at $BUILTINS -- run ./build-builtins.sh"; exit 1; }
    CLANG_INC="$(clang_resource_include "$TC")" || { echo "FAIL: no one clang resource dir in $TC"; exit 1; }
    ;;
  native)
    HTC="${SWIFT_HOST_TOOLCHAIN:-/usr/local/mavergreen/swift-toolchain}"
    native_host_shim "$HTC" "$ROOT/native-host" || { echo "FAIL: no host toolchain shim from $HTC"; exit 1; }
    HTC_RELEASE="$(host_toolchain_release "$HTC")" || exit 1
    echo "    host toolchain $HTC: release $HTC_RELEASE"
    TC="$ROOT/native-host/usr"
    CLANG_INC="$(clang_resource_include "$HTC")" || { echo "FAIL: no one clang resource dir in $HTC"; exit 1; }
    BUILTINS="${SWIFT_BUILTINS:-$(dirname "$CLANG_INC")/lib/darwin/libclang_rt.osx.a}"
    [ -f "$BUILTINS" ] || { echo "FAIL: no builtins archive at $BUILTINS -- the installed swift-toolchain predates it; name one with SWIFT_BUILTINS"; exit 1; }
    # platform: step 7 reads imports with nm when there is no dyld_info; clang22's llvm-nm is the one
    #           proven on the box (the spike), and a GNU nm earlier on PATH would not know -m.
    NM="${NM:-/usr/local/mavergreen/clang22/bin/llvm-nm}"
    command -v "$NM" >/dev/null 2>&1 || { echo "FAIL: no $NM (mavericks-clang-22's native pkg provides it; NM names another)"; exit 1; }
    ;;
  *) echo "FAIL: mode '$MODE' is neither cross nor native"; exit 1 ;;
esac
SDK_RUNTIME="$(sh "$SHIPYARD/fetch_sdk.sh" --arch arm64)" || { echo "FAIL: could not fetch the pinned modern SDK"; exit 1; }
clang_resource_shim "$CLANG_INC" "$BUILTINS" "$ROOT/clang-resource" || { echo "FAIL: could not lay out $ROOT/clang-resource"; exit 1; }
echo "    host compiler $TC; SDK $SDK_RUNTIME; linker $LLD; builtins $BUILTINS"

echo "==> 2. pinned swift source, reset to pristine (a previous run left it patched)"
sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/swift.git "$SWIFT_TAG" "$SWIFT_SHA" swift
test "$(git -C swift rev-parse HEAD)" = "$SWIFT_SHA" || { echo "FAIL: swift SHA mismatch (want $SWIFT_SHA)"; exit 1; }
# platform: some macOS checkouts fail `git apply` with iconv_open(UTF-8, UTF-8-MAC) on unicode paths.
git -C swift config core.precomposeunicode false
git -C swift reset -q --hard "$SWIFT_SHA"
git -C swift clean -q -fdx

echo "==> 3. runtime patches (patches/runtime, applied in RUNTIME_PATCHES' order)"
#  0001 unsized operator delete  — 10.9's libc++ lacks __ZdlPvm (sized delete).
#       Safe: IRGen (the only consumer needing sized dealloc) isn't built here.
#  0002 os-version 10.9 fallback — guards os_system_version_get_current_version
#       (macOS 10.10, called unguarded by the availability backing) with a
#       CoreFoundation plist fallback so `if #available` works instead of aborting
#       under 10.9's dyld. Turns an unguarded weak import into a guarded one.
#  0003 guard objc_readClassPair (macOS 10.11) in swift_instantiateObjCClass AND
#       do the minimal in-place objc4-532 realization of runtime-instantiated
#       generic classes when it is absent (calloc class_rw_t, RW_REALIZED,
#       rw->ro=ro, empty cache/vtable, install into data_NEVER_USE) so the ObjC
#       runtime can read/message them on 10.9. (Replaces the earlier broken "skip".)
#  0004 realization-aware getROData — objc4-532 realizes classes eagerly at image
#       load, so a class's Data word may be a class_rw_t; follow rw->ro when
#       RW_REALIZED is set. Both overloads. Fixes garbage ro reads on 10.9.
#  0005 objc-super instance size — in initClassFieldOffsetVector, on the
#       readClassPair-absent (10.9/10.10) runtime, size a subclass from
#       class_getInstanceSize(super) when the objc-super branch would otherwise
#       under-size it (static Swift super's is-swift bit not observed on 10.9).
#  0007 is-swift mask legacy bit — SWIFT_CLASS_IS_SWIFT_MASK=1 for sub-10.14.4
#       Apple targets. The 6.3.3 compiler tags static classes with the LEGACY
#       is-swift bit (bit 0 / value 1) when targeting <10.14.4; a runtime that
#       hardcodes bit 1 (value 2) then reads every static Swift class as
#       isTypeMetadata()==false -> mangled reflection names, and is the root of
#       0005's superIsTypeMetadata==0. Confirmed safe on real 10.9.5 (pure-objc
#       classes leave data low bits free). This is the ROOT fix 0005 symptom-patched.
#  0008 drop @DebugDescription — equivalence, not 10.9: the toolchain that builds the runtime on
#       10.9 has no swift-syntax, so hasFeature(Macros) is false there, which compiles
#       ObjectIdentifier+DebugDescription.swift to nothing (CI's compiler expands its macro into
#       __TEXT,__lldbsummaries) and drops a String fast path in StringBridge.swift. 0008 drops
#       the file and keeps the fast path in both modes, so both build the same Swift code. Lost:
#       LLDB's ObjectIdentifier summary. Undone when the toolchain gains macros (milestone L).
# Patches are --no-prefix format; apply with -p0. A new patch needs its number here and a marker grep
# below: a patch file this list lacks fails the build rather than being skipped, and
# tests/runtime-patch-list-test.sh holds the list, the files and the marker greps together.
RUNTIME_PATCHES="0001 0002 0003 0004 0005 0007 0008"
PATCHES_DIR="$HERE/patches/runtime"
UNLISTED="$(runtime_patches_unlisted "$PATCHES_DIR" $RUNTIME_PATCHES)" || {
  [ -z "$UNLISTED" ] || printf '%s\n' "$UNLISTED"
  echo "FAIL: build.sh's RUNTIME_PATCHES does not list every patch in $PATCHES_DIR (listed above) -- add its number, and a marker grep"; exit 1; }
for n in $RUNTIME_PATCHES; do
  for p in "$PATCHES_DIR/$n"-*.patch; do
    git -C swift apply -p0 --check "$p" && git -C swift apply -p0 "$p" || { echo "patch failed: $p"; exit 1; }
  done
done
grep -q 'fno-sized-deallocation' swift/CMakeLists.txt || { echo "patch 0001 not applied"; exit 1; }
grep -q 'CFPropertyListCreateWithStream' swift/stdlib/public/stubs/Availability.mm || { echo "patch 0002 not applied"; exit 1; }
grep -q 'mav_minimalRealize' swift/stdlib/public/runtime/SwiftObject.mm || { echo "patch 0003 (realization) not applied"; exit 1; }
grep -q 'mav_roFromClassData' swift/stdlib/public/runtime/Metadata.cpp || { echo "patch 0004 (getROData) not applied"; exit 1; }
grep -q 'class_getInstanceSize((Class)const_cast' swift/stdlib/public/runtime/Metadata.cpp || { echo "patch 0005 (objc-super size) not applied"; exit 1; }
grep -q 'ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 101404' swift/include/swift/Runtime/Config.h || { echo "patch 0007 (is-swift mask) not applied"; exit 1; }
grep -q 'was: hasFeature(Macros)' swift/stdlib/public/core/StringBridge.swift || { echo "patch 0008 (DebugDescription) not applied"; exit 1; }
# de-instrumented: no debug logging must ship
! grep -rq 'getenv("MAV_' swift/stdlib/public/runtime/ || { echo "MAV debug logging leaked into patches"; exit 1; }

echo "==> 4. Swift STDLIB-ONLY configure (prebuilt toolchain as native tools)"
# Every compile maps the build root, by both its spellings, to /mavergreen-build. Every link (the
# runtime's, and CMake's own probes) is ld64.lld's; the runtime's also takes the builtins archive from
# the -resource-dir shim, so the driver puts it last. /opt/pkg is never searched (see build-llvm.sh).
PM_C="$(prefix_map_flags c "$ROOT")"
PM_SWIFT="$(prefix_map_flags swift "$ROOT")"
LINK="-fuse-ld=lld --ld-path=$LLD"
# A reused stdlib-build is kept only while the host compiler, clang, clang's cfgs and builtins archive are
# the bytes it was configured with: ninja cannot see them change (a toolchain update, say), and would keep the objects
# the previous ones built.
STAMP="$(host_inputs_stamp "$TC/bin/swift-frontend" "$TC/bin/clang" "$BUILTINS")" || { echo "FAIL: could not stamp the host inputs"; exit 1; }
reuse_build_dir "$ROOT/stdlib-build" "$STAMP" || exit 1
# LLVM_BUILD_* are build-tree-only variables that an install tree does not define, but
# SwiftSharedCMakeConfig.cmake preconditions on them. LLVM_BUILD_MAIN_SRC_DIR only needs to be
# set, never to exist: it feeds LLVM_MAIN_SRC_DIR, read solely by test/ and lib/Basic, both
# skipped under SWIFT_INCLUDE_TESTS=OFF / SWIFT_INCLUDE_TOOLS=OFF -- so no LLVM source is needed.
# Clang_DIR, LLVM_TABLEGEN and CLANG_TABLEGEN are deliberately absent: CMake reports them
# unused in this configuration, since the branch that would read them is behind SWIFT_INCLUDE_TOOLS.
shipyard-cmake -G Ninja -S swift -B "$ROOT/stdlib-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$TC/bin/clang" -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
  -DCMAKE_OSX_SYSROOT="$SDK_RUNTIME" -DSWIFT_SDK_OSX_PATH="$SDK_RUNTIME" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg \
  "-DCMAKE_C_FLAGS=$PM_C" "-DCMAKE_CXX_FLAGS=$PM_C" \
  "-DCMAKE_EXE_LINKER_FLAGS=$LINK" "-DCMAKE_MODULE_LINKER_FLAGS=$LINK" \
  "-DCMAKE_SHARED_LINKER_FLAGS=$LINK -resource-dir $ROOT/clang-resource" \
  -DLLVM_DIR="$LLVMB/lib/cmake/llvm" \
  -DLLVM_BUILD_LIBRARY_DIR="$LLVMB/lib" \
  -DLLVM_BUILD_BINARY_DIR="$LLVMB/bin" \
  -DLLVM_BUILD_MAIN_SRC_DIR="$LLVMB" \
  -DSWIFT_INCLUDE_TOOLS=OFF \
  -DSWIFT_BUILD_STDLIB=ON -DSWIFT_BUILD_DYNAMIC_STDLIB=ON -DSWIFT_BUILD_STATIC_STDLIB=OFF \
  -DSWIFT_BUILD_SDK_OVERLAY=OFF -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
  -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
  -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF \
  -DSWIFT_BUILD_PERF_TESTSUITE=OFF -DSWIFT_BUILD_EXAMPLES=OFF \
  -DSWIFT_SDKS="OSX" \
  -DSWIFT_HOST_VARIANT_SDK=OSX -DSWIFT_HOST_VARIANT_ARCH="$(uname -m)" \
  -DSWIFT_PRIMARY_VARIANT_SDK=OSX -DSWIFT_PRIMARY_VARIANT_ARCH="$ARCH" \
  -DSWIFT_DARWIN_SUPPORTED_ARCHS="$ARCH" \
  -DSWIFT_DARWIN_DEPLOYMENT_VERSION_OSX="$DEPLOYMENT" \
  -DSWIFT_THREADING_PACKAGE="OSX:pthreads" \
  -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$TC/bin" -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$TC/bin" \
  -DSWIFT_EXPERIMENTAL_EXTRA_FLAGS="$PM_SWIFT;-Xfrontend;-disable-availability-checking"
printf '%s\n' "$STAMP" > "$ROOT/stdlib-build/mavergreen-inputs.stamp"
PY="$(sed -n 's/^_Python3_EXECUTABLE:INTERNAL=//p' "$ROOT/stdlib-build/CMakeCache.txt")"
if [ -n "$PY" ]; then echo "    gyb runs $PY: $("$PY" --version 2>&1 || :)"; else echo "    CMake's cache names no python for gyb"; fi

echo "==> 5. build libswiftCore (+ SwiftOnoneSupport)"
ninja -C "$ROOT/stdlib-build" swiftCore-macosx-$ARCH swiftSwiftOnoneSupport-macosx-$ARCH

echo "==> 6. stage the payload (usr/local/mavergreen/swift-runtime/, for package.sh's pkgbuild --root)"
OUT="${SWIFT_RUNTIME_OUT:-$SWIFT_BUILD/payload/runtime}"
sh "$HERE/scripts/stage-runtime.sh" "$ROOT/stdlib-build/lib/swift/macosx/$ARCH" "$OUT" "$HERE/LICENSE"
CORE="$OUT/usr/local/mavergreen/swift-runtime/lib/swift/libswiftCore.dylib"

echo "==> 7. self pre-flight (must show minOS 10.9 and NO os_unfair_lock)"
# platform: dyld_info reads an x86_64 Mach-O natively on an arm64 host. `arch -x86_64 dyld_info`
#           needs Rosetta AND an x86_64 slice in dyld_info, and Command Line Tools 27 ships it arm64-only.
#           OS X 10.9 has none: macho_minos and macho_imports (lib.sh) fall back to otool and nm.
# Captured before any grep: piped straight into grep, a reader that could not run read as "no
# os_unfair_lock, no hard objc_readClassPair" and this step printed OK having checked nothing.
MINOS="$(DYLDINFO="$DYLDINFO" macho_minos "$CORE")"
IMPORTS_OUT="$(DYLDINFO="$DYLDINFO" macho_imports "$CORE")" || { echo "FAIL: could not read $CORE's imports"; exit 1; }
echo "minOS $MINOS; $(printf '%s\n' "$IMPORTS_OUT" | grep -c .) imports (read with ${DYLDINFO:-otool and ${NM:-nm}})"
[ "$MINOS" = "$DEPLOYMENT" ] || { echo "FAIL: built runtime is minOS '$MINOS', not $DEPLOYMENT"; exit 1; }
[ -n "$IMPORTS_OUT" ] || { echo "FAIL: read no imports from $CORE"; exit 1; }
if printf '%s\n' "$IMPORTS_OUT" | grep -q 'os_unfair_lock'; then
  echo "FAIL: os_unfair_lock still imported"; exit 1
fi
# objc_readClassPair must be present only as a *weak* import (guarded), never hard.
if printf '%s\n' "$IMPORTS_OUT" | grep 'objc_readClassPair' | grep -qv '\[weak-import\]'; then
  echo "FAIL: objc_readClassPair is a HARD import"; exit 1
fi
# The strings checks below capture strings' output first, as above: a dylib strings could not read
# would otherwise read as "no MAV_, no paths".
# release build must carry no debug-logging leftovers.
[ -f "$CORE" ] || { echo "FAIL: no $CORE to check"; exit 1; }
CORE_S="$(strings "$CORE")" || { echo "FAIL: could not read $CORE's strings"; exit 1; }
if printf '%s\n' "$CORE_S" | grep -q 'MAV_'; then
  echo "FAIL: debug (MAV_) strings present in shipped dylib"; exit 1
fi
# No path of this machine's work tree survives (the prefix maps above), in any spelling; nor any other
# absolute path (a foreign machine's, through a linked archive, say) beyond the mapped root and the OS's.
# An absolute path here is a / then a name of two or more characters then a /: strings -a also finds
# code bytes that start with / (such as "/h/h/", "/fff."), and a bare ^/ would fail on those.
RP="$(CDPATH='' cd -P -- "$ROOT" && pwd -P)"; LP="$(CDPATH='' cd -L -- "$ROOT" && pwd -L)"
for lib in "$CORE" "$(dirname "$CORE")/libswiftSwiftOnoneSupport.dylib"; do
  [ -f "$lib" ] || { echo "FAIL: no $lib to check"; exit 1; }
  S="$(strings -a "$lib")" || { echo "FAIL: could not read $lib's strings"; exit 1; }
  if printf '%s\n' "$S" | grep -F -e "$ROOT" -e "$RP" -e "$LP"; then
    echo "FAIL: $lib carries the build root's path (listed above)"; exit 1
  fi
  FOREIGN="$(printf '%s\n' "$S" | grep -E '^/[A-Za-z][A-Za-z0-9._-]+/' | grep -v -e '^/mavergreen-build/' -e '^/usr/lib/' -e '^/System/' || :)"
  if [ -n "$FOREIGN" ]; then
    printf '%s\n' "$FOREIGN"; echo "FAIL: $lib carries an absolute path outside /mavergreen-build, /usr/lib and /System (listed above)"; exit 1
  fi
done
echo "OK: no os_unfair_lock; objc_readClassPair weak-guarded; no debug strings; no build paths; staged in $OUT"
