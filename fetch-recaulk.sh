#!/bin/sh
# platform: macOS-only -- pkgutil expands Recaulk's installer
#   usage: fetch-recaulk.sh
#          Prints the prefix of Recaulk, the family's library of back-filled OS APIs (lib/librecaulk.a, from
#          which build.sh links the definitions libswiftCore takes), at pins.env's RECAULK_VERSION. An
#          installed /usr/local/mavergreen/recaulk at that version is used as is; otherwise shipyard's
#          fetch_product_pkg.sh downloads the release's .pkg, verifies it against that release's own
#          SHA256SUMS, and unpacks it into ~/Library/Caches/mavergreen-recaulk without root. Everything
#          but the prefix goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_product_pkg.sh)
PREFIX=/usr/local/mavergreen/recaulk
ok() { [ -f "$1/lib/librecaulk.a" ]; }

have="$(pkgutil --pkg-info dev.mavergreen.recaulk 2>/dev/null | sed -n 's/^version: //p')"
if [ "$have" = "$RECAULK_VERSION" ] && ok "$PREFIX"; then
  echo "$PREFIX"; exit 0
fi

CACHE="${MAVERGREEN_RECAULK_CACHE:-$HOME/Library/Caches/mavergreen-recaulk}"
D="$CACHE/$RECAULK_VERSION/recaulk"
if ! ok "$D"; then
  mkdir -p "$(dirname "$D")"
  sh "$SHIPYARD/fetch_product_pkg.sh" recaulk "$RECAULK_VERSION" "$D" >/dev/null
  ok "$D" || { echo "fetch-recaulk: recaulk-$RECAULK_VERSION.pkg holds no lib/librecaulk.a -- payload layout changed?" >&2; exit 1; }
fi
echo "$D"
