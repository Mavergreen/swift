#!/bin/sh
# platform: macOS-only -- pkgutil expands mavericks-clang-22's installer
#   usage: fetch-clang22.sh
#          Prints the prefix of mavericks-clang-22's CROSS toolchain (arm64 host, default target
#          x86_64-apple-macos10.9) at pins.env's CLANG22_VERSION, with its 10.9 SDK wired. An installed
#          /usr/local/mavergreen/clang22-cross at that version whose SDK is wired is used as is;
#          otherwise the release's cross .pkg is downloaded, verified against that release's own
#          SHA256SUMS, and its toolchain component unpacked into ~/Library/Caches/mavericks-clang
#          without root (clang.cfg addresses everything <CFGDIR>-relative, so the tree works at any
#          path). Everything but the prefix goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pins.env"
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_sdk.sh)
PREFIX=/usr/local/mavergreen/clang22-cross
REL="https://github.com/Mavergreen/clang-22/releases/download/$CLANG22_VERSION"
PKG="mavericks-clang-22-cross-$CLANG22_VERSION.pkg"

have="$(pkgutil --pkg-info dev.mavergreen.clang.clang22-cross 2>/dev/null | sed -n 's/^version: //p')"
if [ "$have" = "$CLANG22_VERSION" ] && [ -x "$PREFIX/bin/clang" ] && [ -d "$PREFIX/SDKs/MacOSX10.9.sdk" ]; then
  echo "$PREFIX"; exit 0
fi

CACHE="${MAVERICKS_CLANG_CACHE:-$HOME/Library/Caches/mavericks-clang}"
TC="$CACHE/$CLANG22_VERSION/cross"
if [ ! -x "$TC/bin/clang" ]; then
  mkdir -p "$CACHE"
  SUMS="$CACHE/$CLANG22_VERSION.SHA256SUMS"
  curl -fsSL --retry 3 --retry-delay 5 -o "$SUMS.tmp" "$REL/SHA256SUMS" && mv "$SUMS.tmp" "$SUMS"
  line="$(grep -E "  $PKG\$" "$SUMS" || true)"
  [ -n "$line" ] || { echo "fetch-clang22: $PKG is not listed in $CLANG22_VERSION's SHA256SUMS" >&2; exit 1; }
  [ -f "$CACHE/$PKG" ] || { curl -fSL --retry 3 --retry-delay 5 -o "$CACHE/$PKG.tmp" "$REL/$PKG" >&2 && mv "$CACHE/$PKG.tmp" "$CACHE/$PKG"; }
  ( cd "$CACHE" && printf '%s\n' "$line" | shasum -a 256 -c - ) >&2 || { rm -f "$CACHE/$PKG"; echo "fetch-clang22: checksum mismatch" >&2; exit 1; }
  TMP="$CACHE/.expand.$$"
  rm -rf "$TMP"
  trap 'rm -rf "$TMP"' EXIT INT TERM
  pkgutil --expand-full "$CACHE/$PKG" "$TMP" >&2
  # spec: shipyard set_install_floor.sh -- a family product archive holds dev.mavergreen.base and the
  #       product's own component; only the product's payload carries its prefix.
  PAYLOAD=""
  for c in "$TMP"/*.pkg; do
    if [ -x "$c/Payload$PREFIX/bin/clang" ]; then PAYLOAD="$c/Payload$PREFIX"; fi
  done
  [ -n "$PAYLOAD" ] || { echo "fetch-clang22: no component of $PKG holds $PREFIX/bin/clang -- payload layout changed?" >&2; exit 1; }
  rm -rf "$TC"; mkdir -p "$(dirname "$TC")"; mv "$PAYLOAD" "$TC"
  rm -rf "$TMP" "$CACHE/$PKG"; trap - EXIT INT TERM
fi
# platform: the pkg installs SDKs as a link into /usr/local/mavergreen/var/clang22-cross, which an
#           unpacked copy lacks; clang.cfg looks for <CFGDIR>/../SDKs/MacOSX10.9.sdk.
if [ ! -d "$TC/SDKs/MacOSX10.9.sdk" ]; then
  [ -L "$TC/SDKs" ] && rm -f "$TC/SDKs"
  mkdir -p "$TC/SDKs"
  ln -sfn "$(sh "$SHIPYARD/fetch_sdk.sh")" "$TC/SDKs/MacOSX10.9.sdk"
fi
echo "$TC"
