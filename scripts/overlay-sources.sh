#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch, cp
#   usage: overlay-sources.sh <tree-6.2> <tree-5.4> <swift-tree> <gyb> <out>
#          Lays out the Darwin and ObjectiveC overlays' sources, replacing whatever <out> held, from the
#          pinned trees build.sh fetches (pins.env's SWIFT62_SHA and SWIFT54_SHA; spec: "The overlays"):
#            <out>/Darwin/: 6.2's stdlib/public/Platform files that its CMakeLists.txt compiles into
#              swiftDarwin -- Platform.swift, TiocConstants.swift, POSIXError.swift, MachError.swift, and
#              tgmath.swift and Darwin.swift, from their .gyb by <gyb> (the 6.4.1 tree's utils/gyb, as the
#              stdlib build runs it) with -D CMAKE_SDK=OSX. Not its magic-symbols-for-install-name.c: the
#              install name is @rpath already.
#            <out>/ObjectiveC/: 5.4's stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift, patched by
#              patches/overlays (OVERLAY_PATCHES below), and shims/: 5.4's ObjectiveCOverlayShims.h (6.4
#              dropped it; two inlines over objc_autoreleasePoolPush/Pop, both in 10.7) under a one-module
#              module.modulemap, _SwiftObjectiveCOverlayShims, which ObjectiveC.swift imports
#              @_implementationOnly, so no client sees it.
#            <out>/apinotes/Dispatch.apinotes: <swift-tree>'s (the SWIFT_SHA tree, $ROOT/swift: not the 5.4
#              tree) apinotes/Dispatch.apinotes, patched by patches/overlays' 0002, which makes
#              dispatch_sync and dispatch_barrier_sync's block NoEscape and dispatch_block_flags_t a
#              SwiftWrapper struct (the 10.9 SDK declares neither). The clang importer reads it, as
#              -iapinotes-modules, to import the 10.9 SDK's Dispatch for the Dispatch overlay and its clients.
#   Env: PYTHON (gyb's python, default python3: build.sh names the one CMake found).
set -eu
[ $# -eq 5 ] || { echo "usage: overlay-sources.sh <tree-6.2> <tree-5.4> <swift-tree> <gyb> <out>" >&2; exit 2; }
T62="$1"; T54="$2"; TSW="$3"; GYB="$4"; OUT="$5"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"   # -> patch_source, runtime_patches_unlisted
PLAT="$T62/stdlib/public/Platform"
OBJC="$T54/stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift"
SHIM="$T54/stdlib/public/SwiftShims/ObjectiveCOverlayShims.h"
APN="$TSW/apinotes/Dispatch.apinotes"
for f in "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" \
         "$PLAT/tgmath.swift.gyb" "$PLAT/Darwin.swift.gyb" "$OBJC" "$SHIM" "$APN" "$GYB"; do
  [ -f "$f" ] || { echo "overlay-sources.sh: no $f" >&2; exit 1; }
done
# gyb's Python orders sets and dicts by hash; a fixed seed keeps the generated sources the same run to run.
# --line-directive '': gyb's default marks each block with a comment naming the .gyb by its absolute path,
# so the sources (never the compiled bytes) differed between build roots.
PYTHONHASHSEED=0; export PYTHONHASHSEED
rm -rf "$OUT"; mkdir -p "$OUT/Darwin" "$OUT/ObjectiveC/shims" "$OUT/apinotes" "$OUT/.patch"

cp "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" "$OUT/Darwin/"
for g in tgmath Darwin; do
  "${PYTHON:-python3}" "$GYB" -D CMAKE_SDK=OSX --line-directive '' -o "$OUT/Darwin/$g.swift" "$PLAT/$g.swift.gyb" \
    || { echo "overlay-sources.sh: gyb failed on $PLAT/$g.swift.gyb" >&2; exit 1; }
done

# Patches are -p0 from a tree root, applied to a copy of the file at its own path (the tree stays
# upstream's bytes), in OVERLAY_PATCHES' order; a patch the list lacks fails, as build.sh's runtime ones do.
# 0001 is from the 5.4 root; 0002's file is in the SWIFT_SHA tree (<swift-tree>), not the 5.4 one, so both
# copies sit under one scratch root, $OUT/.patch, each at its own tree-relative path.
#  0001 hash is a method -- the 10.9 SDK's NSObject declares -hash a method, later SDKs a @property, so
#       `hash` becomes `hash()` three times.
#  0002 apinotes -- Dispatch.apinotes: NoEscape on parameter 1 of dispatch_sync and dispatch_barrier_sync (10.9's
#       headers lack DISPATCH_NOESCAPE, which a C redeclaration cannot add as far as Swift sees), and
#       SwiftWrapper: struct on dispatch_block_flags_t (Recaulk declares it a plain integer, not an option set).
OVERLAY_PATCHES="0001 0002"
PATCHES_DIR="$HERE/patches/overlays"
UNLISTED="$(runtime_patches_unlisted "$PATCHES_DIR" $OVERLAY_PATCHES)" || {
  [ -z "$UNLISTED" ] || printf '%s\n' "$UNLISTED" >&2
  echo "overlay-sources.sh: OVERLAY_PATCHES does not list every patch in $PATCHES_DIR (listed above) -- add its number, and a marker grep" >&2; exit 1; }
P="$OUT/.patch/stdlib/public/Darwin/ObjectiveC"
mkdir -p "$P" "$OUT/.patch/apinotes" && cp "$OBJC" "$P/" && cp "$APN" "$OUT/.patch/apinotes/"
for n in $OVERLAY_PATCHES; do
  for p in "$PATCHES_DIR/$n"-*.patch; do patch_source "$OUT/.patch" "$p" || exit 1; done
done
grep -q 'Mavericks: the 10.9 SDK declares -hash a method' "$P/ObjectiveC.swift" || { echo "overlay-sources.sh: overlay patch 0001 (hash) not applied" >&2; exit 1; }
AP="$OUT/.patch/apinotes/Dispatch.apinotes"
[ "$(grep -c '^    NoEscape: true$' "$AP")" = 2 ] && grep -q '^  SwiftWrapper: struct$' "$AP" || { echo "overlay-sources.sh: overlay patch 0002 (Dispatch.apinotes) not applied" >&2; exit 1; }
cp "$P/ObjectiveC.swift" "$OUT/ObjectiveC/"
cp "$AP" "$OUT/apinotes/"
rm -rf "$OUT/.patch"
cp "$SHIM" "$OUT/ObjectiveC/shims/"
printf 'module _SwiftObjectiveCOverlayShims {\n  header "ObjectiveCOverlayShims.h"\n}\n' > "$OUT/ObjectiveC/shims/module.modulemap"
