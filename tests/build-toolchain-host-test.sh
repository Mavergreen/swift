#!/bin/sh
# platform: macOS-only -- runs build-toolchain.sh with every tool it calls faked, uname too for its Linux host
# usage: sh tests/build-toolchain-host-test.sh
#   build-toolchain.sh must build each toolchain from its own dirs and checkout, with its own patches and
#   configure, and without building anything: every tool it runs is a fake that records its arguments.
#   The x86_64 toolchain (the default) is the same configuration in both modes -- clang22 with its
#   llvm-libtool-darwin, llvm-ar, llvm-ranlib and lld, the 10.9 SDK's stubs, the prefix maps, clang's
#   default linker and host linker version, the Swift half compiled by SWIFT_HOST_TOOLCHAIN against the
#   11.3 SDK with its module cache in the build root and libswiftDarwin's own link dir, compiler patches
#   0001 and 0002 -- plus,
#   modern (CI), the cross-compiling settings, build-llvm.sh's TableGen and the native helpers, and a
#   refusal when no host toolchain is named; mavericks (OS X 10.9), none of those, the installed toolchain by
#   default, and the check read with otool. A changed host toolchain configures the Swift build afresh,
#   and the same one does not. Each build dir is started afresh when a source tree it compiles is another
#   commit's (lib.sh's source_stamp), and kept when the sources are the same. The arm64 toolchain (modern mode only) applies 0001 alone to its own
#   checkout, configures for an arm64 / macOS 11.0 host against the 11.3 SDK with no native helpers and no
#   -runtime-compatibility-version, pins the same clang defaults, and its check refuses a frontend that
#   does not run on the OS's /usr/lib/swift. A missing host swiftc, either host's, is refused before
#   anything is configured, as is, on every host, an llvm-project without llvm patch 0007's stable sort of a
#   coroutine frame's allocas. Any other host is refused before anything runs. Both hosts take cmark and the
#   compiler's swift as GitHub's tarballs of their pinned commits through shipyard's fetch_pinned_source.sh,
#   check cmark's release pin with curl, patch with patch, and never run git; force LLVM's version stamp to
#   LLVM_SHA and its repository, turn Swift's off, and look for no git, LibEdit, LibXml2 or pkg-config.
#   Natively nothing runs xcrun, the x86_64 configures answer CMake's and LLVM's Apple probes in both modes
#   (lib.sh's apple_probe_answers; the arm64 host's Apple clang asks Xcode, D7), and the x86_64 checks read
#   with clang22's llvm-otool, llvm-lipo, llvm-nm and llvm-strings in both modes. "The installed toolchain" is
#   SWIFT_INSTALLED_TOOLCHAIN, here always a prefix under this test's own dir, so whether this machine has
#   /usr/local/mavergreen/swift-toolchain (OS X 10.9 does, as does a Mac with the pkg) changes nothing.
#   The linux host (a faked Linux uname) builds with the swift.org Linux seed that fetch-linux-seed.sh prints:
#   its clang and clang++ compile, its swiftc compiles the Swift half (HOSTTOOLS), the cmake on PATH
#   configures, build-llvm.sh's TableGen, compiler patches 0001, 0003, 0004, 0005 and 0006 in its own checkout,
#   no Dispatch, pkg-config looked for (uuid-dev is required first), lld with --gc-sections, the seed clang's
#   ld.lld pointed at the lld built in step 1 (and refused if the seed's clang cannot then link with it); it stages the
#   prefix build.sh takes as SWIFT_HOST_TOOLCHAIN, with the seed's libswiftCore.so and its own dsymutil, and refuses a clang whose
#   default triple (read without its cfgs), or a swift-frontend whose default target, is not
#   x86_64-apple-macosx10.9; its OK line says when it has no builtins; --stop-after llvm builds LLVM, clang, lld and
#   dsymutil and stops, saying so, and any other --stop-after is refused before anything runs. --host linux on Darwin, and any other host on Linux, is
#   refused before anything runs.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-toolchain-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"
. "$REPO/lib.sh"   # -> LLVM_REPO_URL, SWIFT_REPO_URL, CMARK_REPO_URL

# A copy of the script under test, with its own sources, beside fakes for what it runs.
R="$T/repo"; mkdir -p "$R/scripts" "$R/patches"
cp "$REPO/build-toolchain.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
cp -R "$REPO/patches/compiler" "$R/patches/"
mkdir -p "$R/toolchain"; cp "$REPO/toolchain/clang.cfg" "$R/toolchain/"
# The Linux seed: fetch-linux-seed.sh prints its usr, a toolchain whose clang, swiftc and libswiftCore.so the build takes.
# Each fetch extracts it afresh, so its ld.lld is again its own lld: one built for Ubuntu 24.04's libxml2.so.2
# and ICU 74, which cannot start on a newer Linux. Its clang runs the ld.lld beside it, as the real one does.
printf '#!/bin/sh\necho "fetch-linux-seed $*" >> "%s/log"\nln -sf lld "%s/seed/usr/bin/ld.lld"\necho "%s/seed/usr"\n' "$T" "$T" "$T" > "$R/fetch-linux-seed.sh"
mkdir -p "$T/seed/usr/bin" "$T/seed/usr/lib/swift/linux"
for t in clang++ swiftc; do printf '#!/bin/sh\n' > "$T/seed/usr/bin/$t"; done
cat > "$T/seed/usr/bin/clang" <<F
#!/bin/sh
echo "seed-clang \$*" >> "$T/log"
[ "\$*" = "-fuse-ld=lld -Wl,--version -o /dev/null" ] || exit 0
exec "\${0%/*}/ld.lld" --version
F
printf '#!/bin/sh\necho "ld.lld: error while loading shared libraries: libxml2.so.2: cannot open shared object file" >&2\nexit 127\n' > "$T/seed/usr/bin/lld"
printf '#!/bin/sh\necho "Swift version 6.4.2 (swift.org seed)"\n' > "$T/seed/usr/bin/swift-frontend"
chmod +x "$T/seed/usr/bin/"*; echo seedcore > "$T/seed/usr/lib/swift/linux/libswiftCore.so"
printf '#!/bin/sh\necho "%s/clang22"\n' "$T" > "$R/fetch-clang22.sh"
printf '#!/bin/sh\necho "guard ALLOW=${MAVERICKS_ALLOW_ARCHS:-} LIPO=${LIPO:-} OTOOL=${OTOOL:-} NM=${NM:-} STRINGS=${STRINGS:-} $*" >> "%s/log"\n' "$T" > "$R/scripts/guard.sh"
REAL_SHIPYARD="$(. "$REPO/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || { echo "no shipyard -- skipping"; exit 77; }
mkdir -p "$T/bin" "$T/shipyard"
for P in "$T/clang22" "$T/clang22n"; do
  mkdir -p "$P/bin"
  for t in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm llvm-strings; do printf '#!/bin/sh\n' > "$P/bin/$t"; done
  chmod +x "$P/bin/"*
done
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
echo "fetch_pinned_source \$*" >> "$T/log"
rm -rf "\$4"; mkdir -p "\$4/lib/Driver" "\$4/cmake/modules" "\$4/include/swift/AST" "\$4/lib/AST" "\$4/lib/Serialization" "\$4/lib/IRGen" "\$4/lib/Sema"; : > "\$4/lib/Driver/Driver.cpp"; : > "\$4/cmake/modules/AddSwift.cmake"
# FAKE_SWIFT_SOURCE and FAKE_CMARK_SOURCE stand for another commit's tarball of the compiler's source, or cmark's.
l="\$1 \$2 \$3"; case "\$4" in swift-compiler*) l="\${FAKE_SWIFT_SOURCE:-\$l}" ;; cmark) l="\${FAKE_CMARK_SOURCE:-\$l}" ;; esac
echo "\$l" > "\$4/.mavergreen-source"
F
cat > "$T/shipyard/fetch_sdk.sh" <<F
#!/bin/sh
case "\$*" in '--arch arm64') echo "$T/sdk/MacOSX11.3.sdk" ;; '') echo "$T/sdk/MacOSX10.9.sdk" ;; *) exit 9 ;; esac
F
# sdk109_stubs sources these two; the stub-form SDK is already in the cache, so nothing is fetched.
cp "$REAL_SHIPYARD/mavericks_fetch.sh" "$T/shipyard/"   # shipyard_curl, for check_release_pin
printf 'shipyard_fetch_pinned() { echo "fetched $*" >> "%s/log"; return 1; }\n' "$T" >> "$T/shipyard/mavericks_fetch.sh"
printf 'shipyard_sdk_pin() { echo "https://example.invalid/x.tar.xz 0 MacOSX10.9.sdk.tar.xz MacOSX10.9.sdk"; }\n' > "$T/shipyard/sdk-pins.sh"
mkdir -p "$T/sdkcache/stubs/MacOSX10.9.sdk/usr/lib"
printf '#!/bin/sh\necho "git $*" >> "%s/log"\nexit 1\n' "$T" > "$T/bin/git"
cat > "$T/bin/curl" <<F
#!/bin/sh
o=""; u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2 ;; -*) shift ;; *) u="\$1"; shift ;; esac; done
echo "curl \$u" >> "$T/log"
{ printf '001e# service=git-upload-pack\\n0000'; printf '003d%s refs/tags/%s\\n0000' "$CMARK_SHA" "$CMARK_TAG"; } > "\$o"
F
# patch: a dry run applies; a real one, in the tree it runs in, writes the marker build-toolchain.sh greps.
cat > "$T/bin/patch" <<F
#!/bin/sh
p=""; dry=0
for a in "\$@"; do case "\$a" in --dry-run) dry=1 ;; esac; done
while [ \$# -gt 0 ]; do case "\$1" in -i) p="\$2"; shift 2 ;; *) shift ;; esac; done
[ "\$dry" = 1 ] && exit 0
echo "patch \$(basename "\$PWD") \$p" >> "$T/log"
case "\${p##*/}" in
  0001-*) echo 'any macOS SDK back to 10.9 is accepted' >> lib/Driver/Driver.cpp ;;
  0002-*) echo "host tools run on the toolchain's own bundled runtime" >> cmake/modules/AddSwift.cmake ;;
  0003-*) for f in lib/AST/Availability.cpp include/swift/AST/ASTContext.h lib/Serialization/Deserialization.cpp; do echo "Mavergreen: the 10.9 runtime is the pkgs'" >> \$f; done ;;
  0004-*) echo 'Mavergreen: the length of the string passed, which is empty when optimizing' >> lib/IRGen/GenHeap.cpp ;;
  0005-*) for f in lib/AST/Decl.cpp lib/Sema/TypeCheckExpr.cpp lib/Sema/TypeCheckDeclPrimary.cpp; do echo "Mavergreen: #isolation is the caller's" >> \$f; done ;;
  0006-*) mkdir -p stdlib/public/Cxx/libstdcxx; echo '# Mavergreen: no swift-stdlib target exists when SWIFT_BUILD_STDLIB is off' >> stdlib/public/Cxx/libstdcxx/CMakeLists.txt ;;
esac
F
# shipyard-cmake records its arguments and, like a configure, leaves a CMakeCache.txt in its -B dir.
cat > "$T/bin/shipyard-cmake" <<F
#!/bin/sh
{ echo "shipyard-cmake"; for a in "\$@"; do echo "  \$a"; done; echo "  env CC_FOR_BUILD=\${CC_FOR_BUILD:-}"; } >> "$T/log"
b=""; for a in "\$@"; do if [ "\$b" = next ]; then mkdir -p "\$a" && : > "\$a/CMakeCache.txt"; b=""; elif [ "\$a" = -B ]; then b=next; fi; done
F
# On Linux the cmake on PATH configures; it records itself as cmake.
sed 's/echo "shipyard-cmake"/echo "cmake"/' "$T/bin/shipyard-cmake" > "$T/bin/cmake"
# uname is the host's unless FAKE_UNAME names another kernel for -s.
printf '#!/bin/sh\nif [ -n "${FAKE_UNAME:-}" ] && [ "$1" = -s ]; then echo "$FAKE_UNAME"; else exec /usr/bin/uname "$@"; fi\n' > "$T/bin/uname"
# pkg-config finds uuid (uuid-dev) unless FAKE_NO_UUID.
printf '#!/bin/sh\necho "pkg-config $*" >> "%s/log"\n[ -z "${FAKE_NO_UUID:-}" ]\n' "$T" > "$T/bin/pkg-config"
# ninja records its arguments and, in a Linux build dir, leaves what that build makes (from $T/tpl).
mkdir -p "$T/tpl"
# clang: its own default target without its cfgs (FAKE_TRIPLE), and, read through them, the cfgs'
# -mmacosx-version-min's, which masks a bad default.
cat > "$T/tpl/clang" <<'F'
#!/bin/sh
case "$*" in
  '--no-default-config -print-target-triple') echo "${FAKE_TRIPLE:-x86_64-apple-macosx10.9}" ;;
  -print-target-triple) echo x86_64-apple-macosx10.9 ;;
  *) exit 9 ;;
esac
F
cat > "$T/tpl/lld" <<'F'
#!/bin/sh
[ -z "${FAKE_LLD_BROKEN:-}" ] || { echo "lld: cannot start" >&2; exit 127; }
case "${0##*/}:$*" in ld.lld:--version) echo "LLD 21.1.6 (compatible with GNU linkers)" ;; *) exit 9 ;; esac
F
cat > "$T/tpl/swift-frontend" <<'F'
#!/bin/sh
echo "Swift version 6.4.2 (linux frontend)"; echo "Target: ${FAKE_FE_TARGET:-x86_64-apple-macosx10.9}"
F
chmod +x "$T/tpl/"*
cat > "$T/bin/ninja" <<F
#!/bin/sh
{ echo "ninja"; for a in "\$@"; do echo "  \$a"; done; } >> "$T/log"
case "\$2" in
  */llvm-linux) mkdir -p "\$2/bin" "\$2/lib/clang/21/include"; echo hdr > "\$2/lib/clang/21/include/stddef.h"
                cp "$T/tpl/clang" "\$2/bin/clang"; cp "$T/tpl/lld" "\$2/bin/lld"; echo dsymutil > "\$2/bin/dsymutil" ;;
  */swift-linux) mkdir -p "\$2/bin" "\$2/lib/swift/migrator" "\$2/lib/swift/linux"; echo mig > "\$2/lib/swift/migrator/macos4.json"
                 cp "$T/tpl/swift-frontend" "\$2/bin/swift-frontend" ;;
esac
F
printf '#!/bin/sh\necho "python3 $*" >> "%s/log"\nexit "${FAKE_AUDIT_RC:-0}"\n' "$T" > "$T/bin/python3"
cat > "$T/bin/xcrun" <<F
#!/bin/sh
echo "xcrun \$*" >> "$T/xcrun.log"
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
# OS X 10.9 has no dyld_info: the native check reads clang22's llvm-otool's load commands (a header table
# first, then LC_BUILD_VERSION's sdk before its minos, as llvm-otool prints them); the host's otool must
# never run.
cat > "$T/llvm-otool" <<'F'
#!/bin/sh
[ "$1" = -l ] || exit 9
printf 'Mach header\n      magic cputype cpusubtype  caps    filetype ncmds sizeofcmds      flags\n'
printf '       cmd LC_BUILD_VERSION\n   cmdsize 32\n  platform 1\n       sdk 10.9\n     minos %s\n    ntools 1\n      tool 3\n   version 1267.0\n' "${FAKE_OTOOL_MIN:-10.9}"
printf '          cmd LC_RPATH\n      cmdsize 48\n         path @loader_path/../lib/swift/macosx (offset 12)\n'
F
printf '#!/bin/sh\necho "otool $*" >> "%s/log"\nexit 9\n' "$T" > "$T/bin/otool"
for P in "$T/clang22" "$T/clang22n"; do cp "$T/llvm-otool" "$P/bin/llvm-otool"; chmod +x "$P/bin/llvm-otool"; done
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
CORO="$W/llvm-project/llvm/lib/Transforms/Coroutines/CoroFrame.cpp"; mkdir -p "${CORO%/*}"
echo '  llvm::stable_sort(FrameData.Allocas, [&](const auto &Iter1, const auto &Iter2) {' > "$CORO"
LLVM_SOURCE="$LLVM_REPO_URL $LLVM_SHA $LLVM_TARBALL_SHA256"   # build-llvm.sh's extraction
echo "$LLVM_SOURCE" > "$W/llvm-project/.mavergreen-source"
run() {  # run <log-name> <mode> [build-toolchain.sh args] -- a fresh checkout state and log each time
  _n="$1"; _m="$2"; shift 2
  rm -rf "$W/swift-compiler" "$W/swift-compiler-arm64" "$W/swift-compiler-linux" "$W/cmark" "$T/log" "$T/xcrun.log"; : > "$T/log"
  _rc=0
  PATH="$T/bin:$PATH" CC_FOR_BUILD="" SHIPYARD_SCRIPTS="$T/shipyard" SWIFT_WORK="$W" JOBS=2 MAVERICKS_USE_CCACHE=0 MAVERICKS_MODE="$_m" \
    MAVERICKS_SDK_CACHE="$T/sdkcache" CLANG22_PREFIX="$T/clang22n" sh "$R/build-toolchain.sh" "$@" > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
has() { grep -qxF -- "$2" "$T/$1.log" || fail "$1: never ran [$2]: $(cat "$T/$1.out")"; }
lacks() { if grep -qF -- "$2" "$T/$1.log"; then fail "$1: ran [$2]"; fi; }
sources() {  # what both hosts' builds fetch, check and never run; $2 is that host's compiler checkout
  has "$1" "curl $CMARK_REPO_URL/info/refs?service=git-upload-pack"
  has "$1" "fetch_pinned_source $CMARK_REPO_URL $CMARK_SHA $CMARK_TARBALL_SHA256 cmark"
  has "$1" "fetch_pinned_source $SWIFT_REPO_URL $SWIFT_SHA $SWIFT_TARBALL_SHA256 $2"
  has "$1" "  -DLLVM_FORCE_VC_REVISION=$LLVM_SHA"
  has "$1" "  -DLLVM_FORCE_VC_REPOSITORY=$LLVM_REPO_URL"
  for f in -DSWIFT_APPEND_VC_REV=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON -DCMAKE_DISABLE_FIND_PACKAGE_LibEdit=ON \
           -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON; do has "$1" "  $f"; done
  if grep -q '^git ' "$T/$1.log"; then fail "$1 ran git: $(grep '^git ' "$T/$1.log" | head -1)"; fi
}
x86_both() {  # what the x86_64 toolchain's configure is in either mode; $2 is that mode's clang22
  sources "$1" swift-compiler
  has "$1" "patch swift-compiler <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
  has "$1" "patch swift-compiler <T>/repo/patches/compiler/0002-hosttools-rpath-loader-path.patch"
  has "$1" "patch swift-compiler <T>/repo/patches/compiler/0003-runtime-versions-macos-10.9.patch"
  has "$1" "patch swift-compiler <T>/repo/patches/compiler/0004-escaping-closure-check-filename-length.patch"
  has "$1" "patch swift-compiler <T>/repo/patches/compiler/0005-isolation-default-arg-caller-side.patch"
  has "$1" "  -DSWIFT_LIPO=<T>/$2/bin/llvm-lipo"
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
  has "$1" "  -DCMAKE_TAPI=/usr/bin/false"
  has "$1" "  -DCMAKE_STRIP=<T>/$2/bin/llvm-strip"
  has "$1" "  -DLD64_EXECUTABLE=/usr/bin/false"
  has "$1" "  -DCMAKE_Swift_COMPILER=<T>/host/bin/swiftc"
  has "$1" "  -DCMAKE_EXE_LINKER_FLAGS=-L<T>/w/swiftdarwin-x86"
  has "$1" "  -DSWIFT_COMPILER_SOURCES_SDK_FLAGS=-sdk;<T>/sdk/MacOSX11.3.sdk;-Xcc;-D_LIBCPP_DISABLE_AVAILABILITY;-Xfrontend;-disable-availability-checking;-runtime-compatibility-version;none;-module-cache-path;<T>/w/swift-x86-modcache"
  has "$1" "guard ALLOW= LIPO=<T>/$2/bin/llvm-lipo OTOOL=<T>/$2/bin/llvm-otool NM=<T>/$2/bin/llvm-nm STRINGS=<T>/$2/bin/llvm-strings <T>/w/swift-x86/bin/swift-frontend <T>/w/llvm-x86/bin/lld <T>/w/llvm-x86/bin/clang <T>/w/llvm-x86/bin/dsymutil"
  lacks "$1" "otool -l"
  lacks "$1" "<T>/sdk/MacOSX10.9.sdk"
  lacks "$1" "toolchain/usr/bin/swiftc"
  lacks "$1" "xcrun"
  lacks "$1" "fetched"
  lacks "$1" "arm64"
  [ "$(readlink "$W/swiftdarwin-x86/libswiftDarwin.tbd")" = "$T/sdk/MacOSX11.3.sdk/usr/lib/swift/libswiftDarwin.tbd" ] \
    || fail "$1: swiftdarwin-x86 does not hold the 11.3 SDK's libswiftDarwin.tbd alone"
  [ "$(ls "$W/swiftdarwin-x86")" = libswiftDarwin.tbd ] || fail "$1: swiftdarwin-x86 holds more than libswiftDarwin.tbd"
  grep -qx '    host: Swift version 6.4 (host)' "$T/$1.out" || fail "$1: did not print the host's version: $(cat "$T/$1.out")"
  grep -qx 'OK: swift-frontend, lld, clang and dsymutil for x86_64 / 10.9' "$T/$1.out" || fail "$1 did not finish OK: $(cat "$T/$1.out")"
}

echo "-- x86_64, cross (CI): clang22-cross, build-llvm.sh's TableGen, the native helpers, the named host toolchain"
SWIFT_HOST_TOOLCHAIN="$H"; export SWIFT_HOST_TOOLCHAIN
run x86 modern || fail "the modern-mode x86_64 build failed: $(cat "$T/x86.out")"
x86_both x86 clang22
has x86 "  -DCMAKE_CROSSCOMPILING=ON"
has x86 "  -DLLVM_TABLEGEN=<T>/w/llvm-build/bin/llvm-tblgen"
has x86 "  -DSWIFT_NATIVE_CLANG_TOOLS_PATH=<T>/host/bin"
has x86 "  -DSWIFT_SOURCE_DIR=<T>/w/swift-compiler"
has x86 "  env CC_FOR_BUILD="
lacks x86 "clang22n"
cmp -s "$W/swift-x86/mavergreen-host.stamp" - <<EOF || fail "the host stamp is not host_swiftc_stamp's: $(cat "$W/swift-x86/mavergreen-host.stamp")"
$(. "$REPO/lib.sh" && host_swiftc_stamp "$H")
EOF

echo "-- x86_64, modern, the same host again: the Swift build is kept; a changed one is configured afresh"
run again modern || fail "the second run failed: $(cat "$T/again.out")"
if grep -q 'configuring it afresh' "$T/again.out"; then fail "the same host reconfigured the Swift build"; fi
echo module2 > "$H/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
run changed modern || fail "the run with a changed host failed: $(cat "$T/changed.out")"
grep -q "$W/swift-x86: its host swiftc changed" "$T/changed.out" || fail "a changed host kept the Swift build: $(cat "$T/changed.out")"

echo "-- x86_64, modern: each build dir records the sources it compiles; the same ones keep it, another commit's"
echo "   (whose tarball's files are all older than the objects) starts afresh each dir that compiles it, and only those"
DIRS="llvm-x86 cmark-x86 swift-x86 native-helpers"
mark() { for d in $DIRS; do : > "$W/$d/kept.o"; done; }
kept() {  # kept <log-name> <dir>... -- those dirs kept, the others of DIRS started afresh
  _kn="$1"; shift
  for d in $DIRS; do
    case " $* " in
      *" $d "*) [ -f "$W/$d/kept.o" ] || fail "$_kn: removed $d: $(cat "$T/$_kn.out")" ;;
      *) [ ! -e "$W/$d/kept.o" ] || fail "$_kn: kept $d, which compiles the moved source: $(cat "$T/$_kn.out")"
         grep -q "removing $W/$d: " "$T/$_kn.out" || fail "$_kn: removed $d without saying so" ;;
    esac
  done
}
mark
run same modern || fail "the run with the same sources failed: $(cat "$T/same.out")"
kept same $DIRS
L_LINE="source llvm-project $LLVM_SOURCE"
C_LINE="source cmark $CMARK_REPO_URL $CMARK_SHA $CMARK_TARBALL_SHA256"
S_LINE="source swift-compiler $SWIFT_REPO_URL $SWIFT_SHA $SWIFT_TARBALL_SHA256"
[ "$(cat "$W/llvm-x86/mavergreen-inputs.stamp")" = "$L_LINE" ] || fail "llvm-x86's stamp: $(cat "$W/llvm-x86/mavergreen-inputs.stamp")"
[ "$(cat "$W/cmark-x86/mavergreen-inputs.stamp")" = "$C_LINE" ] || fail "cmark-x86's stamp: $(cat "$W/cmark-x86/mavergreen-inputs.stamp")"
# The compiler's source line is followed by each compiler patch the x86_64 build applied to it, in order.
for p in "$REPO"/patches/compiler/*.patch; do
  case "${p##*/}" in 0006-*) continue ;; esac   # the linux host's alone
  S_LINE="$S_LINE
patch swift-compiler ${p##*/} $(shasum -a 256 < "$p" | awk '{ print $1 }')"
done
[ "$(cat "$W/swift-x86/mavergreen-inputs.stamp")" = "$S_LINE
$L_LINE
$C_LINE" ] || fail "swift-x86's stamp: $(cat "$W/swift-x86/mavergreen-inputs.stamp")"
[ "$(cat "$W/native-helpers/mavergreen-inputs.stamp")" = "$S_LINE
$L_LINE" ] || fail "native-helpers' stamp: $(cat "$W/native-helpers/mavergreen-inputs.stamp")"
OLD_SWIFT="$SWIFT_REPO_URL 1111111111111111111111111111111111111111 $SWIFT_TARBALL_SHA256"
(export FAKE_SWIFT_SOURCE="$OLD_SWIFT"; run swiftmoved modern) || fail "the run with another swift commit failed: $(cat "$T/swiftmoved.out")"
kept swiftmoved llvm-x86 cmark-x86
mark
echo "$LLVM_REPO_URL 2222222222222222222222222222222222222222 $LLVM_TARBALL_SHA256" > "$W/llvm-project/.mavergreen-source"
(export FAKE_SWIFT_SOURCE="$OLD_SWIFT"; run llvmmoved modern) || fail "the run with another llvm-project commit failed: $(cat "$T/llvmmoved.out")"
kept llvmmoved cmark-x86
echo "$LLVM_SOURCE" > "$W/llvm-project/.mavergreen-source"
run back modern || fail "the run back at the pinned sources failed: $(cat "$T/back.out")"
mark
(export FAKE_CMARK_SOURCE="$CMARK_REPO_URL 3333333333333333333333333333333333333333 $CMARK_TARBALL_SHA256"; run cmarkmoved modern) \
  || fail "the run with another cmark commit failed: $(cat "$T/cmarkmoved.out")"
kept cmarkmoved llvm-x86 native-helpers
run back modern || fail "the run back at the pinned sources failed: $(cat "$T/back.out")"
mv "$W/llvm-project/.mavergreen-source" "$T/llvm-source.away"
if run nosource modern; then fail "built from an llvm-project no build-llvm.sh extracted"; fi
mv "$T/llvm-source.away" "$W/llvm-project/.mavergreen-source"
grep -q 'llvm-project is no source tree build-llvm.sh extracted -- run ./build-llvm.sh' "$T/nosource.out" || fail "nosource: $(cat "$T/nosource.out")"
lacks nosource "shipyard-cmake"

echo "-- an llvm-project without llvm patch 0007 (a coroutine frame's allocas in a stable order): every host refuses it"
cp "$CORO" "$T/coro.away"
echo '  sort(FrameData.Allocas, [&](const auto &Iter1, const auto &Iter2) {' > "$CORO"
for h in x86_64 arm64 linux; do
  u=Darwin; [ "$h" = linux ] && u=Linux
  if (export FAKE_UNAME=$u; run no0007 modern --host $h); then fail "$h: built from an llvm-project without patch 0007"; fi
  grep -q 'FAIL: llvm-project lacks patches/llvm -- run ./build-llvm.sh' "$T/no0007.out" || fail "no0007 ($h): $(cat "$T/no0007.out")"
  lacks no0007 "cmake"
done
mv "$T/coro.away" "$CORO"

echo "-- x86_64, modern, no host toolchain named: refused (CI never builds with an earlier release)"
unset SWIFT_HOST_TOOLCHAIN
if run nohost modern; then fail "built with no SWIFT_HOST_TOOLCHAIN in modern mode"; fi
grep -q 'name the toolchain that compiles the Swift half with SWIFT_HOST_TOOLCHAIN' "$T/nohost.out" || fail "nohost: $(cat "$T/nohost.out")"
lacks nohost "shipyard-cmake"
if grep -q '^==> 1\.' "$T/nohost.out"; then fail "nohost: step 1 ran before the missing host toolchain was refused"; fi

echo "-- x86_64, mavericks (OS X 10.9): clang22's native toolchain, its own TableGen and helpers, the check with otool"
(SWIFT_HOST_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 run native mavericks) || fail "the mavericks-mode build failed: $(cat "$T/native.out")"
x86_both native clang22n
has native "  -DLLVM_TABLEGEN=<T>/w/llvm-x86/bin/llvm-tblgen"
# LLVM's config.guess, on a configure over a cache (stages 2 and 3), asks CC_FOR_BUILD, never a CLT cc.
has native "  env CC_FOR_BUILD=<T>/clang22n/bin/clang"
! grep -qxF "  env CC_FOR_BUILD=" "$T/native.log" || fail "native: a configure without CC_FOR_BUILD"
lacks native "CMAKE_CROSSCOMPILING"
lacks native "llvm-build"
lacks native "native-helpers"
lacks native "SWIFT_NATIVE_"
lacks native "<T>/clang22/"
[ ! -f "$T/xcrun.log" ] || fail "mavericks ran xcrun: $(cat "$T/xcrun.log")"
if (SWIFT_HOST_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 FAKE_OTOOL_MIN=10.10 run native1010 mavericks); then fail "passed a binary otool reads as minOS 10.10"; fi
grep -q "records minOS/SDK '10.10 10.9'" "$T/native1010.out" || fail "native1010: $(cat "$T/native1010.out")"
if (FAKE_NO_DYLDINFO=1 run default mavericks); then fail "built with the installed toolchain, which is not there"; fi
grep -q "no $T/installed/bin/swiftc" "$T/default.out" || fail "mavericks mode's default host is not the installed toolchain: $(cat "$T/default.out")"
lacks default "shipyard-cmake"
(SWIFT_INSTALLED_TOOLCHAIN="$H" FAKE_NO_DYLDINFO=1 run inst mavericks) || fail "the mavericks-mode build with an installed toolchain failed: $(cat "$T/inst.out")"
has inst "  -DCMAKE_Swift_COMPILER=<T>/host/bin/swiftc"
grep -qF 'SWIFT_INSTALLED_TOOLCHAIN:-/usr/local/mavergreen/swift-toolchain}' "$R/build-toolchain.sh" \
  || fail "the installed toolchain is not /usr/local/mavergreen/swift-toolchain by default"
rc=0; run narm mavericks --host arm64 || rc=$?
[ "$rc" -eq 2 ] || fail "mavericks --host arm64: exit $rc, not 2"
[ ! -s "$T/narm.log" ] || fail "mavericks --host arm64 ran [$(head -1 "$T/narm.log")] before refusing"

echo "-- arm64: 0001 alone in its own checkout, Apple clang for arm64 / 11.0 on the 11.3 SDK, no native helpers"
export FAKE_ARCH=arm64 FAKE_PLATFORM='11.0      11.3' FAKE_RPATH=/usr/lib/swift
run arm64 modern --host arm64 || fail "the arm64 build failed: $(cat "$T/arm64.out")"
sources arm64 swift-compiler-arm64
has arm64 "patch swift-compiler-arm64 <T>/repo/patches/compiler/0001-accept-10.9-sdk.patch"
has arm64 "patch swift-compiler-arm64 <T>/repo/patches/compiler/0003-runtime-versions-macos-10.9.patch"
has arm64 "patch swift-compiler-arm64 <T>/repo/patches/compiler/0004-escaping-closure-check-filename-length.patch"
has arm64 "patch swift-compiler-arm64 <T>/repo/patches/compiler/0005-isolation-default-arg-caller-side.patch"
lacks arm64 "0002-hosttools-rpath-loader-path.patch"
lacks arm64 "patch swift-compiler "
lacks arm64 "SWIFT_LIPO"
lacks arm64 "CMAKE_TAPI"
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
has arm64 "guard ALLOW=arm64 LIPO= OTOOL= NM= STRINGS= <T>/w/swift-arm64/bin/swift-frontend <T>/w/llvm-arm64/bin/lld <T>/w/llvm-arm64/bin/clang <T>/w/llvm-arm64/bin/dsymutil"
has arm64 "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
grep -qx 'OK: swift-frontend, lld, clang and dsymutil for arm64 / macOS 11.0, targeting x86_64 / OS X 10.9' "$T/arm64.out" \
  || fail "arm64 did not finish OK: $(cat "$T/arm64.out")"

echo "-- arm64 with no host swiftc (build.sh's): refused before step 1"
mv "$W/toolchain/usr/bin/swiftc" "$W/toolchain/usr/bin/swiftc.away"
rc=0; run notc modern --host arm64 || rc=$?
mv "$W/toolchain/usr/bin/swiftc.away" "$W/toolchain/usr/bin/swiftc"
[ "$rc" -ne 0 ] || fail "built arm64 with no host swiftc"
grep -q 'FAIL: no host swiftc -- run ./build.sh' "$T/notc.out" || fail "notc: $(cat "$T/notc.out")"
if grep -q '^==> 1\.' "$T/notc.out"; then fail "notc: step 1 ran before the missing host swiftc was refused"; fi
lacks notc "shipyard-cmake"

echo "-- arm64's check refuses a frontend on the package's own stdlib, or one the audit fails"
# platform: POSIX leaves unspecified whether a VAR=val prefix on a function call outlives the call,
#           and macOS's /bin/sh (bash 3.2) keeps it; a subshell confines each override to its own case.
if (FAKE_RPATH=@loader_path/../lib/swift/macosx run rp modern --host arm64); then fail "passed a frontend with rpath @loader_path/../lib/swift/macosx"; fi
grep -q "^FAIL: swift-frontend's rpaths are \[@loader_path/../lib/swift/macosx\]" "$T/rp.out" || fail "rpath: $(cat "$T/rp.out")"
if (FAKE_CORE=@rpath/libswiftCore.dylib run core modern --host arm64); then fail "passed a frontend loading @rpath/libswiftCore.dylib"; fi
grep -q "^FAIL: swift-frontend does not load the OS's /usr/lib/swift/libswiftCore.dylib" "$T/core.out" || fail "core: $(cat "$T/core.out")"
if (FAKE_CORE='/usr/lib/swift/libswiftCore.dylib
@rpath/libswift_Concurrency.dylib' run rpathlib modern --host arm64); then fail "passed a frontend also loading @rpath/libswift_Concurrency.dylib"; fi
grep -q "^FAIL: swift-frontend loads a Swift library through @rpath" "$T/rpathlib.out" || fail "rpathlib: $(cat "$T/rpathlib.out")"
if (FAKE_AUDIT_RC=1 run audit modern --host arm64); then fail "passed a frontend the import audit failed"; fi
has audit "python3 <T>/repo/scripts/audit-imports.py <T>/w/swift-arm64/bin/swift-frontend <T>/sdk/MacOSX11.3.sdk"
if grep -q '^OK:' "$T/audit.out"; then fail "printed OK after the import audit failed: $(cat "$T/audit.out")"; fi
unset FAKE_ARCH FAKE_PLATFORM FAKE_RPATH

echo "-- linux (a Linux uname): the seed's clang, clang++ and swiftc, the cmake on PATH, 0006, no Dispatch, lld, the staged prefix"
mkdir -p "$W/builtins-x86/lib/darwin"; echo rt > "$W/builtins-x86/lib/darwin/libclang_rt.osx.a"
(export FAKE_UNAME=Linux; run linux modern --host linux) || fail "the linux build failed: $(cat "$T/linux.out")"
has linux "fetch-linux-seed <T>/w/linux-seed"
has linux "pkg-config --exists uuid"
has linux "curl $CMARK_REPO_URL/info/refs?service=git-upload-pack"
has linux "fetch_pinned_source $SWIFT_REPO_URL $SWIFT_SHA $SWIFT_TARBALL_SHA256 swift-compiler-linux"
for p in 0001-accept-10.9-sdk 0003-runtime-versions-macos-10.9 0004-escaping-closure-check-filename-length \
         0005-isolation-default-arg-caller-side 0006-linux-libstdcxx-no-stdlib-target; do
  has linux "patch swift-compiler-linux <T>/repo/patches/compiler/$p.patch"
done
lacks linux "0002-hosttools-rpath-loader-path.patch"
has linux "cmake"
lacks linux "shipyard-cmake"
for f in -DCMAKE_C_COMPILER=\<T\>/seed/usr/bin/clang -DCMAKE_CXX_COMPILER=\<T\>/seed/usr/bin/clang++ \
         -DCMAKE_Swift_COMPILER=\<T\>/seed/usr/bin/swiftc -DBOOTSTRAPPING_MODE=HOSTTOOLS \
         -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-macosx10.9 -DLLVM_TARGETS_TO_BUILD=X86 \
         -DLLVM_TABLEGEN=\<T\>/w/llvm-build/bin/llvm-tblgen -DCLANG_TABLEGEN=\<T\>/w/llvm-build/bin/clang-tblgen \
         -DCLANG_DEFAULT_LINKER=lld -DHOST_LINK_VERSION=241.9 \
         -DSWIFT_HOST_VARIANT_SDK=LINUX -DSWIFT_HOST_VARIANT_ARCH=x86_64 -DSWIFT_SDKS=LINUX \
         -DSWIFT_ENABLE_DISPATCH=OFF -DSWIFT_USE_LINKER=lld -DLLVM_USE_LINKER=lld -DCMAKE_EXE_LINKER_FLAGS=-Wl,--gc-sections \
         -DSWIFT_BUILD_STDLIB=OFF -DSWIFT_APPEND_VC_REV=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON \
         "-DLLVM_FORCE_VC_REVISION=$LLVM_SHA" \<T\>/w/llvm-linux \<T\>/w/cmark-linux \<T\>/w/swift-linux; do
  has linux "  $f"
done
lacks linux "CMAKE_DISABLE_FIND_PACKAGE_PkgConfig"
lacks linux "CMAKE_LINKER"   # an Apple host's reason (clang's `ld -v`); nothing on Linux reads it
lacks linux "CMAKE_OSX_"
lacks linux "MacOSX"
lacks linux "clang22"
lacks linux "native-helpers"
lacks linux "guard "
lacks linux "llvm-x86"
if grep -q '^git ' "$T/linux.log"; then fail "linux ran git"; fi
grep -qx '    host: Swift version 6.4.2 (swift.org seed)' "$T/linux.out" || fail "linux: did not print the seed's version: $(cat "$T/linux.out")"
[ "$(readlink "$T/seed/usr/bin/ld.lld")" = "$W/llvm-linux/bin/lld" ] \
  || fail "linux: the seed's ld.lld is [$(readlink "$T/seed/usr/bin/ld.lld")], not step 1's lld"
_ck="$(grep -nxF 'seed-clang -fuse-ld=lld -Wl,--version -o /dev/null' "$T/linux.log" | head -n 1 | cut -d: -f1)"
_sw="$(grep -nxF '  <T>/w/swift-linux' "$T/linux.log" | head -n 1 | cut -d: -f1)"
[ -n "$_ck" ] && [ -n "$_sw" ] && [ "$_ck" -lt "$_sw" ] \
  || fail "linux: the seed's clang did not link with lld before the Swift build was configured (lines ${_ck:-none}, ${_sw:-none})"
P="$W/toolchain-linux"
for f in bin/swift-frontend bin/clang bin/clang.cfg bin/clang++.cfg bin/ld64.lld bin/dsymutil lib/swift/migrator/macos4.json \
         lib/clang/21/include/stddef.h; do
  [ -f "$P/$f" ] && [ ! -L "$P/$f" ] || fail "linux: the prefix holds no file $f: $(cat "$T/linux.out")"
done
[ "$(readlink "$P/bin/swiftc")" = swift-frontend ] || fail "linux: bin/swiftc is not a link to swift-frontend"
[ "$(readlink "$P/bin/clang++")" = clang ] || fail "linux: bin/clang++ is not a link to clang"
[ "$(readlink "$P/lib/swift/clang")" = ../clang/21 ] || fail "linux: lib/swift/clang is not a link to ../clang/21"
cmp -s "$P/lib/swift/linux/libswiftCore.so" "$T/seed/usr/lib/swift/linux/libswiftCore.so" || fail "linux: no seed libswiftCore.so in lib/swift/linux"
cmp -s "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a" "$W/builtins-x86/lib/darwin/libclang_rt.osx.a" || fail "linux: no builtins in the prefix"
cmp -s "$P/bin/clang.cfg" "$REPO/toolchain/clang.cfg" && cmp -s "$P/bin/clang++.cfg" "$REPO/toolchain/clang.cfg" || fail "linux: the cfgs are not toolchain/clang.cfg"
grep -qx "OK: the Linux toolchain prefix at $P (build.sh's SWIFT_HOST_TOOLCHAIN), targeting x86_64 / OS X 10.9" "$T/linux.out" \
  || fail "linux did not finish OK: $(cat "$T/linux.out")"
echo "   without build-builtins.sh's archive, the prefix is staged without one, saying so"
mv "$W/builtins-x86" "$T/builtins.away"
(export FAKE_UNAME=Linux; run linuxnort modern --host linux) || fail "the linux build without builtins failed: $(cat "$T/linuxnort.out")"
mv "$T/builtins.away" "$W/builtins-x86"
[ ! -e "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a" ] || fail "linuxnort: staged a builtins archive from nowhere"
grep -q 'no builtins archive at .*run build-builtins.sh' "$T/linuxnort.out" || fail "linuxnort: did not say so: $(cat "$T/linuxnort.out")"
grep -qx "OK: the Linux toolchain prefix at $P (build.sh's SWIFT_HOST_TOOLCHAIN) (without builtins), targeting x86_64 / OS X 10.9" "$T/linuxnort.out" \
  || fail "linuxnort: the OK line does not say the prefix is without builtins: $(cat "$T/linuxnort.out")"
echo "   a clang whose default triple is not x86_64-apple-macosx10.9 (a host uname leaking into it) is refused,"
echo "   though its cfgs mask it, and so is a swift-frontend whose default target is not"
if (export FAKE_UNAME=Linux FAKE_TRIPLE=x86_64-apple-darwin6.8.0-1017-azure; run linuxtriple modern --host linux); then
  fail "passed a clang whose default triple is x86_64-apple-darwin6.8.0-1017-azure"; fi
grep -q "default target is x86_64-apple-darwin6.8.0-1017-azure, not x86_64-apple-macosx10.9" "$T/linuxtriple.out" || fail "linuxtriple: $(cat "$T/linuxtriple.out")"
if grep -q '^OK:' "$T/linuxtriple.out"; then fail "linuxtriple printed OK"; fi
if (export FAKE_UNAME=Linux FAKE_FE_TARGET=x86_64-apple-macosx10.3-2-t2-noble; run linuxfe modern --host linux); then
  fail "passed a swift-frontend whose default target is x86_64-apple-macosx10.3-2-t2-noble"; fi
grep -q "swift-frontend's default target is not x86_64-apple-macosx10.9" "$T/linuxfe.out" || fail "linuxfe: $(cat "$T/linuxfe.out")"
if grep -q '^OK:' "$T/linuxfe.out"; then fail "linuxfe printed OK"; fi
echo "   a seed clang that cannot run lld as ld.lld is refused before the Swift build is configured"
if (export FAKE_UNAME=Linux FAKE_LLD_BROKEN=1; run linuxlld modern --host linux); then fail "built with an lld that does not run"; fi
grep -q "FAIL: the seed's clang cannot link with lld" "$T/linuxlld.out" || fail "linuxlld: $(cat "$T/linuxlld.out")"
lacks linuxlld "  <T>/w/swift-linux"
if grep -q '^OK:' "$T/linuxlld.out"; then fail "linuxlld printed OK"; fi
echo "   no uuid-dev: refused before anything is fetched or configured"
if (export FAKE_UNAME=Linux FAKE_NO_UUID=1; run linuxnouuid modern --host linux); then fail "built with no uuid-dev"; fi
grep -q 'FAIL: .*uuid-dev' "$T/linuxnouuid.out" || fail "linuxnouuid: $(cat "$T/linuxnouuid.out")"
lacks linuxnouuid "cmake"
lacks linuxnouuid "fetch-linux-seed"

echo "   --stop-after llvm: LLVM, clang, lld and dsymutil, then nothing more (CI's linux-compiler-llvm job)"
rm -rf "$W/toolchain-linux"
(export FAKE_UNAME=Linux; run linuxstop modern --host linux --stop-after llvm) || fail "--stop-after llvm failed: $(cat "$T/linuxstop.out")"
has linuxstop "  <T>/w/llvm-linux"
lacks linuxstop "cmark"
lacks linuxstop "swift-linux"
lacks linuxstop "fetch_pinned_source"
[ ! -e "$W/toolchain-linux" ] || fail "--stop-after llvm staged a prefix"
grep -qx "OK: LLVM, clang, lld and dsymutil for the linux host at $W/llvm-linux; build-toolchain.sh without --stop-after finishes the compiler" "$T/linuxstop.out" \
  || fail "--stop-after llvm did not say where it stopped: $(cat "$T/linuxstop.out")"
for bad in "--stop-after swift" "--stop-after"; do
  rc=0; (export FAKE_UNAME=Linux; run linuxbadstop modern --host linux $bad) || rc=$?
  [ "$rc" -eq 2 ] || fail "'$bad': exit $rc, not 2: $(cat "$T/linuxbadstop.out")"
  [ ! -s "$T/linuxbadstop.log" ] || fail "'$bad' ran [$(head -1 "$T/linuxbadstop.log")] before refusing"
done

echo "-- --host linux on Darwin, and any other host on Linux, is refused before anything runs"
rc=0; run linuxmac modern --host linux || rc=$?
[ "$rc" -eq 2 ] || fail "--host linux on Darwin: exit $rc, not 2: $(cat "$T/linuxmac.out")"
grep -qx 'FAIL: --host linux builds on Linux' "$T/linuxmac.out" || fail "linuxmac: $(cat "$T/linuxmac.out")"
[ ! -s "$T/linuxmac.log" ] || fail "--host linux on Darwin ran [$(head -1 "$T/linuxmac.log")] before refusing"
for h in "" "--host x86_64" "--host arm64"; do
  rc=0; (export FAKE_UNAME=Linux; run linuxother modern $h) || rc=$?
  [ "$rc" -eq 2 ] || fail "'$h' on Linux: exit $rc, not 2: $(cat "$T/linuxother.out")"
  grep -qx 'FAIL: on Linux, --host linux is the only host' "$T/linuxother.out" || fail "linuxother '$h': $(cat "$T/linuxother.out")"
  [ ! -s "$T/linuxother.log" ] || fail "'$h' on Linux ran [$(head -1 "$T/linuxother.log")] before refusing"
done

echo "-- any other host, or mode, is refused before anything runs"
for bad in "--host x86" "--host" "--hots arm64"; do
  rc=0; run bad modern $bad || rc=$?
  [ "$rc" -eq 2 ] || fail "'$bad': exit $rc, not 2: $(cat "$T/bad.out")"
  [ ! -s "$T/bad.log" ] || fail "'$bad' ran [$(head -1 "$T/bad.log")] before refusing"
done
rc=0; run badmode sideways || rc=$?
[ "$rc" -eq 2 ] || fail "mode 'sideways': exit $rc, not 2"
grep -q "mode 'sideways' is neither mavericks nor modern" "$T/badmode.out" || fail "badmode: $(cat "$T/badmode.out")"
for old in native cross; do   # shipyard's old mode names are no modes
  rc=0; run "bad$old" "$old" || rc=$?
  [ "$rc" -eq 2 ] || fail "mode '$old': exit $rc, not 2"
  grep -q "mode '$old' is neither mavericks nor modern" "$T/bad$old.out" || fail "bad$old: $(cat "$T/bad$old.out")"
  [ ! -s "$T/bad$old.log" ] || fail "mode '$old' ran [$(head -1 "$T/bad$old.log")] before refusing"
done
echo "PASS"
