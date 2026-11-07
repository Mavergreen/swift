#!/bin/sh
# platform: host-agnostic
# usage: sh tests/compiler-patch-audit-test.sh
#   Compiler patch 0003 maps the compiler's runtime table to OS X 10.9, because the Swift runtime on a
#   Mavergreen 10.9 is the one its pkgs ship, and keeps closed every feature whose need is 10.9's own OS
#   (spec: the 2026-11-06 amendment, item 1). patches/compiler/0003-AUDIT.md classifies each feature of
#   the pinned FeatureAvailability.def; this test holds the patch to that list:
#     - every FEATURE( of the pinned .def has exactly one AUDIT row, and every row names one of them;
#     - a row is open (what it needs ships in our pkgs), closed (what it needs is the OS's) or
#       unreleased (upstream's FUTURE, left alone), and cites a backticked symbol;
#     - after the patch, every closed or unreleased feature reads FUTURE, and no open one does;
#     - every macOS entry of RuntimeVersions.def for a Swift version up to SWIFT_VERSION's (6.4) reads
#       (10, 9, 0), and any later one is upstream's;
#     - every file the patch touches carries its marker.
#   Where the pinned 10.9 SDK's stub libraries are cached (lib.sh's sdk109_stubs; MAVERICKS_SDK_CACHE),
#   every closed row's symbol must be absent from 10.9's libobjc and libSystem, and present in neither.
#   The pinned tree is build-toolchain.sh's fetched compiler source, COMPILER_SRC (default
#   $MAVERICKS_BUILD_ROOT/swift/work/swift-compiler), read patched or not: an unpatched one is patched in
#   a copy. SKIPs (77) when there is no fetched tree.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
SRC="${COMPILER_SRC:-$MAVERICKS_BUILD_ROOT/swift/work/swift-compiler}"
FA=include/swift/AST/FeatureAvailability.def
RV=include/swift/AST/RuntimeVersions.def
[ -f "$SRC/$FA" ] && [ -f "$SRC/$RV" ] || { echo "no fetched compiler source at $SRC (run build-toolchain.sh) -- skipping"; exit 77; }
PATCH="$REPO/patches/compiler/0003-runtime-versions-macos-10.9.patch"
AUDIT="$REPO/patches/compiler/0003-AUDIT.md"
MARK='Mavergreen: the 10.9 runtime is the pkgs'"'"
[ -f "$PATCH" ] || fail "no $PATCH"
[ -f "$AUDIT" ] || fail "no $AUDIT"
T="$(mktemp -d "${TMPDIR:-/tmp}/compiler-patch-audit.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# The files the patch touches, from its --no-prefix headers.
FILES="$(sed -n 's/^+++ \([^ 	]*\).*/\1/p' "$PATCH")"
[ -n "$FILES" ] || fail "read no file from $PATCH"
for f in $FILES; do
  [ -f "$SRC/$f" ] || fail "the patch touches $f, which $SRC lacks"
  mkdir -p "$T/p/$(dirname "$f")" && cp "$SRC/$f" "$T/p/$f"
done
if grep -q "$MARK" "$T/p/$FA"; then
  echo "-- $SRC is patched already (build-toolchain.sh's step 3)"
else
  echo "-- patching a copy of $SRC's files"
  ( cd "$T/p" && patch -p0 -N -F 0 --no-backup-if-mismatch -s -i "$PATCH" < /dev/null ) > "$T/out" 2>&1 \
    || fail "the patch does not apply to $SRC: $(cat "$T/out")"
fi
P="$T/p"

echo "-- every file the patch touches carries its marker"
for f in $FILES; do grep -q "$MARK" "$P/$f" || fail "$f lacks the marker \"$MARK\""; done

# FEATURE(Name, (M, m)) or FEATURE(Name, FUTURE): name and version, one per line, from a .def.
features() { awk '/^FEATURE\(/ { s = $0; sub(/^FEATURE\(/, "", s); n = s; sub(/,.*/, "", n)
  v = s; sub(/^[^,]*, */, "", v); sub(/\) *$/, "", v); gsub(/ /, "", v); print n, v }' "$1"; }
features "$SRC/$FA" | awk '{ print $1 }' | LC_ALL=C sort > "$T/names"
[ -s "$T/names" ] || fail "read no FEATURE( from $SRC/$FA"
[ "$(wc -l < "$T/names" | tr -d ' ')" = "$(grep -c '^FEATURE(' "$SRC/$FA")" ] || fail "could not read every FEATURE( of $FA"

# AUDIT rows: | `Name` | (M, m) or FUTURE | open/closed/unreleased | needs | readers |
awk -F'|' '/^\| *`[A-Za-z0-9]+` *\|/ {
  n = $2; gsub(/[ `]/, "", n); s = $4; gsub(/[ *]/, "", s); printf "%s %s\n", n, s
  if ($5 !~ /`[^`]+`/) printf "NOSYMBOL %s\n", n > "/dev/stderr"
}' "$AUDIT" > "$T/rows" 2> "$T/nosym"

echo "-- one AUDIT row per FEATURE( of the pinned .def ($(wc -l < "$T/names" | tr -d ' ') features)"
awk '{ print $1 }' "$T/rows" | LC_ALL=C sort > "$T/rownames"
dup="$(uniq -d "$T/rownames")"; [ -z "$dup" ] || fail "more than one AUDIT row for: $dup"
miss="$(LC_ALL=C comm -23 "$T/names" "$T/rownames")"; [ -z "$miss" ] || fail "no AUDIT row for: $(echo $miss)"
extra="$(LC_ALL=C comm -13 "$T/names" "$T/rownames")"; [ -z "$extra" ] || fail "AUDIT rows for no FEATURE( of the .def: $(echo $extra)"
bad="$(awk '$2 != "open" && $2 != "closed" && $2 != "unreleased" { print $1 "=" $2 }' "$T/rows")"
[ -z "$bad" ] || fail "rows neither open, closed nor unreleased: $(echo $bad)"
[ ! -s "$T/nosym" ] || fail "rows that cite no backticked symbol: $(awk '{ print $2 }' "$T/nosym" | tr '\n' ' ')"

echo "-- closed and unreleased features read FUTURE after the patch; open ones do not"
features "$P/$FA" > "$T/patched"
while read -r n s; do
  v="$(awk -v n="$n" '$1 == n { print $2 }' "$T/patched")"
  [ -n "$v" ] || fail "$n is not in the patched $FA"
  u="$(features "$SRC/$FA" | awk -v n="$n" '$1 == n { print $2 }')"
  case "$s" in
    closed) [ "$v" = FUTURE ] || fail "$n is closed in the AUDIT but reads $v in the patched $FA" ;;
    unreleased) [ "$v" = FUTURE ] && [ "$u" = FUTURE ] || fail "$n is unreleased in the AUDIT but upstream's reads $u, the patched $v" ;;
    open) [ "$v" != FUTURE ] || fail "$n is open in the AUDIT but reads FUTURE in the patched $FA"
          [ "$v" = "$u" ] || fail "$n is open, but the patch moved its version from $u to $v" ;;
  esac
done < "$T/rows"

echo "-- RuntimeVersions.def: every macOS entry up to 6.4 reads (10, 9, 0), later ones upstream's"
# One line per RUNTIME_VERSION: "<major> <minor> <macOS version>".
rv() { awk '
  /^RUNTIME_VERSION\(/ { inv = 1; next }
  inv && /^ *\([0-9]+, *[0-9]+\),/ { s = $0; gsub(/[ (),]/, " ", s); split(s, a, " "); maj = a[1]; min = a[2]; next }
  inv && /PLATFORM\(macOS,/ { v = $0; sub(/.*PLATFORM\(macOS, */, "", v); sub(/\) *$/, "", v); gsub(/ /, "", v); print maj, min, v }
  /^\)/ { inv = 0 }' "$1"; }
rv "$SRC/$RV" > "$T/rv-up"; rv "$P/$RV" > "$T/rv-p"
[ -s "$T/rv-p" ] || fail "read no macOS entry from the patched $RV"
[ "$(wc -l < "$T/rv-p" | tr -d " ")" = "$(grep -c '^RUNTIME_VERSION(' "$SRC/$RV")" ] || fail "not every RUNTIME_VERSION of $RV has one macOS entry"
n=0
while read -r maj min v; do
  n=$((n + 1)); up="$(sed -n "${n}p" "$T/rv-up")"
  if [ "$maj" -lt 6 ] || { [ "$maj" -eq 6 ] && [ "$min" -le 4 ]; }; then
    [ "$v" = "(10,9,0)" ] || fail "Swift $maj.$min's macOS entry reads $v, not (10, 9, 0)"
  else
    [ "$maj $min $v" = "$up" ] || fail "Swift $maj.$min's macOS entry is not upstream's ($up)"
  fi
done < "$T/rv-p"

STUBS="${MAVERICKS_SDK_CACHE:-$HOME/Library/Caches/mavericks-sdk}/stubs/MacOSX10.9.sdk/usr/lib"
NM="${NM:-nm}"
if [ -f "$STUBS/libobjc.A.dylib" ] && "$NM" -gU "$STUBS/libobjc.A.dylib" > "$T/objc.nm" 2>/dev/null && [ -s "$T/objc.nm" ]; then
  echo "-- every closed row's symbol is absent from 10.9's libobjc and libSystem ($STUBS)"
  for d in "$STUBS"/system/*.dylib "$STUBS/libSystem.B.dylib"; do "$NM" -gU "$d" 2>/dev/null; done > "$T/sys.nm"
  awk -F'|' '/^\| *`[A-Za-z0-9]+` *\|/ { s = $4; gsub(/[ *]/, "", s); if (s != "closed") next
    n = $2; gsub(/[ `]/, "", n); x = $5; sub(/^[^`]*`/, "", x); sub(/`.*/, "", x); print n, x }' "$AUDIT" > "$T/closed"
  while read -r n sym; do
    if grep -q " _$sym\$" "$T/objc.nm" "$T/sys.nm"; then fail "$n is closed for $sym, which 10.9 exports"; fi
  done < "$T/closed"
else
  echo "-- (no cached 10.9 SDK stubs at $STUBS: the closed rows' symbols are not checked against 10.9)"
fi
echo "PASS"
