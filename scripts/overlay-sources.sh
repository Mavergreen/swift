#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch, cp
#   usage: overlay-sources.sh <tree-6.2> <tree-5.4> <gyb> <out>
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
#   Env: PYTHON (gyb's python, default python3: build.sh names the one CMake found).
set -eu
[ $# -eq 4 ] || { echo "usage: overlay-sources.sh <tree-6.2> <tree-5.4> <gyb> <out>" >&2; exit 2; }
T62="$1"; T54="$2"; GYB="$3"; OUT="$4"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"   # -> patch_source, runtime_patches_unlisted
PLAT="$T62/stdlib/public/Platform"
OBJC="$T54/stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift"
SHIM="$T54/stdlib/public/SwiftShims/ObjectiveCOverlayShims.h"
for f in "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" \
         "$PLAT/tgmath.swift.gyb" "$PLAT/Darwin.swift.gyb" "$OBJC" "$SHIM" "$GYB"; do
  [ -f "$f" ] || { echo "overlay-sources.sh: no $f" >&2; exit 1; }
done
# gyb's Python orders sets and dicts by hash; a fixed seed keeps the generated sources the same run to run.
PYTHONHASHSEED=0; export PYTHONHASHSEED
rm -rf "$OUT"; mkdir -p "$OUT/Darwin" "$OUT/ObjectiveC/shims" "$OUT/.patch"

cp "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" "$OUT/Darwin/"
for g in tgmath Darwin; do
  "${PYTHON:-python3}" "$GYB" -D CMAKE_SDK=OSX -o "$OUT/Darwin/$g.swift" "$PLAT/$g.swift.gyb" \
    || { echo "overlay-sources.sh: gyb failed on $PLAT/$g.swift.gyb" >&2; exit 1; }
done

# Patches are -p0 from the 5.4 root, applied to a copy of the file at its own path (the tree stays
# upstream's bytes), in OVERLAY_PATCHES' order; a patch the list lacks fails, as build.sh's runtime ones do.
#  0001 hash is a method -- the 10.9 SDK's NSObject declares -hash a method, later SDKs a @property, so
#       `hash` becomes `hash()` three times.
OVERLAY_PATCHES="0001"
PATCHES_DIR="$HERE/patches/overlays"
UNLISTED="$(runtime_patches_unlisted "$PATCHES_DIR" $OVERLAY_PATCHES)" || {
  [ -z "$UNLISTED" ] || printf '%s\n' "$UNLISTED" >&2
  echo "overlay-sources.sh: OVERLAY_PATCHES does not list every patch in $PATCHES_DIR (listed above) -- add its number, and a marker grep" >&2; exit 1; }
P="$OUT/.patch/stdlib/public/Darwin/ObjectiveC"
mkdir -p "$P" && cp "$OBJC" "$P/"
for n in $OVERLAY_PATCHES; do
  for p in "$PATCHES_DIR/$n"-*.patch; do patch_source "$OUT/.patch" "$p" || exit 1; done
done
grep -q 'Mavericks: the 10.9 SDK declares -hash a method' "$P/ObjectiveC.swift" || { echo "overlay-sources.sh: overlay patch 0001 (hash) not applied" >&2; exit 1; }
cp "$P/ObjectiveC.swift" "$OUT/ObjectiveC/"
rm -rf "$OUT/.patch"
cp "$SHIM" "$OUT/ObjectiveC/shims/"
printf 'module _SwiftObjectiveCOverlayShims {\n  header "ObjectiveCOverlayShims.h"\n}\n' > "$OUT/ObjectiveC/shims/module.modulemap"
