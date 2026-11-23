#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pkg-extract-test.sh
#   lib.sh's pkg_extract_product must lay out, from a product archive shaped like this repo's pkgs (the
#   family's base component first, then the product's, with an updater under Library/), exactly the
#   product's /usr/local/mavergreen/<product> tree, its links and modes kept, replacing what the dir
#   held; and refuse an archive no component of which installs that product, or more than one does.
#   It reads the archive with shipyard's stevedore (fetch_stevedore.sh), on a Mac and on Linux alike,
#   never with pkgutil or ditto: here a stevedore on PATH (the pinned one, which STEVEDORE names) logs
#   each call, and a pkgutil, ditto and lsbom on PATH fail, logging theirs. The fixtures are made with
#   stevedore too. CI's build job and the 10.9 acceptance read the release's own pkgs with it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pkg-extract.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/msc.sh"    # -> $SHIPYARD (fetch_stevedore.sh)
REAL="$(sh "$SHIPYARD/fetch_stevedore.sh")" || fail "shipyard's fetch_stevedore.sh found no stevedore"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "stevedore $*" >> "%s/log"\nexec "%s" "$@"\n' "$T" "$REAL" > "$T/bin/stevedore"
for c in pkgutil ditto lsbom; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/log"\nexit 1\n' "$c" "$T" > "$T/bin/$c"
done
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"; STEVEDORE="$T/bin/stevedore"; export PATH STEVEDORE
. "$REPO/scripts/outdir.sh"
. "$REPO/lib.sh"
component() {  # component <name> <root>
  "$REAL" component --root "$2" --identifier "dev.mavergreen.$1" --version 1 --install-location / \
    --mtime 1700000000 --out "$T/$1.pkg" > /dev/null || fail "stevedore component $1"
}
product() {  # product <out> <component>... -- a product archive of the components, in that order
  _o="$1"; shift
  { echo '<?xml version="1.0" encoding="utf-8"?>'; echo '<installer-gui-script minSpecVersion="1">'
    for _c; do echo "  <pkg-ref id=\"dev.mavergreen.$_c\" version=\"1\">$_c.pkg</pkg-ref>"; done
    echo '  <choices-outline><line choice="c"/></choices-outline>'; echo '  <choice id="c">'
    for _c; do echo "    <pkg-ref id=\"dev.mavergreen.$_c\"/>"; done
    echo '  </choice>'; echo '</installer-gui-script>'; } > "$T/$_o.xml"
  _args=""; for _c; do _args="$_args --package $T/$_c.pkg"; done
  # shellcheck disable=SC2086  # $T holds no space (mktemp's template)
  "$REAL" product --distribution "$T/$_o.xml" $_args --mtime 1700000000 --out "$T/$_o.pkg" > /dev/null \
    || fail "stevedore product $_o"
}
mkdir -p "$T/base/usr/local/mavergreen/share" "$T/tc/usr/local/mavergreen/swift-toolchain/bin" "$T/tc/Library/Application Support/x"
echo base > "$T/base/usr/local/mavergreen/share/base.txt"
printf '#!/bin/sh\necho swiftc\n' > "$T/tc/usr/local/mavergreen/swift-toolchain/bin/swiftc"; chmod 755 "$T/tc/usr/local/mavergreen/swift-toolchain/bin/swiftc"
echo clang > "$T/tc/usr/local/mavergreen/swift-toolchain/bin/clang"; chmod 644 "$T/tc/usr/local/mavergreen/swift-toolchain/bin/clang"
ln -s clang "$T/tc/usr/local/mavergreen/swift-toolchain/bin/clang++"
echo updater > "$T/tc/Library/Application Support/x/updater"
component base "$T/base"; component swift-toolchain "$T/tc"
product product base swift-toolchain
: > "$T/log"

echo "-- the product's tree alone, links and modes kept, replacing the dir; read by stevedore alone"
mkdir -p "$T/out/stale"
got="$(pkg_extract_product "$T/product.pkg" swift-toolchain "$T/out")" || fail "pkg_extract_product failed: $(cat "$T/log")"
[ "$got" = "$T/out/usr/local/mavergreen/swift-toolchain" ] || fail "printed '$got'"
[ "$(cd "$T/out" && find . ! -type d | sort | tr '\n' ' ')" = "./usr/local/mavergreen/swift-toolchain/bin/clang ./usr/local/mavergreen/swift-toolchain/bin/clang++ ./usr/local/mavergreen/swift-toolchain/bin/swiftc " ] \
  || fail "extracted $(cd "$T/out" && find . ! -type d | sort | tr '\n' ' ')"
[ "$(readlink "$got/bin/clang++")" = clang ] || fail "bin/clang++ is not a link to clang"
[ -x "$got/bin/swiftc" ] && [ "$("$got/bin/swiftc")" = swiftc ] || fail "bin/swiftc lost its mode"
[ ! -x "$got/bin/clang" ] || fail "bin/clang gained an execute bit"
[ ! -e "$T/out.x" ] || fail "left its scratch dir $T/out.x"
grep -qx "stevedore expand $T/product.pkg $T/out.x/pkg" "$T/log" || fail "did not expand the pkg with stevedore: $(cat "$T/log")"
if grep -Eq '^(pkgutil|ditto|lsbom) ' "$T/log"; then fail "ran a macOS-only reader: $(grep -E '^(pkgutil|ditto|lsbom) ' "$T/log")"; fi

echo "-- refused: no component installs the product, or two do"
if pkg_extract_product "$T/product.pkg" swift-toolchain-cross "$T/out2" > /dev/null 2> "$T/err"; then fail "found a product the archive lacks"; fi
grep -q 'no component of .* installs /usr/local/mavergreen/swift-toolchain-cross' "$T/err" || fail "did not say so: $(cat "$T/err")"
mkdir -p "$T/tc2/usr/local/mavergreen/swift-toolchain/bin"; echo other > "$T/tc2/usr/local/mavergreen/swift-toolchain/bin/swiftc"
component other "$T/tc2"
product two swift-toolchain other
if pkg_extract_product "$T/two.pkg" swift-toolchain "$T/out3" > /dev/null 2> "$T/err"; then fail "picked one of two components"; fi
grep -q 'more than one component' "$T/err" || fail "did not say so: $(cat "$T/err")"
if pkg_extract_product "$T/product.pkg" swift-toolchain out4 > /dev/null 2>&1; then fail "accepted a relative dir"; fi
mkdir -p "$T/home/keep"; echo kept > "$T/home/keep/f"
if HOME="$T/home" pkg_extract_product "$T/product.pkg" swift-toolchain "$T/home" > /dev/null 2> "$T/err"; then fail "accepted \$HOME as the dir"; fi
grep -q 'it is \$HOME' "$T/err" || fail "did not say \$HOME: $(cat "$T/err")"
[ -f "$T/home/keep/f" ] || fail "removed \$HOME's files"
if pkg_extract_product "$T/product.pkg" swift-toolchain / > /dev/null 2> "$T/err"; then fail "accepted / as the dir"; fi
grep -q "refusing out-dir" "$T/err" || fail "did not refuse /: $(cat "$T/err")"

echo "-- refused: an archive stevedore cannot read, and no shipyard to find stevedore with"
echo 'not a pkg' > "$T/junk.pkg"
if pkg_extract_product "$T/junk.pkg" swift-toolchain "$T/out5" > /dev/null 2> "$T/err"; then fail "extracted a file that is no pkg"; fi
grep -q 'stevedore could not expand' "$T/err" || fail "did not say so: $(cat "$T/err")"
if ( SHIPYARD=""; pkg_extract_product "$T/product.pkg" swift-toolchain "$T/out6" ) > /dev/null 2> "$T/err"; then fail "ran without \$SHIPYARD"; fi
grep -q 'msc.sh' "$T/err" || fail "did not say to source msc.sh: $(cat "$T/err")"
if grep -Eq '^(pkgutil|ditto|lsbom) ' "$T/log"; then fail "ran a macOS-only reader: $(grep -E '^(pkgutil|ditto|lsbom) ' "$T/log")"; fi
echo "PASS"
