#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild assemble the pkg
#   usage: [STAGE_HOST=x86_64|arm64] package-toolchain.sh
#          Packages $OUT (scripts/stage-toolchain.sh's payload for the same STAGE_HOST) as
#          $DIST/<product>-<version>.pkg: shipyard's stage_product.sh writes the manifest and install
#          scripts and stages the updater ($UPD_APP) when it is built; pkgbuild; then set_install_floor.sh.
#          STAGE_HOST x86_64 (the default) is swift-toolchain, for OS X 10.9: a 10.9.5 floor, x86_64. arm64
#          is swift-toolchain-cross, for an Apple-silicon Mac: an 11.0 floor, arm64, and the line
#          `cross` in group swift, so it always exports swiftc-cross, and swiftc when it is the group's
#          selected member. Both put dev.mavergreen.base first. REQUIRE_UPDATER=1 refuses to package
#          without the updater. The release's SHA256SUMS are publish-release.yml's to write.
#          Env: MAVERICKS_BUILD_ROOT, OUT, DIST, UPD_APP, REQUIRE_UPDATER, STAGE_HOST.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, toolchain_host_select
toolchain_host_select "${STAGE_HOST:-x86_64}" || exit 2
OUT="${OUT:-$SWIFT_BUILD/payload/$TH_PAYLOAD}"
DIST="${DIST:-$SWIFT_BUILD/dist}"
[ -f "$HERE/UPSTREAM_VERSION" ] || sh "$HERE/scripts/derive-upstream-version.sh" >/dev/null
. "$HERE/msc.sh"    # -> $SHIPYARD: resolve-version, stage_product and set_install_floor
VERSION="$(MAVERICKS_ROOT="$HERE" sh "$SHIPYARD/resolve-version.sh")"
PRODUCT="$TH_PRODUCT"
IDENTIFIER="dev.mavergreen.$PRODUCT"
NAME="$PRODUCT-$VERSION"
LICENSE_TXT="$OUT/usr/local/mavergreen/$PRODUCT/share/doc/LICENSE.txt"
[ -f "$LICENSE_TXT" ] || { echo "no $PRODUCT payload in $OUT; run STAGE_HOST=${STAGE_HOST:-x86_64} scripts/stage-toolchain.sh" >&2; exit 1; }
# Nothing installs at the root of the disk: pkgbuild --root ships every file in $OUT.
stray="$(find "$OUT" -mindepth 1 -maxdepth 1 ! -type d)"
[ -z "$stray" ] || { echo "files at the payload root would install into /: $stray" >&2; exit 1; }
mkdir -p "$DIST"

RES="$DIST/resources-$TH_PAYLOAD"; rm -rf "$RES"; mkdir -p "$RES"
cp "$HERE/scripts/resources/Welcome-$TH_PAYLOAD.html" "$RES/Welcome.html"
cp "$LICENSE_TXT" "$RES/LICENSE.txt"

UPD_APP="${UPD_APP:-$SWIFT_BUILD/build/updater-$TH_PAYLOAD/$PRODUCT-updater.app}"
# Only stage_product.sh puts anything under $OUT/Library, and $OUT persists between builds.
rm -rf "$OUT/Library"
SCR="$DIST/pkg-scripts-$TH_PAYLOAD"; rm -rf "$SCR"
# spec: shipyard docs/superpowers/specs/2026-09-24-install-layout-design.md decision 4 -- a bare name two
#       groups want makes `mavergreen link` refuse the whole product, and clang22's group owns clang,
#       clang++ and ld64.lld (clang22-cross's too, on the modern Mac); clang's cfgs are not commands.
#       swift-frontend run directly would skip swiftc's 10.9 defaults. One list: both toolchains exclude
#       the same six.
set -- --exclude bin/swift-frontend --exclude bin/ld64.lld --exclude bin/clang --exclude bin/clang++ \
  --exclude bin/clang.cfg --exclude bin/clang++.cfg --scripts-out "$SCR"
if [ "$PRODUCT" = swift-toolchain ]; then
  set -- --stage "$OUT" --product "$PRODUCT" --name "Mavericks Swift Toolchain" --group swift --version "$VERSION" "$@"
else
  # spec: the conventions skill, "Multiple upstream lines" and "Groups, lines and selection" -- a
  #       variant-only line (rust-cross's `cross`) joins its product's group; the line member always
  #       exports <cmd>-<line>, and the bare name belongs to the group's selected member.
  set -- --stage "$OUT" --product "$PRODUCT" --name "Mavericks Swift Toolchain (cross)" --group swift --line cross \
    --version "$VERSION" "$@"
fi
if [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
elif [ "${REQUIRE_UPDATER:-}" = 1 ]; then
  echo "no updater app at $UPD_APP, and REQUIRE_UPDATER=1: a release never ships without its updater -- build it: shipyard-cmake --build \"\$SWIFT_BUILD/build/updater-$TH_PAYLOAD\" --target $PRODUCT-updater" >&2
  exit 1
else
  echo "   (no updater app at $UPD_APP; packaging the toolchain only)"
fi
sh "$SHIPYARD/stage_product.sh" "$@"

pkgbuild --root "$OUT" --identifier "$IDENTIFIER" --version "$VERSION" \
  --scripts "$SCR" --install-location / "$DIST/$PRODUCT-component.pkg"
if [ "$PRODUCT" = swift-toolchain ]; then
  TITLE="Mavericks Swift Toolchain — a Swift compiler for OS X 10.9"; set -- --host-arch x86_64
else
  # It RUNS on an Apple-silicon Mac and only targets 10.9, so its floor is macOS 11.0, arm64: the floor
  # of clang22-cross and rust-cross, declared in INGREDIENTS.md (floor:swift-toolchain-cross-*.pkg).
  TITLE="Mavericks Swift Toolchain (cross) — builds OS X 10.9 programs on an Apple-silicon Mac"
  set -- --min-os 11.0 --host-arch arm64
fi
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENTIFIER" \
  --title "$TITLE" \
  --component "$DIST/$PRODUCT-component.pkg" \
  --out "$DIST/$NAME.pkg" \
  --resources "$RES" --welcome Welcome.html --license LICENSE.txt "$@" --require-scripts
# The component pkg has no install floor; only the product archive ships.
rm -f "$DIST/$PRODUCT-component.pkg"
echo "OK -> $DIST/$NAME.pkg"
