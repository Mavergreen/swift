#!/bin/sh
# platform: macOS-only -- pkgutil expands mavericks-clang-22's installer
#   usage: fetch-clang22.sh
#          Prints the prefix of mavericks-clang-22's CROSS toolchain (arm64 host, default target
#          x86_64-apple-macos10.9) at pins.env's CLANG22_VERSION, with its 10.9 SDK wired. An installed
#          /usr/local/mavergreen/clang22-cross at that version whose SDK is wired is used as is;
#          otherwise shipyard's fetch_product_pkg.sh downloads the release's cross .pkg (cached in
#          ~/Library/Caches/mavergreen-pkgs), verifies it against that release's own SHA256SUMS, and
#          unpacks its toolchain component into ~/Library/Caches/mavericks-clang without root
#          (clang.cfg addresses everything <CFGDIR>-relative, so the tree works at any path).
#          Everything but the prefix goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_product_pkg.sh, fetch_sdk.sh)
PREFIX=/usr/local/mavergreen/clang22-cross
PKG="mavericks-clang-22-cross-$CLANG22_VERSION.pkg"

have="$(pkgutil --pkg-info dev.mavergreen.clang.clang22-cross 2>/dev/null | sed -n 's/^version: //p')"
if [ "$have" = "$CLANG22_VERSION" ] && [ -x "$PREFIX/bin/clang" ] && [ -d "$PREFIX/SDKs/MacOSX10.9.sdk" ]; then
  echo "$PREFIX"; exit 0
fi

CACHE="${MAVERICKS_CLANG_CACHE:-$HOME/Library/Caches/mavericks-clang}"
TC="$CACHE/$CLANG22_VERSION/cross"
if [ ! -x "$TC/bin/clang" ]; then
  # shipyard's fetch_product_pkg.sh: the release's pkg, verified against its own SHA256SUMS, and its
  # clang22-cross component (picked by identifier, from shipyard's registry) unpacked as $TC.
  mkdir -p "$(dirname "$TC")"
  sh "$SHIPYARD/fetch_product_pkg.sh" --asset "$PKG" clang22-cross "$CLANG22_VERSION" "$TC" >/dev/null
  [ -x "$TC/bin/clang" ] || { echo "fetch-clang22: $PKG's clang22-cross component holds no bin/clang -- payload layout changed?" >&2; exit 1; }
fi
# platform: the pkg installs SDKs as a link into /usr/local/mavergreen/var/clang22-cross, which an
#           unpacked copy lacks; clang.cfg looks for <CFGDIR>/../SDKs/MacOSX10.9.sdk.
if [ ! -d "$TC/SDKs/MacOSX10.9.sdk" ]; then
  [ -L "$TC/SDKs" ] && rm -f "$TC/SDKs"
  mkdir -p "$TC/SDKs"
  ln -sfn "$(sh "$SHIPYARD/fetch_sdk.sh")" "$TC/SDKs/MacOSX10.9.sdk"
fi
echo "$TC"
