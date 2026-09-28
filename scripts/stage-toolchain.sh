#!/bin/sh
# platform: host-agnostic
#   usage: [STAGE_HOST=x86_64|arm64] stage-toolchain.sh <out-dir>
#          Lays out a toolchain .pkg's payload under <out-dir>/usr/local/mavergreen/<product> from this
#          build: build-toolchain.sh --host $STAGE_HOST's compiler, lld, clang, clang's headers and
#          helper outputs; build-builtins.sh's compiler-rt builtins, where that clang looks for them (the
#          archive the runtime was linked with); build.sh's stdlib build in the same build root (in
#          CI's build job, the one the runtime .pkg is staged from; build-cross runs its own, and collect
#          checks the two are the same bytes); the swiftc and ld wrappers; shipyard's SDK fetcher and the two scripts it
#          sources; clang's clang.cfg and clang++.cfg. STAGE_HOST x86_64 (the default) is the native
#          toolchain, swift-toolchain; arm64 the cross toolchain, swift-toolchain-cross. Everything but
#          what each host's build makes itself (the three binaries, clang's headers, the helper outputs)
#          is the same bytes in both. <out-dir> persists between builds, so its usr/ is removed first;
#          <out-dir>/Library belongs to package-toolchain.sh and is left alone.
#          Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, STAGE_HOST.
set -eu
[ $# -eq 1 ] || { echo "usage: stage-toolchain.sh <out-dir>" >&2; exit 2; }
OUT="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/outdir.sh"
refuse_root_outdir stage-toolchain "$OUT"
. "$HERE/lib.sh"     # -> $SWIFT_BUILD, clang_resource_include, toolchain_host_select
toolchain_host_select "${STAGE_HOST:-x86_64}" || exit 2
. "$HERE/msc.sh"     # -> $SHIPYARD (fetch_sdk.sh, mavericks_fetch.sh, sdk-pins.sh)
W="${SWIFT_WORK:-$SWIFT_BUILD/work}"
LB="$W/$TH_LLVM"; SB="$W/$TH_SWIFT"
STDLIB="$W/stdlib-build/lib/swift"
# A reused build root keeps the previous LLVM major's resource dir beside the new one; picking either
# silently could ship the wrong clang headers, so none, or more than one, is refused, named.
CLANG_INC="$(clang_resource_include "$LB")" || { echo "stage-toolchain: run build-toolchain.sh --host ${STAGE_HOST:-x86_64}" >&2; exit 1; }
BUILTINS="$W/builtins-x86/lib/darwin/libclang_rt.osx.a"
for f in "$SB/bin/swift-frontend" "$LB/bin/lld" "$LB/bin/clang" "$BUILTINS" \
         "$STDLIB/macosx/Swift.swiftmodule" "$STDLIB/macosx/SwiftOnoneSupport.swiftmodule" \
         "$STDLIB/macosx/x86_64/libswiftCore.dylib" "$STDLIB/macosx/x86_64/libswiftSwiftOnoneSupport.dylib" \
         "$STDLIB/macosx/layouts-x86_64.yaml" "$STDLIB/shims" "$SB/share/swift/compatibility-symbols" \
         "$W/llvm-project/llvm/LICENSE.TXT" "$SHIPYARD/sdk-pins.sh"; do
  [ -e "$f" ] || { echo "stage-toolchain: missing $f -- run build-builtins.sh, build.sh and build-toolchain.sh --host ${STAGE_HOST:-x86_64}" >&2; exit 1; }
done

P="$OUT/usr/local/mavergreen/$TH_PRODUCT"
rm -rf "$OUT/usr"
CLANG_V="$(basename "$(dirname "$CLANG_INC")")"
mkdir -p "$P/bin" "$P/libexec/mavergreen-swift" "$P/lib/swift/macosx" "$P/lib/clang/$CLANG_V/lib/darwin" \
  "$P/share/swift/diagnostics" "$P/share/doc"
cp "$SB/bin/swift-frontend" "$P/bin/swift-frontend"
cp "$LB/bin/lld" "$P/bin/ld64.lld"
cp "$LB/bin/clang" "$P/bin/clang"
ln -s clang "$P/bin/clang++"
# clang loads <driver>.cfg from its own bin/: clang.cfg for clang, clang++.cfg for clang++ (toolchain/clang.cfg).
cp "$HERE/toolchain/clang.cfg" "$P/bin/clang.cfg"
cp "$HERE/toolchain/clang.cfg" "$P/bin/clang++.cfg"
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
# ...and its builtins at <resource dir>/lib/darwin, where clang's driver looks (so C's @available links),
# and where swiftc's does, through lib/swift/clang, linking it into every program as swift.org's does.
# build.sh on OS X 10.9 links the runtime with these same bytes.
cp "$BUILTINS" "$P/lib/clang/$CLANG_V/lib/darwin/libclang_rt.osx.a"
ln -s "../clang/$CLANG_V" "$P/lib/swift/clang"
cp "$SB/share/swift/compatibility-symbols" "$P/share/swift/"
for f in "$SB"/share/swift/diagnostics/*.db "$SB"/share/swift/diagnostics/*.strings \
         "$SB"/share/swift/diagnostics/*.yaml; do
  if [ -f "$f" ]; then cp "$f" "$P/share/swift/diagnostics/"; fi
done
cp "$HERE/LICENSE" "$P/share/doc/LICENSE.txt"
cp "$W/llvm-project/llvm/LICENSE.TXT" "$P/share/doc/LICENSE-LLVM.txt"
cp "$HERE/NOTICE" "$P/share/doc/NOTICE"
