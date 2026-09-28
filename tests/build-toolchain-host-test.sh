#!/bin/sh
# platform: macOS-only -- runs build-toolchain.sh, a macOS-only script, with every tool it calls faked
# usage: sh tests/build-toolchain-host-test.sh
#   build-toolchain.sh --host must build each host's toolchain from its own dirs and checkout, with
#   its own patches and configure, and without building anything: every tool it runs is a fake that
#   records its arguments. x86_64 (the default) applies compiler patches 0001 and 0002, cross-compiles
#   with clang22 and runs the native helpers; arm64 applies 0001 alone to its own checkout, configures
#   for an arm64 / macOS 11.0 host against the 11.3 SDK with no native helpers and no
#   -runtime-compatibility-version, and its check stage refuses a frontend that does not run on the
#   OS's /usr/lib/swift. Any other host is refused before anything runs. TRACE_OUT=<file> keeps the
#   x86_64 run's record of commands, with this test's temp dir spelled <T>, to compare two versions.
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
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
echo "clone_pinned \$*" >> "$T/log"
mkdir -p "\$4/lib/Driver" "\$4/cmake/modules"; : >> "\$4/lib/Driver/Driver.cpp"; : >> "\$4/cmake/modules/AddSwift.cmake"
F
cat > "$T/shipyard/fetch_sdk.sh" <<F
#!/bin/sh
case "\$*" in '--arch arm64') echo "$T/sdk/MacOSX11.3.sdk" ;; '') echo "$T/sdk/MacOSX10.9.sdk" ;; *) exit 9 ;; esac
F
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
for c in shipyard-cmake ninja; do
  printf '#!/bin/sh\n{ echo "%s"; for a in "$@"; do echo "  $a"; done; } >> "%s/log"\n' "$c" "$T" > "$T/bin/$c"
done
printf '#!/bin/sh\necho "python3 $*" >> "%s/log"\nexit "${FAKE_AUDIT_RC:-0}"\n' "$T" > "$T/bin/python3"
cat > "$T/bin/xcrun" <<F
#!/bin/sh
case "\$*" in '-f dyld_info') echo "$T/bin/dyld_info" ;; '--show-sdk-path') echo "$T/sdk/modern" ;; *) exit 9 ;; esac
F
cat > "$T/bin/dyld_info" <<'F'
#!/bin/sh
printf '%s [%s]:\n' "$2" "${FAKE_ARCH:-x86_64}"
case "$1" in
  -platform) printf '    -platform:\n        platform     minOS      sdk\n          macOS      %s\n' "${FAKE_PLATFORM:-10.9      10.9}" ;;
  -rpaths) printf '    -rpaths:\n        %s\n' "${FAKE_RPATH:-@loader_path/../lib/swift/macosx}" ;;
  -dependents) printf '    -linked_dylibs:\n        attributes       load path\n                         %s\n' "${FAKE_CORE:-/usr/lib/swift/libswiftCore.dylib}" ;;
esac
F
chmod +x "$T/bin/"* "$T/shipyard/"* "$R/fetch-clang22.sh" "$R/scripts/guard.sh"
W="$T/w"; mkdir -p "$W/llvm-build/bin" "$W/llvm-build/lib" "$W/llvm-project/lld/MachO" "$W/toolchain/usr/bin"
for f in llvm-build/bin/llvm-tblgen toolchain/usr/bin/swiftc; do printf '#!/bin/sh\n' > "$W/$f"; chmod +x "$W/$f"; done
: > "$W/llvm-build/lib/libLLVMBitstreamReader.a"
echo "swiftlang's fork refuses every Apple-platform input" > "$W/llvm-project/lld/MachO/InputFiles.cpp"
run() {  # run <log-name> [build-toolchain.sh args] -- a fresh checkout state and log each time
  _n="$1"; shift
  rm -rf "$W/swift-compiler" "$W/swift-compiler-arm64" "$W/cmark" "$T/log"; : > "$T/log"
  _rc=0
  PATH="$T/bin:$PATH" SHIPYARD_SCRIPTS="$T/shipyard" SWIFT_WORK="$W" JOBS=2 MAVERICKS_USE_CCACHE=0 \
    sh "$R/build-toolchain.sh" "$@" > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
has() { grep -qxF -- "$2" "$T/$1.log" || fail "$1: never ran [$2]: $(cat "$T/$1.out")"; }
lacks() { if grep -qF -- "$2" "$T/$1.log"; then fail "$1: ran [$2]"; fi; }

echo "-- x86_64, the default: 0001 and 0002, clang22 cross-compiling, the native helpers, the bundled runtime"
run x86 || fail "the x86_64 build failed: $(cat "$T/x86.out")"
if [ -n "${TRACE_OUT:-}" ]; then cp "$T/x86.log" "$TRACE_OUT"; fi
has x86 "git -C swift-compiler apply -p0 <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
has x86 "git -C swift-compiler apply -p0 <T>/repo/patches/compiler/0002-hosttools-rpath-loader-path.patch"
has x86 "  -DCMAKE_C_COMPILER=<T>/clang22/bin/clang"
has x86 "  -DCMAKE_CROSSCOMPILING=ON"
has x86 "  -DSWIFT_SOURCE_DIR=<T>/w/swift-compiler"
has x86 "  -DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;<T>/sdk/modern;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-disable-availability-checking;-runtime-compatibility-version;none"
has x86 "guard ALLOW= <T>/w/swift-x86/bin/swift-frontend <T>/w/llvm-x86/bin/lld <T>/w/llvm-x86/bin/clang"
lacks x86 "arm64"
grep -qx 'OK: swift-frontend, lld and clang for x86_64 / 10.9' "$T/x86.out" || fail "x86_64 did not finish OK: $(cat "$T/x86.out")"

echo "-- arm64: 0001 alone in its own checkout, Apple clang for arm64 / 11.0 on the 11.3 SDK, no native helpers"
export FAKE_ARCH=arm64 FAKE_PLATFORM='11.0      11.3' FAKE_RPATH=/usr/lib/swift
run arm64 --host arm64 || fail "the arm64 build failed: $(cat "$T/arm64.out")"
has arm64 "git -C swift-compiler-arm64 apply -p0 <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
lacks arm64 "0002-hosttools-rpath-loader-path.patch"
lacks arm64 "git -C swift-compiler "
has arm64 "  -DCMAKE_C_COMPILER=/usr/bin/clang"
has arm64 "  -DCMAKE_OSX_SYSROOT=<T>/sdk/MacOSX11.3.sdk"
has arm64 "  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"
has arm64 "  -DCMAKE_OSX_ARCHITECTURES=arm64"
has arm64 "  -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9"
has arm64 "  -DLLVM_TARGETS_TO_BUILD=X86"
has arm64 "  -DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;<T>/sdk/MacOSX11.3.sdk;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-strict-implicit-module-context"
has arm64 "  <T>/w/llvm-arm64"
has arm64 "  <T>/w/cmark-arm64"
has arm64 "  <T>/w/swift-arm64"
lacks arm64 "CMAKE_CROSSCOMPILING"
lacks arm64 "native-helpers"
lacks arm64 "runtime-compatibility-version"
lacks arm64 "clang22"
lacks arm64 "llvm-x86"
has arm64 "guard ALLOW=arm64 <T>/w/swift-arm64/bin/swift-frontend <T>/w/llvm-arm64/bin/lld <T>/w/llvm-arm64/bin/clang"
has arm64 "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
grep -qx 'OK: swift-frontend, lld and clang for arm64 / macOS 11.0, targeting x86_64 / OS X 10.9' "$T/arm64.out" \
  || fail "arm64 did not finish OK: $(cat "$T/arm64.out")"

echo "-- arm64's check refuses a frontend on the package's own stdlib, or one the audit fails"
# platform: macOS's /bin/sh (bash 3.2) leaks a VAR=val prefix on a shell-FUNCTION call past that call
#           (unlike a real POSIX shell, or bash 4+); a subshell confines each override to its own case.
if (FAKE_RPATH=@loader_path/../lib/swift/macosx run rp --host arm64); then fail "passed a frontend with rpath @loader_path/../lib/swift/macosx"; fi
grep -q "^FAIL: swift-frontend's rpaths are \[@loader_path/../lib/swift/macosx\]" "$T/rp.out" || fail "rpath: $(cat "$T/rp.out")"
if (FAKE_CORE=@rpath/libswiftCore.dylib run core --host arm64); then fail "passed a frontend loading @rpath/libswiftCore.dylib"; fi
grep -q "^FAIL: swift-frontend does not load the OS's /usr/lib/swift/libswiftCore.dylib" "$T/core.out" || fail "core: $(cat "$T/core.out")"
if (FAKE_AUDIT_RC=1 run audit --host arm64); then fail "passed a frontend the import audit failed"; fi
has audit "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
if grep -q '^OK:' "$T/audit.out"; then fail "printed OK after the import audit failed: $(cat "$T/audit.out")"; fi
unset FAKE_ARCH FAKE_PLATFORM FAKE_RPATH

echo "-- any other host is refused before anything runs"
for bad in "--host x86" "--host" "--hots arm64"; do
  rc=0; run bad $bad || rc=$?
  [ "$rc" -eq 2 ] || fail "'$bad': exit $rc, not 2: $(cat "$T/bad.out")"
  [ ! -s "$T/bad.log" ] || fail "'$bad' ran [$(head -1 "$T/bad.log")] before refusing"
done
echo "PASS"
