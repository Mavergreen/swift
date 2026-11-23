#!/bin/sh
# platform: host-agnostic -- shipyard's fetch_product_pkg.sh reads the pkg (stevedore); a Mac also reads the receipt
#   usage: fetch-recaulk.sh
#          Prints the prefix of Recaulk, the family's library of back-filled OS APIs (lib/librecaulk.a, from
#          which build.sh links the definitions libswiftCore takes, and share/recaulk/notices.tsv, the
#          notices of its members, which build.sh's step 7 holds the dylibs and NOTICE to; the release's
#          recaulk-notices.tsv asset is the same file, and the pkg's copy is verified with the pkg; and
#          share/recaulk/image-local-shadows.txt, the hidden copies of 10.9's own exports its members may
#          carry, which build.sh's recaulk_subset admits), at pins.env's RECAULK_VERSION. An
#          installed /usr/local/mavergreen/recaulk at that version is used as is; otherwise shipyard's
#          fetch_product_pkg.sh downloads the release's .pkg, verifies it against that release's own
#          SHA256SUMS, and unpacks it into ~/Library/Caches/mavergreen-recaulk (~/.cache/mavergreen-recaulk
#          on Linux, where no pkg receipt says what is installed) without root. Everything but the prefix
#          goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_product_pkg.sh)
PREFIX=/usr/local/mavergreen/recaulk
ok() { [ -f "$1/lib/librecaulk.a" ] && [ -f "$1/share/recaulk/notices.tsv" ] && [ -f "$1/share/recaulk/image-local-shadows.txt" ]; }

have=""
if [ "$(uname -s)" = Darwin ]; then
  # platform: guarded macOS-only call -- the uname test above; a pkg receipt exists only on a Mac
  have="$(pkgutil --pkg-info dev.mavergreen.recaulk 2>/dev/null | sed -n 's/^version: //p')"
fi
if [ "$have" = "$RECAULK_VERSION" ] && ok "$PREFIX"; then
  echo "$PREFIX"; exit 0
fi

# platform: Linux keeps caches under XDG's cache home, as shipyard's fetchers do there.
case "$(uname -s)" in
  Linux) CACHE="${MAVERGREEN_RECAULK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mavergreen-recaulk}" ;;
  *) CACHE="${MAVERGREEN_RECAULK_CACHE:-$HOME/Library/Caches/mavergreen-recaulk}" ;;
esac
D="$CACHE/$RECAULK_VERSION/recaulk"
if ! ok "$D"; then
  mkdir -p "$(dirname "$D")"
  sh "$SHIPYARD/fetch_product_pkg.sh" recaulk "$RECAULK_VERSION" "$D" >/dev/null
  ok "$D" || { echo "fetch-recaulk: recaulk-$RECAULK_VERSION.pkg holds no lib/librecaulk.a, share/recaulk/notices.tsv or share/recaulk/image-local-shadows.txt -- payload layout changed?" >&2; exit 1; }
fi
echo "$D"
