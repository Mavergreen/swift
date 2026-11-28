#!/bin/sh
# platform: macOS-only -- runs build.sh's Mac modes, mavericks and modern, which a Linux host refuses or runs otherwise
# usage: sh tests/build-mavericks-host-test.sh
#   build.sh must build with a host toolchain of this checkout's Swift only: step 1 prints the release the
#   toolchain's pkg names in its mavergreen.plist, and refuses one of another Swift version, or one no pkg
#   installed unless SWIFT_HOST_TOOLCHAIN_VERSION declares it; it never asks pkgutil. Mavericks mode cannot run
#   here (it needs OS X 10.9 and the installed toolchain), so a fake toolchain prefix stands in; NM names no program, so a
#   toolchain step 1 accepts stops there, at the next check, before any SDK fetch. Modern mode (CI) takes
#   the toolchain SWIFT_HOST_TOOLCHAIN names the same way, never the swift.org pkg, and stops at the SDK
#   fetch (this test's shipyard has none), and passes CMAKE_OSX_ARCHITECTURES=x86_64 to the stdlib configure
#   (an arm64 Mac's CMake probe would ask the x86_64-only toolchain clang for arm64; step 1 reports the flag
#   it will pass); without it, it wants the swift.org pkg and passes none. Past step 1, natively (fakes for
#   everything), it must take the swift source as GitHub's tarball of SWIFT_SHA through shipyard's
#   fetch_pinned_source.sh, apply patches/runtime in RUNTIME_PATCHES' order with patch, configure the stdlib
#   with clang22's llvm-ar, llvm-ranlib and llvm-lipo and with LibXml2, LibEdit and pkg-config not looked
#   for, CMake's Apple probes answered and check_language(Swift)'s probe not run (its sub-configure names no
#   SDK and asks xcrun for one), and never run git or xcrun (OS X 10.9 has neither without the Command Line
#   Tools). A stdlib-build is kept while the swift source is the same commit's, and started afresh when it
#   is another's (its stamp records the source and the patches applied to it, lib.sh's source_stamp). Step
#   5b builds the test support with Concurrency (--runtime-floor, StdlibUnittest's Concurrency define, every
#   upstream layer staged) when the host compiler declares a 10.9 async function, and without it, saying
#   so, when it refuses one as the swift.org seed does (no compiler patch 0003), so CI's first build.sh
#   completes; a probe that fails otherwise stops the build.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-mavericks-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"   # -> SWIFT_VERSION
unset SWIFT_HOST_TOOLCHAIN_VERSION

R="$T/root"; mkdir -p "$R/swift/out/llvm/lib/cmake/llvm" "$R/swift/work/llvm-build/bin" "$T/shipyard" "$T/fakebin"
: > "$R/swift/work/llvm-build/bin/ld64.lld"; chmod +x "$R/swift/work/llvm-build/bin/ld64.lld"
H="$T/tc"; mkdir -p "$H/bin" "$H/lib/swift/macosx" "$H/lib/clang/21/include" "$H/lib/clang/21/lib/darwin"
: > "$H/bin/swift-frontend"; : > "$H/bin/clang"; : > "$H/bin/ld64.lld"; : > "$H/lib/clang/21/lib/darwin/libclang_rt.osx.a"
printf '#!/bin/sh\necho "pkgutil $*" >> "%s/pkgutil-args"\nexit 1\n' "$T" > "$T/fakebin/pkgutil"
chmod +x "$T/fakebin/pkgutil"
manifest() {  # $1 = the version the prefix's mavergreen.plist names, or nothing for no pkg (no manifest)
  rm -f "$H/mavergreen.plist"
  [ -z "${1:-}" ] || printf '%s\n' '<plist version="1.0">' '<dict>' '  <key>identifier</key>' '  <string>dev.mavergreen.swift-toolchain</string>' \
    '  <key>version</key>' "  <string>$1</string>" '</dict>' '</plist>' > "$H/mavergreen.plist"
}
build() {  # runs build.sh's mavericks mode; its output in $T/out
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=mavericks \
      SWIFT_HOST_TOOLCHAIN="$H" NM="$T/no-nm"
    unset SWIFT_WORK SWIFT_BUILTINS
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
went_past_step_1() { grep -q "FAIL: no $T/no-nm" "$T/out"; }

echo "-- a manifest of this checkout's Swift: printed, and step 1 goes on"
manifest "$SWIFT_VERSION-mavericks.7"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.7 (pkg dev.mavergreen.swift-toolchain)" "$T/out" \
  || fail "did not print the release: $(cat "$T/out")"
went_past_step_1 || fail "stopped before the check after the release's: $(cat "$T/out")"
if grep -q 'CMAKE_OSX_ARCHITECTURES' "$T/out"; then fail "mavericks mode passes CMAKE_OSX_ARCHITECTURES: $(cat "$T/out")"; fi
[ ! -e "$T/pkgutil-args" ] || fail "asked pkgutil: $(cat "$T/pkgutil-args")"

echo "-- a manifest of another Swift: refused in step 1"
manifest "0.0.1-mavericks.1"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q "FAIL: the host toolchain at $H is release 0.0.1-mavericks.1" "$T/out" || fail "did not refuse 0.0.1: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain of another Swift: $(cat "$T/out")"; fi

echo "-- no manifest (mavergreen.plist): refused, unless SWIFT_HOST_TOOLCHAIN_VERSION declares this checkout's Swift"
manifest ""
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/out" || fail "did not name the override: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain with no manifest: $(cat "$T/out")"; fi
if ( export SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.7"; build ); then fail "build.sh succeeded with a fake toolchain"; fi
grep -q "release $SWIFT_VERSION-mavericks.7 (declared" "$T/out" || fail "did not print the declared release: $(cat "$T/out")"
went_past_step_1 || fail "stopped at a declared release of this checkout's Swift: $(cat "$T/out")"

echo "-- modern mode with SWIFT_HOST_TOOLCHAIN: that toolchain, its manifest checked, never the swift.org pkg"
build_cross() {  # build.sh's modern mode; $1 names the host toolchain, or nothing for none
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=modern
    unset SWIFT_WORK SWIFT_BUILTINS NM SWIFT_HOST_TOOLCHAIN
    if [ -n "$1" ]; then export SWIFT_HOST_TOOLCHAIN="$1"; fi
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
manifest ""
if ( export SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.9"; build_cross "$H" ); then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.9 (declared by SWIFT_HOST_TOOLCHAIN_VERSION)" "$T/out" \
  || fail "modern mode did not take the named toolchain: $(cat "$T/out")"
grep -q 'FAIL: could not fetch the pinned modern SDK' "$T/out" || fail "modern mode stopped before the SDK fetch: $(cat "$T/out")"
if grep -q 'swift.org toolchain' "$T/out"; then fail "modern mode looked for the swift.org pkg beside a named toolchain"; fi
grep -qxF "    cmake architectures: -DCMAKE_OSX_ARCHITECTURES=x86_64 (a named host toolchain's clang is x86_64 only)" "$T/out" \
  || fail "modern mode with a named toolchain did not pass CMAKE_OSX_ARCHITECTURES: $(cat "$T/out")"
if build_cross "$H"; then fail "build.sh succeeded with a fake toolchain"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/out" || fail "modern mode took a manifest-less toolchain without a declared release: $(cat "$T/out")"
if build_cross ""; then fail "build.sh succeeded with no swift.org pkg"; fi
if grep -q 'CMAKE_OSX_ARCHITECTURES' "$T/out"; then fail "modern mode without a host toolchain passes CMAKE_OSX_ARCHITECTURES"; fi
grep -q "FAIL: no swift.org toolchain at $R/swift/cache/" "$T/out" || fail "modern mode without a host toolchain: $(cat "$T/out")"

echo "-- the stdlib configure takes step 1's architecture arguments (the call is run here with a fake shipyard-cmake)"
# Reaching step 4 for real needs the pinned swift source, patched; so the configure call itself is cut out of
# build.sh (from `shipyard_cmake` to the first line with no trailing backslash) and run with CMAKE_ARCH_ARGS set,
# lib.sh's shipyard_cmake running shipyard-cmake on a Mac.
{ echo ". \"$REPO/lib.sh\""; awk '/^shipyard_cmake /{on=1} on{print} on&&!/\\$/{exit}' "$REPO/build.sh"; } > "$T/configure.sh"
grep -q '^shipyard_cmake ' "$T/configure.sh" || fail "found no shipyard_cmake call in build.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$T/fakebin/shipyard-cmake"; chmod +x "$T/fakebin/shipyard-cmake"
configure_args() {  # $1 = CMAKE_ARCH_ARGS; the arguments the call passes, one a line
  ( set +eu; CMAKE_ARCH_ARGS="$1"
    PATH="$T/fakebin:$PATH"
    . "$T/configure.sh" ) > "$T/cmake-args"
}
configure_args "-DCMAKE_OSX_ARCHITECTURES=x86_64"
grep -qxF -e '-DCMAKE_OSX_ARCHITECTURES=x86_64' "$T/cmake-args" || fail "the configure call dropped CMAKE_ARCH_ARGS: $(cat "$T/cmake-args")"
configure_args ""
if grep -q 'CMAKE_OSX_ARCHITECTURES' "$T/cmake-args"; then fail "the configure call passes an architecture of its own"; fi

echo "-- natively, past step 1: the swift tarball, patch in RUNTIME_PATCHES' order, clang22's archiver; no git, no xcrun"
C22="$T/clang22n"; mkdir -p "$C22/bin"
for t in clang clang++ ld64.lld llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-otool llvm-strings; do
  printf '#!/bin/sh\n' > "$C22/bin/$t"; chmod +x "$C22/bin/$t"
done
# Recaulk: recaulk_subset reads the archive with clang22's llvm-nm -A and writes the subset with its llvm-ar.
# fwd-97.o calls close, which a socket_close member shadows beside dup2, as in Recaulk 20261118.1: the
# 10.9 SDK's libSystem stub (llvm-nm -gU, below) exports close, so the subset leaves socket_close out.
# spec: Recaulk's share/recaulk/image-local-shadows.txt -- since 20261120.3 dispatch_activate's body is in
#       dispatch_inactive.o beside hidden copies of dispatch_queue_create and dispatch_resume, which that list
#       (the fake pkg's, below) names.
cat > "$C22/bin/llvm-nm" <<'F'
#!/bin/sh
case "$*" in *libSystem.B.dylib) printf '%s\n' "0000000000001000 T _close" "0000000000001010 T _dup2" "0000000000001020 T _fma"; exit 0 ;; esac
[ "$1" = -A ] || exit 0
printf '%s\n' "$2:fwd-97.o: 0000000000000000 T _os_system_version_get_current_version" "$2:fwd-97.o:                  U ___recaulk_resolve" \
  "$2:fwd-97.o:                  U _close" "$2:recaulk-socket_close.o: 0000000000000000 T _close" \
  "$2:recaulk-socket_close.o: 0000000000000010 T _dup2" \
  "$2:fwd-resolve.o: 0000000000000000 T ___recaulk_resolve" "$2:fwd-9.o: 0000000000000000 T _os_signpost_enabled" \
  "$2:fwd-90.o: 0000000000000000 T _objc_readClassPair" "$2:fwd-90.o:                  U ___recaulk_resolve" \
  "$2:recaulk-libm_fma.o: 0000000000000000 T _fma" "$2:recaulk-libm_fma.o: 0000000000000010 T ___recaulk_fma" \
  "$2:recaulk-libm_fma.o:                  U ___recaulk_libm_exact_sum" "$2:recaulk-libm_exact.o: 0000000000000000 T ___recaulk_libm_exact_sum" \
  "$2:recaulk-libm_fmal.o: 0000000000000000 T _fmal" "$2:recaulk-libm_fmal.o:                  U ___recaulk_libm_exact_sum" \
  "$2:recaulk-libm_truncl.o: 0000000000000000 T _truncl" "$2:recaulk-libm_truncl.o: 0000000000000010 T ___recaulk_truncl" \
  "$2:fwd-40.o: 0000000000000000 T _clock_gettime" "$2:fwd-40.o:                  U ___recaulk_resolve" \
  "$2:fwd-41.o: 0000000000000000 T _clock_getres" "$2:fwd-41.o:                  U ___recaulk_resolve" \
  "$2:recaulk-qos_class.o: 0000000000000000 T _qos_class_self" \
  "$2:recaulk-dispatch_modern.o: 0000000000000000 T _voucher_copy" "$2:recaulk-dispatch_modern.o: 0000000000000010 T _voucher_adopt" \
  "$2:recaulk-dispatch_modern.o: 0000000000000020 T _os_release" \
  "$2:fwd-46.o: 0000000000000000 T _dispatch_activate" "$2:fwd-46.o:                  U ___recaulk_impl_dispatch_activate" \
  "$2:fwd-46.o:                  U ___recaulk_resolve" \
  "$2:recaulk-dispatch_inactive.o: 0000000000000000 T ___recaulk_impl_dispatch_activate" \
  "$2:recaulk-dispatch_inactive.o: 0000000000000010 T ___recaulk_dispatch_queue_create" \
  "$2:recaulk-dispatch_inactive.o: 0000000000000020 T _dispatch_queue_create" \
  "$2:recaulk-dispatch_inactive.o: 0000000000000030 T ___recaulk_dispatch_resume" \
  "$2:recaulk-dispatch_inactive.o: 0000000000000040 T _dispatch_resume" \
  "$2:recaulk-dispatch_modern.o: 0000000000000040 T ___recaulk_copy_helper_block_8_32b" \
  "$2:fwd-47.o: 0000000000000000 T _dispatch_assert_queue\$V2" "$2:fwd-47.o:                  U ___recaulk_resolve" \
  "$2:recaulk-dispatch_assert_queue.o: 0000000000000000 T ___recaulk_impl_dispatch_assert_queue\$V2"
F
printf '#!/bin/sh\ncase "$1" in rcs) : > "$2" ;; esac\n' > "$C22/bin/llvm-ar"; chmod +x "$C22/bin/llvm-nm" "$C22/bin/llvm-ar"
printf '#!/bin/sh\necho "%s/sdk/MacOSX11.3.sdk"\n' "$T" > "$T/shipyard/fetch_sdk.sh"
# The 10.9 SDK's stubs (lib.sh's sdk109_stubs), already in the cache, with the libSystem stub llvm-nm reads above.
printf '%s\n' 'shipyard_sdk_pin() { echo https://example.invalid/sdk 0 MacOSX10.9.sdk.tar.xz MacOSX10.9.sdk; }' > "$T/shipyard/sdk-pins.sh"
: > "$T/shipyard/mavericks_fetch.sh"
mkdir -p "$T/sdk-cache/stubs/MacOSX10.9.sdk/usr/lib"; : > "$T/sdk-cache/stubs/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib"
# libcxx22: clang22's libc++ headers, and fetch-libcxx22.sh's pkg, unpacked where it names (its last argument)
mkdir -p "$C22/include/c++/v1"; : > "$C22/include/c++/v1/__config"
cat > "$T/shipyard/fetch_product_pkg.sh" <<'F'
#!/bin/sh
for d in "$@"; do :; done
case " $* " in
  *" recaulk "*) mkdir -p "$d/lib" "$d/share/recaulk" && : > "$d/lib/librecaulk.a" && : > "$d/share/recaulk/notices.tsv"
                 [ -n "${FAKE_RECAULK_NO_SHADOWS:-}" ] \
                   || printf '%s\n' '# <member> <symbol> <reason>' 'recaulk-libm_fma.o _fma rounds once' \
                        'recaulk-socket_close.o _dup2 does not hang' 'recaulk-dispatch_inactive.o _dispatch_queue_create starts inactive' \
                        'recaulk-dispatch_inactive.o _dispatch_resume counts as the activation' > "$d/share/recaulk/image-local-shadows.txt" ;;
  *) mkdir -p "$d/lib" && : > "$d/lib/libc++.1.dylib" && : > "$d/lib/libc++abi.1.dylib" ;;
esac
F
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
echo "fetch_pinned_source \$*" >> "$T/log"
rm -rf "\$4"; mkdir -p "\$4/stdlib/public/stubs" "\$4/stdlib/public/runtime" "\$4/stdlib/public/core" "\$4/include/swift/Runtime" \
  "\$4/stdlib/private/StdlibUnittest" "\$4/stdlib/public/Concurrency"
for f in CMakeLists.txt stdlib/public/stubs/Availability.mm stdlib/public/runtime/SwiftObject.mm stdlib/public/runtime/Metadata.cpp \
         include/swift/Runtime/Config.h stdlib/public/core/StringBridge.swift stdlib/private/StdlibUnittest/StdlibUnittest.swift \
         stdlib/public/core/FloatingPointParsing.swift.gyb stdlib/public/Concurrency/CMakeLists.txt \
         stdlib/public/Concurrency/DispatchGlobalExecutor.cpp stdlib/public/Concurrency/TracingSignpost.h; do : > "\$4/\$f"; done
echo "\${FAKE_SWIFT_SOURCE:-\$1 \$2 \$3}" > "\$4/.mavergreen-source"   # FAKE_SWIFT_SOURCE: another commit's tarball
F
# patch: a dry run applies; a real one writes the marker build.sh greps for that patch.
cat > "$T/fakebin/patch" <<'F'
#!/bin/sh
p=""; dry=0
for a in "$@"; do case "$a" in --dry-run) dry=1 ;; esac; done
while [ $# -gt 0 ]; do case "$1" in -i) p="$2"; shift 2 ;; *) shift ;; esac; done
[ "$dry" = 1 ] && exit 0
echo "patch $(basename "$p")" >> "$FAKE_LOG"
case "$(basename "$p")" in
  0004-*) echo mav_roFromClassData >> stdlib/public/runtime/Metadata.cpp ;;
  0005-*) echo 'class_getInstanceSize((Class)const_cast' >> stdlib/public/runtime/Metadata.cpp ;;
  0007-*) echo 'ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 101404' >> include/swift/Runtime/Config.h ;;
  0008-*) echo 'was: hasFeature(Macros)' >> stdlib/public/core/StringBridge.swift ;;
  0009-*) echo 'Mavericks: no libc++ autolink' >> stdlib/public/runtime/Metadata.cpp ;;
  0010-*) echo 'Mavericks: Foundation-free StdlibUnittest' >> stdlib/private/StdlibUnittest/StdlibUnittest.swift ;;
  0011-*) echo 'Mavericks: through a function that carries the same availability' >> stdlib/public/core/FloatingPointParsing.swift.gyb ;;
  0012-*) echo "Mavericks: follow the stdlib's 10.9" >> stdlib/public/Concurrency/CMakeLists.txt ;;
  0013-*) echo 'mavericks_concurrency_link_flags UNIX_COMMAND "${MAVERGREEN_CONCURRENCY_LINK_FLAGS}"' >> stdlib/public/Concurrency/CMakeLists.txt ;;
  0014-*) echo mav_globalQueueIdentifier >> stdlib/public/Concurrency/DispatchGlobalExecutor.cpp ;;
  0015-*) echo 'ENSURE_LOGS();  // Mavericks: the one trace call without it' >> stdlib/public/Concurrency/TracingSignpost.h ;;
  0016-*) echo "Mavericks: OS X 10.9's libdispatch does not know the bit-63 encoding" >> stdlib/public/Concurrency/DispatchGlobalExecutor.cpp ;;
  0017-*) echo "#define MAV_DISPATCH_ASYNC_SWIFT_JOB_LOOKED_UP 1" >> stdlib/public/Concurrency/DispatchGlobalExecutor.cpp ;;
esac
F
# The stdlib configure records its arguments and leaves a cache; the build (ninja) stops the run.
cat > "$T/fakebin/shipyard-cmake" <<F
#!/bin/sh
{ echo "shipyard-cmake"; for a in "\$@"; do echo "  \$a"; done; } >> "$T/log"
b=""; for a in "\$@"; do if [ "\$b" = next ]; then mkdir -p "\$a" && : > "\$a/CMakeCache.txt"; b=""; elif [ "\$a" = -B ]; then b=next; fi; done
F
printf '#!/bin/sh\nexit 3\n' > "$T/fakebin/ninja"
for c in git xcrun; do printf '#!/bin/sh\necho "%s $*" >> "%s/log"\nexit 1\n' "$c" "$T" > "$T/fakebin/$c"; done
chmod +x "$T/shipyard/"* "$T/fakebin/"*
manifest "$SWIFT_VERSION-mavericks.9"
build_native() {  # build.sh's mavericks mode past step 1, everything faked; ninja stops it after the configure
  : > "$T/log"
  if ( export PATH="$T/fakebin:$PATH" FAKE_LOG="$T/log" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=mavericks \
        SWIFT_HOST_TOOLCHAIN="$H" CLANG22_PREFIX="$C22" MAVERICKS_CLANG_CACHE="$T/clang-cache" MAVERGREEN_RECAULK_CACHE="$T/recaulk-cache" \
        MAVERICKS_SDK_CACHE="$T/sdk-cache"
      unset SWIFT_WORK SWIFT_BUILTINS NM
      sh "$REPO/build.sh" ) > "$T/out" 2>&1; then fail "build.sh got past a build that failed: $(cat "$T/out")"; fi
}
echo "-- a Recaulk pkg without share/recaulk/image-local-shadows.txt is refused at step 1"
FAKE_RECAULK_NO_SHADOWS=1; export FAKE_RECAULK_NO_SHADOWS
build_native
grep -q 'share/recaulk/image-local-shadows.txt -- payload layout changed?' "$T/out" || fail "took a Recaulk with no image-local-shadows.txt: $(cat "$T/out")"
unset FAKE_RECAULK_NO_SHADOWS; rm -rf "$T/recaulk-cache"
build_native
grep -qxF "fetch_pinned_source https://github.com/swiftlang/swift.git $SWIFT_SHA $SWIFT_TARBALL_SHA256 swift" "$T/log" \
  || fail "did not fetch the swift tarball by its pin: $(cat "$T/out")"
grep -qxF "fetch_pinned_source https://github.com/swiftlang/swift.git $SWIFT40_SHA $SWIFT40_TARBALL_SHA256 swift-4.0" "$T/log" \
  || fail "did not fetch swift-4.0's tarball by its pin: $(grep fetch_pinned_source "$T/log")"
[ "$(sed -n 's/^patch \([0-9]*\)-.*/\1/p' "$T/log" | tr '\n' ' ')" = "0004 0005 0007 0008 0009 0010 0011 0012 0013 0014 0015 0016 0017 " ] \
  || fail "patched in another order: $(grep '^patch' "$T/log" | tr '\n' ' ')"
for a in "-DCMAKE_AR=$C22/bin/llvm-ar" "-DCMAKE_RANLIB=$C22/bin/llvm-ranlib" "-DSWIFT_LIPO=$C22/bin/llvm-lipo" -DSWIFT_ENABLE_LIBXML2=OFF \
         -DCMAKE_TAPI=/usr/bin/false "-DCMAKE_STRIP=$C22/bin/llvm-strip" -DLD64_EXECUTABLE=/usr/bin/false -DCMAKE_Swift_COMPILER=NOTFOUND \
         -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON -DCMAKE_DISABLE_FIND_PACKAGE_LibEdit=ON -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON; do
  grep -qxF -e "  $a" "$T/log" || fail "the stdlib configure lacks $a: $(cat "$T/log")"
done
LCX="$T/clang-cache/$CLANG22_VERSION/libcxx22/lib/libc++.1.dylib"
grep -qxF -e "  -DCMAKE_CXX_FLAGS=$(grep -m1 '^  -DCMAKE_C_FLAGS=' "$T/log" | sed 's/^  -DCMAKE_C_FLAGS=//') -nostdinc++ -isystem $C22/include/c++/v1 -ffile-prefix-map=$C22/include/c++/v1=/mavergreen-libcxx22/include" "$T/log" \
  || fail "the stdlib's C++ does not compile against clang22's libc++ headers alone: $(grep CMAKE_CXX_FLAGS "$T/log")"
grep -q -e "^  -DCMAKE_SHARED_LINKER_FLAGS=.* -nostdlib++ $LCX -Wl,-rpath,@loader_path/../../../../mavergreen/libcxx22/lib $R/swift/work/recaulk-runtime.a -Wl,-unexported_symbols_list,$R/swift/work/recaulk-runtime.unexported\$" "$T/log" \
  || fail "the runtime does not link libcxx22's libc++ by path, alone, with the rpath that reaches it installed, then Recaulk's subset, hidden: $(grep CMAKE_SHARED_LINKER_FLAGS "$T/log")"
# The subset is the APIs named and what they need, never the archive's other APIs.
[ "$(tr '\n' ' ' < "$R/swift/work/recaulk-runtime.unexported")" = "___recaulk_fma ___recaulk_libm_exact_sum ___recaulk_resolve ___recaulk_truncl _fma _fmal _objc_readClassPair _os_system_version_get_current_version _truncl " ] \
  || fail "Recaulk's subset: $(cat "$R/swift/work/recaulk-runtime.unexported")"
# libswift_Concurrency: built, and its own subset reaches its link alone, through patch 0013's hook; the
# dispatch member's block helper (___recaulk_-prefixed since Recaulk 20261108.3) is hidden with the rest, and
# so are the dispatch_queue_create and dispatch_resume shadows dispatch_activate's member carries.
grep -qxF -e "  -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=ON" "$T/log" || fail "the stdlib configure does not turn Concurrency on: $(cat "$T/log")"
# Strict availability: StdlibDeploymentTarget N keeps SwiftStdlib N's OS versions in the shipped modules,
# not the deployment target's (AddSwiftStdlib.cmake), so a client from 10.14.4 gets upstream's diagnostics.
grep -qxF -e "  -DSWIFT_STDLIB_ENABLE_STRICT_AVAILABILITY=ON" "$T/log" || fail "the stdlib configure does not turn strict availability on: $(cat "$T/log")"
grep -qxF -e "  -DMAVERGREEN_CONCURRENCY_LINK_FLAGS=$R/swift/work/recaulk-concurrency.a -Wl,-unexported_symbols_list,$R/swift/work/recaulk-concurrency.unexported" "$T/log" \
  || fail "Concurrency's link does not take its Recaulk subset, hidden: $(grep MAVERGREEN_CONCURRENCY "$T/log")"
[ "$(tr '\n' ' ' < "$R/swift/work/recaulk-concurrency.unexported")" = "___recaulk_copy_helper_block_8_32b ___recaulk_dispatch_queue_create ___recaulk_dispatch_resume ___recaulk_impl_dispatch_activate ___recaulk_resolve _clock_getres _clock_gettime _dispatch_activate _dispatch_assert_queue\$V2 _dispatch_queue_create _dispatch_resume _os_release _qos_class_self _voucher_adopt _voucher_copy " ] \
  || fail "Recaulk's subset for Concurrency: $(cat "$R/swift/work/recaulk-concurrency.unexported")"
# Test support only runs on this runtime: step 5b's test support (below) takes --runtime-floor (every released
# SwiftStdlib version is 10.9 there), and the shipped overlays' build_overlay never does.
if awk '/^build_overlay\(\) \{/,/^}/' "$REPO/build.sh" | grep -q -e '--runtime-floor'; then fail "build_overlay passes --runtime-floor: a shipped module's availability would be 10.9"; fi
awk '/^build_overlay\(\) \{/,/^}/' "$REPO/build.sh" | grep -q 'build-module.sh' || fail "no build_overlay calling build-module.sh in build.sh"
# spec: "The overlays" -- one SDK view for the whole module graph: every overlay, as every program, is compiled
#       against recaulk-materialize's view, its sdk/MacOSX10.9.sdk and its overlay.json.
awk '/^build_overlay\(\) \{/,/^}/' "$REPO/build.sh" | grep -qF -e '--sdk "$SDK_VIEW_SDK" --sdk-view "$SDK_VIEW_VFS"' \
  || fail "build_overlay does not compile against the SDK view"
grep -qx 'RECAULK_MATERIALIZE="$RECAULK_PREFIX/bin/recaulk-materialize"' "$REPO/build.sh" \
  && grep -q '^"$RECAULK_MATERIALIZE" --sdk "$SDK_PLAIN" --out "$SDK_VIEW" --profile "$SDK_VIEW_PROFILE"' "$REPO/build.sh" \
  || fail "build.sh does not make the SDK view with Recaulk's recaulk-materialize"
# On Linux, which cannot run the pkg's Mach-O, the release's Linux one makes it (fetch-recaulk.sh --materializer).
awk '/^RECAULK_MATERIALIZE=/,/^"\$RECAULK_MATERIALIZE" --sdk/' "$REPO/build.sh" | grep -q 'if \[ "\$HOST" = linux \]; then' \
  && awk '/^RECAULK_MATERIALIZE=/,/^"\$RECAULK_MATERIALIZE" --sdk/' "$REPO/build.sh" | grep -qF 'RECAULK_MATERIALIZE="$(sh "$HERE/fetch-recaulk.sh" --materializer)"' \
  || fail "build.sh on Linux does not take the release's Linux recaulk-materialize"
# Step 5b builds the overlays in the order they import each other, Foundation's three after Dispatch: CoreFoundation,
# CoreGraphics, then Foundation, which links 10.9's Foundation and CoreFoundation frameworks, as CoreGraphics links
# ApplicationServices (10.9's CoreGraphics is inside it); Foundation's two Objective-C files go to its link; step 7
# checks every one of them.
ORDER="$(sed -n 's/^build_overlay \([A-Za-z]*\) .*/\1/p' "$REPO/build.sh" | tr '\n' ' ')"
[ "$ORDER" = "Darwin ObjectiveC Dispatch CoreFoundation CoreGraphics Foundation " ] || fail "step 5b builds the overlays in the order: $ORDER"
OV="$(awk '/^build_overlay Foundation /,/[^\\]$/' "$REPO/build.sh")"
for w in '--flag -framework --flag Foundation' '--flag -framework --flag CoreFoundation' 'BundleLookup.mm.o' 'DataThunks.m.o'; do
  printf '%s\n' "$OV" | grep -qe "$w" || fail "the Foundation overlay's build_overlay lacks $w: $OV"
done
awk '/^build_overlay CoreGraphics /,/[^\\]$/' "$REPO/build.sh" | grep -qe '--flag -framework --flag ApplicationServices' \
  || fail "the CoreGraphics overlay does not link ApplicationServices"
for f in BundleLookup.mm DataThunks.m; do
  grep -q "^host_object .*/Foundation/$f\"" "$REPO/build.sh" || fail "step 5b does not compile $f with host_object"
done
# Foundation's sources are every .swift laid out for it: none there fails, naming the directory, before any compile
# (an unmatched glob would hand build-module.sh the literal ./*.swift).
FS="$(awk '/^# Every \.swift overlay-sources\.sh laid out for Foundation/,/^build_overlay Foundation /' "$REPO/build.sh" | sed '$d')"
[ -n "$FS" ] || fail "no listing of Foundation's sources in build.sh"
mkdir -p "$T/ovs/Foundation"
rc=0; out="$(OVS="$T/ovs" sh -c "set -u; $FS
echo listed" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "listed an empty $T/ovs/Foundation as Foundation's sources: $out"
case "$out" in *FAIL*"$T/ovs/Foundation"*) ;; *) fail "the empty source dir was not named: $out" ;; esac
: > "$T/ovs/Foundation/b.swift"; : > "$T/ovs/Foundation/a.swift"
out="$(OVS="$T/ovs" sh -c "set -u; $FS
echo \"\$FOUNDATION_SOURCES\"" 2>&1)" || fail "refused two sources: $out"
[ "$(printf '%s' "$out" | tr '\n' ' ')" = "$T/ovs/Foundation/a.swift $T/ovs/Foundation/b.swift" ] || fail "Foundation's sources are [$out]"
sed -n '/^SHIPPED_DYLIBS=/p' "$REPO/build.sh" | grep -q ' \$FOUNDATION_DYLIBS"$' || fail "step 7's SHIPPED_DYLIBS lacks \$FOUNDATION_DYLIBS"
for l in CoreFoundation CoreGraphics Foundation; do
  sed -n '/^FOUNDATION_DYLIBS=/p' "$REPO/build.sh" | grep -q "/libswift$l\.dylib" || fail "step 7's FOUNDATION_DYLIBS lacks libswift$l.dylib"
  grep -q "^RUNTIME_DYLIBS=.*libswift$l\.dylib" "$REPO/scripts/stage-runtime.sh" || fail "stage-runtime.sh's RUNTIME_DYLIBS lacks libswift$l.dylib"
done
if grep -q '^git \|^xcrun ' "$T/log"; then fail "ran $(grep '^git \|^xcrun ' "$T/log" | head -1)"; fi
# A Mac configures for its own platform: the Linux host's CMake platform and install_name_tool are not passed.
if grep -q 'CMAKE_SYSTEM_NAME\|CMAKE_SYSTEM_PROCESSOR\|CMAKE_INSTALL_NAME_TOOL' "$T/log"; then fail "a Mac configure passes the Linux host's CMake platform: $(cat "$T/log")"; fi

echo "-- step 5b's test support: with Concurrency when the host compiler declares a 10.9 async function; without"
echo "   it, and without upstream's concurrency tests, saying so, when it refuses one (the swift.org seed); else FAIL"
# Step 5b is past the fake ninja, so its test-support half is cut out of build.sh (from SUP= to the line that
# reports the modules), after the host_object it compiles C with, and run with a fake host compiler, clang, gyb
# and build-module.sh.
awk '/^host_object\(\) \{/,/^}/' "$REPO/build.sh" > "$T/support.sh"
grep -q '^host_object() {' "$T/support.sh" || fail "found no host_object in build.sh"
awk '/^SUP="\$ROOT\/stdlib-build\/selftest-support"/{on=1} on{print} on&&/^echo "    test support \(never in a pkg\)/{exit}' "$REPO/build.sh" >> "$T/support.sh"
grep -q 'test support (never in a pkg)' "$T/support.sh" || fail "found no test-support half of step 5b in build.sh: $(cat "$T/support.sh")"
S5="$T/s5"; mkdir -p "$S5/tc/bin" "$S5/here/scripts" "$S5/root/swift/utils" "$S5/res"
mkdir -p "$S5/here/tests"; cp -R "$REPO/tests/upstream" "$S5/here/tests/"
# swiftc: answers the probe (a -typecheck) as FAKE_PROBE says: pass, refuse (patch 0003 absent), or broken
cat > "$S5/tc/bin/swiftc" <<'F'
#!/bin/sh
echo "swiftc $*" >> "$FAKE_LOG"
case "$FAKE_PROBE" in
  pass) exit 0 ;;
  refuse) echo "probe.swift:1:24: error: concurrency is only available in macOS 10.15.0 or newer" >&2; exit 1 ;;
  *) echo "<unknown>:0: error: unable to load standard library for target 'x86_64-apple-macosx10.9'" >&2; exit 1 ;;
esac
F
# clang, clang++ and gyb write the -o they are given; build-module.sh records its arguments and writes its module
printf '#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -o) : > "$2"; shift 2 ;; *) shift ;; esac; done
' > "$S5/tc/bin/clang"
cp "$S5/tc/bin/clang" "$S5/tc/bin/clang++"; cp "$S5/tc/bin/clang" "$S5/py"
cat > "$S5/here/scripts/build-module.sh" <<'F'
#!/bin/sh
echo "build-module.sh $*" >> "$FAKE_LOG"
while [ $# -gt 0 ]; do case "$1" in --name) n="$2"; shift 2 ;; --out) o="$2"; shift 2 ;; --) break ;; *) shift ;; esac; done
mkdir -p "$o/$n.swiftmodule" "$o/x86_64" && : > "$o/x86_64/libswift$n.dylib"
F
chmod +x "$S5/tc/bin/"* "$S5/py" "$S5/here/scripts/build-module.sh"
support() {  # $1 = the probe's answer; the cut's output in $T/out, and UPSTREAM_LISTS's last line
  : > "$T/log"
  ( set -eu; export FAKE_LOG="$T/log" FAKE_PROBE="$1"
    ROOT="$S5/root" HERE="$S5/here" TC="$S5/tc" PY="$S5/py" ARCH=x86_64 DEPLOYMENT=10.9 SDK_OVERLAYS="$S5/sdk" SDK_VIEW_SDK="$S5/sdk" SDK_VIEW_VFS="$S5/sdk/overlay.json" PM_C="" CXX_LIBCXX=""
    RES="$S5/res" LLD=/usr/bin/true
    . "$T/support.sh"; echo "UPSTREAM_LISTS=$UPSTREAM_LISTS" ) > "$T/out" 2>&1
}
support pass || fail "step 5b's test support failed with a compiler that declares async for 10.9: $(cat "$T/out")"
grep -q '^swiftc .*-typecheck' "$T/log" || fail "step 5b did not probe the host compiler: $(cat "$T/log")"
grep -q 'test support: with Concurrency' "$T/out" || fail "step 5b did not say it builds test support with Concurrency: $(cat "$T/out")"
for m in SwiftPrivate SwiftPrivateLibcExtras SwiftPrivateThreadExtras StdlibUnittest; do
  grep -q "^build-module.sh .*--name $m .*--sdk $S5/sdk --sdk-view $S5/sdk/overlay.json" "$T/log" \
    || fail "$m is not built against the SDK view: $(cat "$T/log")"
done
for m in SwiftPrivate SwiftPrivateLibcExtras SwiftPrivateThreadExtras StdlibUnittest; do
  grep -q "^build-module.sh .*--name $m .*--runtime-floor" "$T/log" || fail "with Concurrency, $m is built without --runtime-floor: $(cat "$T/log")"
done
grep '^build-module.sh .*--name StdlibUnittest ' "$T/log" | grep -qF -e '--flag -D --flag SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY' \
  || fail "with Concurrency, StdlibUnittest is built without -D SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY: $(cat "$T/log")"
L="$(sed -n 's/^UPSTREAM_LISTS=//p' "$T/out")"
[ "$(cd "$L" && ls)" = "$(cd "$REPO/tests/upstream" && ls)" ] || fail "with Concurrency, the staged lists are not every layer's: $L"
support refuse || fail "step 5b's test support failed with the swift.org seed, which refuses async for 10.9: $(cat "$T/out")"
grep -q "test support: without Concurrency -- the host compiler .*concurrency is only available in macOS 10.15.0 or newer" "$T/out" \
  || fail "step 5b did not say why it builds test support without Concurrency: $(cat "$T/out")"
grep -q "upstream's concurrency tests are not staged" "$T/out" || fail "step 5b did not say it skips upstream's concurrency tests: $(cat "$T/out")"
[ "$(grep -c '^build-module.sh ' "$T/log")" -eq 4 ] || fail "without Concurrency, not the four test-support modules: $(cat "$T/log")"
if grep -q '^build-module.sh .*--runtime-floor' "$T/log"; then fail "without Concurrency, test support is built with --runtime-floor: $(cat "$T/log")"; fi
if grep -q '^build-module.sh .*SWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY' "$T/log"; then fail "without Concurrency, StdlibUnittest reads the Concurrency define: $(cat "$T/log")"; fi
L="$(sed -n 's/^UPSTREAM_LISTS=//p' "$T/out")"
[ "$(cd "$L" && ls)" = "$(cd "$REPO/tests/upstream" && ls | grep -vx concurrency.list)" ] || fail "without Concurrency, the staged lists: $(cd "$L" && ls)"
for f in "$L"/*.list; do cmp -s "$f" "$REPO/tests/upstream/${f##*/}" || fail "without Concurrency, ${f##*/} is not the reviewed list"; done
if support broken; then fail "step 5b went on past a host compiler the probe could not run: $(cat "$T/out")"; fi
grep -q 'unable to load standard library' "$T/out" && grep -q 'FAIL: could not ask .* async function' "$T/out" \
  || fail "step 5b's failed probe did not show its error: $(cat "$T/out")"
# Step 6 stages the layers step 5b chose.
grep -q '^PYTHON=.*stage-selftest-support.sh" "$ROOT/stdlib-build" "$ROOT/swift" "$UPSTREAM_LISTS" ' "$REPO/build.sh" \
  || fail "step 6 does not stage the lists step 5b chose: $(grep 'stage-selftest-support.sh"' "$REPO/build.sh")"
SB="$R/swift/work/stdlib-build"
grep -q '^archiver ' "$SB/mavergreen-inputs.stamp" \
  || fail "the stdlib-build's stamp does not record the archiver: $(cat "$SB/mavergreen-inputs.stamp")"
# libcxx22's dylib and headers and the two Recaulk subsets (Core's, Concurrency's), and the host shim's
# clang and clang++ (scripts that keep the cfgs' Recaulk line from the runtime): six further inputs.
[ "$(grep -c '^input ' "$SB/mavergreen-inputs.stamp")" -eq 6 ] \
  || fail "the stdlib-build's stamp does not record libcxx22, Recaulk and the shim's clang: $(cat "$SB/mavergreen-inputs.stamp")"
for f in clang clang++; do
  grep -qx "input $(shasum -a 256 < "$R/swift/work/native-host/usr/bin/$f" | awk '{ print $1 }')" "$SB/mavergreen-inputs.stamp" \
    || fail "the stdlib-build's stamp does not record the shim's $f: $(cat "$SB/mavergreen-inputs.stamp")"
done
# Its clang line is the toolchain's own clang, the binary the shim's scripts run, not a script.
grep -qx "clang $(shasum -a 256 < "$H/bin/clang" | awk '{ print $1 }')" "$SB/mavergreen-inputs.stamp" \
  || fail "the stdlib-build's stamp does not record the toolchain's clang: $(cat "$SB/mavergreen-inputs.stamp")"
# The runtime patches applied, in order (lib.sh's source_stamp): a changed patch set starts it afresh.
[ "$(sed -n 's/^patch swift \([0-9]*\)-[^ ]*\.patch [0-9a-f]\{64\}$/\1/p' "$SB/mavergreen-inputs.stamp" | tr '\n' ' ')" = "0004 0005 0007 0008 0009 0010 0011 0012 0013 0014 0015 0016 0017 " ] \
  || fail "the stdlib-build's stamp does not record the runtime patches: $(cat "$SB/mavergreen-inputs.stamp")"

echo "-- the stdlib-build's stamp records the swift source: the same commit keeps it, another commit's starts it afresh"
grep -qxF "source swift https://github.com/swiftlang/swift.git $SWIFT_SHA $SWIFT_TARBALL_SHA256" "$SB/mavergreen-inputs.stamp" \
  || fail "the stdlib-build's stamp does not record the swift source: $(cat "$SB/mavergreen-inputs.stamp")"
: > "$SB/kept.o"
build_native
[ -f "$SB/kept.o" ] || fail "the same swift source removed the stdlib-build: $(cat "$T/out")"
(export FAKE_SWIFT_SOURCE="https://github.com/swiftlang/swift.git 1111111111111111111111111111111111111111 $SWIFT_TARBALL_SHA256"; build_native) || exit 1
[ ! -e "$SB/kept.o" ] || fail "another swift commit kept the stdlib-build: $(cat "$T/out")"
grep -q "removing $SB: " "$T/out" || fail "removed the stdlib-build without saying so: $(cat "$T/out")"
echo "PASS"
