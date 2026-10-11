#!/bin/sh
# platform: macOS-only -- runs build.sh (macOS-only), in both modes, with a fake pkgutil and toolchain
# usage: sh tests/build-native-host-test.sh
#   build.sh must build with a host toolchain of this checkout's Swift only: step 1 prints the release the
#   toolchain's receipt names, and refuses one of another Swift version, or one no pkg installed unless
#   SWIFT_HOST_TOOLCHAIN_VERSION declares it. Native mode cannot run here (it needs OS X 10.9 and the
#   installed toolchain), so a fake toolchain prefix and a fake pkgutil stand in; NM names no program, so a
#   toolchain step 1 accepts stops there, at the next check, before any SDK fetch. Cross mode (CI) takes
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
#   is another's (its stamp records the source, lib.sh's source_stamp).
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-native-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"   # -> SWIFT_VERSION
unset SWIFT_HOST_TOOLCHAIN_VERSION

R="$T/root"; mkdir -p "$R/swift/out/llvm/lib/cmake/llvm" "$R/swift/work/llvm-build/bin" "$T/shipyard" "$T/fakebin"
: > "$R/swift/work/llvm-build/bin/ld64.lld"; chmod +x "$R/swift/work/llvm-build/bin/ld64.lld"
H="$T/tc"; mkdir -p "$H/bin" "$H/lib/swift/macosx" "$H/lib/clang/21/include" "$H/lib/clang/21/lib/darwin"
: > "$H/bin/swift-frontend"; : > "$H/bin/clang"; : > "$H/bin/ld64.lld"; : > "$H/lib/clang/21/lib/darwin/libclang_rt.osx.a"
printf '#!/bin/sh\n[ "$1" = --file-info ] || exit 2\necho "$2" >> "%s/pkgutil-args"\ncat "%s/receipt"\n' "$T" "$T" > "$T/fakebin/pkgutil"
chmod +x "$T/fakebin/pkgutil"
receipt() {  # $1 = pkg-version, or nothing for no receipt
  { echo "volume: /"; echo "path: $H/bin/swift-frontend"
    [ -z "${1:-}" ] || printf '\npkgid: dev.mavergreen.swift-toolchain\npkg-version: %s\ninstall-time: 1790384965\n' "$1"; } > "$T/receipt"
}
build() {  # runs build.sh's native mode; its output in $T/out
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=native \
      SWIFT_HOST_TOOLCHAIN="$H" NM="$T/no-nm"
    unset SWIFT_WORK SWIFT_BUILTINS
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
went_past_step_1() { grep -q "FAIL: no $T/no-nm" "$T/out"; }

echo "-- a receipt of this checkout's Swift: printed, and step 1 goes on"
receipt "$SWIFT_VERSION-mavericks.7"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.7 (pkg dev.mavergreen.swift-toolchain)" "$T/out" \
  || fail "did not print the release: $(cat "$T/out")"
went_past_step_1 || fail "stopped before the check after the release's: $(cat "$T/out")"
if grep -q 'CMAKE_OSX_ARCHITECTURES' "$T/out"; then fail "native mode passes CMAKE_OSX_ARCHITECTURES: $(cat "$T/out")"; fi
grep -qxF "$H/bin/swift-frontend" "$T/pkgutil-args" || fail "looked up another file's receipt: $(cat "$T/pkgutil-args")"

echo "-- a receipt of another Swift: refused in step 1"
receipt "0.0.1-mavericks.1"
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q "FAIL: the host toolchain at $H is release 0.0.1-mavericks.1" "$T/out" || fail "did not refuse 0.0.1: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain of another Swift: $(cat "$T/out")"; fi

echo "-- no receipt: refused, unless SWIFT_HOST_TOOLCHAIN_VERSION declares this checkout's Swift"
receipt ""
if build; then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/out" || fail "did not name the override: $(cat "$T/out")"
if went_past_step_1; then fail "went on past a toolchain with no receipt: $(cat "$T/out")"; fi
if ( export SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.7"; build ); then fail "build.sh succeeded with a fake toolchain"; fi
grep -q "release $SWIFT_VERSION-mavericks.7 (declared" "$T/out" || fail "did not print the declared release: $(cat "$T/out")"
went_past_step_1 || fail "stopped at a declared release of this checkout's Swift: $(cat "$T/out")"

echo "-- cross mode with SWIFT_HOST_TOOLCHAIN: that toolchain, its receipt checked, never the swift.org pkg"
build_cross() {  # build.sh's cross mode; $1 names the host toolchain, or nothing for none
  ( export PATH="$T/fakebin:$PATH" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=cross
    unset SWIFT_WORK SWIFT_BUILTINS NM SWIFT_HOST_TOOLCHAIN
    if [ -n "$1" ]; then export SWIFT_HOST_TOOLCHAIN="$1"; fi
    sh "$REPO/build.sh" ) > "$T/out" 2>&1
}
receipt ""
if ( export SWIFT_HOST_TOOLCHAIN_VERSION="$SWIFT_VERSION-mavericks.9"; build_cross "$H" ); then fail "build.sh succeeded with a fake toolchain: $(cat "$T/out")"; fi
grep -qxF "    host toolchain $H: release $SWIFT_VERSION-mavericks.9 (declared by SWIFT_HOST_TOOLCHAIN_VERSION)" "$T/out" \
  || fail "cross mode did not take the named toolchain: $(cat "$T/out")"
grep -q 'FAIL: could not fetch the pinned modern SDK' "$T/out" || fail "cross mode stopped before the SDK fetch: $(cat "$T/out")"
if grep -q 'swift.org toolchain' "$T/out"; then fail "cross mode looked for the swift.org pkg beside a named toolchain"; fi
grep -qxF "    cmake architectures: -DCMAKE_OSX_ARCHITECTURES=x86_64 (a named host toolchain's clang is x86_64 only)" "$T/out" \
  || fail "cross mode with a named toolchain did not pass CMAKE_OSX_ARCHITECTURES: $(cat "$T/out")"
if build_cross "$H"; then fail "build.sh succeeded with a fake toolchain"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/out" || fail "cross mode took a receipt-less toolchain without a declared release: $(cat "$T/out")"
if build_cross ""; then fail "build.sh succeeded with no swift.org pkg"; fi
if grep -q 'CMAKE_OSX_ARCHITECTURES' "$T/out"; then fail "cross mode without a host toolchain passes CMAKE_OSX_ARCHITECTURES"; fi
grep -q "FAIL: no swift.org toolchain at $R/swift/cache/" "$T/out" || fail "cross mode without a host toolchain: $(cat "$T/out")"

echo "-- the stdlib configure takes step 1's architecture arguments (the call is run here with a fake shipyard-cmake)"
# Reaching step 4 for real needs the pinned swift source, patched; so the configure call itself is cut out of
# build.sh (from `shipyard-cmake` to the first line with no trailing backslash) and run with CMAKE_ARCH_ARGS set.
awk '/^shipyard-cmake /{on=1} on{print} on&&!/\\$/{exit}' "$REPO/build.sh" > "$T/configure.sh"
[ -s "$T/configure.sh" ] || fail "found no shipyard-cmake call in build.sh"
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
for t in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm llvm-otool llvm-strings; do
  printf '#!/bin/sh\n' > "$C22/bin/$t"; chmod +x "$C22/bin/$t"
done
printf '#!/bin/sh\necho "%s/sdk/MacOSX11.3.sdk"\n' "$T" > "$T/shipyard/fetch_sdk.sh"
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
echo "fetch_pinned_source \$*" >> "$T/log"
rm -rf "\$4"; mkdir -p "\$4/stdlib/public/stubs" "\$4/stdlib/public/runtime" "\$4/stdlib/public/core" "\$4/include/swift/Runtime"
for f in CMakeLists.txt stdlib/public/stubs/Availability.mm stdlib/public/runtime/SwiftObject.mm stdlib/public/runtime/Metadata.cpp \
         include/swift/Runtime/Config.h stdlib/public/core/StringBridge.swift; do : > "\$4/\$f"; done
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
  0001-*) echo fno-sized-deallocation >> CMakeLists.txt ;;
  0002-*) echo CFPropertyListCreateWithStream >> stdlib/public/stubs/Availability.mm ;;
  0003-*) echo mav_minimalRealize >> stdlib/public/runtime/SwiftObject.mm ;;
  0004-*) echo mav_roFromClassData >> stdlib/public/runtime/Metadata.cpp ;;
  0005-*) echo 'class_getInstanceSize((Class)const_cast' >> stdlib/public/runtime/Metadata.cpp ;;
  0007-*) echo 'ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 101404' >> include/swift/Runtime/Config.h ;;
  0008-*) echo 'was: hasFeature(Macros)' >> stdlib/public/core/StringBridge.swift ;;
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
receipt "$SWIFT_VERSION-mavericks.9"
build_native() {  # build.sh's native mode past step 1, everything faked; ninja stops it after the configure
  : > "$T/log"
  if ( export PATH="$T/fakebin:$PATH" FAKE_LOG="$T/log" MAVERICKS_BUILD_ROOT="$R" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_MODE=native \
        SWIFT_HOST_TOOLCHAIN="$H" CLANG22_PREFIX="$C22"
      unset SWIFT_WORK SWIFT_BUILTINS NM
      sh "$REPO/build.sh" ) > "$T/out" 2>&1; then fail "build.sh got past a build that failed: $(cat "$T/out")"; fi
}
build_native
grep -qxF "fetch_pinned_source https://github.com/swiftlang/swift.git $SWIFT_SHA $SWIFT_TARBALL_SHA256 swift" "$T/log" \
  || fail "did not fetch the swift tarball by its pin: $(cat "$T/out")"
[ "$(sed -n 's/^patch \([0-9]*\)-.*/\1/p' "$T/log" | tr '\n' ' ')" = "0001 0002 0003 0004 0005 0007 0008 " ] \
  || fail "patched in another order: $(grep '^patch' "$T/log" | tr '\n' ' ')"
for a in "-DCMAKE_AR=$C22/bin/llvm-ar" "-DCMAKE_RANLIB=$C22/bin/llvm-ranlib" "-DSWIFT_LIPO=$C22/bin/llvm-lipo" -DSWIFT_ENABLE_LIBXML2=OFF \
         -DCMAKE_TAPI=/usr/bin/false "-DCMAKE_STRIP=$C22/bin/llvm-strip" -DLD64_EXECUTABLE=/usr/bin/false -DCMAKE_Swift_COMPILER=NOTFOUND \
         -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON -DCMAKE_DISABLE_FIND_PACKAGE_LibEdit=ON -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON; do
  grep -qxF -e "  $a" "$T/log" || fail "the stdlib configure lacks $a: $(cat "$T/log")"
done
if grep -q '^git \|^xcrun ' "$T/log"; then fail "ran $(grep '^git \|^xcrun ' "$T/log" | head -1)"; fi
SB="$R/swift/work/stdlib-build"
grep -q '^archiver ' "$SB/mavergreen-inputs.stamp" \
  || fail "the stdlib-build's stamp does not record the archiver: $(cat "$SB/mavergreen-inputs.stamp")"

echo "-- the stdlib-build's stamp records the swift source: the same commit keeps it, another commit's starts it afresh"
grep -qxF "source swift https://github.com/swiftlang/swift.git $SWIFT_SHA $SWIFT_TARBALL_SHA256" "$SB/mavergreen-inputs.stamp" \
  || fail "the stdlib-build's stamp does not record the swift source: $(cat "$SB/mavergreen-inputs.stamp")"
: > "$SB/kept.o"
build_native
[ -f "$SB/kept.o" ] || fail "the same swift source removed the stdlib-build: $(cat "$T/out")"
(export FAKE_SWIFT_SOURCE="https://github.com/swiftlang/swift.git 1111111111111111111111111111111111111111 $SWIFT_TARBALL_SHA256"; build_native)
[ ! -e "$SB/kept.o" ] || fail "another swift commit kept the stdlib-build: $(cat "$T/out")"
grep -q "removing $SB: " "$T/out" || fail "removed the stdlib-build without saying so: $(cat "$T/out")"
echo "PASS"
