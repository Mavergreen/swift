#!/bin/sh
# platform: macOS-only -- runs build-llvm.sh, a macOS-only script, with every tool it calls faked
# usage: sh tests/build-llvm-mode-test.sh
#   build-llvm.sh must take llvm-project as GitHub's tarball of LLVM_SHA through shipyard's
#   fetch_pinned_source.sh, verified by LLVM_TARBALL_SHA256, check the release pin with curl, apply
#   patches/llvm with patch, and never run git; configure LLVM in both modes with LibEdit, zlib, zstd,
#   terminfo and LibXml2 off by name, git never looked for, and the version stamp forced to LLVM_SHA and its
#   repository; in cross mode (CI) with Apple's clang and the host's otool, in native mode (OS X 10.9) with
#   mavericks-clang-22's clang, the 10.9 SDK, and its llvm-libtool-darwin, llvm-ar, llvm-ranlib and
#   llvm-otool, never a Command Line Tools stub, and natively with CMake's and LLVM's Apple probes answered
#   (lib.sh's apple_probe_answers) and clang22's lld as the linker clang's configure reads, so no configure
#   asks xcrun or runs a Command Line Tools ld (cross mode keeps Apple's tools: D7). A warm llvm-build is kept
#   while its options and llvm-project's commit are the same, and removed and configured afresh, never in
#   place, when either differs. A tarball pin that does not match fails before anything is
#   configured, naming the pin to refresh. Nothing is built: every tool is a fake that records its arguments.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-llvm-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"

R="$T/repo"; mkdir -p "$R/patches"
cp "$REPO/build-llvm.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
cp -R "$REPO/patches/llvm" "$R/patches/"
mkdir -p "$T/bin" "$T/shipyard" "$T/clang22n/bin"
# shipyard: the tarball fetcher lays out the five files patches/llvm touch, and stamps the tree.
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
echo "fetch_pinned_source \$*" >> "$T/log"
[ "\$3" = "\${FAKE_GOOD_SHA256:-$LLVM_TARBALL_SHA256}" ] || exit 1
rm -rf "\$4"; mkdir -p "\$4/llvm/lib/CAS" "\$4/llvm/cmake/modules" "\$4/lld/MachO" "\$4/compiler-rt/cmake/Modules"
: > "\$4/llvm/lib/CAS/OnDiskCommon.cpp"; : > "\$4/llvm/cmake/modules/AddLLVM.cmake"
: > "\$4/lld/MachO/InputFiles.cpp"; : > "\$4/compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake"
: > "\$4/compiler-rt/cmake/base-config-ix.cmake"
echo "\${FAKE_LLVM_SOURCE:-\$1 \$2 \$3}" > "\$4/.mavergreen-source"   # FAKE_LLVM_SOURCE: another commit's tarball
F
printf '#!/bin/sh\necho "fetch_sdk $*" >> "%s/log"\necho "%s/sdk/MacOSX10.9.sdk"\n' "$T" "$T" > "$T/shipyard/fetch_sdk.sh"
# The release pin's ref advertisement: llvm-project's tag at LLVM_SHA.
cat > "$T/bin/curl" <<F
#!/bin/sh
o=""; u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2 ;; -*) shift ;; *) u="\$1"; shift ;; esac; done
echo "curl \$u" >> "$T/log"
{ printf '001e# service=git-upload-pack\\n0000'; printf '003d%s refs/tags/%s\\n0000' "$LLVM_SHA" "$LLVM_TAG"; } > "\$o"
F
# patch: a dry run applies; a real one writes the marker build-llvm.sh greps for that patch.
cat > "$T/bin/patch" <<'F'
#!/bin/sh
p=""; dry=0
for a in "$@"; do case "$a" in --dry-run) dry=1 ;; esac; done
while [ $# -gt 0 ]; do case "$1" in -i) p="$2"; shift 2 ;; *) shift ;; esac; done
echo "patch $(basename "$p") dry=$dry" >> "$FAKE_LOG"
[ "$dry" = 1 ] && exit 0
case "$(basename "$p")" in
  0001-*) echo 'absent before macOS 10.10' >> llvm/lib/CAS/OnDiskCommon.cpp ;;
  0002-*) echo 'LLVM_LINKER_IS_LLD AND NOT APPLE' >> llvm/cmake/modules/AddLLVM.cmake ;;
  0003-*) echo "swiftlang's fork refuses every Apple-platform input" >> lld/MachO/InputFiles.cpp ;;
  0004-*) echo 'Mavergreen: extra flags for the Darwin builtins' >> compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake ;;
  0005-*) echo 'Mavergreen: a configure that names the macOS SDK' >> compiler-rt/cmake/base-config-ix.cmake ;;
esac
F
# shipyard-cmake: a configure records its arguments and leaves a cache; an install lays out what step 4 edits.
cat > "$T/bin/shipyard-cmake" <<F
#!/bin/sh
if [ "\$1" = --install ]; then
  o=""; while [ \$# -gt 0 ]; do case "\$1" in --prefix) o="\$2"; shift 2 ;; *) shift ;; esac; done
  mkdir -p "\$o/lib/cmake/llvm" "\$o/lib/cmake/clang"
  printf '%s\n' 'set(LLVM_CMAKE_DIR "\${LLVM_INSTALL_PREFIX}/lib/cmake/llvm")' 'set(LLVM_DEFAULT_EXTERNAL_LIT /x/lit)' > "\$o/lib/cmake/llvm/LLVMConfig.cmake"
  echo '# Loop over all imported files and verify that they actually exist' > "\$o/lib/cmake/llvm/LLVMExports.cmake"
  : > "\$o/lib/cmake/llvm/LLVMInstallSymlink.cmake"
  exit 0
fi
{ echo "shipyard-cmake"; for a in "\$@"; do echo "  \$a"; done; echo "  env CC_FOR_BUILD=\${CC_FOR_BUILD:-}"; } >> "$T/log"
[ ! -e llvm-build/CMakeCache.txt ] || echo "configured over a CMakeCache.txt" >> "$T/log"
[ ! -e llvm-build/CMakeFiles ] || echo "configured over a CMakeFiles" >> "$T/log"
mkdir -p llvm-build; printf 'CMAKE_COMMAND:INTERNAL=%s\n' "$T/bin/shipyard-cmake" > llvm-build/CMakeCache.txt; : > llvm-build/build.ninja
F
cat > "$T/bin/ninja" <<'F'
#!/bin/sh
echo "ninja $*" >> "$FAKE_LOG"
mkdir -p llvm-build/bin
for b in ld64.lld lld llvm-tblgen clang-tblgen llvm-config llvm-min-tblgen; do printf '#!/bin/sh\n' > "llvm-build/bin/$b"; chmod +x "llvm-build/bin/$b"; done
F
# Readers of lld's libraries: the host's otool (cross) and clang22's llvm-otool (native).
for o in "$T/bin/otool" "$T/clang22n/bin/llvm-otool"; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/log"\nprintf "%%s:\\n\\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\\n" "$2"\n' "$o" "$T" > "$o"
done
printf '#!/bin/sh\necho "git $*" >> "%s/log"\nexit 1\n' "$T" > "$T/bin/git"
for t in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm llvm-strings; do printf '#!/bin/sh\n' > "$T/clang22n/bin/$t"; done
chmod +x "$T/bin/"* "$T/shipyard/"* "$T/clang22n/bin/"*
run() {  # run <log-name> <mode> -- a fresh build root (KEEP_ROOT=1: the last run's) and log each time
  _n="$1"; [ "${KEEP_ROOT:-0}" = 1 ] || rm -rf "$T/root"; rm -f "$T/log"; : > "$T/log"; _rc=0
  PATH="$T/bin:$PATH" CC_FOR_BUILD="" FAKE_LOG="$T/log" SHIPYARD_SCRIPTS="$T/shipyard" MAVERICKS_BUILD_ROOT="$T/root" MAVERICKS_MODE="$2" \
    CLANG22_PREFIX="$T/clang22n" sh "$R/build-llvm.sh" > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
has() { grep -qxF -- "$2" "$T/$1.log" || fail "$1: never ran [$2]: $(cat "$T/$1.out")"; }
lacks() { if grep -qF -- "$2" "$T/$1.log"; then fail "$1: ran [$2]"; fi; }
both() {
  has "$1" "curl $LLVM_REPO_URL/info/refs?service=git-upload-pack"
  has "$1" "fetch_pinned_source $LLVM_REPO_URL $LLVM_SHA $LLVM_TARBALL_SHA256 llvm-project"
  for p in "$REPO"/patches/llvm/*.patch; do has "$1" "patch $(basename "$p") dry=0"; done
  for f in -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
           "-DLLVM_FORCE_VC_REVISION=$LLVM_SHA" "-DLLVM_FORCE_VC_REPOSITORY=$LLVM_REPO_URL" -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON; do
    has "$1" "  $f"
  done
  if grep -q "^git " "$T/$1.log"; then fail "$1 ran git: $(grep "^git " "$T/$1.log")"; fi
  grep -q '^OK: relocatable LLVM build-support tree' "$T/$1.out" || fail "$1 did not finish OK: $(cat "$T/$1.out")"
}
. "$REPO/lib.sh"   # -> LLVM_REPO_URL

echo "-- cross (CI): the tarball, patch, curl, no git; Apple's clang, the host's otool, no clang22 tools"
run cross cross || fail "the cross build failed: $(cat "$T/cross.out")"
both cross
has cross "  -DCMAKE_C_COMPILER=/usr/bin/clang"
has cross "<T>/bin/otool -L llvm-build/bin/lld"
has cross "  env CC_FOR_BUILD="
lacks cross "CMAKE_LIBTOOL"
lacks cross "CMAKE_TAPI"
lacks cross "fetch_sdk"
lacks cross "clang22n"

echo "-- native (OS X 10.9): clang22's clang, archivers and llvm-otool, the 10.9 SDK; no Command Line Tools stub"
run native native || fail "the native build failed: $(cat "$T/native.out")"
both native
has native "  -DCMAKE_C_COMPILER=<T>/clang22n/bin/clang"
has native "  -DCMAKE_CXX_COMPILER=<T>/clang22n/bin/clang++"
has native "  -DCMAKE_OSX_SYSROOT=<T>/sdk/MacOSX10.9.sdk"
has native "  -DCMAKE_LIBTOOL=<T>/clang22n/bin/llvm-libtool-darwin"
has native "  -DCMAKE_AR=<T>/clang22n/bin/llvm-ar"
has native "  -DCMAKE_RANLIB=<T>/clang22n/bin/llvm-ranlib"
has native "<T>/clang22n/bin/llvm-otool -L llvm-build/bin/lld"
# LLVM's config.guess, on a configure over a cache, asks CC_FOR_BUILD and never a Command Line Tools cc.
has native "  env CC_FOR_BUILD=<T>/clang22n/bin/clang"
! grep -qxF "  env CC_FOR_BUILD=" "$T/native.log" || fail "native: a configure without CC_FOR_BUILD"
for a in -DCMAKE_TAPI=/usr/bin/false -DCMAKE_STRIP=\<T\>/clang22n/bin/llvm-strip -DLD64_EXECUTABLE=/usr/bin/false \
         -DCMAKE_LINKER=\<T\>/clang22n/bin/ld64.lld -DHOST_LINK_VERSION=241.9; do has native "  $a"; done
lacks native "<T>/bin/otool"

echo "-- a warm llvm-build: kept with the same configure and source; one configured with other options (a root"
echo "   from before T5a, the Command Line Tools' ld its CMAKE_LINKER) or from another commit is built afresh"
LB="$T/root/swift/work/llvm-build"
: > "$LB/kept.o"
KEEP_ROOT=1 run same native || fail "the warm native build failed: $(cat "$T/same.out")"
[ -f "$LB/kept.o" ] || fail "same: the same configure removed llvm-build: $(cat "$T/same.out")"
lacks same "shipyard-cmake"
# CMake's record of what its first configure found, which shadows a later -DCMAKE_LINKER.
mkdir -p "$LB/CMakeFiles/4.4.0"; echo 'set(CMAKE_LINKER "/usr/bin/ld")' > "$LB/CMakeFiles/4.4.0/CMakeCCompiler.cmake"
sed 's|ld64.lld$|ld|' "$LB/mavergreen-inputs.stamp" > "$T/old-stamp"; mv "$T/old-stamp" "$LB/mavergreen-inputs.stamp"
KEEP_ROOT=1 run pre native || fail "the native build over an old llvm-build failed: $(cat "$T/pre.out")"
both pre
has pre "  -DCMAKE_LINKER=<T>/clang22n/bin/ld64.lld"
lacks pre "configured over"
[ ! -e "$LB/kept.o" ] && [ ! -e "$LB/CMakeFiles/4.4.0" ] || fail "pre: llvm-build was configured again in place: $(ls -R "$LB")"
grep -q "removing llvm-build: what its stamp records" "$T/pre.out" || fail "pre: removed llvm-build without saying so: $(cat "$T/pre.out")"
# A root whose llvm-build was configured by a build-llvm.sh that wrote no stamp.
: > "$LB/kept.o"; rm -f "$LB/mavergreen-inputs.stamp"
KEEP_ROOT=1 run nostamp native || fail "the native build over an unstamped llvm-build failed: $(cat "$T/nostamp.out")"
[ ! -e "$LB/kept.o" ] || fail "nostamp: kept an llvm-build that records no stamp"
lacks nostamp "configured over"
grep -qxF "source llvm-project $LLVM_REPO_URL $LLVM_SHA $LLVM_TARBALL_SHA256" "$LB/mavergreen-inputs.stamp" \
  || fail "llvm-build's stamp does not record the llvm-project source: $(cat "$LB/mavergreen-inputs.stamp")"
# The same options, another commit's tarball (its files all older than the objects): started afresh.
: > "$LB/kept.o"
(export FAKE_LLVM_SOURCE="$LLVM_REPO_URL 1111111111111111111111111111111111111111 $LLVM_TARBALL_SHA256"
 KEEP_ROOT=1 run moved native) || fail "the native build over another commit's llvm-build failed: $(cat "$T/moved.out")"
[ ! -e "$LB/kept.o" ] || fail "moved: kept an llvm-build built from another commit's source"
lacks moved "configured over"

echo "-- a tarball pin that does not match: refused before anything is configured, naming the pin"
if (FAKE_GOOD_SHA256=another run stale cross); then fail "built with a stale LLVM_TARBALL_SHA256"; fi
grep -q 'pin-source-tarballs.sh and commit pins.env.s LLVM_TARBALL_SHA256' "$T/stale.out" || fail "stale: $(cat "$T/stale.out")"
lacks stale "shipyard-cmake"
lacks stale "patch "
echo "PASS"
