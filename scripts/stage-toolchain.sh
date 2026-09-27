#!/bin/sh
# platform: host-agnostic
#   usage: stage-toolchain.sh <out-dir>
#          Lays out the toolchain .pkg's payload under <out-dir>/usr/local/mavergreen/swift-toolchain
#          from this build: build-toolchain.sh's compiler, lld, clang, clang's headers and helper
#          outputs; build.sh's stdlib build (the one the runtime .pkg is staged from); the swiftc and ld
#          wrappers; shipyard's SDK fetcher and the two scripts it sources. <out-dir> persists between
#          builds, so its usr/ is removed first; <out-dir>/Library belongs to package-toolchain.sh and
#          is left alone. Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK.
set -eu
[ $# -eq 1 ] || { echo "usage: stage-toolchain.sh <out-dir>" >&2; exit 2; }
OUT="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/outdir.sh"
refuse_root_outdir stage-toolchain "$OUT"
. "$HERE/lib.sh"     # -> $SWIFT_BUILD
. "$HERE/msc.sh"     # -> $SHIPYARD (fetch_sdk.sh, mavericks_fetch.sh, sdk-pins.sh)
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"
STDLIB="$W/stdlib-build/lib/swift"
# A reused build root keeps the previous LLVM major's resource dir beside the new one; picking either
# silently could ship the wrong clang headers, so more than one is refused, named.
CLANG_INC=""; n=0
for d in "$W"/llvm-x86/lib/clang/*/include; do
  if [ -d "$d" ]; then CLANG_INC="$CLANG_INC${CLANG_INC:+ }$d"; n=$((n + 1)); fi
done
[ "$n" -le 1 ] || { echo "stage-toolchain: $n clang resource dirs, where one was expected (a stale LLVM major in a reused build root? remove it): $CLANG_INC" >&2; exit 1; }
for f in "$W/swift-x86/bin/swift-frontend" "$W/llvm-x86/bin/lld" "$W/llvm-x86/bin/clang" "${CLANG_INC:-$W/llvm-x86/lib/clang/<v>/include}" \
         "$STDLIB/macosx/Swift.swiftmodule" "$STDLIB/macosx/SwiftOnoneSupport.swiftmodule" \
         "$STDLIB/macosx/x86_64/libswiftCore.dylib" "$STDLIB/macosx/x86_64/libswiftSwiftOnoneSupport.dylib" \
         "$STDLIB/macosx/layouts-x86_64.yaml" "$STDLIB/shims" "$W/swift-x86/share/swift/compatibility-symbols" \
         "$W/llvm-project/llvm/LICENSE.TXT" "$SHIPYARD/sdk-pins.sh"; do
  [ -e "$f" ] || { echo "stage-toolchain: missing $f -- run build.sh and build-toolchain.sh" >&2; exit 1; }
done

P="$OUT/usr/local/mavergreen/swift-toolchain"
rm -rf "$OUT/usr"
CLANG_V="$(basename "$(dirname "$CLANG_INC")")"
mkdir -p "$P/bin" "$P/libexec/mavergreen-swift" "$P/lib/swift/macosx" "$P/lib/clang/$CLANG_V" \
  "$P/share/swift/diagnostics" "$P/share/doc"
cp "$W/swift-x86/bin/swift-frontend" "$P/bin/swift-frontend"
cp "$W/llvm-x86/bin/lld" "$P/bin/ld64.lld"
cp "$W/llvm-x86/bin/clang" "$P/bin/clang"
ln -s clang "$P/bin/clang++"
cp "$HERE/toolchain/swiftc" "$P/bin/swiftc"
cp "$HERE/toolchain/ld" "$P/libexec/mavergreen-swift/ld"
chmod 755 "$P/bin/swiftc" "$P/libexec/mavergreen-swift/ld"
cp "$SHIPYARD/fetch_sdk.sh" "$SHIPYARD/mavericks_fetch.sh" "$SHIPYARD/sdk-pins.sh" "$P/libexec/mavergreen-swift/"
cp -R "$STDLIB/macosx/Swift.swiftmodule" "$STDLIB/macosx/SwiftOnoneSupport.swiftmodule" "$P/lib/swift/macosx/"
cp "$STDLIB/macosx/layouts-x86_64.yaml" "$STDLIB/macosx/x86_64/libswiftCore.dylib" \
   "$STDLIB/macosx/x86_64/libswiftSwiftOnoneSupport.dylib" "$P/lib/swift/macosx/"
cp -R "$STDLIB/shims" "$P/lib/swift/shims"
# clang finds its resource headers at <bin>/../lib/clang/<v>; Swift at lib/swift/clang, as in swift.org toolchains.
cp -R "$CLANG_INC" "$P/lib/clang/$CLANG_V/include"
ln -s "../clang/$CLANG_V" "$P/lib/swift/clang"
cp "$W/swift-x86/share/swift/compatibility-symbols" "$P/share/swift/"
for f in "$W"/swift-x86/share/swift/diagnostics/*.db "$W"/swift-x86/share/swift/diagnostics/*.strings \
         "$W"/swift-x86/share/swift/diagnostics/*.yaml; do
  if [ -f "$f" ]; then cp "$f" "$P/share/swift/diagnostics/"; fi
done
cp "$HERE/LICENSE" "$P/share/doc/LICENSE.txt"
cp "$W/llvm-project/llvm/LICENSE.TXT" "$P/share/doc/LICENSE-LLVM.txt"
cp "$HERE/NOTICE" "$P/share/doc/NOTICE"
