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
#     - the same split for declarations (the maintainer's decision of 2026-11-08): below 10.14.4,
#       getPkgsRuntimeIntroduced() makes a declaration of the runtime pkg's own Swift modules (exactly
#       Swift, _Concurrency, SwiftOnoneSupport, _Builtin_float; never Darwin or ObjectiveC, whose
#       availability is the OS's APIs') introduced on macOS at a released runtime's macOS version
#       (read from RuntimeVersions.def, no version written in) available from 10.9, and the deserializer
#       applies it to every @available it reads, on macOS and anyAppleOS, before it makes the attribute;
#     - the split is written once (one isMacOSXVersionLT in Availability.cpp), and each test of it is
#       the exact line, so a negated or ||-ed condition fails;
#     - Span takes no exception: the rule opens it with SwiftStdlib 5.0's 10.14.4, and the runtime pkg
#       ships the library Core's $ld$previous names for it (PreviousModuleInstallName.json) as a link
#       to libswiftCore.dylib (scripts/stage-runtime.sh), as upstream's stdlib install does;
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
DS=lib/Serialization/Deserialization.cpp
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
case " $(echo $FILES) " in *" $DS "*) ;; *) fail "the patch does not touch $DS, where @available is read" ;; esac
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
body() { awk -v h="$1" 'index($0, h) == 1 { p = 1 } p { print } p && /^}/ { exit }' "${2:-$P/$AV}"; }
# has_line <file> <line>: <file> has a line that is exactly <line> (fixed string, whole line).
has_line() { grep -qxF -- "$2" "$1"; }

echo "-- the split: below macOS 10.14.4, a released version is available from 10.9; upstream's otherwise"
[ "$(grep -c 'isMacOSXVersionLT(' "$P/$AV")" = 1 ] \
  || fail "$AV tests a macOS version other than once: the split is written in one place: $(grep -n 'isMacOSXVersionLT(' "$P/$AV")"
body 'static bool isMacOSTargetBeforeSwiftInTheOS(' > "$T/before"
has_line "$T/before" '  return target.isMacOSX() && target.isMacOSXVersionLT(10, 14, 4);' \
  || fail "isMacOSTargetBeforeSwiftInTheOS does not test for exactly a macOS target below 10.14.4: $(cat "$T/before")"
body 'AvailabilityRange ASTContext::getSwiftAvailability(' > "$T/swift"
[ -s "$T/swift" ] || fail "no getSwiftAvailability in $AV"
grep -q 'auto upstream = getOSSwiftAvailability(major, minor);' "$T/swift" || fail "getSwiftAvailability does not start from upstream's table"
has_line "$T/swift" '  if (isMacOSTargetBeforeSwiftInTheOS(LangOpts.Target) &&' || fail "getSwiftAvailability does not split on the target, as the first of its conditions: $(cat "$T/swift")"
grep -q 'getRawMinimumVersion() < llvm::VersionTuple(99, 99)' "$T/swift" || fail "getSwiftAvailability does not leave FUTURE alone"
grep -q 'VersionRange::allGTE(llvm::VersionTuple(10, 9, 0))' "$T/swift" || fail "getSwiftAvailability does not map to 10.9"
grep -q '^  return upstream;$' "$T/swift" || fail "getSwiftAvailability does not return upstream's otherwise"
[ "$(grep -c 'return' "$T/swift")" = 2 ] || fail "getSwiftAvailability has a return besides the two: $(cat "$T/swift")"
body 'AvailabilityRange ASTContext::getOSSwiftAvailability(' > "$T/os"
grep -q '#include "swift/AST/RuntimeVersions.def"' "$T/os" || fail "getOSSwiftAvailability is not upstream's table reader"

echo "-- declarations: below 10.14.4, the runtime pkg's modules' released introductions are from 10.9"
body 'bool ASTContext::isPkgsRuntimeModule(' | sed -n 's/.*\.Case("\([A-Za-z0-9_]*\)", true).*/\1/p' | LC_ALL=C sort > "$T/modules"
[ "$(echo $(cat "$T/modules"))" = "Swift SwiftOnoneSupport _Builtin_float _Concurrency" ] \
  || fail "isPkgsRuntimeModule names [$(echo $(cat "$T/modules"))], not the runtime pkg's Swift modules: Swift, _Concurrency, SwiftOnoneSupport, _Builtin_float"
body 'bool ASTContext::isPkgsRuntimeModule(' | grep -q '\.Default(false);' || fail "isPkgsRuntimeModule does not default to false"
body 'bool ASTContext::isPkgsRuntimeModule(' > "$T/modsw"
[ "$(grep -c '\.Case(' "$T/modsw")" = 4 ] || fail "isPkgsRuntimeModule has other than 4 .Case( lines: $(cat "$T/modsw")"
x="$(grep -o '\.[A-Za-z]*(' "$T/modsw" | grep -vxF -e '.Case(' -e '.Default(' || true)"
[ -z "$x" ] || fail "isPkgsRuntimeModule's StringSwitch uses more than .Case and .Default(false): $(echo $x)"
[ "$(grep -c '\.Default(' "$T/modsw")" = 1 ] || fail "isPkgsRuntimeModule has other than one .Default(: $(cat "$T/modsw")"
body 'bool ASTContext::isPkgsRuntimeModule(' | grep -Eq '"(Darwin|ObjectiveC)"' && fail "isPkgsRuntimeModule names Darwin or ObjectiveC, whose availability is the OS's APIs'"
body 'ASTContext::getPkgsRuntimeIntroduced(' > "$T/decl"
[ -s "$T/decl" ] || fail "no getPkgsRuntimeIntroduced in $AV"
has_line "$T/decl" '  if (!isMacOSTargetBeforeSwiftInTheOS(LangOpts.Target) ||' \
  || fail "getPkgsRuntimeIntroduced does not return upstream's (none) for a target from 10.14.4 first: $(cat "$T/decl")"
has_line "$T/decl" '      !isPkgsRuntimeModule(module))' || fail "getPkgsRuntimeIntroduced does not return upstream's (none) outside the runtime pkg's modules"
grep -q '#include "swift/AST/RuntimeVersions.def"' "$T/decl" || fail "getPkgsRuntimeIntroduced does not read its versions from RuntimeVersions.def"
grep -q '^#define PLATFORM_macOS(V)' "$T/decl" || fail "getPkgsRuntimeIntroduced does not compare macOS's entries"
for p in iOS watchOS visionOS; do
  has_line "$T/decl" "#define PLATFORM_$p(V)" || fail "getPkgsRuntimeIntroduced compares $p's entries, not only macOS's"
done
grep -q '^#define FUTURE.*return' "$T/decl" && fail "getPkgsRuntimeIntroduced counts FUTURE as released"
x="$(grep -o 'VersionTuple([0-9][0-9, ]*)' "$T/decl" | grep -vxF 'VersionTuple(10, 9, 0)' || true)"
[ -z "$x" ] || fail "getPkgsRuntimeIntroduced writes a version in, not RuntimeVersions.def's: $(echo $x)"
grep -q 'return llvm::VersionTuple(10, 9, 0);' "$T/decl" || fail "getPkgsRuntimeIntroduced does not map to 10.9"
[ "$(grep -c 'return' "$T/decl")" = 3 ] || fail "getPkgsRuntimeIntroduced has a return besides upstream's twice and 10.9's: $(cat "$T/decl")"
grep -q 'CompatibilitySpan' "$T/decl" && fail "getPkgsRuntimeIntroduced makes an exception for Span: the runtime pkg ships its library"
body 'DeclDeserializer::readAvailable_DECL_ATTR(' "$P/$DS" > "$T/ds"
[ -s "$T/ds" ] || fail "no readAvailable_DECL_ATTR in $DS"
has_line "$T/ds" '    auto module = MF.getAssociatedModule()->getName().str();' \
  || fail "readAvailable_DECL_ATTR does not name the module it reads: $(cat "$T/ds")"
cl="$(grep -n 'ctx\.getPkgsRuntimeIntroduced(module, Introduced)' "$T/ds" | head -n 1 | cut -d: -f1)"
[ -n "$cl" ] || fail "readAvailable_DECL_ATTR does not ask getPkgsRuntimeIntroduced for the module it reads: $(cat "$T/ds")"
al="$(grep -n 'new (ctx)' "$T/ds" | tail -n 1 | cut -d: -f1)"
[ -n "$al" ] && [ "$cl" -lt "$al" ] || fail "readAvailable_DECL_ATTR asks getPkgsRuntimeIntroduced after it makes the attribute"
has_line "$T/ds" '      (domain.getPlatformKind() == PlatformKind::macOS ||' && has_line "$T/ds" '       domain.getPlatformKind() == PlatformKind::anyAppleOS)) {' \
  || fail "readAvailable_DECL_ATTR does not apply the rule on exactly macOS and anyAppleOS: $(cat "$T/ds")"
has_line "$T/ds" '      Introduced = *moved;' || fail "readAvailable_DECL_ATTR does not take the moved version: $(cat "$T/ds")"
has_line "$T/ds" '      domain = AvailabilityDomain::forPlatform(PlatformKind::macOS);' \
  || fail "readAvailable_DECL_ATTR does not make an anyAppleOS introduction macOS's when it moves it"

echo "-- Span: no exception, and the runtime pkg ships the library Core's \$ld\$previous names"
MAP="$SRC/stdlib/public/core/PreviousModuleInstallName.json"
[ -f "$MAP" ] || fail "no $MAP: where does Core's \$ld\$previous for Span point now?"
SPAN_NAME="$(tr -d ' \n' < "$MAP" | sed -n 's/.*"module":"CompatibilitySpan","install_name":"@rpath\/\([^"]*\)".*/\1/p')"
[ "$SPAN_NAME" = libswiftCompatibilitySpan.dylib ] \
  || fail "$MAP no longer sends CompatibilitySpan to @rpath/libswiftCompatibilitySpan.dylib: $(cat "$MAP")"
has_line "$REPO/scripts/stage-runtime.sh" 'ln -s libswiftCore.dylib "$PREFIX/lib/swift/libswiftCompatibilitySpan.dylib"' \
  || fail "scripts/stage-runtime.sh does not ship libswiftCompatibilitySpan.dylib as a link to libswiftCore.dylib"

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
