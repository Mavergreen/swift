#!/bin/sh
# platform: macOS-only -- runs build-toolchain.sh, a macOS-only script, with every tool it calls faked
# usage: sh tests/build-toolchain-host-test.sh
#   build-toolchain.sh must build each toolchain from its own dirs and checkout, with its own patches and
#   configure, and without building anything: every tool it runs is a fake that records its arguments.
#   The x86_64 toolchain (the default) is the same configuration in both modes -- clang22 with its
#   llvm-libtool-darwin, llvm-ar, llvm-ranlib and lld, the 10.9 SDK's stubs, the prefix maps, clang's
#   default linker and host linker version, the Swift half compiled by SWIFT_HOST_TOOLCHAIN against the
#   11.3 SDK with its module cache in the build root and libswiftDarwin's own link dir, compiler patches
#   0001 and 0002 -- plus,
#   cross (CI), the cross-compiling settings, build-llvm.sh's TableGen and the native helpers, and a
#   refusal when no host toolchain is named; native (OS X 10.9), none of those, the installed toolchain by
#   default, and the check read with otool. A changed host toolchain configures the Swift build afresh,
#   and the same one does not. The arm64 toolchain (cross mode only) applies 0001 alone to its own
#   checkout, configures for an arm64 / macOS 11.0 host against the 11.3 SDK with no native helpers and no
#   -runtime-compatibility-version, pins the same clang defaults, and its check refuses a frontend that
#   does not run on the OS's /usr/lib/swift. A missing host swiftc, either host's, is refused before
#   anything is configured. Any other host is refused before anything runs. "The installed toolchain" is
#   SWIFT_INSTALLED_TOOLCHAIN, here always a prefix under this test's own dir, so whether this machine has
#   /usr/local/mavergreen/swift-toolchain (OS X 10.9 does, as does a Mac with the pkg) changes nothing.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-toolchain-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"

# A copy of the script under test, with its own sources, beside fakes for what it runs.
R="$T/repo"; mkdir -p "$R/scripts" "$R/patches"
cp "$REPO/build-toolchain.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
cp -R "$REPO/patches/compiler" "$R/patches/"
printf '#!/bin/sh\necho "%s/clang22"\n' "$T" > "$R/fetch-clang22.sh"
printf '#!/bin/sh\necho "guard ALLOW=${MAVERICKS_ALLOW_ARCHS:-} $*" >> "%s/log"\n' "$T" > "$R/scripts/guard.sh"
mkdir -p "$T/bin" "$T/shipyard"
for P in "$T/clang22" "$T/clang22n"; do
  mkdir -p "$P/bin"
  for t in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm; do printf '#!/bin/sh\n' > "$P/bin/$t"; done
  chmod +x "$P/bin/"*
done
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
echo "clone_pinned \$*" >> "$T/log"
mkdir -p "\$4/lib/Driver" "\$4/cmake/modules"; : >> "\$4/lib/Driver/Driver.cpp"; : >> "\$4/cmake/modules/AddSwift.cmake"
F
cat > "$T/shipyard/fetch_sdk.sh" <<F
#!/bin/sh
case "\$*" in '--arch arm64') echo "$T/sdk/MacOSX11.3.sdk" ;; '') echo "$T/sdk/MacOSX10.9.sdk" ;; *) exit 9 ;; esac
F
# sdk109_stubs sources these two; the stub-form SDK is already in the cache, so nothing is fetched.
printf 'mav_fetch_pinned() { echo "fetched $*" >> "%s/log"; return 1; }\n' "$T" > "$T/shipyard/mavericks_fetch.sh"
printf 'mav_sdk_pin() { echo "https://example.invalid/x.tar.xz 0 MacOSX10.9.sdk.tar.xz MacOSX10.9.sdk"; }\n' > "$T/shipyard/sdk-pins.sh"
mkdir -p "$T/sdkcache/stubs/MacOSX10.9.sdk/usr/lib"
cat > "$T/bin/git" <<F
#!/bin/sh
echo "git \$*" >> "$T/log"
case "\$*" in
  ls-remote*) echo "$CMARK_SHA	refs/tags/$CMARK_TAG" ;;
  *' apply -p0 --check '*) : ;;
  *' apply -p0 '*) d="\$2"; p="\$5"
     case "\${p##*/}" in
       0001-*) echo 'any macOS SDK back to 10.9 is accepted' >> "\$d/lib/Driver/Driver.cpp" ;;
       0002-*) echo "host tools run on the toolchain's own bundled runtime" >> "\$d/cmake/modules/AddSwift.cmake" ;;
     esac ;;
esac
F
# shipyard-cmake records its arguments and, like a configure, leaves a CMakeCache.txt in its -B dir.
cat > "$T/bin/shipyard-cmake" <<F
#!/bin/sh
{ echo "shipyard-cmake"; for a in "\$@"; do echo "  \$a"; done; } >> "$T/log"
b=""; for a in "\$@"; do if [ "\$b" = next ]; then mkdir -p "\$a" && : > "\$a/CMakeCache.txt"; b=""; elif [ "\$a" = -B ]; then b=next; fi; done
F
printf '#!/bin/sh\n{ echo "ninja"; for a in "$@"; do echo "  $a"; done; } >> "%s/log"\n' "$T" > "$T/bin/ninja"
printf '#!/bin/sh\necho "python3 $*" >> "%s/log"\nexit "${FAKE_AUDIT_RC:-0}"\n' "$T" > "$T/bin/python3"
cat > "$T/bin/xcrun" <<F
#!/bin/sh
case "\$*" in
  '-f dyld_info') [ -z "\${FAKE_NO_DYLDINFO:-}" ] || exit 1; echo "$T/bin/dyld_info" ;;
  *) echo "xcrun \$*" >> "$T/log"; exit 9 ;;
esac
F
cat > "$T/bin/dyld_info" <<'F'
#!/bin/sh
printf '%s [%s]:\n' "$2" "${FAKE_ARCH:-x86_64}"
case "$1" in
  -platform) printf '    -platform:\n        platform     minOS      sdk\n          macOS      %s\n' "${FAKE_PLATFORM:-10.9      10.9}" ;;
  -rpaths) printf '    -rpaths:\n        %s\n' "${FAKE_RPATH:-@loader_path/../lib/swift/macosx}" ;;
  -dependents) printf '    -linked_dylibs:\n        attributes       load path\n'
     printf '%s\n' "${FAKE_CORE:-/usr/lib/swift/libswiftCore.dylib}" | while IFS= read -r _dep; do
       printf '                         %s\n' "$_dep"
     done ;;
esac
F
# OS X 10.9 has no dyld_info: the native check reads otool's load commands.
cat > "$T/bin/otool" <<'F'
#!/bin/sh
[ "$1" = -l ] || exit 9
printf '      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n  version %s\n      sdk 10.9\n' "${FAKE_OTOOL_MIN:-10.9}"
printf '          cmd LC_RPATH\n      cmdsize 48\n         path @loader_path/../lib/swift/macosx (offset 12)\n'
F
chmod +x "$T/bin/"* "$T/shipyard/"* "$R/fetch-clang22.sh" "$R/scripts/guard.sh"
# A host Swift toolchain: what host_swiftc_stamp hashes, and a frontend that prints its version.
H="$T/host"; mkdir -p "$H/bin" "$H/lib/swift/macosx/Swift.swiftmodule"
printf '#!/bin/sh\n' > "$H/bin/swiftc"; printf '#!/bin/sh\necho "Swift version 6.4 (host)"\n' > "$H/bin/swift-frontend"; chmod +x "$H/bin/"*
echo module > "$H/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"; echo core > "$H/lib/swift/macosx/libswiftCore.dylib"
W="$T/w"; mkdir -p "$W/llvm-build/bin" "$W/llvm-build/lib" "$W/llvm-project/lld/MachO" "$W/toolchain/usr/bin"
for f in llvm-build/bin/llvm-tblgen toolchain/usr/bin/swiftc; do printf '#!/bin/sh\n' > "$W/$f"; chmod +x "$W/$f"; done
: > "$W/llvm-build/lib/libLLVMBitstreamReader.a"
# Native mode's default host toolchain, where no toolchain is installed: every run that names none says so.
SWIFT_INSTALLED_TOOLCHAIN="$T/installed"; export SWIFT_INSTALLED_TOOLCHAIN
echo "swiftlang's fork refuses every Apple-platform input" > "$W/llvm-project/lld/MachO/InputFiles.cpp"
run() {  # run <log-name> <mode> [build-toolchain.sh args] -- a fresh checkout state and log each time
  _n="$1"; _m="$2"; shift 2
  rm -rf "$W/swift-compiler" "$W/swift-compiler-arm64" "$W/cmark" "$T/log"; : > "$T/log"
  _rc=0
  PATH="$T/bin:$PATH" SHIPYARD_SCRIPTS="$T/shipyard" SWIFT_WORK="$W" JOBS=2 MAVERICKS_USE_CCACHE=0 MAVERICKS_MODE="$_m" \
    MAVERICKS_SDK_CACHE="$T/sdkcache" CLANG22_PREFIX="$T/clang22n" sh "$R/build-toolchain.sh" "$@" > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
has() { grep -qxF -- "$2" "$T/$1.log" || fail "$1: never ran [$2]: $(cat "$T/$1.out")"; }
lacks() { if grep -qF -- "$2" "$T/$1.log"; then fail "$1: ran [$2]"; fi; }
x86_both() {  # what the x86_64 toolchain's configure is in either mode; $2 is that mode's clang22
  has "$1" "git -C swift-compiler apply -p0 <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
  has "$1" "git -C swift-compiler apply -p0 <T>/repo/patches/compiler/0002-hosttools-rpath-loader-path.patch"
  has "$1" "  -DCMAKE_C_COMPILER=<T>/$2/bin/clang"
  has "$1" "  -DCMAKE_AR=<T>/$2/bin/llvm-ar"
  has "$1" "  -DCMAKE_RANLIB=<T>/$2/bin/llvm-ranlib"
  has "$1" "  -DCMAKE_LIBTOOL=<T>/$2/bin/llvm-libtool-darwin"
  has "$1" "  -DCMAKE_LINKER=<T>/$2/bin/ld64.lld"
  has "$1" "  -DCMAKE_C_FLAGS=-ffile-prefix-map=<T>/w=/mavergreen-build -ffile-prefix-map=<T>/w=/mavergreen-build"
  has "$1" "  -DCMAKE_CXX_FLAGS=-ffile-prefix-map=<T>/w=/mavergreen-build -ffile-prefix-map=<T>/w=/mavergreen-build"
  has "$1" "  -DCMAKE_OSX_SYSROOT=<T>/sdkcache/stubs/MacOSX10.9.sdk"
  has "$1" "  -DSWIFT_SDK_OSX_PATH=<T>/sdkcache/stubs/MacOSX10.9.sdk"
  has "$1" "  -DCLANG_DEFAULT_LINKER=lld"
  has "$1" "  -DHOST_LINK_VERSION=241.9"
  has "$1" "  -DCMAKE_Swift_COMPILER=<T>/host/bin/swiftc"
  has "$1" "  -DCMAKE_EXE_LINKER_FLAGS=-L<T>/w/swiftdarwin-x86"
  has "$1" "  -DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;<T>/sdk/MacOSX11.3.sdk;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-disable-availability-checking;-runtime-compatibility-version;none;-module-cache-path;<T>/w/swift-x86-modcache"
  has "$1" "guard ALLOW= <T>/w/swift-x86/bin/swift-frontend <T>/w/llvm-x86/bin/lld <T>/w/llvm-x86/bin/clang"
  lacks "$1" "<T>/sdk/MacOSX10.9.sdk"
  lacks "$1" "toolchain/usr/bin/swiftc"
  lacks "$1" "xcrun"
  lacks "$1" "fetched"
  lacks "$1" "arm64"
  [ "$(readlink "$W/swiftdarwin-x86/libswiftDarwin.tbd")" = "$T/sdk/MacOSX11.3.sdk/usr/lib/swift/libswiftDarwin.tbd" ] \
    || fail "$1: swiftdarwin-x86 does not hold the 11.3 SDK's libswiftDarwin.tbd alone"
  [ "$(ls "$W/swiftdarwin-x86")" = libswiftDarwin.tbd ] || fail "$1: swiftdarwin-x86 holds more than libswiftDarwin.tbd"
  grep -qx '    host: Swift version 6.4 (host)' "$T/$1.out" || fail "$1: did not print the host's version: $(cat "$T/$1.out")"
  grep -qx 'OK: swift-frontend, lld and clang for x86_64 / 10.9' "$T/$1.out" || fail "$1 did not finish OK: $(cat "$T/$1.out")"
}

echo "-- x86_64, cross (CI): clang22-cross, build-llvm.sh's TableGen, the native helpers, the named host toolchain"
SWIFT_HOST_TOOLCHAIN="$H"; export SWIFT_HOST_TOOLCHAIN
run x86 cross || fail "the cross x86_64 build failed: $(cat "$T/x86.out")"
x86_both x86 clang22
has x86 "  -DCMAKE_CROSSCOMPILING=ON"
has x86 "  -DLLVM_TABLEGEN=<T>/w/llvm-build/bin/llvm-tblgen"
has x86 "  -DSWIFT_NATIVE_CLANG_TOOLS_PATH=<T>/host/bin"
has x86 "  -DSWIFT_SOURCE_DIR=<T>/w/swift-compiler"
lacks x86 "clang22n"
cmp -s "$W/swift-x86/mavergreen-host.stamp" - <<EOF || fail "the host stamp is not host_swiftc_stamp's: $(cat "$W/swift-x86/mavergreen-host.stamp")"
$(. "$REPO/lib.sh" && host_swiftc_stamp "$H")
EOF

echo "-- x86_64, cross, the same host again: the Swift build is kept; a changed one is configured afresh"
run again cross || fail "the second run failed: $(cat "$T/again.out")"
if grep -q 'configuring it afresh' "$T/again.out"; then fail "the same host reconfigured the Swift build"; fi
echo module2 > "$H/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
run changed cross || fail "the run with a changed host failed: $(cat "$T/changed.out")"
grep -q "$W/swift-x86: its host swiftc changed" "$T/changed.out" || fail "a changed host kept the Swift build: $(cat "$T/changed.out")"

echo "-- x86_64, cross, no host toolchain named: refused (CI never builds with an earlier release)"
unset SWIFT_HOST_TOOLCHAIN
if run nohost cross; then fail "built with no SWIFT_HOST_TOOLCHAIN in cross mode"; fi
grep -q 'name the toolchain that compiles the Swift half with SWIFT_HOST_TOOLCHAIN' "$T/nohost.out" || fail "nohost: $(cat "$T/nohost.out")"
lacks nohost "shipyard-cmake"
if grep -q '^==> 1\.' "$T/nohost.out"; then fail "nohost: step 1 ran before the missing host toolchain was refused"; fi

echo "-- x86_64, native (OS X 10.9): clang22's native toolchain, its own TableGen and helpers, the check with otool"
(SWIFT_HOST_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 run native native) || fail "the native build failed: $(cat "$T/native.out")"
x86_both native clang22n
has native "  -DLLVM_TABLEGEN=<T>/w/llvm-x86/bin/llvm-tblgen"
lacks native "CMAKE_CROSSCOMPILING"
lacks native "llvm-build"
lacks native "native-helpers"
lacks native "SWIFT_NATIVE_"
lacks native "<T>/clang22/"
if (SWIFT_HOST_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 FAKE_OTOOL_MIN=10.10 run native1010 native); then fail "passed a binary otool reads as minOS 10.10"; fi
grep -q "records minOS/SDK '10.10 10.9'" "$T/native1010.out" || fail "native1010: $(cat "$T/native1010.out")"
if (FAKE_NO_DYLDINFO=1 run default native); then fail "built with the installed toolchain, which is not there"; fi
grep -q "no $T/installed/bin/swiftc" "$T/default.out" || fail "native's default host is not the installed toolchain: $(cat "$T/default.out")"
lacks default "shipyard-cmake"
(SWIFT_INSTALLED_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 run inst native) || fail "the native build with an installed toolchain failed: $(cat "$T/inst.out")"
has inst "  -DCMAKE_Swift_COMPILER=<T>/host/bin/swiftc"
grep -qF 'SWIFT_INSTALLED_TOOLCHAIN:-/usr/local/mavergreen/swift-toolchain}' "$R/build-toolchain.sh" \
  || fail "the installed toolchain is not /usr/local/mavergreen/swift-toolchain by default"
rc=0; run narm native --host arm64 || rc=$?
[ "$rc" -eq 2 ] || fail "native --host arm64: exit $rc, not 2"
[ ! -s "$T/narm.log" ] || fail "native --host arm64 ran [$(head -1 "$T/narm.log")] before refusing"

echo "-- arm64: 0001 alone in its own checkout, Apple clang for arm64 / 11.0 on the 11.3 SDK, no native helpers"
export FAKE_ARCH=arm64 FAKE_PLATFORM='11.0      11.3' FAKE_RPATH=/usr/lib/swift
run arm64 cross --host arm64 || fail "the arm64 build failed: $(cat "$T/arm64.out")"
has arm64 "git -C swift-compiler-arm64 apply -p0 <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
lacks arm64 "0002-hosttools-rpath-loader-path.patch"
lacks arm64 "git -C swift-compiler "
has arm64 "  -DCMAKE_C_COMPILER=/usr/bin/clang"
has arm64 "  -DCMAKE_OSX_SYSROOT=<T>/sdk/MacOSX11.3.sdk"
has arm64 "  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"
has arm64 "  -DCMAKE_OSX_ARCHITECTURES=arm64"
has arm64 "  -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9"
has arm64 "  -DLLVM_TARGETS_TO_BUILD=X86"
has arm64 "  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw"
has arm64 "  -DLLVM_TABLEGEN=<T>/w/llvm-build/bin/llvm-tblgen"
has arm64 "  -DCLANG_TABLEGEN=<T>/w/llvm-build/bin/clang-tblgen"
has arm64 "  -DLLVM_NATIVE_TOOL_DIR=<T>/w/llvm-build/bin"
has arm64 "  -DCMAKE_LINKER=<T>/w/llvm-build/bin/ld64.lld"
has arm64 "  -DCLANG_DEFAULT_LINKER=lld"
has arm64 "  -DHOST_LINK_VERSION=241.9"
has arm64 "  -DCMAKE_Swift_COMPILER=<T>/w/toolchain/usr/bin/swiftc"
has arm64 "  -DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;<T>/sdk/MacOSX11.3.sdk;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-strict-implicit-module-context"
has arm64 "  <T>/w/llvm-arm64"
has arm64 "  <T>/w/cmark-arm64"
has arm64 "  <T>/w/swift-arm64"
lacks arm64 "CMAKE_CROSSCOMPILING"
lacks arm64 "native-helpers"
lacks arm64 "runtime-compatibility-version"
lacks arm64 "clang22"
lacks arm64 "llvm-x86"
lacks arm64 "stubs"
has arm64 "guard ALLOW=arm64 <T>/w/swift-arm64/bin/swift-frontend <T>/w/llvm-arm64/bin/lld <T>/w/llvm-arm64/bin/clang"
has arm64 "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
grep -qx 'OK: swift-frontend, lld and clang for arm64 / macOS 11.0, targeting x86_64 / OS X 10.9' "$T/arm64.out" \
  || fail "arm64 did not finish OK: $(cat "$T/arm64.out")"

echo "-- arm64 with no host swiftc (build.sh's): refused before step 1"
mv "$W/toolchain/usr/bin/swiftc" "$W/toolchain/usr/bin/swiftc.away"
rc=0; run notc cross --host arm64 || rc=$?
mv "$W/toolchain/usr/bin/swiftc.away" "$W/toolchain/usr/bin/swiftc"
[ "$rc" -ne 0 ] || fail "built arm64 with no host swiftc"
grep -q 'FAIL: no host swiftc -- run ./build.sh' "$T/notc.out" || fail "notc: $(cat "$T/notc.out")"
if grep -q '^==> 1\.' "$T/notc.out"; then fail "notc: step 1 ran before the missing host swiftc was refused"; fi
lacks notc "shipyard-cmake"

echo "-- arm64's check refuses a frontend on the package's own stdlib, or one the audit fails"
# platform: POSIX leaves unspecified whether a VAR=val prefix on a function call outlives the call,
#           and macOS's /bin/sh (bash 3.2) keeps it; a subshell confines each override to its own case.
if (FAKE_RPATH=@loader_path/../lib/swift/macosx run rp cross --host arm64); then fail "passed a frontend with rpath @loader_path/../lib/swift/macosx"; fi
grep -q "^FAIL: swift-frontend's rpaths are \[@loader_path/../lib/swift/macosx\]" "$T/rp.out" || fail "rpath: $(cat "$T/rp.out")"
if (FAKE_CORE=@rpath/libswiftCore.dylib run core cross --host arm64); then fail "passed a frontend loading @rpath/libswiftCore.dylib"; fi
grep -q "^FAIL: swift-frontend does not load the OS's /usr/lib/swift/libswiftCore.dylib" "$T/core.out" || fail "core: $(cat "$T/core.out")"
if (FAKE_CORE='/usr/lib/swift/libswiftCore.dylib
@rpath/libswift_Concurrency.dylib' run rpathlib cross --host arm64); then fail "passed a frontend also loading @rpath/libswift_Concurrency.dylib"; fi
grep -q "^FAIL: swift-frontend loads a Swift library through @rpath" "$T/rpathlib.out" || fail "rpathlib: $(cat "$T/rpathlib.out")"
if (FAKE_AUDIT_RC=1 run audit cross --host arm64); then fail "passed a frontend the import audit failed"; fi
has audit "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
if grep -q '^OK:' "$T/audit.out"; then fail "printed OK after the import audit failed: $(cat "$T/audit.out")"; fi
unset FAKE_ARCH FAKE_PLATFORM FAKE_RPATH

echo "-- any other host, or mode, is refused before anything runs"
for bad in "--host x86" "--host" "--hots arm64"; do
  rc=0; run bad cross $bad || rc=$?
  [ "$rc" -eq 2 ] || fail "'$bad': exit $rc, not 2: $(cat "$T/bad.out")"
  [ ! -s "$T/bad.log" ] || fail "'$bad' ran [$(head -1 "$T/bad.log")] before refusing"
done
rc=0; run badmode sideways || rc=$?
[ "$rc" -eq 2 ] || fail "mode 'sideways': exit $rc, not 2"
grep -q "mode 'sideways' is neither cross nor native" "$T/badmode.out" || fail "badmode: $(cat "$T/badmode.out")"
echo "PASS"
