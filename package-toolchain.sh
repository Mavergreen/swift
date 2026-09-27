#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild assemble the pkg
#   usage: package-toolchain.sh
#          Packages $OUT (scripts/stage-toolchain.sh's payload) as $DIST/swift-toolchain-<version>.pkg:
#          shipyard's stage_product.sh writes the manifest and install scripts and stages the updater
#          ($UPD_APP) when it is built; pkgbuild; then set_install_floor.sh for the 10.9.5 floor, with
#          dev.mavergreen.base first. REQUIRE_UPDATER=1 refuses to package without the updater.
#          The release's SHA256SUMS are publish-release.yml's to write.
#          Env: MAVERICKS_BUILD_ROOT, OUT, DIST, UPD_APP, REQUIRE_UPDATER.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD
OUT="${OUT:-$SWIFT_BUILD/payload/toolchain}"
DIST="${DIST:-$SWIFT_BUILD/dist}"
[ -f "$HERE/UPSTREAM_VERSION" ] || sh "$HERE/scripts/derive-upstream-version.sh" >/dev/null
. "$HERE/msc.sh"    # -> $SHIPYARD: resolve-version, stage_product and set_install_floor
VERSION="$(MAVERICKS_ROOT="$HERE" sh "$SHIPYARD/resolve-version.sh")"
PRODUCT=swift-toolchain
IDENTIFIER=dev.mavergreen.swift-toolchain
NAME="$PRODUCT-$VERSION"
LICENSE_TXT="$OUT/usr/local/mavergreen/$PRODUCT/share/doc/LICENSE.txt"
[ -f "$LICENSE_TXT" ] || { echo "no toolchain payload in $OUT; run scripts/stage-toolchain.sh" >&2; exit 1; }
# Nothing installs at the root of the disk: pkgbuild --root ships every file in $OUT.
stray="$(find "$OUT" -mindepth 1 -maxdepth 1 ! -type d)"
[ -z "$stray" ] || { echo "files at the payload root would install into /: $stray" >&2; exit 1; }
mkdir -p "$DIST"

RES="$DIST/resources-toolchain"; rm -rf "$RES"; mkdir -p "$RES"
cp "$HERE/scripts/resources/Welcome-toolchain.html" "$RES/Welcome.html"
cp "$LICENSE_TXT" "$RES/LICENSE.txt"

UPD_APP="${UPD_APP:-$SWIFT_BUILD/build/updater-toolchain/$PRODUCT-updater.app}"
# Only stage_product.sh puts anything under $OUT/Library, and $OUT persists between builds.
rm -rf "$OUT/Library"
SCR="$DIST/pkg-scripts-toolchain"; rm -rf "$SCR"
# spec: shipyard docs/superpowers/specs/2026-09-24-install-layout-design.md decision 4 -- a bare name two
#       groups want makes `mavergreen link` refuse the whole product, and clang22's group owns clang,
#       clang++ and ld64.lld. swift-frontend run directly would skip swiftc's 10.9 defaults.
set -- --stage "$OUT" --product "$PRODUCT" --name "Mavericks Swift Toolchain" --group swift --version "$VERSION" \
  --exclude bin/swift-frontend --exclude bin/ld64.lld --exclude bin/clang --exclude bin/clang++ --scripts-out "$SCR"
if [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
elif [ "${REQUIRE_UPDATER:-}" = 1 ]; then
  echo "no updater app at $UPD_APP, and REQUIRE_UPDATER=1: a release never ships without its updater -- build it: shipyard-cmake --build \"\$SWIFT_BUILD/build/updater-toolchain\" --target $PRODUCT-updater" >&2
  exit 1
else
  echo "   (no updater app at $UPD_APP; packaging the toolchain only)"
fi
sh "$SHIPYARD/stage_product.sh" "$@"

pkgbuild --root "$OUT" --identifier "$IDENTIFIER" --version "$VERSION" \
  --scripts "$SCR" --install-location / "$DIST/$PRODUCT-component.pkg"
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENTIFIER" \
  --title "Mavericks Swift Toolchain — a Swift compiler for OS X 10.9" \
  --component "$DIST/$PRODUCT-component.pkg" \
  --out "$DIST/$NAME.pkg" \
  --resources "$RES" --welcome Welcome.html --license LICENSE.txt --host-arch x86_64 --require-scripts
# The component pkg has no 10.9.5 floor; only the product archive ships.
rm -f "$DIST/$PRODUCT-component.pkg"
echo "OK -> $DIST/$NAME.pkg"
