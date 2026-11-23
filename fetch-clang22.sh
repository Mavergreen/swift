#!/bin/sh
# platform: host-agnostic -- Linux takes shipyard's fetch_clang22.sh; a Mac reads its pkg receipt with pkgutil
#   usage: fetch-clang22.sh
#          On Linux: prints the clang22 shipyard's fetch_clang22.sh gives for components/clang22 (whose
#          version must be pins.env's CLANG22_VERSION): install@v1's products: install at
#          /usr/local/mavergreen/clang22, else the release's linux-x86_64 archive, verified against its
#          SHA256SUMS. Every compile the build makes with it names the 10.9 SDK itself.
#          On a Mac: prints the prefix of mavericks-clang-22's CROSS toolchain (arm64 host, default target
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
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_product_pkg.sh, fetch_sdk.sh, fetch_clang22.sh)
if [ "$(uname -s)" = Linux ]; then
  # platform: clang-22 publishes no pkg for Linux but a linux-x86_64 archive, which shipyard's fetch_clang22.sh
  #           reads its release for from a pin directory, components/clang22.
  PIN="$(cat "$HERE/components/clang22/version")" || { echo "fetch-clang22: no $HERE/components/clang22/version" >&2; exit 1; }
  [ "$PIN" = "$CLANG22_VERSION" ] || {
    echo "fetch-clang22: components/clang22/version is $PIN, but pins.env's CLANG22_VERSION is $CLANG22_VERSION -- one release pins both" >&2; exit 1; }
  # platform: before shipyard v1.0.822 (whose install-products.sh came with it), its fetch_clang22.sh
  #           neither used install@v1's /usr/local/mavergreen/clang22 nor verified the archive against the
  #           release's SHA256SUMS: it wanted a components/clang22/linux-sha256 this repo does not keep.
  [ -f "$SHIPYARD/install-products.sh" ] || {
    echo "fetch-clang22: the shipyard at $SHIPYARD predates v1.0.822, whose fetch_clang22.sh this needs on Linux" >&2; exit 1; }
  exec sh "$SHIPYARD/fetch_clang22.sh" "$HERE/components/clang22"
fi
PREFIX=/usr/local/mavergreen/clang22-cross
PKG="mavericks-clang-22-cross-$CLANG22_VERSION.pkg"

# platform: guarded macOS-only call -- the Linux branch above has exec'd; this is a Mac
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
