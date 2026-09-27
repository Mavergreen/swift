#!/bin/sh
# platform: macOS-only -- pkgbuild builds, and pkgutil expands, the pkg under test
# usage: sh tests/stage-and-package-test.sh   (from the repo root, as run-repo-tests.sh runs it)
#   Stages a fake build with scripts/stage-runtime.sh, packages it with package.sh, and checks the
#   payload is exactly the runtime prefix and its manifest (plus, when an updater is staged, the
#   updater and LaunchAgent the registry derives), and passes artifact conformance with no deviation.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
command -v pkgbuild >/dev/null 2>&1 || { echo "no pkgbuild (not macOS) -- skipping"; exit 77; }
. "$REPO/msc.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f scripts/stage-runtime.sh ] || fail "no scripts/stage-runtime.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/stage-and-package.XXXXXX")"
trap 'rm -rf "$T"' EXIT
P=usr/local/mavergreen/swift-runtime

mkdir -p "$T/built"
printf 'int f(void){return 0;}\n' > "$T/f.c"
for lib in libswiftCore libswiftSwiftOnoneSupport; do
  cc -dynamiclib -arch x86_64 -mmacosx-version-min=10.9 -install_name "@rpath/$lib.dylib" \
    -o "$T/built/$lib.dylib" "$T/f.c"
done

echo "-- staging refuses a build with no libswiftSwiftOnoneSupport.dylib"
mkdir -p "$T/partial"; cp "$T/built/libswiftCore.dylib" "$T/partial/"
if sh scripts/stage-runtime.sh "$T/partial" "$T/out-partial" LICENSE 2> "$T/partial.err"; then
  fail "stage-runtime.sh succeeded without libswiftSwiftOnoneSupport.dylib"
fi
grep -q 'has no libswiftSwiftOnoneSupport.dylib' "$T/partial.err" \
  || fail "stage-runtime.sh failed, but not for the missing dylib: $(cat "$T/partial.err")"

echo "-- staging refuses an empty out-dir, or / by any name, before writing anything"
# Every command that writes is faked (and fails), so a regressed guard fails this test instead of
# deleting /usr or writing into a writable /usr/local. $T/rootchild/.. is / only physically (as rm
# resolves it); /tmp/.. is / only logically on macOS, where /tmp is a symlink into /private.
mkdir -p "$T/fakebin"
for c in rm mkdir cp mv ln chmod; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/writes.log"\nexit 1\n' "$c" "$T" > "$T/fakebin/$c"; chmod +x "$T/fakebin/$c"
done
ln -s /bin "$T/rootchild"
for bad in "" // /. /tmp/.. "$T/rootchild/.."; do
  rc=0; PATH="$T/fakebin:$PATH" sh scripts/stage-runtime.sh "$T/built" "$bad" LICENSE 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "stage-runtime.sh out-dir '$bad': exit $rc, not 2 (refused)"
  [ ! -f "$T/writes.log" ] || fail "stage-runtime.sh tried to write, with out-dir '$bad': $(cat "$T/writes.log")"
done

echo "-- package.sh refuses an OUT that has only the old /usr/lib/swift layout"
mkdir -p "$T/old/usr/lib/swift"; cp "$T/built/libswiftCore.dylib" "$T/old/usr/lib/swift/"
if OUT="$T/old" DIST="$T/dist-old" UPD_APP=/nonexistent sh ./package.sh > "$T/old.log" 2>&1; then
  fail "package.sh packaged an OUT with no $P"
fi
grep -q 'run build.sh' "$T/old.log" || fail "package.sh refused, but without saying to run build.sh"

echo "-- staging replaces whatever an earlier layout left in OUT"
# Two earlier layouts: the released one (usr/lib/swift + a doc dir), and the never-released interim
# usr/local/mavergreen-swift-runtime a local build.sh staged before the family's
# /usr/local/mavergreen/<product> layout; OUT persists between builds, so either can be there.
I=usr/local/mavergreen-swift-runtime
mkdir -p "$T/out/usr/lib/swift" "$T/out/usr/local/share/doc/mavericks-swift-runtime" \
  "$T/out/$I/lib/swift" "$T/out/Library/keep"
: > "$T/out/usr/lib/swift/libswiftCore.dylib"
: > "$T/out/usr/local/share/doc/mavericks-swift-runtime/LICENSE.txt"
: > "$T/out/$I/lib/swift/libswiftCore.dylib"
: > "$T/out/$I/LICENSE.txt"
: > "$T/out/LICENSE.txt"
sh scripts/stage-runtime.sh "$T/built" "$T/out" LICENSE
got="$(cd "$T/out" && find usr LICENSE.txt Library 2>/dev/null | sort)"
want="$(printf '%s\n' Library Library/keep usr usr/local usr/local/mavergreen "$P" "$P/lib" \
  "$P/lib/swift" "$P/lib/swift/libswiftCore.dylib" "$P/lib/swift/libswiftSwiftOnoneSupport.dylib" \
  "$P/share" "$P/share/doc" "$P/share/doc/LICENSE.txt" | sort)"
[ "$got" = "$want" ] || fail "staged tree is
$got
wanted
$want"
cmp -s LICENSE "$T/out/$P/share/doc/LICENSE.txt" || fail "staged LICENSE.txt is not this repo's LICENSE"

expand_pkg() {
  rm -rf "$2"; pkgutil --expand "$1" "$2" || fail "pkgutil --expand $1 failed"
  comp=""
  for c in "$2"/*.pkg; do
    if grep -q 'identifier="dev.mavergreen.swift-runtime"' "$c/PackageInfo"; then comp="$c"; fi
  done
  [ -n "$comp" ] || fail "$1 has no dev.mavergreen.swift-runtime component"
  first="$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$2/Distribution" | grep -vx default | head -n 1)"
  [ "$first" = dev.mavergreen.base ] || fail "$1's first choice is '$first', not dev.mavergreen.base"
  mkdir -p "$2/root"; tar -xf "$comp/Payload" -C "$2/root" || fail "cannot extract $comp/Payload"
  manifest="$2/root/$P/mavergreen.plist"
  [ -f "$manifest" ] || fail "$1 carries no $P/mavergreen.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :product' "$manifest")" = swift-runtime ] \
    || fail "the manifest does not name product swift-runtime"
}
# platform: a pkg built on a macOS 27 host whose files carry com.apple.provenance lists AppleDouble
#           ._* members for them; CI-built pkgs have none, and 10.9's installer lays down no ._ file.
payload_of() { lsbom -s "$comp/Bom" | grep -v '/\._' | sort; }
outside_of() { _i=0; while _v="$(/usr/libexec/PlistBuddy -c "Print :outside:$_i" "$1" 2>/dev/null)"; do echo "$_v"; _i=$((_i + 1)); done; }
want_payload="$(printf '%s\n' . ./usr ./usr/local ./usr/local/mavergreen "./$P" "./$P/lib" "./$P/lib/swift" \
  "./$P/lib/swift/libswiftCore.dylib" "./$P/lib/swift/libswiftSwiftOnoneSupport.dylib" \
  "./$P/share" "./$P/share/doc" "./$P/share/doc/LICENSE.txt" "./$P/mavergreen.plist" | sort)"

echo "-- package.sh stages the updater under the identity shipyard's registry derives for swift-runtime"
U="Library/Application Support/Mavergreen/swift-runtime-updater.app"
LA=Library/LaunchAgents/dev.mavergreen.swift-runtime-updatecheck.plist
FEED="$(sh "$SHIPYARD/product-name.sh" feed swift-runtime)" || fail "shipyard's registry derives no feed for swift-runtime"
case "$FEED" in
  https://github.com/Mavergreen/*/releases/latest/download/swift-runtime.xml) ;;
  *) fail "the registry derives the feed '$FEED', not a Mavergreen repo's /releases/latest/download/swift-runtime.xml" ;;
esac
A="$T/upd/swift-runtime-updater.app"
mkdir -p "$A/Contents/MacOS"
printf '#!/bin/sh\n' > "$A/Contents/MacOS/swift-runtime-updater"; chmod +x "$A/Contents/MacOS/swift-runtime-updater"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.mavergreen.swift-runtime.updater" \
  -c "Add :SUFeedURL string $FEED" "$A/Contents/Info.plist" >/dev/null
OUT="$T/out" DIST="$T/dist-upd" UPD_APP="$A" sh ./package.sh > "$T/pkg-upd.log" 2>&1 \
  || { cat "$T/pkg-upd.log" >&2; fail "package.sh failed with an updater"; }
pkg_upd="$(ls "$T/dist-upd"/swift-runtime-*.pkg)"
expand_pkg "$pkg_upd" "$T/x-upd"
payload="$(payload_of)"
want_upd="$(printf '%s\n' "$want_payload" ./Library "./Library/Application Support" \
  "./Library/Application Support/Mavergreen" "./$U" "./$U/Contents" "./$U/Contents/Info.plist" \
  "./$U/Contents/MacOS" "./$U/Contents/MacOS/swift-runtime-updater" ./Library/LaunchAgents "./$LA" | sort)"
[ "$payload" = "$want_upd" ] || fail "payload with an updater is
$payload
wanted
$want_upd"
[ "$(outside_of "$manifest" | sort)" = "$(printf '%s\n' "$LA" "$U" | sort)" ] \
  || fail "the manifest's outside is [$(outside_of "$manifest")], not the updater and its LaunchAgent"
[ "$(/usr/libexec/PlistBuddy -c 'Print :appcast' "$manifest")" = "$FEED" ] \
  || fail "the manifest's appcast is not $FEED"
grep -q dev.mavergreen.swift-runtime-updatecheck "$comp/Scripts/postinstall" \
  || fail "the postinstall does not load dev.mavergreen.swift-runtime-updatecheck"

echo "-- with REQUIRE_UPDATER=1, package.sh refuses to package without the updater, naming it"
rc=0; OUT="$T/out" DIST="$T/dist-noupd" UPD_APP="$T/missing/swift-runtime-updater.app" REQUIRE_UPDATER=1 \
  sh ./package.sh > "$T/noupd.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "package.sh packaged without the updater although REQUIRE_UPDATER=1"
grep -q "$T/missing/swift-runtime-updater.app" "$T/noupd.log" \
  || fail "package.sh refused, but did not name the missing updater: $(cat "$T/noupd.log")"
[ -z "$(ls "$T/dist-noupd"/swift-runtime-*.pkg 2>/dev/null)" ] || fail "package.sh left a pkg behind after refusing"

echo "-- package.sh packages exactly the prefix, with no updater left from an earlier run, run from /"
( cd / && OUT="$T/out" DIST="$T/dist" UPD_APP=/nonexistent sh "$REPO/package.sh" ) > "$T/pkg.log" 2>&1 \
  || { cat "$T/pkg.log" >&2; fail "package.sh failed on the staged layout"; }
pkg="$(ls "$T/dist"/swift-runtime-*.pkg)"
expand_pkg "$pkg" "$T/x"
payload="$(payload_of)"
[ "$payload" = "$want_payload" ] || fail "payload is
$payload
wanted
$want_payload"
[ -z "$(outside_of "$manifest")" ] || fail "with no updater the manifest's outside is not empty: $(outside_of "$manifest")"
[ -z "$(/usr/libexec/PlistBuddy -c 'Print :appcast' "$manifest" 2>/dev/null)" ] \
  || fail "with no updater the manifest names an appcast"

echo "-- the pkg passes artifact conformance with no install-path deviation of its own (the swift.org mirror's is scoped to its toolchain)"
if grep '^- install-path:' INGREDIENTS.md | grep -qv '^- install-path:Library/Developer/Toolchains/swift-\*\.xctoolchain/\*:'; then
  fail "INGREDIENTS.md declares an install-path deviation beyond the swift.org mirror's"
fi
version="$(basename "$pkg" .pkg)"; version="${version#swift-runtime-}"
conform() {
  facts="$(sh "$SHIPYARD/artifact-facts.sh" "$1" "$version")" || fail "artifact-facts.sh failed on $1"
  printf '%s\n' "$facts" | grep -qx end-of-facts || fail "artifact-facts.sh on $1 stopped early"
  printf '%s\n' "$facts" | sh "$SHIPYARD/check-artifact-conformance.sh" || fail "artifact conformance failed on $1"
}
conform "$T/dist"
sh "$SHIPYARD/stand-in-feeds.sh" "$T/dist-upd" "$version" || fail "stand-in-feeds.sh failed"
conform "$T/dist-upd"
echo "PASS"
