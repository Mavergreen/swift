#!/bin/sh
# platform: host-agnostic -- shipyard's fetch_product_pkg.sh reads the pkg (stevedore); a Mac also reads the receipt
#   usage: fetch-libcxx22.sh
#          Prints the prefix of libcxx22, the family's shared libc++ (lib/libc++.1.dylib, whose install name
#          the runtime links), at pins.env's CLANG22_VERSION: one release run publishes clang22,
#          clang22-cross and libcxx22 under one version. An installed /usr/local/mavergreen/libcxx22 at that
#          version is used as is; otherwise shipyard's fetch_product_pkg.sh downloads the release's
#          libcxx22 .pkg, verifies it against that release's own SHA256SUMS, and unpacks it into
#          ~/Library/Caches/mavericks-clang (~/.cache/mavericks-clang on Linux, where no pkg receipt says
#          what is installed) without root. Everything but the prefix goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_product_pkg.sh)
PREFIX=/usr/local/mavergreen/libcxx22
PKG="libcxx22-$CLANG22_VERSION.pkg"
ok() { [ -f "$1/lib/libc++.1.dylib" ] && [ -f "$1/lib/libc++abi.1.dylib" ]; }

have=""
if [ "$(uname -s)" = Darwin ]; then
  # platform: guarded macOS-only call -- the uname test above; a pkg receipt exists only on a Mac
  have="$(pkgutil --pkg-info dev.mavergreen.clang.libcxx22 2>/dev/null | sed -n 's/^version: //p')"
fi
if [ "$have" = "$CLANG22_VERSION" ] && ok "$PREFIX"; then
  echo "$PREFIX"; exit 0
fi

# platform: Linux keeps caches under XDG's cache home, as shipyard's fetchers do there.
case "$(uname -s)" in
  Linux) CACHE="${MAVERICKS_CLANG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mavericks-clang}" ;;
  *) CACHE="${MAVERICKS_CLANG_CACHE:-$HOME/Library/Caches/mavericks-clang}" ;;
esac
D="$CACHE/$CLANG22_VERSION/libcxx22"
if ! ok "$D"; then
  mkdir -p "$(dirname "$D")"
  sh "$SHIPYARD/fetch_product_pkg.sh" --asset "$PKG" libcxx22 "$CLANG22_VERSION" "$D" >/dev/null
  ok "$D" || { echo "fetch-libcxx22: $PKG's libcxx22 component holds no lib/libc++.1.dylib and lib/libc++abi.1.dylib -- payload layout changed?" >&2; exit 1; }
fi
echo "$D"
