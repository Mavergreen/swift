#!/bin/sh
# platform: macOS-only -- a modern Mac (cross: pkgutil and ditto expand the swift.org compiler) or OS X 10.9 (native)
# build.sh — from-source build of the Swift runtime (libswiftCore + libswiftSwiftOnoneSupport) for
# OS X 10.9 / x86_64, staged as the runtime .pkg's payload, and beside it, in the stdlib build's tree,
# libswift_Concurrency (the runtime pkg's third dylib, with its _Builtin_float module) and the
# Darwin and ObjectiveC overlays (libswiftDarwin, libswiftObjectiveC and their modules: swift-6.2's
# Platform and swift-5.4's ObjectiveC sources, pinned tarballs, compiled against the 10.9 SDK by
# scripts/build-module.sh with the stdlib's flags). No Apple prebuilt runtime bytes ship.
#
# One recipe, two modes (MAVERICKS_MODE, else shipyard's mavericks_mode.sh), the same bytes from both.
# The host Swift compiler and clang are a Mavergreen toolchain's, run bare through a shim dir, with the
# builtins archive that toolchain ships, whenever SWIFT_HOST_TOOLCHAIN names one:
#   cross (CI, a modern Mac): CI's build-cross job names the same run's cross toolchain, so the stdlib
#     every pkg ships is compiled by this repo's compiler. Without SWIFT_HOST_TOOLCHAIN the host is the
#     swift.org toolchain (mirror-toolchain.sh -> $SWIFT_BUILD/cache/<pkg>, signer-verified) with
#     build-builtins.sh's archive: CI's one seed, whose stdlib only makes that cross toolchain runnable.
#   native (OS X 10.9): the INSTALLED swift-toolchain (SWIFT_HOST_TOOLCHAIN, default
#     /usr/local/mavergreen/swift-toolchain), or a stage of self-host.sh.
#   Both: LLVM build support and ld64.lld from build-llvm.sh; the pinned modern SDK (shipyard's
#   fetch_sdk.sh --arch arm64, MacOSX11.3.sdk); the runtime linked by that lld with the builtins archive
#   where the driver puts its own; the build root prefix-mapped to /mavergreen-build; the swift source as
#   GitHub's tarball of SWIFT_SHA, verified by SWIFT_TARBALL_SHA256 and patched with the OS's patch;
#   mavericks-clang-22's llvm-ar and llvm-ranlib make the stdlib's archives (pins.env's CLANG22_VERSION:
#   cross, fetch-clang22.sh's; native, the installed one, CLANG22_PREFIX); the stdlib's C++ compiles against
#   that clang22's libc++ headers and links libcxx22's libc++.1.dylib (fetch-libcxx22.sh, the same release),
#   the family's one shared libc++, never the SDK's, which on 10.9 is the OS's own; libswiftCore links
#   Recaulk's definitions of the post-10.9 APIs RECAULK_RUNTIME_SYMBOLS names, statically, from
#   librecaulk.a (fetch-recaulk.sh, pins.env's RECAULK_VERSION), and nothing else of Recaulk's;
#   libswift_Concurrency, those RECAULK_CONCURRENCY_SYMBOLS names, the same way.
# Env: MAVERICKS_BUILD_ROOT (build root, see lib.sh), SWIFT_WORK (sources and build trees, default
#   $SWIFT_BUILD/work), SWIFT_RUNTIME_OUT (the staged payload, default $SWIFT_BUILD/payload/runtime),
#   SWIFT_SELFTEST_SUPPORT_OUT (the self-test's support, default $SWIFT_BUILD/payload/selftest-support),
#   MAVERICKS_MODE, SWIFT_HOST_TOOLCHAIN, SWIFT_HOST_TOOLCHAIN_VERSION (the release of a host toolchain no
#   pkg installed, a copy; see lib.sh's host_toolchain_release), SWIFT_BUILTINS (a libclang_rt.osx.a to
#   link instead of the mode's own), NM (native mode's nm), CLANG22_PREFIX, MAVERICKS_SDK_CACHE
#   (fetch_sdk.sh's cache), MAVERICKS_SOURCE_CACHE (fetch_pinned_source.sh's).
# Host: cmake through shipyard-cmake, ninja, python3 (gyb), curl, patch, tar. No git and, on OS X 10.9,
# none of Xcode's Command Line Tools: natively the checks read with clang22's llvm-otool, llvm-nm and
# llvm-strings. On 10.9 ninja and python3 are Mavergreen's packages, not pkgsrc's; see DEVELOPING.md.
# Output: $SWIFT_RUNTIME_OUT, in scripts/stage-runtime.sh's layout, for package.sh; and
#   $SWIFT_SELFTEST_SUPPORT_OUT, in scripts/stage-selftest-support.sh's, for make-selftest.sh (never a pkg).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"   # capture BEFORE the cd below: $0 is relative as ./build.sh
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, verify_toolchain_signature, expand_toolchain, the build helpers
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_pinned_source.sh, mavericks_mode.sh, fetch_sdk.sh)
ROOT="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$ROOT"; cd "$ROOT"
LLVMB="$SWIFT_BUILD/out/llvm"
LLD="$ROOT/llvm-build/bin/ld64.lld"
# gyb generates stdlib sources with Python; a fixed hash seed keeps set and dict order, and so those
# sources, the same from run to run (a two-root build once differed by 48 bytes of reordered strings).
PYTHONHASHSEED=0; export PYTHONHASHSEED
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"
# platform: OS X 10.9 has no dyld_info (nor, without the Command Line Tools, any xcrun to find a tool);
#           step 7 then reads the runtime with otool, nm and strings (lib.sh), clang22's below.
DYLDINFO=""
if [ "$MODE" = cross ]; then DYLDINFO="$(xcrun -f dyld_info 2>/dev/null || :)"; fi

echo "==> 1. host build environment ($MODE: LLVM build support and lld built here, the pinned SDK fetched, a host compiler)"
# Reported, not required: CMake finds gyb's python itself (step 4 names the one it found), and 3.14
# (CI), 3.13 (OS X 10.9, pkgsrc) and 3.9 (a modern Mac's Command Line Tools) have built the same runtime.
echo "    python3 on PATH: $(if command -v python3 >/dev/null 2>&1; then python3 --version 2>&1; else echo none; fi)"
[ -d "$LLVMB/lib/cmake/llvm" ] || { echo "FAIL: no LLVM build support at $LLVMB -- run ./build-llvm.sh"; exit 1; }
[ -x "$LLD" ] || { echo "FAIL: no $LLD -- run ./build-llvm.sh"; exit 1; }
# An override that names no file is reported as such; each mode's own message is for its own archive.
[ -z "${SWIFT_BUILTINS:-}" ] || [ -f "$SWIFT_BUILTINS" ] || {
  echo "FAIL: SWIFT_BUILTINS names no file: $SWIFT_BUILTINS"; exit 1; }
case "$MODE" in cross|native) ;; *) echo "FAIL: mode '$MODE' is neither cross nor native"; exit 1 ;; esac
HTC="${SWIFT_HOST_TOOLCHAIN:-}"
if [ -z "$HTC" ] && [ "$MODE" = native ]; then HTC=/usr/local/mavergreen/swift-toolchain; fi
CMAKE_ARCH_ARGS=""   # extra stdlib-configure arguments (word-split on use, step 4): the architecture a named host's clang needs
if [ -n "$HTC" ]; then
  native_host_shim "$HTC" "$ROOT/native-host" || { echo "FAIL: no host toolchain shim from $HTC"; exit 1; }
  HTC_RELEASE="$(host_toolchain_release "$HTC")" || exit 1
  echo "    host toolchain $HTC: release $HTC_RELEASE"
  # A named toolchain's clang is x86_64 only; on an arm64 Mac CMake's compiler probe would ask it for arm64.
  # (Byte-neutral: Task 1's stdlib with the cross toolchain as host was identical.) The swift.org host's
  # clang is universal and is left as it was, as is native mode, whose Mac is x86_64.
  if [ "$MODE" = cross ]; then
    CMAKE_ARCH_ARGS="-DCMAKE_OSX_ARCHITECTURES=$ARCH"
    echo "    cmake architectures: $CMAKE_ARCH_ARGS (a named host toolchain's clang is x86_64 only)"
  fi
  TC="$ROOT/native-host/usr"
  CLANG_INC="$(clang_resource_include "$HTC")" || { echo "FAIL: no one clang resource dir in $HTC"; exit 1; }
  BUILTINS="${SWIFT_BUILTINS:-$(dirname "$CLANG_INC")/lib/darwin/libclang_rt.osx.a}"
  [ -f "$BUILTINS" ] || { echo "FAIL: no builtins archive at $BUILTINS -- the host swift-toolchain predates it; name one with SWIFT_BUILTINS"; exit 1; }
else
  PKG="$SWIFT_BUILD/cache/$TOOLCHAIN_ASSET"
  [ -f "$PKG" ] || { echo "FAIL: no swift.org toolchain at $PKG -- run ./mirror-toolchain.sh"; exit 1; }
  verify_toolchain_signature "$PKG"
  expand_toolchain "$PKG" toolchain || { echo "FAIL: could not expand $PKG"; exit 1; }
  TC="$ROOT/toolchain/usr"
  BUILTINS="${SWIFT_BUILTINS:-$ROOT/builtins-x86/lib/darwin/libclang_rt.osx.a}"
  [ -f "$BUILTINS" ] || { echo "FAIL: no builtins archive at $BUILTINS -- run ./build-builtins.sh"; exit 1; }
  CLANG_INC="$(clang_resource_include "$TC")" || { echo "FAIL: no one clang resource dir in $TC"; exit 1; }
fi
if [ "$MODE" = native ]; then
  # platform: step 7 reads imports with nm when there is no dyld_info; clang22's llvm-nm is the one
  #           proven on the box (the spike), and a GNU nm earlier on PATH would not know -m.
  NM="${NM:-${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}/bin/llvm-nm}"
  command -v "$NM" >/dev/null 2>&1 || { echo "FAIL: no $NM (mavericks-clang-22's native pkg provides it; NM names another)"; exit 1; }
fi
SDK_RUNTIME="$(sh "$SHIPYARD/fetch_sdk.sh" --arch arm64)" || { echo "FAIL: could not fetch the pinned modern SDK"; exit 1; }
# The stdlib's archives (libswiftCommandLineSupport.a, which libswiftCore links) are made by clang22's
# llvm-ar and llvm-ranlib in both modes: the Command Line Tools' ar is a stub on 10.9 without them, and
# one archiver on both hosts makes the same archive bytes. llvm-lipo answers Swift's configure-time
# lipo lookup, which would otherwise ask xcrun. Natively, step 7 reads with clang22's llvm-otool and
# llvm-strings.
X="$(clang22_prefix "$MODE" "$HERE")/bin" || { echo "FAIL: no usable mavericks-clang-22 ($MODE)"; exit 1; }
if [ "$MODE" = native ]; then OTOOL="$X/llvm-otool"; STRINGS="$X/llvm-strings"; export OTOOL; else STRINGS=strings; fi
# spec: INGREDIENTS.md "One C++ runtime" -- one shared libc++ per process,
#       the family's, never the OS's: libcxx22's headers from the clang22 above, its dylib by path
#       (-L would be searched inside the SDK first, -isysroot's doing), and the headers' directory mapped,
#       since cross and native find them in different places
CXXINC="$(dirname "$X")/include/c++/v1"
[ -f "$CXXINC/__config" ] || { echo "FAIL: no libc++ headers at $CXXINC (mavericks-clang-22 ships them)"; exit 1; }
LIBCXX_PREFIX="$(sh "$HERE/fetch-libcxx22.sh")" || { echo "FAIL: could not fetch libcxx22 $CLANG22_VERSION"; exit 1; }
LIBCXX="$LIBCXX_PREFIX/lib/libc++.1.dylib"
# platform: ld64.lld follows libc++.1.dylib's re-export of libc++abi.1.dylib by its install name, under each
#           -syslibroot, and has no -dylib_file; a fetched libcxx22 is not at that name, so a second root
#           holds it there (CI's runner has no libcxx22 installed; the SDK stays the first root)
LIBCXX_ROOT="$ROOT/libcxx22-root"
rm -rf "$LIBCXX_ROOT"; mkdir -p "$LIBCXX_ROOT/usr/local/mavergreen"
ln -s "$LIBCXX_PREFIX" "$LIBCXX_ROOT/usr/local/mavergreen/libcxx22"
CXX_LIBCXX="-nostdinc++ -isystem $CXXINC -ffile-prefix-map=$CXXINC=/mavergreen-libcxx22/include"
# spec: INGREDIENTS.md "Recaulk" -- libswiftCore takes Recaulk's definition of each API named here, and
#       only those: a forwarder that calls the OS's where it has one (macOS 10.12 and later, for
#       os_system_version_get_current_version; macOS 10.11, objc_readClassPair) and Recaulk's body on
#       10.9. Not _objc_realizeClassFromSwift: upstream's legacy, fragile-layout path stays, as a 10.9
#       deployment target's metadata expects. And fma, fmal and truncl, which 10.9 has but gets wrong (fma's
#       sign in a cancellation, Double.addingProduct at -Onone; fmal's rounding, Float80.addingProduct;
#       truncl(-0) is +0, Float80.round(.towardZero)): Recaulk's are correct on every macOS, and
#       libswiftCore is the one shipped dylib that imports any of them. Only libswiftCore's own calls reach
#       these copies; a program's inlined stdlib code calls its own, which the toolchains' ld wrapper
#       links into every program (toolchain/ld). The whole archive would also
#       bind weak imports whose presence the runtime reads as "the OS has this" (os_signpost_enabled
#       turns tracing on over a NULL os_log_create on 10.9), so lib.sh's recaulk_subset picks the members
#       by symbol, and the link hides every global they define.
RECAULK_RUNTIME_SYMBOLS="_os_system_version_get_current_version _objc_readClassPair _fma _fmal _truncl"
RECAULK_PREFIX="$(sh "$HERE/fetch-recaulk.sh")" || { echo "FAIL: could not fetch Recaulk $RECAULK_VERSION"; exit 1; }
RECAULK_A="$ROOT/recaulk-runtime.a"; RECAULK_UNX="$ROOT/recaulk-runtime.unexported"
# shellcheck disable=SC2086  # space-free symbol names
( NM="$X/llvm-nm"; AR="$X/llvm-ar"; recaulk_subset "$RECAULK_PREFIX/lib/librecaulk.a" "$RECAULK_A" "$RECAULK_UNX" $RECAULK_RUNTIME_SYMBOLS ) \
  || { echo "FAIL: could not take $RECAULK_RUNTIME_SYMBOLS from $RECAULK_PREFIX/lib/librecaulk.a"; exit 1; }
echo "    Recaulk $RECAULK_VERSION: $RECAULK_RUNTIME_SYMBOLS, $(grep -c . "$RECAULK_UNX") globals, all unexported"
# spec: INGREDIENTS.md "Recaulk" -- libswift_Concurrency calls, unguarded or strongly, these APIs 10.9
#       lacks (the A1 spike's Q1 table): voucher_copy and voucher_adopt, strong (VoucherShims.h:60,63), so
#       without them it does not load; qos_class_self for every task created (Actor.cpp:345); clock_gettime
#       and clock_getres for every clock read and Task.sleep (Clock.cpp); dispatch_activate, a sleep with
#       tolerance (DispatchGlobalExecutor.cpp); os_release, once a voucher is non-NULL (VoucherShims.h:74);
#       and dispatch_assert_queue$V2, weak and called unguarded (ExecutorBridge.cpp:80), when
#       MainActor.assumeIsolated, preconditionIsolated or assertIsolated ask the main executor off its own
#       job. Its own subset, linked into it alone through patch 0013's hook and hidden as Core's is.
RECAULK_CONCURRENCY_SYMBOLS="_clock_gettime _clock_getres _qos_class_self _voucher_copy _voucher_adopt _os_release _dispatch_activate _dispatch_assert_queue\$V2"
RECAULK_CONC_A="$ROOT/recaulk-concurrency.a"; RECAULK_CONC_UNX="$ROOT/recaulk-concurrency.unexported"
# shellcheck disable=SC2086  # space-free symbol names
( NM="$X/llvm-nm"; AR="$X/llvm-ar"
  recaulk_subset "$RECAULK_PREFIX/lib/librecaulk.a" "$RECAULK_CONC_A" "$RECAULK_CONC_UNX" $RECAULK_CONCURRENCY_SYMBOLS ) \
  || { echo "FAIL: could not take $RECAULK_CONCURRENCY_SYMBOLS from $RECAULK_PREFIX/lib/librecaulk.a"; exit 1; }
echo "    Recaulk $RECAULK_VERSION for Concurrency: $RECAULK_CONCURRENCY_SYMBOLS, $(grep -c . "$RECAULK_CONC_UNX") globals, all unexported"
clang_resource_shim "$CLANG_INC" "$BUILTINS" "$ROOT/clang-resource" || { echo "FAIL: could not lay out $ROOT/clang-resource"; exit 1; }
echo "    host compiler $TC; SDK $SDK_RUNTIME; linker $LLD; builtins $BUILTINS"

echo "==> 2. pinned swift sources (GitHub's tarballs of SWIFT_SHA, and of SWIFT62_SHA and SWIFT54_SHA for the overlays, each verified by its TARBALL_SHA256, extracted afresh)"
fetch_source swift "$SWIFT_REPO_URL" "$SWIFT_SHA" "$SWIFT_TARBALL_SHA256" SWIFT_TARBALL_SHA256 || exit 1
fetch_source swift-6.2 "$SWIFT_REPO_URL" "$SWIFT62_SHA" "$SWIFT62_TARBALL_SHA256" SWIFT62_TARBALL_SHA256 || exit 1
fetch_source swift-5.4 "$SWIFT_REPO_URL" "$SWIFT54_SHA" "$SWIFT54_TARBALL_SHA256" SWIFT54_TARBALL_SHA256 || exit 1

echo "==> 3. runtime patches (patches/runtime, applied in RUNTIME_PATCHES' order)"
#  0004 realization-aware getROData — objc4-532 realizes classes eagerly at image
#       load, so a class's Data word may be a class_rw_t; follow rw->ro when
#       RW_REALIZED is set. Both overloads. Fixes garbage ro reads on 10.9.
#  0005 objc-super instance size — in initClassFieldOffsetVector, where
#       libobjc lacks readClassPair (10.9/10.10), size a subclass from
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
#  0009 no libc++ autolink — Metadata.cpp's `.linker_option "-lc++"` (for a statically linked
#       libswiftCore, never built here) would resolve to the SDK's libc++, i.e. 10.9's own, and load a
#       second libc++ beside libcxx22's, which the link names by path.
#  0010 Foundation-free StdlibUnittest — test support only, never in a pkg (step 5b builds it for the
#       self-test bundle): under -D MAVERICKS_NO_FOUNDATION it imports no Foundation, which no 10.9 pkg
#       ships (its weak Optional<Foundation.Locale> aborted every test there), and reads
#       SystemVersion.plist with POSIX calls. Core's and OnoneSupport's bytes are unchanged by it.
#  0011 float parsing delegation — step 4 compiles the stdlib under -disable-availability-checking,
#       where `#available` folds to true but refines nothing for overload resolution, so
#       FloatingPointParsing's generic init?<S: StringProtocol> took init?(_: Substring) (SwiftStdlib
#       5.3, above 10.9) for potentially unavailable and called itself: Double("1.1") overflowed the
#       stack and Float(String) looped, in Core and in every -O client that inlined the body. It now
#       delegates through a local function carrying the same @available, where the concrete init
#       resolves. Behavior is upstream's on every OS, since `#available` is folded away under that
#       flag; the compiler's own "infinite recursion" warning is gone.
#  0012 Concurrency deployment floor — Concurrency's CMakeLists.txt raised its deployment target to
#       10.15 whatever the stdlib's; it now follows SWIFT_DARWIN_DEPLOYMENT_VERSION_OSX, 10.9, so the dylib
#       records minOS 10.9 as Core does, and step 7 holds it to that.
#  0013 Concurrency extra link flags — a hook, MAVERGREEN_CONCURRENCY_LINK_FLAGS, appended to Concurrency's
#       LINK_FLAGS: step 4 passes Recaulk's subset for Concurrency and its unexported list, so they reach
#       that link alone (CMAKE_SHARED_LINKER_FLAGS, which carries Core's subset, reaches every dylib).
#  0014 Concurrency legacy dispatch priority — 10.9's libdispatch predates QoS classes: its
#       dispatch_get_global_queue answers NULL for every QoS class but 0, and Concurrency passed a job's
#       QoS. Below 10.10 a QoS now maps to the DISPATCH_QUEUE_PRIORITY_* value later libdispatch maps it to.
#  0015 Concurrency task_resume tracing guard — task_resume is the one trace call without ENSURE_LOGS(),
#       so on 10.9, where os_signpost is absent (weak, NULL), it called os_signpost_id_make_with_pointer:
#       the A1 spike's first box run died in dyld's lazy binding there.
#  0016 Concurrency continuous deadline as uptime — 10.9's libdispatch never fires a deadline in the
#       continuous clock's bit-63 encoding, and every Task.sleep uses one (the spike's box hung, both
#       threads idle); below 10.15 such a deadline is expressed as an uptime one, which 10.9 honours.
# Patches are --no-prefix format; patch_source applies them with -p0. A new patch needs its number here and a marker grep
# below: a patch file this list lacks fails the build rather than being skipped, and
# tests/runtime-patch-list-test.sh holds the list, the files and the marker greps together.
RUNTIME_PATCHES="0004 0005 0007 0008 0009 0010 0011 0012 0013 0014 0015 0016"
PATCHES_DIR="$HERE/patches/runtime"
UNLISTED="$(runtime_patches_unlisted "$PATCHES_DIR" $RUNTIME_PATCHES)" || {
  [ -z "$UNLISTED" ] || printf '%s\n' "$UNLISTED"
  echo "FAIL: build.sh's RUNTIME_PATCHES does not list every patch in $PATCHES_DIR (listed above) -- add its number, and a marker grep"; exit 1; }
for n in $RUNTIME_PATCHES; do
  for p in "$PATCHES_DIR/$n"-*.patch; do
    patch_source "$ROOT/swift" "$p" || exit 1
  done
done
grep -q 'mav_roFromClassData' swift/stdlib/public/runtime/Metadata.cpp || { echo "patch 0004 (getROData) not applied"; exit 1; }
grep -q 'class_getInstanceSize((Class)const_cast' swift/stdlib/public/runtime/Metadata.cpp || { echo "patch 0005 (objc-super size) not applied"; exit 1; }
grep -q 'ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 101404' swift/include/swift/Runtime/Config.h || { echo "patch 0007 (is-swift mask) not applied"; exit 1; }
grep -q 'was: hasFeature(Macros)' swift/stdlib/public/core/StringBridge.swift || { echo "patch 0008 (DebugDescription) not applied"; exit 1; }
grep -q 'Mavericks: no libc++ autolink' swift/stdlib/public/runtime/Metadata.cpp || { echo "patch 0009 (no libc++ autolink) not applied"; exit 1; }
grep -q 'Mavericks: Foundation-free StdlibUnittest' swift/stdlib/private/StdlibUnittest/StdlibUnittest.swift || { echo "patch 0010 (Foundation-free StdlibUnittest) not applied"; exit 1; }
grep -q 'Mavericks: through a function that carries the same availability' swift/stdlib/public/core/FloatingPointParsing.swift.gyb || { echo "patch 0011 (float parsing delegation) not applied"; exit 1; }
grep -q "Mavericks: follow the stdlib's 10.9" swift/stdlib/public/Concurrency/CMakeLists.txt || { echo "patch 0012 (Concurrency deployment floor) not applied"; exit 1; }
grep -q 'mavericks_concurrency_link_flags UNIX_COMMAND "${MAVERGREEN_CONCURRENCY_LINK_FLAGS}"' swift/stdlib/public/Concurrency/CMakeLists.txt || { echo "patch 0013 (Concurrency extra link flags) not applied"; exit 1; }
grep -q 'mav_globalQueueIdentifier' swift/stdlib/public/Concurrency/DispatchGlobalExecutor.cpp || { echo "patch 0014 (Concurrency legacy dispatch priority) not applied"; exit 1; }
grep -q 'ENSURE_LOGS();  // Mavericks: the one trace call without it' swift/stdlib/public/Concurrency/TracingSignpost.h || { echo "patch 0015 (Concurrency task_resume tracing guard) not applied"; exit 1; }
grep -q 'Mavericks: OS X 10.9.s libdispatch does not know the bit-63 encoding' swift/stdlib/public/Concurrency/DispatchGlobalExecutor.cpp || { echo "patch 0016 (Concurrency continuous deadline as uptime) not applied"; exit 1; }
# de-instrumented: no debug logging must ship
! grep -rq 'getenv("MAV_' swift/stdlib/public/runtime/ || { echo "MAV debug logging leaked into patches"; exit 1; }

echo "==> 4. Swift STDLIB-ONLY configure (prebuilt toolchain as native tools)"
# Every compile maps the build root, by both its spellings, to /mavergreen-build. Every link (the
# runtime's, and CMake's own probes) is ld64.lld's; the runtime's also takes the builtins archive from
# the -resource-dir shim, so the driver puts it last. /opt/pkg is never searched (see build-llvm.sh).
PM_C="$(prefix_map_flags c "$ROOT")"
PM_SWIFT="$(prefix_map_flags swift "$ROOT")"
LINK="-fuse-ld=lld --ld-path=$LLD"
# A reused stdlib-build is kept only while the host compiler, clang, clang's cfgs, builtins archive and
# archiver are the bytes it was configured with, and swift the source it compiled, with the same patches
# (a file a patch stops touching is extracted again with the tarball's old date): ninja cannot see them
# change (a toolchain update, say, or a pin moved to an older commit, whose tarball's files all carry that
# commit's date), and would keep the objects the previous ones built; and a configured tree keeps its
# first CMAKE_AR. The overlays' trees are stamped too: step 5b writes into this tree.
STAMP="$(host_inputs_stamp "$TC/bin/swift-frontend" "$TC/bin/clang" "$BUILTINS" "$X/llvm-ar" "$LIBCXX" "$CXXINC/__config" "$RECAULK_A" "$RECAULK_CONC_A" && source_stamp swift swift-6.2 swift-5.4)" || { echo "FAIL: could not stamp the host inputs and the swift sources"; exit 1; }
reuse_build_dir "$ROOT/stdlib-build" "$STAMP" || exit 1
# LLVM_BUILD_* are build-tree-only variables that an install tree does not define, but
# SwiftSharedCMakeConfig.cmake preconditions on them. LLVM_BUILD_MAIN_SRC_DIR only needs to be
# set, never to exist: it feeds LLVM_MAIN_SRC_DIR, read solely by test/ and lib/Basic, both
# skipped under SWIFT_INCLUDE_TESTS=OFF / SWIFT_INCLUDE_TOOLS=OFF -- so no LLVM source is needed.
# Clang_DIR, LLVM_TABLEGEN and CLANG_TABLEGEN are deliberately absent: CMake reports them
# unused in this configuration, since the branch that would read them is behind SWIFT_INCLUDE_TOOLS.
# LibXml2, LibEdit and pkg-config are not looked for, so what the host has on PATH changes nothing.
# No xcrun and no Command Line Tools name, in either mode (T5a): CMake's Apple probes answered (lib.sh's
# apple_probe_answers), and CMAKE_Swift_COMPILER named as what Swift's check_language(Swift) has always
# found here (NOTFOUND: this build compiles Swift through SWIFT_NATIVE_SWIFT_TOOLS_PATH), so that check's
# sub-configure, which names no SDK and asks xcrun for one, is not run.
# SWIFT_STDLIB_ENABLE_STRICT_AVAILABILITY: the declarations marked StdlibDeploymentTarget N (Duration, Clock,
# the String views' newer members, ...) keep SwiftStdlib N's OS versions in the modules we ship, as every
# other declaration does; without it AddSwiftStdlib.cmake clamps them to the deployment target, 10.9, for
# every client, and a client built for 10.15 could use Duration, which 10.15's own runtime lacks. Below
# 10.14.4 compiler patch 0003 opens them all the same (INGREDIENTS.md "The compiler's runtime table").
# shellcheck disable=SC2046  # space-free words
shipyard-cmake -G Ninja -S swift -B "$ROOT/stdlib-build" \
  $(apple_probe_answers "$X") -DCMAKE_Swift_COMPILER=NOTFOUND \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$TC/bin/clang" -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
  -DCMAKE_OSX_SYSROOT="$SDK_RUNTIME" -DSWIFT_SDK_OSX_PATH="$SDK_RUNTIME" \
  $CMAKE_ARCH_ARGS \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg \
  -DCMAKE_AR="$X/llvm-ar" -DCMAKE_RANLIB="$X/llvm-ranlib" -DSWIFT_LIPO="$X/llvm-lipo" \
  -DSWIFT_ENABLE_LIBXML2=OFF -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON -DCMAKE_DISABLE_FIND_PACKAGE_LibEdit=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
  "-DCMAKE_C_FLAGS=$PM_C" "-DCMAKE_CXX_FLAGS=$PM_C $CXX_LIBCXX" \
  "-DCMAKE_EXE_LINKER_FLAGS=$LINK" "-DCMAKE_MODULE_LINKER_FLAGS=$LINK" \
  "-DCMAKE_SHARED_LINKER_FLAGS=$LINK -resource-dir $ROOT/clang-resource -nostdlib++ $LIBCXX -Wl,-syslibroot,$LIBCXX_ROOT $RECAULK_A -Wl,-unexported_symbols_list,$RECAULK_UNX" \
  -DLLVM_DIR="$LLVMB/lib/cmake/llvm" \
  -DLLVM_BUILD_LIBRARY_DIR="$LLVMB/lib" \
  -DLLVM_BUILD_BINARY_DIR="$LLVMB/bin" \
  -DLLVM_BUILD_MAIN_SRC_DIR="$LLVMB" \
  -DSWIFT_INCLUDE_TOOLS=OFF \
  -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=ON \
  "-DMAVERGREEN_CONCURRENCY_LINK_FLAGS=$RECAULK_CONC_A -Wl,-unexported_symbols_list,$RECAULK_CONC_UNX" \
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
  -DSWIFT_STDLIB_ENABLE_STRICT_AVAILABILITY=ON \
  -DSWIFT_THREADING_PACKAGE="OSX:pthreads" \
  -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$TC/bin" -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$TC/bin" \
  -DSWIFT_EXPERIMENTAL_EXTRA_FLAGS="$PM_SWIFT;-Xfrontend;-disable-availability-checking"
printf '%s\n' "$STAMP" > "$ROOT/stdlib-build/mavergreen-inputs.stamp"
PY="$(sed -n 's/^_Python3_EXECUTABLE:INTERNAL=//p' "$ROOT/stdlib-build/CMakeCache.txt")"
if [ -n "$PY" ]; then echo "    gyb runs $PY: $("$PY" --version 2>&1 || :)"; else echo "    CMake's cache names no python for gyb"; fi

echo "==> 5. build libswiftCore (+ SwiftOnoneSupport, and _Concurrency)"
ninja -C "$ROOT/stdlib-build" swiftCore-macosx-$ARCH swiftSwiftOnoneSupport-macosx-$ARCH swift_Concurrency-macosx-$ARCH

echo "==> 5b. the Darwin and ObjectiveC overlays, beside libswiftCore (against the 10.9 SDK)"
# spec: "The overlays" -- written into the stdlib build's tree beside Core (lib/swift/macosx/<M>.swiftmodule,
#       macosx/x86_64/lib<swiftM>.dylib), so every later stage reads one tree. Compiled by the host
#       compiler that built Core, against the stdlib just built (its Swift module and libswiftCore) and the
#       10.9 SDK, as our swiftc asks for it (fetch_sdk.sh's SDKSettings.json): the overlays import the SDK's
#       C modules, and the 11.3 SDK's would declare APIs 10.9 lacks. Afresh every run, in seconds.
RES="$ROOT/stdlib-build/lib/swift"
OVS="$ROOT/overlays/src"; OVW="$ROOT/overlays/work"
SDK_OVERLAYS="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || { echo "FAIL: could not fetch the 10.9 SDK"; exit 1; }
# spec: INGREDIENTS.md "Recaulk" -- libswiftDarwin compiles LibcOverlayShims.h's _swift_stdlib_openat, which
#       calls openat (macOS 10.10), so a strong import that fails to load on 10.9: Recaulk's, linked and
#       hidden, as libswiftCore takes its own. Its members are macports-legacy-support's atcalls.c (under
#       the APSL) and pthread_chdir.c (MIT), beside Recaulk's forwarder and resolver.
RECAULK_DARWIN_SYMBOLS="_openat"
RECAULK_DARWIN_A="$ROOT/recaulk-darwin.a"; RECAULK_DARWIN_UNX="$ROOT/recaulk-darwin.unexported"
# shellcheck disable=SC2086  # space-free symbol names
( NM="$X/llvm-nm"; AR="$X/llvm-ar"
  recaulk_subset "$RECAULK_PREFIX/lib/librecaulk.a" "$RECAULK_DARWIN_A" "$RECAULK_DARWIN_UNX" $RECAULK_DARWIN_SYMBOLS ) \
  || { echo "FAIL: could not take $RECAULK_DARWIN_SYMBOLS from $RECAULK_PREFIX/lib/librecaulk.a"; exit 1; }
echo "    Recaulk $RECAULK_VERSION for Darwin: $RECAULK_DARWIN_SYMBOLS, $(grep -c . "$RECAULK_DARWIN_UNX") globals, all unexported"
PYTHON="${PY:-python3}" sh "$HERE/scripts/overlay-sources.sh" "$ROOT/swift-6.2" "$ROOT/swift-5.4" "$ROOT/swift/utils/gyb" "$OVS" \
  || { echo "FAIL: could not lay out the overlays' sources"; exit 1; }
# One line per module: build-module.sh <module> <link-name> [its options --] <sources>...
build_overlay() {
  _bo_m="$1"; _bo_l="$2"; shift 2
  SWIFT_WORK="$ROOT" SWIFTC="$TC/bin/swiftc" LLD="$LLD" sh "$HERE/scripts/build-module.sh" \
    --name "$_bo_m" --link-name "$_bo_l" --sdk "$SDK_OVERLAYS" --resource-dir "$RES" \
    --availability "$ROOT/swift/utils/availability-macros.def" --work "$OVW/$_bo_m" --out "$RES/macosx" "$@" \
    || { echo "FAIL: could not build the $_bo_m overlay"; exit 1; }
  echo "    $_bo_m: $RES/macosx/$_bo_m.swiftmodule, $RES/macosx/$ARCH/lib$_bo_l.dylib"
}
build_overlay Darwin swiftDarwin --link "$RECAULK_DARWIN_A" --unexported "$RECAULK_DARWIN_UNX" -- \
  "$OVS/Darwin/Darwin.swift" "$OVS/Darwin/Platform.swift" "$OVS/Darwin/TiocConstants.swift" \
  "$OVS/Darwin/tgmath.swift" "$OVS/Darwin/POSIXError.swift" "$OVS/Darwin/MachError.swift"
# ObjectiveC imports Darwin, found in --out, where Darwin was just written.
build_overlay ObjectiveC swiftObjectiveC --I "$OVS/ObjectiveC/shims" -- "$OVS/ObjectiveC/ObjectiveC.swift"

# spec: "Upstream tests" -- upstream's own Darwin, ObjectiveC and Concurrency tests run on the 10.9 gate; most import
#       StdlibUnittest: it, and the three modules it imports, are built here with build-module.sh, as their
#       6.4.1 CMakeLists.txt lists their sources and flags, against the Darwin and ObjectiveC just built, with
#       build-module.sh's --runtime-floor: they run only on this runtime, so every released SwiftStdlib version
#       is 10.9 for them (upstream's tests, built for 10.9, call StdlibUnittest's runAllTestsAsync, which says
#       SwiftStdlib 5.1; lit builds them for a newer OS). Test
#       support, never shipped: they go to their own dir, $SUP, not lib/swift/macosx, so no pkg's staging
#       (stage-runtime.sh, stage-toolchain.sh) and no toolchain_digest sees them; step 6 stages them for the
#       self-test bundle and step 7 holds the runtime's payload to none of them. StdlibUnittest is patch
#       0010's, -D MAVERICKS_NO_FOUNDATION, and -D SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY, as the stdlib's
#       CMake passes it with Concurrency on (SwiftSource.cmake): it imports _Concurrency (step 5 built it) for
#       its async entry points, runAllTestsAsync and the async `code`, which upstream's Concurrency tests
#       call; it is the one of the four that reads the define. Not built: stdlib/linker-support's
#       magic-symbols-for-install-name.c, which only names the OS's own earlier install names of a library.
#       Their C and C++ (Subprocess.c; InspectValue, InterceptTraps and OpaqueIdentityFunctions.cpp) are
#       compiled by the host clang against the 10.9 SDK, with the runtime's threading package (pthreads) and
#       libcxx22's headers, and handed to the link; they call nothing of a C++ library (step 7 holds them to
#       that), so no libc++ is linked.
SUP="$ROOT/stdlib-build/selftest-support"; SUW="$ROOT/selftest-support"; PRIV="$ROOT/swift/stdlib/private"
rm -rf "$SUP" "$SUW"; mkdir -p "$SUW/src" "$SUW/obj" "$SUW/probe"
# The floor and the define make StdlibUnittest's @available(SwiftStdlib 5.1) async functions 10.9
# declarations, which only compiler patch 0003 accepts. A host compiler without it -- CI's swift.org seed,
# whose stdlib ships nowhere (build-cross's second build.sh, with the cross toolchain, stages the support
# vm-test uses), or a 6.4.1-mavericks.9 or earlier toolchain on 10.9 -- refuses them ("concurrency is only
# available in macOS 10.15.0 or newer"). So the host compiler is asked once, with a 10.9 async function and
# no availability flag: refused for that reason, test support is built as it was before Concurrency, with
# neither, and step 6 stages every layer but upstream's concurrency tests, which need both; refused for
# any other, the build stops.
printf 'func mavergreenProbe() async {}\n' > "$SUW/probe/probe.swift"
UPSTREAM_LISTS="$HERE/tests/upstream"; SUPPORT_FLOOR=--runtime-floor
SUPPORT_CONCURRENCY="--flag -D --flag SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY"
if "$TC/bin/swiftc" -typecheck -parse-as-library -target "$ARCH-apple-macosx$DEPLOYMENT" -sdk "$SDK_OVERLAYS" -resource-dir "$RES" \
     -module-cache-path "$SUW/probe/cache" "$SUW/probe/probe.swift" > "$SUW/probe/out" 2>&1; then
  echo "    test support: with Concurrency (the host compiler declares an async function for macOS $DEPLOYMENT)"
elif grep -q 'error: concurrency is only available in' "$SUW/probe/out"; then
  echo "    test support: without Concurrency -- the host compiler (no compiler patch 0003) answers: $(grep -m1 'error: ' "$SUW/probe/out" | sed 's/^.*error: //'); upstream's concurrency tests are not staged"
  SUPPORT_FLOOR=""; SUPPORT_CONCURRENCY=""; UPSTREAM_LISTS="$SUW/lists"; mkdir -p "$UPSTREAM_LISTS"
  for l in "$HERE"/tests/upstream/*.list; do
    case "${l##*/}" in concurrency.list) ;; *) cp "$l" "$UPSTREAM_LISTS/" ;; esac
  done
else
  cat "$SUW/probe/out"; echo "FAIL: could not ask $TC/bin/swiftc for a $DEPLOYMENT async function (above)"; exit 1
fi
"${PY:-python3}" "$ROOT/swift/utils/gyb" --line-directive '' -o "$SUW/src/AtomicInt.swift" "$PRIV/SwiftPrivate/AtomicInt.swift.gyb" \
  || { echo "FAIL: gyb failed on $PRIV/SwiftPrivate/AtomicInt.swift.gyb"; exit 1; }
# support_object clang|clang++ <source> [<flag>...] -- $SUW/obj/<source's name>.o
support_object() {
  _so_cc="$1"; _so_s="$2"; shift 2
  # shellcheck disable=SC2086  # space-free words
  "$TC/bin/$_so_cc" -c -target "$ARCH-apple-macosx$DEPLOYMENT" -isysroot "$SDK_OVERLAYS" $PM_C -O2 -g0 -fPIC -fvisibility=hidden \
    -DNDEBUG -DSWIFT_THREADING_PTHREADS -DSWIFT_LIBRARY_EVOLUTION=1 -I"$ROOT/stdlib-build/include" -I"$ROOT/swift/include" \
    -I"$ROOT/swift/stdlib/include" -I"$ROOT/swift/stdlib/public/SwiftShims" "$@" -o "$SUW/obj/${_so_s##*/}.o" "$_so_s" \
    || { echo "FAIL: could not compile $_so_s"; exit 1; }
}
support_object clang "$PRIV/SwiftPrivateLibcExtras/Subprocess.c"
for f in InspectValue InterceptTraps OpaqueIdentityFunctions; do
  # shellcheck disable=SC2086  # space-free words
  support_object clang++ "$PRIV/StdlibUnittest/$f.cpp" -std=c++17 -fno-exceptions -fno-rtti $CXX_LIBCXX \
    -DSWIFT_INLINE_NAMESPACE=__runtime -DLLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1
done
# One line per module, in the order they import each other: build-module.sh <module> [its options --] <sources>...
build_support() {
  _bs_m="$1"; shift
  # shellcheck disable=SC2086  # SUPPORT_FLOOR: one word, or none
  SWIFT_WORK="$ROOT" SWIFTC="$TC/bin/swiftc" LLD="$LLD" sh "$HERE/scripts/build-module.sh" \
    --name "$_bs_m" --link-name "swift$_bs_m" --sdk "$SDK_OVERLAYS" --resource-dir "$RES" \
    --availability "$ROOT/swift/utils/availability-macros.def" --work "$SUW/work/$_bs_m" --out "$SUP" $SUPPORT_FLOOR "$@" \
    || { echo "FAIL: could not build the test-support module $_bs_m"; exit 1; }
}
P="$PRIV/SwiftPrivate"
build_support SwiftPrivate --flag -parse-stdlib --flag -Xfrontend --flag -disable-access-control -- \
  "$P/SwiftPrivate.swift" "$P/IO.swift" "$P/ShardedAtomicCounter.swift" "$SUW/src/AtomicInt.swift"
P="$PRIV/SwiftPrivateLibcExtras"
build_support SwiftPrivateLibcExtras --flag -D --flag SWIFT_STDLIB_HAS_COMMANDLINE --link "$SUW/obj/Subprocess.c.o" -- \
  "$P/SwiftPrivateLibcExtras.swift" "$P/Subprocess.swift"
P="$PRIV/SwiftPrivateThreadExtras"
build_support SwiftPrivateThreadExtras -- "$P/SwiftPrivateThreadExtras.swift" "$P/ThreadBarriers.swift"
P="$PRIV/StdlibUnittest"
# shellcheck disable=SC2086  # space-free words
build_support StdlibUnittest $SUPPORT_CONCURRENCY --flag -D --flag MAVERICKS_NO_FOUNDATION \
  --flag -enable-experimental-feature --flag Lifetimes \
  --link "$SUW/obj/InspectValue.cpp.o" --link "$SUW/obj/InterceptTraps.cpp.o" --link "$SUW/obj/OpaqueIdentityFunctions.cpp.o" -- \
  "$P/StdlibUnittest.swift" "$P/CheckStrideable.swift" "$P/InspectValue.swift" "$P/LifetimeTracked.swift" "$P/MinimalTypes.swift" \
  "$P/OpaqueIdentityFunctions.swift" "$P/RaceTest.swift" "$P/Statistics.swift" "$P/StdlibCoreExtras.swift" \
  "$P/StringConvertible.swift" "$P/StringTestHelpers.swift" "$P/TestHelpers.swift" "$P/TypeIndexed.swift"
SUPPORT_DYLIBS="$SUP/$ARCH/libswiftSwiftPrivate.dylib $SUP/$ARCH/libswiftSwiftPrivateLibcExtras.dylib $SUP/$ARCH/libswiftSwiftPrivateThreadExtras.dylib $SUP/$ARCH/libswiftStdlibUnittest.dylib"
echo "    test support (never in a pkg): $SUP: SwiftPrivate, SwiftPrivateLibcExtras, SwiftPrivateThreadExtras, StdlibUnittest"
# spec: "Upstream tests" -- tests/upstream/<layer>.list names every upstream test the layer's classifier
#       picks from this tree, include or exclude with a reason: a Swift bump that adds one, or gives an included
#       one a RUN: form, compiler flag or REQUIRES:/UNSUPPORTED: the script does not know, stops here until the
#       list is reviewed (scripts/upstream-tests.py check; a changed source does not stop it).
for l in "$HERE"/tests/upstream/*.list; do
  UL="$("${PY:-python3}" -I "$HERE/scripts/upstream-tests.py" check "$ROOT/swift" "$(basename "$l" .list)" "$l" 2>&1)" \
    || { printf '%s\n' "$UL"; echo "FAIL: $l does not cover $ROOT/swift's $(basename "$l" .list) tests (above) -- review the new or changed ones"; exit 1; }
  echo "    $UL"
done

echo "==> 6. stage the payload (usr/local/mavergreen/swift-runtime/, for package.sh's pkgbuild --root)"
OUT="${SWIFT_RUNTIME_OUT:-$SWIFT_BUILD/payload/runtime}"
sh "$HERE/scripts/stage-runtime.sh" "$ROOT/stdlib-build/lib/swift/macosx/$ARCH" "$OUT" "$HERE/LICENSE" "$HERE/NOTICE"
CORE="$OUT/usr/local/mavergreen/swift-runtime/lib/swift/libswiftCore.dylib"
# Beside it, never in it: the self-test bundle's test support and upstream's tests (make-selftest.sh's
# SELFTEST_SUPPORT), which CI's build-cross uploads with the payload for vm-test.
SELFTEST_SUPPORT_OUT="${SWIFT_SELFTEST_SUPPORT_OUT:-$SWIFT_BUILD/payload/selftest-support}"
PYTHON="${PY:-python3}" sh "$HERE/scripts/stage-selftest-support.sh" "$ROOT/stdlib-build" "$ROOT/swift" "$UPSTREAM_LISTS" "$SELFTEST_SUPPORT_OUT" \
  || { echo "FAIL: could not stage the self-test's support in $SELFTEST_SUPPORT_OUT"; exit 1; }

echo "==> 7. self pre-flight (must show minOS 10.9 and NO os_unfair_lock)"
# Every dylib that ships: the staged runtime's two, and the overlays and libswift_Concurrency, read from the
# stdlib build's tree where steps 5 and 5b wrote them (space-free paths: lib.sh refuses a root with whitespace).
DARWIN="$RES/macosx/$ARCH/libswiftDarwin.dylib"
CONCURRENCY="$RES/macosx/$ARCH/libswift_Concurrency.dylib"
SHIPPED_DYLIBS="$CORE $(dirname "$CORE")/libswiftSwiftOnoneSupport.dylib $DARWIN $RES/macosx/$ARCH/libswiftObjectiveC.dylib $CONCURRENCY"
for lib in $SHIPPED_DYLIBS; do [ -f "$lib" ] || { echo "FAIL: no $lib to check"; exit 1; }; done
# platform: dyld_info reads an x86_64 Mach-O natively on an arm64 host. `arch -x86_64 dyld_info`
#           needs Rosetta AND an x86_64 slice in dyld_info, and Command Line Tools 27 ships it arm64-only.
#           OS X 10.9 has none: macho_minos and macho_imports (lib.sh) fall back to otool and nm.
# Captured before any grep: piped straight into grep, a reader that could not run read as "no
# os_unfair_lock" and this step printed OK having checked nothing.
IMPORTS_OUT="$(DYLDINFO="$DYLDINFO" macho_imports "$CORE")" || { echo "FAIL: could not read $CORE's imports"; exit 1; }
echo "$(printf '%s\n' "$IMPORTS_OUT" | grep -c .) imports in $(basename "$CORE") (read with ${DYLDINFO:-${OTOOL:-otool} and ${NM:-nm}})"
[ -n "$IMPORTS_OUT" ] || { echo "FAIL: read no imports from $CORE"; exit 1; }
if printf '%s\n' "$IMPORTS_OUT" | grep -q 'os_unfair_lock'; then
  echo "FAIL: os_unfair_lock still imported"; exit 1
fi
# spec: INGREDIENTS.md "Recaulk" -- each API Recaulk supplies is defined in the image and hidden, never
#       imported; and no other global its members define is exported (the unexported list hides them all).
# recaulk_hidden <dylib> <unexported-list> <symbol>...
recaulk_hidden() {
  _rh_lib="$1"; _rh_unx="$2"; shift 2
  _rh_imp="$(DYLDINFO="$DYLDINFO" macho_imports "$_rh_lib")" || { echo "FAIL: could not read $_rh_lib's imports"; exit 1; }
  _rh_exp="$("${NM:-nm}" -gU "$_rh_lib" | awk '{ print $NF }')" || { echo "FAIL: could not read $_rh_lib's exports"; exit 1; }
  _rh_syms="$("${NM:-nm}" "$_rh_lib")" || { echo "FAIL: could not read $_rh_lib's symbols"; exit 1; }
  [ -n "$_rh_exp" ] || { echo "FAIL: read no exports from $_rh_lib"; exit 1; }
  for _rh_s in "$@"; do
    # Whole names, compared as strings: _fma is not _fmaf, and dispatch_assert_queue$V2 has a $ in it.
    if printf '%s\n' "$_rh_imp" | awk -v s="$_rh_s" '$1 == s { f = 1 } END { exit !f }'; then echo "FAIL: $_rh_s is imported by $_rh_lib, not Recaulk's"; exit 1; fi
    printf '%s\n' "$_rh_syms" | awk -v s="$_rh_s" '($(NF - 1) == "T" || $(NF - 1) == "t") && $NF == s { f = 1 } END { exit !f }' \
      || { echo "FAIL: $_rh_lib does not define $_rh_s"; exit 1; }
  done
  _rh_leak="$(printf '%s\n' "$_rh_exp" | grep -Fx -f "$_rh_unx" || :)"
  [ -z "$_rh_leak" ] || { printf '%s\n' "$_rh_leak"; echo "FAIL: $_rh_lib exports Recaulk's globals (listed above)"; exit 1; }
  if printf '%s\n' "$_rh_exp" | grep -q '^___recaulk_'; then
    printf '%s\n' "$_rh_exp" | grep '^___recaulk_'; echo "FAIL: $_rh_lib exports Recaulk's internals (listed above)"; exit 1
  fi
}
# shellcheck disable=SC2086  # space-free symbol names
recaulk_hidden "$CORE" "$RECAULK_UNX" $RECAULK_RUNTIME_SYMBOLS
recaulk_hidden "$DARWIN" "$RECAULK_DARWIN_UNX" $RECAULK_DARWIN_SYMBOLS
# shellcheck disable=SC2086  # space-free symbol names
recaulk_hidden "$CONCURRENCY" "$RECAULK_CONC_UNX" $RECAULK_CONCURRENCY_SYMBOLS
# spec: INGREDIENTS.md "Recaulk" -- APSL 2.0 section 2.3 wants the "source is available" notice in the code
#       itself and in the documentation. Recaulk embeds it in each Apple-derived member and lists it in
#       share/recaulk/notices.tsv: every dylib that links a Recaulk subset (libswiftCore, libswiftDarwin and
#       libswift_Concurrency; the other two link none) must still carry the notice of each APSL member it
#       links after our link (dead-stripping, -S, the unexported list), and NOTICE must carry it too
#       (lib.sh's recaulk_notices).
#       The tsv lists only APSL members, so a linked MacPorts mp-* member without a row passes only when
#       named here, its licence read and carried in NOTICE: pthread_chdir.c is under legacy-support's MIT
#       LICENSE, and time.c (Concurrency's clock_gettime) under its own ISC-style grant
#       (tests/notice-test.sh holds NOTICE to each name).
RECAULK_NOTICES_REVIEWED="mp-pthread_chdir.o mp-time.o"
# recaulk_notices_in <dylib> <subset.a>
recaulk_notices_in() {
  _rni="$(AR="$X/llvm-ar"; recaulk_notices "$RECAULK_PREFIX/share/recaulk/notices.tsv" "$2" "$1" "$HERE/NOTICE")" \
    || { echo "FAIL: ${1##*/} or NOTICE lacks the APSL notice of a Recaulk member it links (named above)"; exit 1; }
  echo "    ${1##*/}: Recaulk's APSL notices in the code and in NOTICE: $(printf '%s' "${_rni:-none linked}" | tr '\n' ' ')"
}
recaulk_notices_in "$CORE" "$RECAULK_A"
recaulk_notices_in "$DARWIN" "$RECAULK_DARWIN_A"
recaulk_notices_in "$CONCURRENCY" "$RECAULK_CONC_A"
# spec: INGREDIENTS.md "Recaulk in every program" -- both toolchain pkgs ship this librecaulk.a whole
#       (stage-toolchain.sh's lib/recaulk), so NOTICE carries the notice of every APSL member in it (the
#       archive's strings hold each one), and every other MacPorts member is named here, its source's
#       licence read and carried in NOTICE (tests/notice-test.sh holds NOTICE to each name).
RECAULK_ARCHIVE_REVIEWED="mp-clonefile.o mp-dirfuncs_compat.o mp-fmemopen.o mp-fsgetpath.o mp-getentropy.o mp-memstream.o mp-os_unfair_lock.o mp-pthread_chdir.o mp-pthread_get_stacksize_np.o mp-sysconf.o mp-time.o"
_rna="$(AR="$X/llvm-ar"; RECAULK_NOTICES_REVIEWED="$RECAULK_ARCHIVE_REVIEWED"
  recaulk_notices "$RECAULK_PREFIX/share/recaulk/notices.tsv" "$RECAULK_PREFIX/lib/librecaulk.a" "$RECAULK_PREFIX/lib/librecaulk.a" "$HERE/NOTICE")" \
  || { echo "FAIL: NOTICE lacks the notice of an APSL member of librecaulk.a, which the toolchain pkgs ship, or a MacPorts member is unreviewed (named above)"; exit 1; }
echo "    librecaulk.a, which the toolchain pkgs ship: its APSL members' notices in NOTICE: $(printf '%s' "$_rna" | tr '\n' ' ')"
# spec: INGREDIENTS.md "The compiler's runtime table" -- libswift_Builtin_float is not shipped: 6.4's _Concurrency
#       imports its module, and its $ld$previous sends a client below 10.14.4 to @rpath/libswiftDarwin.dylib for the
#       float constants it declares. So every export it has (its force-load symbol and the $ld$ directives aside)
#       must be one libswiftDarwin defines, or a 10.9 program using one fails in dyld, not here. A reader that
#       found no exports would pass vacuously, so none is a failure.
BUILTIN_FLOAT="$RES/macosx/$ARCH/libswift_Builtin_float.dylib"
[ -f "$BUILTIN_FLOAT" ] || { echo "FAIL: no $BUILTIN_FLOAT to check"; exit 1; }
BF_EXPORTS="$("${NM:-nm}" -gU "$BUILTIN_FLOAT" | awk '{ print $NF }' | grep -v -e '^\$ld\$' -e '^__swift_FORCE_LOAD_\$_swift_Builtin_float$' | LC_ALL=C sort)" \
  || { echo "FAIL: could not read $BUILTIN_FLOAT's exports"; exit 1; }
[ -n "$BF_EXPORTS" ] || { echo "FAIL: read no exports from $BUILTIN_FLOAT"; exit 1; }
DARWIN_EXPORTS="$("${NM:-nm}" -gU "$DARWIN" | awk '{ print $NF }' | LC_ALL=C sort)" \
  || { echo "FAIL: could not read $DARWIN's exports"; exit 1; }
printf '%s\n' "$BF_EXPORTS" > "$ROOT/builtin-float-exports.txt"; printf '%s\n' "$DARWIN_EXPORTS" > "$ROOT/darwin-exports.txt"
BF_MISSING="$(LC_ALL=C comm -23 "$ROOT/builtin-float-exports.txt" "$ROOT/darwin-exports.txt")"
rm -f "$ROOT/builtin-float-exports.txt" "$ROOT/darwin-exports.txt"
[ -z "$BF_MISSING" ] || { printf '%s\n' "$BF_MISSING"; echo "FAIL: libswiftDarwin does not define what libswift_Builtin_float exports (listed above)"; exit 1; }
#       The weak imports whose presence the runtime reads as the OS's answer stay the OS's (a
#       whole-archive link would bind them, and os_signpost_enabled would turn tracing on over NULLs).
for s in objc_realizeClassFromSwift os_signpost_enabled os_signpost_emit_with_name_impl availability_version_check; do
  printf '%s\n' "$IMPORTS_OUT" | grep "$s" | grep -q '\[weak-import\]' \
    || { echo "FAIL: $s is not a weak import of the OS's (a Recaulk definition bound it?)"; exit 1; }
done
#       libswift_Concurrency's tracing reads them the same way (TracingCommon.h's weak check, then each
#       call's ENSURE_LOGS, patch 0015 adding task_resume's), so they stay weak imports of the OS's too.
CONC_IMPORTS="$(DYLDINFO="$DYLDINFO" macho_imports "$CONCURRENCY")" || { echo "FAIL: could not read $CONCURRENCY's imports"; exit 1; }
[ -n "$CONC_IMPORTS" ] || { echo "FAIL: read no imports from $CONCURRENCY"; exit 1; }
for s in _os_signpost_enabled __os_signpost_emit_with_name_impl __os_log_create _os_signpost_id_generate _os_signpost_id_make_with_pointer; do
  printf '%s\n' "$CONC_IMPORTS" | awk -v s="$s" '$1 == s && $2 == "[weak-import]" { f = 1 } END { exit !f }' \
    || { echo "FAIL: $s is not a weak import of the OS's in $CONCURRENCY (a Recaulk definition bound it?)"; exit 1; }
done
# spec: INGREDIENTS.md "Recaulk" -- an import the OS lacks fails in dyld on a real 10.9 box, not at link
#       time against the 11.3 SDK. Every symbol the shipped dylibs import from /usr/lib or a framework is
#       checked against the 10.9 SDK's own stubs (lib.sh's sdk109_stubs); a weak one the stubs lack must
#       have a guard cited in the allowlist. Captured first: the output is the list of what failed.
SDK109="$(sdk109_stubs)" || { echo "FAIL: could not fetch the 10.9 SDK's stubs"; exit 1; }
# shellcheck disable=SC2086  # space-free paths
IMPORTS_109="$(DYLDINFO="$DYLDINFO" NM="${NM:-nm}" OTOOL="${OTOOL:-otool}" sh "$HERE/scripts/imports-on-10.9.sh" "$SDK109" \
  "$HERE/scripts/resources/weak-absent-on-10.9.txt" $SHIPPED_DYLIBS)" \
  || { printf '%s\n' "$IMPORTS_109"; echo "FAIL: an OS import is missing from OS X 10.9 (listed above)"; exit 1; }
printf '%s\n' "$IMPORTS_109"
# The strings checks below capture strings' output first, as above: a dylib strings could not read
# would otherwise read as "no MAV_, no paths".
# No path of this machine's work tree survives (the prefix maps above), in any spelling; nor any other
# absolute path (a foreign machine's, through a linked archive, say) beyond the mapped root and the OS's.
# An absolute path here is a / then a name of two or more characters then a /: strings -a also finds
# code bytes that start with / (such as "/h/h/", "/fff."), and a bare ^/ would fail on those.
RP="$(CDPATH='' cd -P -- "$ROOT" && pwd -P)"; LP="$(CDPATH='' cd -L -- "$ROOT" && pwd -L)"
for lib in $SHIPPED_DYLIBS; do
  MINOS="$(DYLDINFO="$DYLDINFO" macho_minos "$lib")"
  [ "$MINOS" = "$DEPLOYMENT" ] || { echo "FAIL: $lib is minOS '$MINOS', not $DEPLOYMENT"; exit 1; }
  S="$("$STRINGS" -a "$lib")" || { echo "FAIL: could not read $lib's strings ($STRINGS)"; exit 1; }
  [ -n "$S" ] || { echo "FAIL: read no strings from $lib ($STRINGS)"; exit 1; }
  # release build must carry no debug-logging leftovers.
  if printf '%s\n' "$S" | grep -q 'MAV_'; then
    echo "FAIL: debug (MAV_) strings present in $lib"; exit 1
  fi
  if printf '%s\n' "$S" | grep -F -e "$ROOT" -e "$RP" -e "$LP"; then
    echo "FAIL: $lib carries the build root's path (listed above)"; exit 1
  fi
  FOREIGN="$(printf '%s\n' "$S" | grep -E '^/[A-Za-z][A-Za-z0-9._-]+/' | grep -v -e '^/mavergreen-build/' -e '^/usr/lib/' -e '^/System/' \
    -e '^/usr/local/mavergreen/libcxx22/lib/libc++\.1\.dylib$' || :)"
  if [ -n "$FOREIGN" ]; then
    printf '%s\n' "$FOREIGN"; echo "FAIL: $lib carries an absolute path outside /mavergreen-build, /usr/lib, /System and libcxx22's libc++ (listed above)"; exit 1
  fi
  # spec: INGREDIENTS.md "One C++ runtime" -- one libc++, the family's,
  #       and one libc++abi, the OS's (libcxx22 re-exports it). The runtime's two have C++ and link
  #       libcxx22's; the overlays have none, and the rule there is only "never the OS's libc++".
  DEPS="$("${OTOOL:-otool}" -L "$lib" | sed 1d | sed 's/^[[:space:]]*//; s/ (compatibility.*//')" || { echo "FAIL: could not list $lib's libraries"; exit 1; }
  printf '%s\n' "$DEPS" | grep -qx '/usr/lib/libSystem\.B\.dylib' \
    || { printf '%s\n' "$DEPS"; echo "FAIL: ${OTOOL:-otool} read no libSystem from $lib, so it read nothing $lib links (listed above)"; exit 1; }
  case "${lib##*/}" in
    libswiftCore.dylib|libswiftSwiftOnoneSupport.dylib|libswift_Concurrency.dylib)
      printf '%s\n' "$DEPS" | grep -qx '/usr/local/mavergreen/libcxx22/lib/libc++\.1\.dylib' \
        || { printf '%s\n' "$DEPS"; echo "FAIL: $lib does not link libcxx22's libc++ (listed above)"; exit 1; }
      # Concurrency is a stdlib dylib, named as Core is (/usr/lib/swift/<name>, with an $ld$previous that
      # makes a 10.9 client record @rpath/<name>); through _Builtin_float, whose $ld$previous below 10.14.4
      # names libswiftDarwin, it loads libswiftDarwin, and does not load on 10.9 without it.
      if [ "${lib##*/}" = libswift_Concurrency.dylib ]; then
        printf '%s\n' "$DEPS" | grep -qx '@rpath/libswiftDarwin\.dylib' \
          || { printf '%s\n' "$DEPS"; echo "FAIL: $lib does not link @rpath/libswiftDarwin.dylib (listed above)"; exit 1; }
        "${NM:-nm}" -gU "$lib" | awk '{ print $NF }' | grep -Fq '$ld$previous$@rpath/libswift_Concurrency.dylib$$1$10.9$' \
          || { echo "FAIL: $lib has no \$ld\$previous naming @rpath/libswift_Concurrency.dylib for a 10.9 client"; exit 1; }
      fi ;;
    *)
      # Global Constraints: every new library is @rpath/<name>, as the Swift libraries reach each other.
      ID="$("${OTOOL:-otool}" -D "$lib" | sed 1d)"
      [ "$ID" = "@rpath/${lib##*/}" ] || { echo "FAIL: $lib's install name is '$ID', not @rpath/${lib##*/}"; exit 1; }
      # Concurrency, through _Builtin_float, demands compatibility version 1.0.0 of libswiftDarwin.
      CV="$("${OTOOL:-otool}" -l "$lib" | awk '/LC_ID_DYLIB/ { f = 1 } f && /compatibility version/ { print $3; exit }')"
      [ "$CV" = 1.0.0 ] || { echo "FAIL: $lib's compatibility version is '$CV', not 1.0.0"; exit 1; } ;;
  esac
  if printf '%s\n' "$DEPS" | grep -qx '/usr/lib/libc++\.1\.dylib'; then
    printf '%s\n' "$DEPS"; echo "FAIL: $lib links the OS's libc++ (listed above)"; exit 1
  fi
  ABI="$("${NM:-nm}" -gU "$lib" | awk '{print $NF}' | grep -E '^___cxa_|^___gxx_personality|^__Unwind_' || :)"
  [ -z "$ABI" ] || { printf '%s\n' "$ABI"; echo "FAIL: $lib defines C++ ABI symbols of its own (listed above)"; exit 1; }
done
# The test-support dylibs (step 5b) never ship: none is in the runtime's payload, by name or by bytes. They
# run on the 10.9 box, so their imports are held to 10.9's, and they call no C++ library (none is linked).
STAGED="$(dirname "$CORE")"
for lib in $SUPPORT_DYLIBS; do
  [ -f "$lib" ] || { echo "FAIL: no $lib to check"; exit 1; }
  [ ! -e "$STAGED/${lib##*/}" ] || { echo "FAIL: the runtime's payload holds the test-support ${lib##*/}"; exit 1; }
  for s in "$STAGED"/*.dylib; do cmp -s "$lib" "$s" && { echo "FAIL: the runtime's payload holds the test-support ${lib##*/} as $s"; exit 1; }; done
  if "${OTOOL:-otool}" -L "$lib" | grep -q 'libc++'; then "${OTOOL:-otool}" -L "$lib"; echo "FAIL: $lib links a libc++ (listed above)"; exit 1; fi
  CXXU="$("${NM:-nm}" -u "$lib" | grep -E '__Z(N|NK)?St|__Znw|__Zdl|___cxa_|___gxx_personality' || :)"
  [ -z "$CXXU" ] || { printf '%s\n' "$CXXU"; echo "FAIL: $lib calls into a C++ library, and none is linked (listed above)"; exit 1; }
done
# shellcheck disable=SC2086  # space-free paths
IMPORTS_SUP="$(DYLDINFO="$DYLDINFO" NM="${NM:-nm}" OTOOL="${OTOOL:-otool}" sh "$HERE/scripts/imports-on-10.9.sh" "$SDK109" \
  "$HERE/scripts/resources/weak-absent-on-10.9.txt" $SUPPORT_DYLIBS)" \
  || { printf '%s\n' "$IMPORTS_SUP"; echo "FAIL: a test-support library imports what OS X 10.9 lacks (listed above)"; exit 1; }
printf '%s\n' "$IMPORTS_SUP"
echo "OK: minOS $DEPLOYMENT; no os_unfair_lock; Recaulk's $RECAULK_RUNTIME_SYMBOLS (libswiftCore), $RECAULK_DARWIN_SYMBOLS (libswiftDarwin) and $RECAULK_CONCURRENCY_SYMBOLS (libswift_Concurrency) defined and hidden; Recaulk's APSL notices in the code and NOTICE; no debug strings; no build paths; checked $(for lib in $SHIPPED_DYLIBS; do printf '%s ' "${lib##*/}"; done); staged in $OUT; no test support in it"
