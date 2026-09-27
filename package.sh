#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild assemble the pkg
# Package $OUT (from build.sh) into a distributable .pkg.
# pkgbuild -> flat component pkg, then the SHARED set_install_floor.sh helper
# (mavericks-shipyard) wraps it with a 10.9.5 install floor + self-checks it.
#
# NOTE: trackpad2's BundleIsVersionChecked dance does NOT apply -- that guards *bundle*
# components; our payload is a plain libswiftCore.dylib (a file), always installed.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD
OUT="${OUT:-$SWIFT_BUILD/payload/runtime}"
DIST="${DIST:-$SWIFT_BUILD/dist}"
# The full version: reuses VERSION if the workflow already resolved it this run, else derives it
# from UPSTREAM_VERSION + the shipped tags. Never a committed file.
[ -f "$HERE/UPSTREAM_VERSION" ] || sh "$HERE/scripts/derive-upstream-version.sh" >/dev/null
. "$HERE/msc.sh"        # -> $SHIPYARD: resolve-version, stage_product and set_install_floor
VERSION="$(MAVERICKS_ROOT="$HERE" sh "$SHIPYARD/resolve-version.sh")"
IDENTIFIER="${PKG_IDENTIFIER:-dev.mavergreen.swift-runtime}"
NAME="swift-runtime-${VERSION}"
mkdir -p "$DIST"
[ -f "$OUT/usr/local/mavergreen/swift-runtime/lib/swift/libswiftCore.dylib" ] || { echo "no build in $OUT; run build.sh" >&2; exit 1; }

echo ">> resources (welcome + license shown at install)"
RES="$DIST/resources"; mkdir -p "$RES"
cp "$HERE/scripts/resources/Welcome.html" "$RES/"
LICENSE_TXT="$OUT/usr/local/mavergreen/swift-runtime/share/doc/LICENSE.txt"
[ -f "$LICENSE_TXT" ] || { echo "no $LICENSE_TXT; run build.sh (it vendors the license)" >&2; exit 1; }
cp "$LICENSE_TXT" "$RES/"

# Nothing installs at the root of the disk. pkgbuild --root "$OUT" --install-location / ships every
# file in $OUT, so a stray file here (the license once was) lands in / on every user's machine.
stray="$(find "$OUT" -mindepth 1 -maxdepth 1 ! -type d)"
[ -z "$stray" ] || { echo "files at the payload root would install into /: $stray" >&2; exit 1; }

echo ">> stage the manifest, install scripts, and the updater app + LaunchAgent (if built)"
UPD_APP="${UPD_APP:-$SWIFT_BUILD/build/updater/swift-runtime-updater.app}"
# Only this step puts anything under $OUT/Library, and $OUT persists between builds: clear it, or a
# previous run's updater ships alongside this one.
rm -rf "$OUT/Library"
SCR="$DIST/pkg-scripts"; rm -rf "$SCR"
set -- --stage "$OUT" --product swift-runtime --name "Mavericks Swift Runtime" --version "$VERSION" --scripts-out "$SCR"
if [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
elif [ "${REQUIRE_UPDATER:-}" = 1 ]; then
  echo "no updater app at $UPD_APP, and REQUIRE_UPDATER=1: a release never ships without its updater -- build it: shipyard-cmake --build \"\$SWIFT_BUILD/build/updater\" --target swift-runtime-updater" >&2
  exit 1
else
  echo "   (no updater app at $UPD_APP; packaging runtime only -- build it: shipyard-cmake --build \"\$SWIFT_BUILD/build/updater\")"
fi
sh "$SHIPYARD/stage_product.sh" "$@"

echo ">> flat component pkg (payload -> /usr/local/mavergreen/swift-runtime, /Library)"
pkgbuild --root "$OUT" --identifier "$IDENTIFIER" --version "$VERSION" \
  --scripts "$SCR" \
  --install-location / "$DIST/swift-runtime-component.pkg"

echo ">> product archive with 10.9.5 floor (shared helper)"
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENTIFIER" \
  --title "Mavericks Swift Runtime — Swift core runtime for OS X 10.9" \
  --component "$DIST/swift-runtime-component.pkg" \
  --out "$DIST/${NAME}.pkg" \
  --resources "$RES" --welcome Welcome.html --license LICENSE.txt --host-arch x86_64 --require-scripts

# The component pkg is an intermediate (no 10.9.5 OS floor -- installing it directly would bypass the
# gate). Only the product archive ships; drop the intermediate so it can't leak into the release glob.
rm -f "$DIST/swift-runtime-component.pkg"

echo ">> checksums"
( cd "$DIST" && shasum -a 256 "${NAME}.pkg" > SHA256SUMS )
cat "$DIST/SHA256SUMS"
echo "OK -> $DIST/${NAME}.pkg"
