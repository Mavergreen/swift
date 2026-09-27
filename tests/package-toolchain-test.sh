#!/bin/sh
# platform: macOS-only -- pkgbuild builds, and pkgutil expands, the pkg under test; PlistBuddy reads its manifest
# usage: sh tests/package-toolchain-test.sh   (from the repo root, as run-repo-tests.sh runs it)
#   Packages a fake staged toolchain with package-toolchain.sh, run from another directory, and checks:
#   the payload is exactly the prefix, its manifest, and the updater and LaunchAgent shipyard's registry
#   derives for swift-toolchain; dev.mavergreen.base installs first; the manifest exports swiftc alone,
#   so the toolchain links beside an installed clang22, whose group owns clang, clang++ and ld64.lld;
#   REQUIRE_UPDATER=1 refuses without the updater; and the pkg passes artifact conformance.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
command -v pkgbuild >/dev/null 2>&1 || { echo "no pkgbuild (not macOS) -- skipping"; exit 77; }
. "$REPO/msc.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/package-toolchain.XXXXXX")"
trap 'rm -rf "$T"' EXIT
P=usr/local/mavergreen/swift-toolchain
FEED="$(sh "$SHIPYARD/product-name.sh" feed swift-toolchain)" \
  || fail "shipyard's registry does not know swift-toolchain (Task 7 registers it)"
[ "$FEED" = https://github.com/Mavergreen/swift/releases/latest/download/swift-toolchain.xml ] \
  || fail "the registry derives the feed '$FEED'"

O="$T/out"
mkdir -p "$O/$P/bin" "$O/$P/lib/swift/macosx" "$O/$P/share/doc"
cp toolchain/swiftc "$O/$P/bin/swiftc"
for f in swift-frontend ld64.lld clang; do echo "$f" > "$O/$P/bin/$f"; done
ln -s clang "$O/$P/bin/clang++"
printf 'int f(void){return 0;}\n' > "$T/f.c"
cc -dynamiclib -arch x86_64 -mmacosx-version-min=10.9 -install_name @rpath/libswiftCore.dylib \
  -o "$O/$P/lib/swift/macosx/libswiftCore.dylib" "$T/f.c"
cp LICENSE "$O/$P/share/doc/LICENSE.txt"
A="$T/upd/swift-toolchain-updater.app"
mkdir -p "$A/Contents/MacOS"
printf '#!/bin/sh\n' > "$A/Contents/MacOS/swift-toolchain-updater"; chmod +x "$A/Contents/MacOS/swift-toolchain-updater"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.mavergreen.swift-toolchain.updater" \
  -c "Add :SUFeedURL string $FEED" "$A/Contents/Info.plist" >/dev/null

echo "-- with REQUIRE_UPDATER=1 and no updater, it refuses, naming the updater"
rc=0; ( cd / && OUT="$O" DIST="$T/dist-noupd" UPD_APP="$T/missing/swift-toolchain-updater.app" REQUIRE_UPDATER=1 \
  sh "$REPO/package-toolchain.sh" ) > "$T/noupd.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "packaged without the updater although REQUIRE_UPDATER=1"
grep -q "$T/missing/swift-toolchain-updater.app" "$T/noupd.log" || fail "refused, but did not name the updater: $(cat "$T/noupd.log")"
[ -z "$(ls "$T/dist-noupd"/swift-toolchain-*.pkg 2>/dev/null)" ] || fail "left a pkg behind after refusing"

echo "-- packages the prefix, its manifest and the derived updater, run from /"
( cd / && OUT="$O" DIST="$T/dist" UPD_APP="$A" sh "$REPO/package-toolchain.sh" ) > "$T/pkg.log" 2>&1 \
  || { cat "$T/pkg.log" >&2; fail "package-toolchain.sh failed"; }
pkg="$(ls "$T/dist"/swift-toolchain-*.pkg)"
X="$T/x"; pkgutil --expand "$pkg" "$X" || fail "pkgutil --expand failed"
comp=""
for c in "$X"/*.pkg; do
  if grep -q 'identifier="dev.mavergreen.swift-toolchain"' "$c/PackageInfo"; then comp="$c"; fi
done
[ -n "$comp" ] || fail "no dev.mavergreen.swift-toolchain component"
first="$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$X/Distribution" | grep -vx default | head -n 1)"
[ "$first" = dev.mavergreen.base ] || fail "the first choice is '$first', not dev.mavergreen.base"
U="Library/Application Support/Mavergreen/swift-toolchain-updater.app"
LA=Library/LaunchAgents/dev.mavergreen.swift-toolchain-updatecheck.plist
# platform: a pkg built on a macOS 27 host whose files carry com.apple.provenance lists AppleDouble
#           ._* members for them; CI-built pkgs have none, and 10.9's installer lays down no ._ file.
got="$(lsbom -s "$comp/Bom" | grep -v '/\._' | sort)"
want="$(printf '%s\n' . ./usr ./usr/local ./usr/local/mavergreen "./$P" "./$P/bin" "./$P/bin/clang" \
  "./$P/bin/clang++" "./$P/bin/ld64.lld" "./$P/bin/swift-frontend" "./$P/bin/swiftc" "./$P/lib" "./$P/lib/swift" \
  "./$P/lib/swift/macosx" "./$P/lib/swift/macosx/libswiftCore.dylib" "./$P/mavergreen.plist" "./$P/share" \
  "./$P/share/doc" "./$P/share/doc/LICENSE.txt" ./Library "./Library/Application Support" \
  "./Library/Application Support/Mavergreen" "./$U" "./$U/Contents" "./$U/Contents/Info.plist" \
  "./$U/Contents/MacOS" "./$U/Contents/MacOS/swift-toolchain-updater" ./Library/LaunchAgents "./$LA" | sort)"
[ "$got" = "$want" ] || fail "payload is
$got
wanted
$want"
V="$T/vol"; mkdir -p "$V"; tar -xf "$comp/Payload" -C "$V" || fail "cannot extract the payload"
M="$V/$P/mavergreen.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$M" 2>/dev/null; }
[ "$(pb product)" = swift-toolchain ] || fail "the manifest's product is '$(pb product)'"
[ "$(pb group)" = swift ] || fail "the manifest's group is '$(pb group)', not swift"
[ "$(pb appcast)" = "$FEED" ] || fail "the manifest's appcast is '$(pb appcast)'"
ex=""; i=0; while e="$(pb "exports-exclude:$i")"; do ex="$ex$e "; i=$((i + 1)); done
[ "$ex" = "bin/swift-frontend bin/ld64.lld bin/clang bin/clang++ " ] || fail "the manifest excludes [$ex]"

echo "-- beside an installed clang22, linking exports swiftc alone and takes none of clang22's names"
C="$T/c22"; mkdir -p "$C/usr/local/mavergreen/clang22/bin"
for f in clang clang++ ld64.lld; do : > "$C/usr/local/mavergreen/clang22/bin/$f"; done
sh "$SHIPYARD/render-manifest.sh" --stage "$C" --product clang22 --name "Clang 22" \
  --version 22.1.1-mavericks.5 --group clang --line 22 >/dev/null || fail "render-manifest.sh failed for the fake clang22"
cp -R "$C/usr/local/mavergreen/clang22" "$V/usr/local/mavergreen/"
MG="$SHIPYARD/mavergreen.sh"
sh "$MG" --root "$V" link clang22 || fail "could not link the fake clang22"
sh "$MG" --root "$V" link swift-toolchain 2> "$T/link.err" \
  || fail "linking swift-toolchain beside clang22 was refused: $(cat "$T/link.err")"
F="$V/usr/local/mavergreen/bin"
[ "$(readlink "$F/swiftc")" = ../swift-toolchain/bin/swiftc ] || fail "bin/swiftc links to '$(readlink "$F/swiftc")'"
for n in clang clang++ ld64.lld; do
  [ "$(readlink "$F/$n")" = "../clang22/bin/$n" ] || fail "bin/$n links to '$(readlink "$F/$n")', not clang22's"
done
[ ! -e "$F/swift-frontend" ] && [ ! -L "$F/swift-frontend" ] || fail "exported swift-frontend"

echo "-- passes artifact conformance (its stdlib dylib by the scoped sdk-pin deviation)"
version="$(basename "$pkg" .pkg)"; version="${version#swift-toolchain-}"
sh "$SHIPYARD/stand-in-feeds.sh" "$T/dist" "$version" || fail "stand-in-feeds.sh failed"
facts="$(sh "$SHIPYARD/artifact-facts.sh" "$T/dist" "$version")" || fail "artifact-facts.sh failed"
printf '%s\n' "$facts" | grep -qx end-of-facts || fail "artifact-facts.sh stopped early"
printf '%s\n' "$facts" | sh "$SHIPYARD/check-artifact-conformance.sh" || fail "artifact conformance failed"
echo "PASS"
