#!/bin/sh
# platform: host-agnostic
# usage: sh tests/compiler-patch-audit-test.sh
#   Compiler patch 0003 makes the compiler's runtime table depend on the target (spec: the 2026-11-06
#   amendment, item 1, and the maintainer's target-dependent refinement): for a macOS deployment target
#   below 10.14.4, whose clients load the Swift runtime the pkgs ship, every released Swift version is
#   available from 10.9; from 10.14.4, whose clients load the OS's, upstream's table holds exactly. What
#   the OS's libobjc provides keeps upstream's table on every target. The split is in one place,
#   lib/AST/Availability.cpp; patches/compiler/0003-AUDIT.md classifies each feature of the pinned
#   FeatureAvailability.def and each direct caller. This test holds the patch to that list:
#     - the patch leaves RuntimeVersions.def and FeatureAvailability.def as upstream wrote them;
#     - getSwiftAvailability() maps a released version (short of FUTURE) to 10.9 for a macOS target
#       below 10.14.4 and is upstream's otherwise; the feature getters (ASTContext.h's FEATURE) take
#       upstream's table, getOSSwiftAvailability(), for exactly isOSRuntimeFeature()'s features;
#     - every FEATURE( of the pinned .def has exactly one AUDIT row, open (what it needs ships in our
#       pkgs), closed (what it needs is the OS's) or unreleased (upstream's FUTURE), citing a backticked
#       symbol; the closed rows are exactly isOSRuntimeFeature()'s; no open row is FUTURE upstream, and
#       every unreleased one is;
#     - every closed direct caller in the AUDIT's callers table asks getOSSwiftAvailability() in its file;
#     - every file the patch touches carries its marker.
#   Where the pinned 10.9 SDK's stub libraries are cached (lib.sh's sdk109_stubs; MAVERICKS_SDK_CACHE),
#   every closed row's symbol must be absent from 10.9's libobjc and libSystem.
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
AV=lib/AST/Availability.cpp
AC=include/swift/AST/ASTContext.h
[ -f "$SRC/$FA" ] && [ -f "$SRC/$AV" ] || { echo "no fetched compiler source at $SRC (run build-toolchain.sh) -- skipping"; exit 77; }
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
echo "-- the patch leaves the table's two .def files upstream's"
for f in $FILES; do
  case "$f" in "$FA"|"$RV") fail "the patch edits $f: upstream's table must hold from 10.14.4" ;; esac
done
for f in $FILES; do
  [ -f "$SRC/$f" ] || fail "the patch touches $f, which $SRC lacks"
  mkdir -p "$T/p/$(dirname "$f")" && cp "$SRC/$f" "$T/p/$f"
done
case " $(echo $FILES) " in *" $AV "*) ;; *) fail "the patch does not touch $AV, where the split belongs" ;; esac
case " $(echo $FILES) " in *" $AC "*) ;; *) fail "the patch does not touch $AC, where the feature getters are" ;; esac
if grep -q "$MARK" "$T/p/$AV"; then
  echo "-- $SRC is patched already (build-toolchain.sh's step 3)"
else
  echo "-- patching a copy of $SRC's files"
  ( cd "$T/p" && patch -p0 -N -F 0 --no-backup-if-mismatch -s -i "$PATCH" < /dev/null ) > "$T/out" 2>&1 \
    || fail "the patch does not apply to $SRC: $(cat "$T/out")"
fi
P="$T/p"

echo "-- every file the patch touches carries its marker"
for f in $FILES; do grep -q "$MARK" "$P/$f" || fail "$f lacks the marker \"$MARK\""; done

# The body of one function of Availability.cpp, from its definition's line to the next line that is
# a lone "}".
body() { awk -v h="$1" 'index($0, h) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$P/$AV"; }

echo "-- the split: below macOS 10.14.4, a released version is available from 10.9; upstream's otherwise"
body 'static bool isMacOSTargetBeforeSwiftInTheOS(' > "$T/before"
grep -q 'target\.isMacOSX() && target\.isMacOSXVersionLT(10, 14, 4)' "$T/before" \
  || fail "isMacOSTargetBeforeSwiftInTheOS does not test for a macOS target below 10.14.4: $(cat "$T/before")"
body 'AvailabilityRange ASTContext::getSwiftAvailability(' > "$T/swift"
[ -s "$T/swift" ] || fail "no getSwiftAvailability in $AV"
grep -q 'auto upstream = getOSSwiftAvailability(major, minor);' "$T/swift" || fail "getSwiftAvailability does not start from upstream's table"
grep -q 'isMacOSTargetBeforeSwiftInTheOS(LangOpts\.Target)' "$T/swift" || fail "getSwiftAvailability does not split on the target"
grep -q 'getRawMinimumVersion() < llvm::VersionTuple(99, 99)' "$T/swift" || fail "getSwiftAvailability does not leave FUTURE alone"
grep -q 'VersionRange::allGTE(llvm::VersionTuple(10, 9, 0))' "$T/swift" || fail "getSwiftAvailability does not map to 10.9"
grep -q '^  return upstream;$' "$T/swift" || fail "getSwiftAvailability does not return upstream's otherwise"
[ "$(grep -c 'return' "$T/swift")" = 2 ] || fail "getSwiftAvailability has a return besides the two: $(cat "$T/swift")"
body 'AvailabilityRange ASTContext::getOSSwiftAvailability(' > "$T/os"
grep -q '#include "swift/AST/RuntimeVersions.def"' "$T/os" || fail "getOSSwiftAvailability is not upstream's table reader"

echo "-- the feature getters take upstream's table for exactly isOSRuntimeFeature's features"
awk '/^#define FEATURE\(N, V\)/ { p = 1 } p { print } p && !/\\$/ { exit }' "$P/$AC" > "$T/macro"
grep -q 'if (isOSRuntimeFeature(#N))' "$T/macro" && grep -q 'return getOSSwiftAvailability V;' "$T/macro" \
  && grep -q 'return getSwiftAvailability V;' "$T/macro" || fail "ASTContext.h's FEATURE does not split on isOSRuntimeFeature: $(cat "$T/macro")"
body 'bool ASTContext::isOSRuntimeFeature(' | sed -n 's/.*\.Case("\([A-Za-z0-9]*\)", true).*/\1/p' | LC_ALL=C sort > "$T/os-features"
[ -s "$T/os-features" ] || fail "isOSRuntimeFeature names no feature"
body 'bool ASTContext::isOSRuntimeFeature(' | grep -q '\.Default(false);' || fail "isOSRuntimeFeature does not default to false"

# FEATURE(Name, (M, m)) or FEATURE(Name, FUTURE): name and version, one per line, from a .def.
features() { awk '/^FEATURE\(/ { s = $0; sub(/^FEATURE\(/, "", s); n = s; sub(/,.*/, "", n)
  v = s; sub(/^[^,]*, */, "", v); sub(/\) *$/, "", v); gsub(/ /, "", v); print n, v }' "$1"; }
features "$SRC/$FA" > "$T/upstream"
awk '{ print $1 }' "$T/upstream" | LC_ALL=C sort > "$T/names"
[ -s "$T/names" ] || fail "read no FEATURE( from $SRC/$FA"
[ "$(wc -l < "$T/names" | tr -d ' ')" = "$(grep -c '^FEATURE(' "$SRC/$FA")" ] || fail "could not read every FEATURE( of $FA"
x="$(LC_ALL=C comm -23 "$T/os-features" "$T/names")"; [ -z "$x" ] || fail "isOSRuntimeFeature names no FEATURE( of the .def: $(echo $x)"

# AUDIT feature rows: | `Name` | (M, m) or FUTURE | open/closed/unreleased | needs | readers |
awk -F'|' '/^## Features/ { f = 1; next } /^## / { f = 0 } f && /^\| *`[A-Za-z0-9]+` *\|/ {
  n = $2; gsub(/[ `]/, "", n); s = $4; gsub(/\*/, "", s); sub(/^ */, "", s); sub(/[ (:;].*/, "", s); printf "%s %s\n", n, s
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

echo "-- the closed rows are exactly isOSRuntimeFeature's; open ones are released, unreleased ones FUTURE"
awk '$2 == "closed" { print $1 }' "$T/rows" | LC_ALL=C sort > "$T/closed-rows"
[ "$(cat "$T/closed-rows")" = "$(cat "$T/os-features")" ] \
  || fail "the AUDIT's closed rows [$(echo $(cat "$T/closed-rows"))] are not isOSRuntimeFeature's [$(echo $(cat "$T/os-features"))]"
while read -r n s; do
  u="$(awk -v n="$n" '$1 == n { print $2 }' "$T/upstream")"
  case "$s" in
    open|closed) [ "$u" != FUTURE ] || fail "$n is $s in the AUDIT but FUTURE upstream" ;;
    unreleased) [ "$u" = FUTURE ] || fail "$n is unreleased in the AUDIT but upstream's reads $u" ;;
  esac
done < "$T/rows"

echo "-- every closed direct caller asks upstream's table"
# AUDIT callers rows: | <File>.cpp:<line> ... | version | closed/open/n/a | ... |
awk -F'|' '/^## Callers/ { f = 1; next } /^## / { f = 0 } f && /^\| *[A-Za-z]+\.(cpp|h):[0-9]/ {
  c = $2; sub(/^ */, "", c); sub(/:.*/, "", c); s = $4; gsub(/\*/, "", s); sub(/^ */, "", s); sub(/[ (:;].*/, "", s); if (s == "closed") print c }' "$AUDIT" > "$T/closed-callers"
[ -s "$T/closed-callers" ] || fail "the AUDIT lists no closed direct caller"
while read -r c; do
  f=""; for g in $FILES; do case "$g" in */"$c") f="$g" ;; esac; done
  [ -n "$f" ] || fail "closed caller $c is in a file the patch does not touch"
  grep -q 'getOSSwiftAvailability(' "$P/$f" || fail "closed caller $c ($f) does not ask getOSSwiftAvailability()"
done < "$T/closed-callers"

STUBS="${MAVERICKS_SDK_CACHE:-$HOME/Library/Caches/mavericks-sdk}/stubs/MacOSX10.9.sdk/usr/lib"
NM="${NM:-nm}"
if [ -f "$STUBS/libobjc.A.dylib" ] && "$NM" -gU "$STUBS/libobjc.A.dylib" > "$T/objc.nm" 2>/dev/null && [ -s "$T/objc.nm" ]; then
  echo "-- every closed row's symbol is absent from 10.9's libobjc and libSystem ($STUBS)"
  for d in "$STUBS"/system/*.dylib "$STUBS/libSystem.B.dylib"; do "$NM" -gU "$d" 2>/dev/null; done > "$T/sys.nm"
  awk -F'|' '/^## Features/ { f = 1; next } /^## / { f = 0 } f && /^\| *`[A-Za-z0-9]+` *\|/ {
    s = $4; gsub(/\*/, "", s); sub(/^ */, "", s); sub(/[ (:;].*/, "", s); if (s != "closed") next
    n = $2; gsub(/[ `]/, "", n); x = $5; sub(/^[^`]*`/, "", x); sub(/`.*/, "", x); print n, x }' "$AUDIT" > "$T/closed"
  while read -r n sym; do
    if grep -q " _$sym\$" "$T/objc.nm" "$T/sys.nm"; then fail "$n is closed for $sym, which 10.9 exports"; fi
  done < "$T/closed"
else
  echo "-- (no cached 10.9 SDK stubs at $STUBS: the closed rows' symbols are not checked against 10.9)"
fi
echo "PASS"
