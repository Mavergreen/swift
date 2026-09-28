#!/bin/sh
# platform: macOS-only -- BSD sed -i '', otool and shipyard-cmake; runs on a modern Mac and on OS X 10.9
# build-llvm.sh — build a RELOCATABLE LLVM build-support tree for the Swift stdlib build, and the lld
# that links the runtime.
#
# Produces out/llvm: a CMake *install* tree (relocatable — LLVMConfig.cmake derives its prefix
# from its own location) rather than a build tree (absolute paths baked in at configure time). And
# $SWIFT_WORK/llvm-build/bin/ld64.lld, which build.sh links the runtime with in both modes, so a CI
# build and an OS X 10.9 build of the same release are the same bytes.
# Runs on a modern Mac (cross mode: /usr/bin/clang) and on OS X 10.9 (native mode: mavericks-clang-22's
# native clang, with the fetched 10.9 SDK, since that pkg leaves its own SDKs/ empty); MAVERICKS_MODE
# overrides shipyard's mavericks_mode.sh, HOST_TOOLS_CC and HOST_TOOLS_CXX the compiler.
# Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, MAVERICKS_MODE, HOST_TOOLS_CC, HOST_TOOLS_CXX.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"   # -> $SHIPYARD (shipyard scripts dir)
. "$HERE/lib.sh"    # -> $SWIFT_BUILD (out-of-tree build root)
# Scratch defaults out of the tree, under $SWIFT_BUILD; SWIFT_WORK overrides it (build.sh shares it).
ROOT="${SWIFT_WORK:-$SWIFT_BUILD/work}"; mkdir -p "$ROOT"; cd "$ROOT"
OUT="$SWIFT_BUILD/out/llvm"

echo "==> 1. pinned llvm-project source (fetched BY SHA via shared clone_pinned.sh)"
check_release_pin llvm-project "$LLVM_SWIFT_RELEASE" "$LLVM_TAG" "$LLVM_SHA" \
  https://github.com/swiftlang/llvm-project.git || exit 1
# clone_pinned fetches the pinned commit DIRECTLY, so where a branch or tag moves later never matters.
# Guard on llvm/ existing, not on .git -- an interrupted checkout leaves a .git whose HEAD passes the
# SHA test while the worktree is empty (cmake then dies confusingly), so re-fetch from scratch then.
if [ ! -d llvm-project/llvm ]; then
  rm -rf llvm-project
  sh "$SHIPYARD/clone_pinned.sh" https://github.com/swiftlang/llvm-project.git "$LLVM_TAG" "$LLVM_SHA" llvm-project
fi
test "$(git -C llvm-project rev-parse HEAD)" = "$LLVM_SHA" || {
  echo "FAIL: llvm-project SHA mismatch (want $LLVM_SHA)"; exit 1; }
[ -d llvm-project/llvm ] || { echo "FAIL: llvm-project checkout incomplete"; exit 1; }

echo "==> 1b. LLVM patches (patches/llvm, on a pristine checkout: a previous run left it patched)"
git -C llvm-project reset -q --hard "$LLVM_SHA"
git -C llvm-project clean -q -fdx
for p in "$HERE"/patches/llvm/*.patch; do
  git -C llvm-project apply -p0 --check "$p" && git -C llvm-project apply -p0 "$p" || { echo "FAIL: patch did not apply: $p"; exit 1; }
done
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
  cross) CC_="${HOST_TOOLS_CC:-/usr/bin/clang}"; CXX_="${HOST_TOOLS_CXX:-/usr/bin/clang++}"; SYSROOT_ARG="" ;;
  # platform: OS X 10.9's Apple clang is too old to build LLVM; mavericks-clang-22's static libc++
  #           fills what 10.9's libc++ lacks. Its pkg leaves SDKs/ empty, so the sysroot is named.
  native) CC_="${HOST_TOOLS_CC:-/usr/local/mavergreen/clang22/bin/clang}"; CXX_="${HOST_TOOLS_CXX:-/usr/local/mavergreen/clang22/bin/clang++}"
          SYSROOT_ARG="-DCMAKE_OSX_SYSROOT=$(sh "$SHIPYARD/fetch_sdk.sh")" ;;
  *) echo "FAIL: mode '$MODE' is neither cross nor native"; exit 1 ;;
esac
# /opt/pkg (pkgsrc, on the 10.9 box) is never searched: a library found there is an accident the
# pkgsrc ledger does not allow. LibXml2 is off by name too: pkg-config finds it despite the ignore.
set -- -G Ninja -S llvm-project/llvm -B llvm-build \
  -DCMAKE_BUILD_TYPE=Release "-DLLVM_ENABLE_PROJECTS=clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
  -DCMAKE_C_COMPILER="$CC_" -DCMAKE_CXX_COMPILER="$CXX_" ${SYSROOT_ARG:+"$SYSROOT_ARG"} \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF
# A reused llvm-build keeps the options it was configured with, so it is configured again whenever
# they change (a build root from before lld joined would otherwise never build it).
if [ ! -f llvm-build/build.ninja ] || [ ! -x "$(sed -n 's/^CMAKE_COMMAND:INTERNAL=//p' llvm-build/CMakeCache.txt)" ] \
   || [ "$(cat llvm-build/mavergreen-configure.args 2>/dev/null)" != "$(printf '%s\n' "$@")" ]; then
  shipyard-cmake "$@"
  printf '%s\n' "$@" > llvm-build/mavergreen-configure.args
fi
# llvm-min-tblgen is named explicitly: step 3 copies it, and relying on it appearing
# transitively would break the copy if a future LLVM stops pulling it in. LLVMBitstreamReader is for
# build-toolchain.sh's native helper tools. lld is for build.sh's link of the runtime (bin/ld64.lld).
ninja -C llvm-build llvm-tblgen llvm-min-tblgen clang-tblgen llvm-config \
      intrinsics_gen clang-tablegen-targets LLVMBitstreamReader lld
[ -x llvm-build/bin/ld64.lld ] || { echo "FAIL: no llvm-build/bin/ld64.lld after building lld"; exit 1; }
# lld links nothing from /opt/pkg; an otool that cannot read it fails this too (lib.sh).
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
