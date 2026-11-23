#!/bin/sh
# platform: host-agnostic
# usage: sh tests/build-linux-host-test.sh
#   On Linux (a faked uname, so this runs on a Mac too) build.sh builds the runtime in cross mode with the
#   toolchain prefix SWIFT_HOST_TOOLCHAIN names (build-toolchain.sh --host linux stages one), whose release
#   SWIFT_HOST_TOOLCHAIN_VERSION declares: it refuses native mode, and the swift.org seed branch, whose
#   installer check and expansion need pkgutil and ditto, before either runs. It reads Mach-O with
#   clang22's llvm-otool, llvm-nm and llvm-strings, says so in step 1, and never runs otool, nm, strings,
#   xcrun, dyld_info, pkgutil, ditto or git; it configures the stdlib with the host's cmake, for a Darwin
#   target on an x86_64 processor, with clang22's llvm-install-name-tool. A clang22 without one of those
#   four stops step 1, naming it. scripts/imports-on-10.9.sh and scripts/guard.sh, on Linux, refuse to
#   run without the reader each needs named, saying which. Everything is faked; ninja stops the build
#   after the configure.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-linux-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"   # -> SWIFT_VERSION, CLANG22_VERSION
unset SWIFT_HOST_TOOLCHAIN_VERSION OTOOL NM STRINGS LIPO DYLDINFO

R="$T/root"; mkdir -p "$R/swift/out/llvm/lib/cmake/llvm" "$R/swift/work/llvm-build/bin" "$T/shipyard" "$T/fakebin"
: > "$R/swift/work/llvm-build/bin/ld64.lld"; chmod +x "$R/swift/work/llvm-build/bin/ld64.lld"
# The toolchain prefix build-toolchain.sh --host linux stages: no pkg installed it, so no mavergreen.plist.
H="$T/tc"; mkdir -p "$H/bin" "$H/lib/swift/macosx" "$H/lib/clang/21/include" "$H/lib/clang/21/lib/darwin"
: > "$H/bin/swift-frontend"; : > "$H/bin/clang"; : > "$H/bin/ld64.lld"; : > "$H/lib/clang/21/lib/darwin/libclang_rt.osx.a"
# uname says Linux; every macOS-only tool, and the Mac's readers and launcher, log that they ran and fail.
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$T/fakebin/uname"
for c in otool nm strings xcrun dyld_info pkgutil ditto lsbom git shipyard-cmake; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/log"\nexit 1\n' "$c" "$T" > "$T/fakebin/$c"
done
# The host's cmake records its arguments and leaves a cache; the build (ninja) stops the run.
cat > "$T/fakebin/cmake" <<F
#!/bin/sh
{ echo "cmake"; for a in "\$@"; do echo "  \$a"; done; } >> "$T/log"
b=""; for a in "\$@"; do if [ "\$b" = next ]; then mkdir -p "\$a" && : > "\$a/CMakeCache.txt"; b=""; elif [ "\$a" = -B ]; then b=next; fi; done
F
printf '#!/bin/sh\nexit 3\n' > "$T/fakebin/ninja"
# patch: a dry run applies; a real one writes the marker build.sh greps for that patch.
cat > "$T/fakebin/patch" <<'F'
#!/bin/sh
p=""; dry=0
for a in "$@"; do case "$a" in --dry-run) dry=1 ;; esac; done
while [ $# -gt 0 ]; do case "$1" in -i) p="$2"; shift 2 ;; *) shift ;; esac; done
[ "$dry" = 1 ] && exit 0
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

# clang22's Linux archive (no llvm-libtool-darwin), which fetch-clang22.sh gets from shipyard's fetch_clang22.sh.
C22="$T/clang22"; mkdir -p "$C22/bin" "$C22/include/c++/v1"; : > "$C22/include/c++/v1/__config"
for t in clang clang++ ld64.lld llvm-ranlib llvm-lipo llvm-strings llvm-install-name-tool; do
  printf '#!/bin/sh\n' > "$C22/bin/$t"
done
printf '#!/bin/sh\necho "llvm-otool $*" >> "%s/log"\n' "$T" > "$C22/bin/llvm-otool"
printf '#!/bin/sh\ncase "$1" in rcs) : > "$2" ;; esac\n' > "$C22/bin/llvm-ar"
# Recaulk's archive as clang22's llvm-nm -A reads it (tests/build-native-host-test.sh's, which says why).
cat > "$C22/bin/llvm-nm" <<F
#!/bin/sh
echo "llvm-nm \$*" >> "$T/log"
F
cat >> "$C22/bin/llvm-nm" <<'F'
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
chmod +x "$C22/bin/"*
# shipyard v1.0.822's fetch_clang22.sh (it names install-products.sh), answering with the archive above.
printf '#!/bin/sh\n# install-products.sh\n[ "$1" = "%s/components/clang22" ] || exit 1\necho "%s"\n' "$REPO" "$C22" > "$T/shipyard/fetch_clang22.sh"
printf '#!/bin/sh\necho "%s/sdk/MacOSX11.3.sdk"\n' "$T" > "$T/shipyard/fetch_sdk.sh"
printf '%s\n' 'shipyard_sdk_pin() { echo https://example.invalid/sdk 0 MacOSX10.9.sdk.tar.xz MacOSX10.9.sdk; }' > "$T/shipyard/sdk-pins.sh"
: > "$T/shipyard/mavericks_fetch.sh"
mkdir -p "$T/sdk-cache/stubs/MacOSX10.9.sdk/usr/lib"; : > "$T/sdk-cache/stubs/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib"
cat > "$T/shipyard/fetch_product_pkg.sh" <<'F'
#!/bin/sh
for d in "$@"; do :; done
case " $* " in
  *" recaulk "*) mkdir -p "$d/lib" "$d/share/recaulk" && : > "$d/lib/librecaulk.a" && : > "$d/share/recaulk/notices.tsv"
                 printf '%s\n' '# <member> <symbol> <reason>' 'recaulk-libm_fma.o _fma rounds once' \
                   'recaulk-socket_close.o _dup2 does not hang' 'recaulk-dispatch_inactive.o _dispatch_queue_create starts inactive' \
                   'recaulk-dispatch_inactive.o _dispatch_resume counts as the activation' > "$d/share/recaulk/image-local-shadows.txt" ;;
  *) mkdir -p "$d/lib" && : > "$d/lib/libc++.1.dylib" && : > "$d/lib/libc++abi.1.dylib" ;;
esac
F
cat > "$T/shipyard/fetch_pinned_source.sh" <<'F'
#!/bin/sh
rm -rf "$4"; mkdir -p "$4/stdlib/public/stubs" "$4/stdlib/public/runtime" "$4/stdlib/public/core" "$4/include/swift/Runtime" \
  "$4/stdlib/private/StdlibUnittest" "$4/stdlib/public/Concurrency"
for f in CMakeLists.txt stdlib/public/stubs/Availability.mm stdlib/public/runtime/SwiftObject.mm stdlib/public/runtime/Metadata.cpp \
         include/swift/Runtime/Config.h stdlib/public/core/StringBridge.swift stdlib/private/StdlibUnittest/StdlibUnittest.swift \
         stdlib/public/core/FloatingPointParsing.swift.gyb stdlib/public/Concurrency/CMakeLists.txt \
         stdlib/public/Concurrency/DispatchGlobalExecutor.cpp stdlib/public/Concurrency/TracingSignpost.h; do : > "$4/$f"; done
echo "$1 $2 $3" > "$4/.mavergreen-source"
F
chmod +x "$T/shipyard/"* "$T/fakebin/"*

build() {  # build.sh on "Linux"; $1 = MAVERICKS_MODE; SWIFT_HOST_TOOLCHAIN and its version as the caller exports them
  : > "$T/log"
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE="$1" \
      MAVERICKS_CLANG_CACHE="$T/clang-cache" MAVERGREEN_RECAULK_CACHE="$T/recaulk-cache" MAVERICKS_SDK_CACHE="$T/sdk-cache"
    unset SWIFT_WORK SWIFT_BUILTINS CLANG22_PREFIX
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
no_mac_tools() {
  if grep -E '^(otool|nm|strings|xcrun|dyld_info|pkgutil|ditto|lsbom|git|shipyard-cmake) ' "$T/log"; then
    fail "$1: ran a macOS-only tool or the Mac's reader (above): $(cat "$T/out")"
  fi
}

echo "-- no SWIFT_HOST_TOOLCHAIN: the swift.org seed branch is refused, before its pkgutil and ditto"
if build cross; then fail "built on Linux with the swift.org seed: $(cat "$T/out")"; fi
grep -q '^FAIL: .*SWIFT_HOST_TOOLCHAIN' "$T/out" || fail "did not say Linux needs SWIFT_HOST_TOOLCHAIN: $(cat "$T/out")"
grep -q 'pkgutil' "$T/out" && grep -q 'ditto' "$T/out" || fail "did not say the seed branch needs pkgutil and ditto: $(cat "$T/out")"
if grep -q 'swift.org toolchain at' "$T/out"; then fail "looked for the swift.org pkg on Linux: $(cat "$T/out")"; fi
no_mac_tools "the seed branch"

echo "-- native mode: refused on Linux"
export SWIFT_HOST_TOOLCHAIN="$H" SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.9"
if build native; then fail "built natively on Linux: $(cat "$T/out")"; fi
grep -q '^FAIL: .*native' "$T/out" || fail "did not refuse native mode: $(cat "$T/out")"
no_mac_tools "native mode"

echo "-- cross mode, the named prefix: clang22's readers, the host's cmake for a Darwin target; no macOS-only tool"
if build cross; then fail "build.sh got past a build that failed: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.9 (declared by SWIFT_HOST_TOOLCHAIN_VERSION)" "$T/out" \
  || fail "did not take the named prefix's declared release: $(cat "$T/out")"
grep -qxF "    readers: $C22/bin/llvm-otool, $C22/bin/llvm-nm and $C22/bin/llvm-strings (clang22's: Linux has no Mach-O otool, nm or strings)" "$T/out" \
  || fail "did not pick clang22's readers: $(cat "$T/out")"
grep -q "^llvm-otool -arch x86_64 -l $T/sdk-cache/stubs/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib\$" "$T/log" \
  || fail "did not read the 10.9 SDK's libSystem with clang22's llvm-otool: $(cat "$T/log")"
grep -qx 'cmake' "$T/log" || fail "the stdlib was not configured with the host's cmake: $(cat "$T/out")"
for a in -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 "-DCMAKE_INSTALL_NAME_TOOL=$C22/bin/llvm-install-name-tool" \
         "-DCMAKE_AR=$C22/bin/llvm-ar" -DCMAKE_OSX_ARCHITECTURES=x86_64; do
  grep -qxF -e "  $a" "$T/log" || fail "the stdlib configure lacks $a: $(cat "$T/log")"
done
no_mac_tools "cross mode"

echo "-- a clang22 without one of the tools Linux reads or configures with: refused in step 1, naming it"
for t in llvm-otool llvm-nm llvm-strings llvm-install-name-tool; do
  mv "$C22/bin/$t" "$T/$t.away"
  if build cross; then fail "built without $t: $(cat "$T/out")"; fi
  grep -q '^FAIL: no ' "$T/out" || fail "no $t: did not FAIL: $(cat "$T/out")"
  grep -qF "no $C22/bin/$t (" "$T/out" || grep -q "^FAIL: no $t (" "$T/out" || fail "did not name $t: $(cat "$T/out")"
  if grep -qx 'cmake' "$T/log"; then fail "configured without $t"; fi
  no_mac_tools "no $t"
  mv "$T/$t.away" "$C22/bin/$t"
done
mv "$C22/bin/llvm-install-name-tool" "$T/inst.away"
build cross || :
grep -qx "FAIL: no llvm-install-name-tool ($C22/bin/llvm-install-name-tool: clang22's, which CMake's Darwin platform asks for)" "$T/out" \
  || fail "did not say FAIL: no llvm-install-name-tool: $(cat "$T/out")"
mv "$T/inst.away" "$C22/bin/llvm-install-name-tool"

echo "-- imports-on-10.9.sh and guard.sh on Linux: each reader named, or FAIL: no <it>"
mkdir -p "$T/sdk109/usr/lib"; : > "$T/allow"; : > "$T/a.dylib"
onlinux() { ( PATH="$T/fakebin:$PATH"; SHIPYARD_SCRIPTS="$T/shipyard"; export PATH SHIPYARD_SCRIPTS; "$@" ) > "$T/out" 2>&1; }
if onlinux sh "$REPO/scripts/imports-on-10.9.sh" "$T/sdk109" "$T/allow" "$T/a.dylib"; then fail "imports-on-10.9 ran with no reader named"; fi
grep -q '^FAIL: no llvm-otool' "$T/out" || fail "imports-on-10.9 without OTOOL: $(cat "$T/out")"
if onlinux env OTOOL="$C22/bin/llvm-otool" sh "$REPO/scripts/imports-on-10.9.sh" "$T/sdk109" "$T/allow" "$T/a.dylib"; then fail "imports-on-10.9 ran with no NM"; fi
grep -q '^FAIL: no llvm-nm' "$T/out" || fail "imports-on-10.9 without NM: $(cat "$T/out")"
if onlinux env OTOOL="$T/absent" NM="$C22/bin/llvm-nm" sh "$REPO/scripts/imports-on-10.9.sh" "$T/sdk109" "$T/allow" "$T/a.dylib"; then fail "imports-on-10.9 ran with an OTOOL that is no program"; fi
grep -q "^FAIL: no llvm-otool" "$T/out" || fail "imports-on-10.9 with OTOOL naming nothing: $(cat "$T/out")"
printf '#!/bin/sh\necho "assert_binary_compatible LIPO=$LIPO OTOOL=$OTOOL NM=$NM STRINGS=$STRINGS $*"\n' > "$T/shipyard/assert_binary_compatible.sh"
for v in LIPO:llvm-lipo OTOOL:llvm-otool NM:llvm-nm STRINGS:llvm-strings; do
  ( for w in LIPO:llvm-lipo OTOOL:llvm-otool NM:llvm-nm STRINGS:llvm-strings; do
      [ "$w" = "$v" ] || export "${w%%:*}=$C22/bin/${w#*:}"
    done
    if onlinux sh "$REPO/scripts/guard.sh" "$T/a.dylib"; then fail "guard.sh ran without ${v%%:*}"; fi
    grep -q "^FAIL: no ${v#*:}" "$T/out" || fail "guard.sh without ${v%%:*}: $(cat "$T/out")" )
done
( export LIPO="$C22/bin/llvm-lipo" OTOOL="$C22/bin/llvm-otool" NM="$C22/bin/llvm-nm" STRINGS="$C22/bin/llvm-strings"
  onlinux sh "$REPO/scripts/guard.sh" "$T/a.dylib" ) || fail "guard.sh refused every reader named: $(cat "$T/out")"
grep -qxF "assert_binary_compatible LIPO=$C22/bin/llvm-lipo OTOOL=$C22/bin/llvm-otool NM=$C22/bin/llvm-nm STRINGS=$C22/bin/llvm-strings $T/a.dylib" "$T/out" \
  || fail "guard.sh did not hand shipyard's guard the readers: $(cat "$T/out")"
echo "PASS"
