#!/bin/sh
# platform: macOS-only -- BSD sed -i '', otool (llvm-otool on 10.9) and shipyard-cmake; runs on a modern Mac and on OS X 10.9
# build-llvm.sh — build a RELOCATABLE LLVM build-support tree for the Swift stdlib build, and the lld
# that links the runtime.
#
# Produces out/llvm: a CMake *install* tree (relocatable — LLVMConfig.cmake derives its prefix
# from its own location) rather than a build tree (absolute paths baked in at configure time). And
# $SWIFT_WORK/llvm-build/bin/ld64.lld, which build.sh links the runtime with in both modes, so a CI
# build and an OS X 10.9 build of the same release are the same bytes.
# Runs on a modern Mac (cross mode: /usr/bin/clang) and on OS X 10.9 (native mode: mavericks-clang-22's
# native clang, with the fetched 10.9 SDK, since that pkg leaves its own SDKs/ empty, and its
# llvm-libtool-darwin, llvm-ar, llvm-ranlib and llvm-otool, since 10.9's are the Command Line Tools');
# MAVERICKS_MODE overrides shipyard's mavericks_mode.sh, HOST_TOOLS_CC and HOST_TOOLS_CXX the compiler.
# The source is GitHub's tarball of LLVM_SHA, verified by LLVM_TARBALL_SHA256 (no git), patched with the
# OS's patch; LLVM's version stamp is forced to that commit and its repository.
# Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, MAVERICKS_MODE, HOST_TOOLS_CC, HOST_TOOLS_CXX, CLANG22_PREFIX,
# MAVERICKS_SDK_CACHE, MAVERICKS_SOURCE_CACHE.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"   # -> $SHIPYARD (shipyard scripts dir)
. "$HERE/lib.sh"    # -> $SWIFT_BUILD (out-of-tree build root)
# Scratch defaults out of the tree, under $SWIFT_BUILD; SWIFT_WORK overrides it (build.sh shares it).
ROOT="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$ROOT"; cd "$ROOT"
OUT="$SWIFT_BUILD/out/llvm"

echo "==> 1. pinned llvm-project source (GitHub's tarball of LLVM_SHA, verified by LLVM_TARBALL_SHA256)"
check_release_pin llvm-project "$LLVM_SWIFT_RELEASE" "$LLVM_TAG" "$LLVM_SHA" "$LLVM_REPO_URL" || exit 1
# Extracted afresh every run, so the patches below start from upstream's bytes.
fetch_source llvm-project "$LLVM_REPO_URL" "$LLVM_SHA" "$LLVM_TARBALL_SHA256" LLVM_TARBALL_SHA256 || exit 1

echo "==> 1b. LLVM patches (patches/llvm)"
patch_source "$ROOT/llvm-project" "$HERE"/patches/llvm/*.patch || exit 1
grep -q 'absent before macOS 10.10' llvm-project/llvm/lib/CAS/OnDiskCommon.cpp || { echo "FAIL: llvm patch 0001 not applied"; exit 1; }
grep -q 'LLVM_LINKER_IS_LLD AND NOT APPLE' llvm-project/llvm/cmake/modules/AddLLVM.cmake || { echo "FAIL: llvm patch 0002 not applied"; exit 1; }
grep -q "swiftlang's fork refuses every Apple-platform input" llvm-project/lld/MachO/InputFiles.cpp || { echo "FAIL: llvm patch 0003 not applied"; exit 1; }
grep -q 'Mavergreen: extra flags for the Darwin builtins' llvm-project/compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake || { echo "FAIL: llvm patch 0004 not applied"; exit 1; }

echo "==> 2. configure + build TableGen and lld (libswiftCore does not link LLVM; lld links it)"
# spec: 2026-09-13 shipyard CMake flag day -- the .cmake files installed in step 3 ARE the shipped
#       product, and this repo's build.sh consumes them with shipyard-cmake. Generating them
#       with one CMake and consuming them with another is the mismatch this repo exists to prevent,
#       so the same pinned shipyard-cmake writes them.
MODE="${MAVERICKS_MODE:-$(sh "$SHIPYARD/mavericks_mode.sh")}"
case "$MODE" in
  cross) CC_="${HOST_TOOLS_CC:-/usr/bin/clang}"; CXX_="${HOST_TOOLS_CXX:-/usr/bin/clang++}" ;;
  # platform: OS X 10.9's Apple clang is too old to build LLVM; mavericks-clang-22's static libc++
  #           fills what 10.9's libc++ lacks. Its pkg leaves SDKs/ empty, so the sysroot is named.
  native) X="$(clang22_prefix native "$HERE")/bin" || { echo "FAIL: no usable mavericks-clang-22 (native)"; exit 1; }
          CC_="${HOST_TOOLS_CC:-$X/clang}"; CXX_="${HOST_TOOLS_CXX:-$X/clang++}"
          SDK109="$(sh "$SHIPYARD/fetch_sdk.sh")" || { echo "FAIL: could not fetch the pinned 10.9 SDK"; exit 1; }
          # platform: OS X 10.9's libtool, ar, ranlib and otool are the Command Line Tools', stubs
          #           without them; LLVM archives with CMAKE_LIBTOOL on an Apple host.
          OTOOL="$X/llvm-otool"; export OTOOL
          # platform: a configure over a CMakeCache.txt hands LLVM's config.guess no CC, so it tries cc,
          #           gcc, c89 and c99, on OS X 10.9 the Command Line Tools' stubs: it gets the clang it configures with.
          CC_FOR_BUILD="$CC_"; export CC_FOR_BUILD ;;
  *) echo "FAIL: mode '$MODE' is neither cross nor native"; exit 1 ;;
esac
# /opt/pkg (pkgsrc, on the 10.9 box) is never searched: a library found there is an accident the
# pkgsrc ledger does not allow, and LibXml2, LibEdit, zlib, zstd and terminfo are off by name, so what
# the host has on PATH (pkg-config finds them despite the ignore) changes nothing. Git is never looked
# for: the source is a tarball, and the version stamp is forced to the pinned commit and its repository,
# the strings git reported from a checkout of it.
set -- -G Ninja -S llvm-project/llvm -B llvm-build \
  -DCMAKE_BUILD_TYPE=Release "-DLLVM_ENABLE_PROJECTS=clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
  -DCMAKE_C_COMPILER="$CC_" -DCMAKE_CXX_COMPILER="$CXX_" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_FORCE_VC_REVISION="$LLVM_SHA" -DLLVM_FORCE_VC_REPOSITORY="$LLVM_REPO_URL" -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF
# Natively, the answers to CMake's and LLVM's Apple probes (lib.sh's apple_probe_answers), and clang22's lld
# as CMAKE_LINKER with lib.sh's HOST_LINK_VERSION, so clang's configure runs no `ld -v` (it found the Command
# Line Tools' ld): what out/llvm's clang/Config/config.h records stays 241.9, as that ld said.
if [ "$MODE" = native ]; then
  # shellcheck disable=SC2046  # apple_probe_answers prints space-free words
  set -- "$@" -DCMAKE_OSX_SYSROOT="$SDK109" \
    -DCMAKE_LIBTOOL="$X/llvm-libtool-darwin" -DCMAKE_AR="$X/llvm-ar" -DCMAKE_RANLIB="$X/llvm-ranlib" \
    -DCMAKE_LINKER="$X/ld64.lld" -DHOST_LINK_VERSION="$HOST_LINK_VERSION" $(apple_probe_answers "$X")
fi
# A reused llvm-build is kept only while these are the options it was configured with and llvm-project
# the source it compiled (lib.sh's reuse_build_dir and source_stamp); otherwise it is removed and built
# afresh (a build root from before lld joined would otherwise never build it). Configured again in place,
# it would keep the tools CMake found on its first configure: CMakeFiles/<version>/CMakeCCompiler.cmake
# sets CMAKE_LINKER whatever -D says later, so a native root from before T5a would still run the Command
# Line Tools' `ld -v`. And ninja, seeing a moved pin's older commit's files all older than its outputs,
# would keep the objects the previous commit built.
STAMP="$(printf '%s\n' "$@" && source_stamp llvm-project)" || { echo "FAIL: could not stamp llvm-build"; exit 1; }
reuse_build_dir llvm-build "$STAMP" || exit 1
if [ ! -f llvm-build/build.ninja ] || [ ! -x "$(sed -n 's/^CMAKE_COMMAND:INTERNAL=//p' llvm-build/CMakeCache.txt)" ]; then
  shipyard-cmake "$@"
  printf '%s\n' "$STAMP" > llvm-build/mavergreen-inputs.stamp
fi
# llvm-min-tblgen is named explicitly: step 3 copies it, and relying on it appearing
# transitively would break the copy if a future LLVM stops pulling it in. LLVMBitstreamReader is for
# build-toolchain.sh's native helper tools. lld is for build.sh's link of the runtime (bin/ld64.lld).
ninja -C llvm-build llvm-tblgen llvm-min-tblgen clang-tblgen llvm-config \
      intrinsics_gen clang-tablegen-targets LLVMBitstreamReader lld
[ -x llvm-build/bin/ld64.lld ] || { echo "FAIL: no llvm-build/bin/ld64.lld after building lld"; exit 1; }
# lld links nothing from /opt/pkg; a reader that cannot read it fails this too (lib.sh, OTOOL).
macho_links_none_under llvm-build/bin/lld /opt/pkg/ || exit 1

echo "==> 3. install the relocatable subset"
rm -rf "$OUT"; mkdir -p "$OUT"
for c in cmake-exports llvm-headers clang-cmake-exports clang-headers; do
  shipyard-cmake --install llvm-build --prefix "$OUT" --component "$c"
done
mkdir -p "$OUT/bin"
for b in llvm-tblgen clang-tblgen llvm-config llvm-min-tblgen; do
  cp "llvm-build/bin/$b" "$OUT/bin/$b"
done

echo "==> 4. relocatability fixups"
# (a) Neutralize the import-existence check. We ship the CMake package WITHOUT LLVM's static
#     archives: only TableGen is built, and SWIFT_INCLUDE_TOOLS=OFF means nothing links LLVM.
#     Without this, find_package(LLVM) aborts on libLLVMDemangle.a.
# platform: awk, not sed: OS X 10.9's BSD sed writes a replacement's \n as a literal n, joining the
#           inserted line to the comment after it.
NEUTRALIZE='set(_cmake_import_check_targets "")  # Mavergreen: no LLVM archives shipped (nothing links them)'
for f in "$OUT/lib/cmake/llvm/LLVMExports.cmake" "$OUT/lib/cmake/clang/ClangTargets.cmake"; do
  [ -f "$f" ] || continue
  awk -v line="$NEUTRALIZE" '/^# Loop over all imported files and verify that they actually exist/ { print line } { print }' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  grep -qxF "$NEUTRALIZE" "$f" || {
    echo "FAIL: import-check neutralization did not apply to $f"; exit 1; }
done
# (b) LLVM_DEFAULT_EXTERNAL_LIT is the one remaining absolute build path. lit is unused
#     (SWIFT_INCLUDE_TESTS=OFF) and it would trip the no-absolute-paths assertion below.
/usr/bin/sed -i '' 's|^set(LLVM_DEFAULT_EXTERNAL_LIT .*|set(LLVM_DEFAULT_EXTERNAL_LIT "")|' \
  "$OUT/lib/cmake/llvm/LLVMConfig.cmake"

echo "==> 5. assert relocatability"
# No path from THIS build may survive in any shipped .cmake file.
if grep -rlF "$ROOT" "$OUT" --include='*.cmake' 2>/dev/null | grep .; then
  echo "FAIL: absolute build paths leaked into the install tree (listed above)"; exit 1
fi
grep -q 'set(LLVM_CMAKE_DIR "${LLVM_INSTALL_PREFIX}/lib/cmake/llvm")' \
  "$OUT/lib/cmake/llvm/LLVMConfig.cmake" || {
  echo "FAIL: LLVM_CMAKE_DIR is not prefix-relative — this is a build tree, not an install tree"
  exit 1; }
[ -f "$OUT/lib/cmake/llvm/LLVMInstallSymlink.cmake" ] || {
  echo "FAIL: LLVMInstallSymlink.cmake missing (Swift's SwiftComponents.cmake:203 needs it)"
  exit 1; }

echo "OK: relocatable LLVM build-support tree at $OUT ($(du -sh "$OUT" | cut -f1))"
