#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild make the fixture archives that pkgutil expands
# usage: sh tests/pkg-extract-test.sh
#   lib.sh's pkg_extract_product must lay out, from a product archive shaped like this repo's pkgs (the
#   family's base component first, then the product's, with an updater under Library/), exactly the
#   product's /usr/local/mavergreen/<product> tree, its links and modes kept, replacing what the dir
#   held; and refuse an archive no component of which installs that product, or more than one does.
#   CI's build job and the 10.9 acceptance read the release's own pkgs with it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v pkgbuild >/dev/null 2>&1 && command -v productbuild >/dev/null 2>&1 || { echo "no pkgbuild -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pkg-extract.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/scripts/outdir.sh"
. "$REPO/lib.sh"
component() {  # component <name> <root>
  pkgbuild --quiet --root "$2" --identifier "dev.mavergreen.$1" --version 1 --install-location / "$T/$1.pkg" || fail "pkgbuild $1"
}
mkdir -p "$T/base/usr/local/mavergreen/share" "$T/tc/usr/local/mavergreen/swift-toolchain/bin" "$T/tc/Library/Application Support/x"
echo base > "$T/base/usr/local/mavergreen/share/base.txt"
printf '#!/bin/sh\necho swiftc\n' > "$T/tc/usr/local/mavergreen/swift-toolchain/bin/swiftc"; chmod 755 "$T/tc/usr/local/mavergreen/swift-toolchain/bin/swiftc"
echo clang > "$T/tc/usr/local/mavergreen/swift-toolchain/bin/clang"; ln -s clang "$T/tc/usr/local/mavergreen/swift-toolchain/bin/clang++"
echo updater > "$T/tc/Library/Application Support/x/updater"
component base "$T/base"; component swift-toolchain "$T/tc"
productbuild --quiet --package "$T/base.pkg" --package "$T/swift-toolchain.pkg" "$T/product.pkg" || fail "productbuild"

echo "-- the product's tree alone, links and modes kept, replacing the dir"
mkdir -p "$T/out/stale"
got="$(pkg_extract_product "$T/product.pkg" swift-toolchain "$T/out")" || fail "pkg_extract_product failed"
[ "$got" = "$T/out/usr/local/mavergreen/swift-toolchain" ] || fail "printed '$got'"
[ "$(cd "$T/out" && find . ! -type d | sort | tr '\n' ' ')" = "./usr/local/mavergreen/swift-toolchain/bin/clang ./usr/local/mavergreen/swift-toolchain/bin/clang++ ./usr/local/mavergreen/swift-toolchain/bin/swiftc " ] \
  || fail "extracted $(cd "$T/out" && find . ! -type d | sort | tr '\n' ' ')"
[ "$(readlink "$got/bin/clang++")" = clang ] || fail "bin/clang++ is not a link to clang"
[ -x "$got/bin/swiftc" ] && [ "$("$got/bin/swiftc")" = swiftc ] || fail "bin/swiftc lost its mode"
[ ! -e "$T/out.x" ] || fail "left its scratch dir $T/out.x"

echo "-- refused: no component installs the product, or two do"
if pkg_extract_product "$T/product.pkg" swift-toolchain-cross "$T/out2" > /dev/null 2> "$T/err"; then fail "found a product the archive lacks"; fi
grep -q 'no component of .* installs /usr/local/mavergreen/swift-toolchain-cross' "$T/err" || fail "did not say so: $(cat "$T/err")"
mkdir -p "$T/tc2/usr/local/mavergreen/swift-toolchain/bin"; echo other > "$T/tc2/usr/local/mavergreen/swift-toolchain/bin/swiftc"
component other "$T/tc2"
productbuild --quiet --package "$T/swift-toolchain.pkg" --package "$T/other.pkg" "$T/two.pkg" || fail "productbuild two"
if pkg_extract_product "$T/two.pkg" swift-toolchain "$T/out3" > /dev/null 2> "$T/err"; then fail "picked one of two components"; fi
grep -q 'more than one component' "$T/err" || fail "did not say so: $(cat "$T/err")"
if pkg_extract_product "$T/product.pkg" swift-toolchain out4 > /dev/null 2>&1; then fail "accepted a relative dir"; fi
mkdir -p "$T/home/keep"; echo kept > "$T/home/keep/f"
if HOME="$T/home" pkg_extract_product "$T/product.pkg" swift-toolchain "$T/home" > /dev/null 2> "$T/err"; then fail "accepted \$HOME as the dir"; fi
grep -q 'it is \$HOME' "$T/err" || fail "did not say \$HOME: $(cat "$T/err")"
[ -f "$T/home/keep/f" ] || fail "removed \$HOME's files"
if pkg_extract_product "$T/product.pkg" swift-toolchain / > /dev/null 2> "$T/err"; then fail "accepted / as the dir"; fi
grep -q "refusing out-dir" "$T/err" || fail "did not refuse /: $(cat "$T/err")"
echo "PASS"
