#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 dylibs and the archive's objects the check reads
# usage: sh tests/recaulk-notices-test.sh
#   APSL 2.0 section 2.3 asks for the "source is available" notice in the code itself as well as in the
#   documentation. Recaulk embeds that notice in each Apple-derived member (a no-dead-strip string) and
#   lists it in its notices.tsv (artifact, member, licence, covered-files, copyright, source-urls,
#   notice). lib.sh's recaulk_notices reads the members of a recaulk_subset archive, and for each one the
#   tsv lists under librecaulk.a with an APSL licence it requires the notice in the dylib's strings and,
#   whitespace aside, in NOTICE. On fixtures: it passes with both present, names the member when the
#   dylib or NOTICE lacks the notice, ignores members it does not link, rows of other artifacts and
#   non-APSL rows, and refuses a tsv whose columns are not the ones it reads.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/recaulk-notices.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"
TAB="$(printf '\t')"
NA="Recaulk member mp-a.o is object code compiled from src/a.c. Source Code of the Covered Code is available under the terms of the Apple Public Source License Version 2.0 at https://example.org/a.c."
NB="Recaulk member mp-b.o is object code compiled from src/b.c, available under the APSL at https://example.org/b.c."
NC="Recaulk member mp-c.o is not linked here, so its notice is not required."
HDR="# artifact${TAB}member${TAB}licence${TAB}covered-files${TAB}copyright${TAB}source-urls${TAB}notice"
{ echo "$HDR"
  echo "librecaulk.a${TAB}mp-a.o${TAB}APSL-2.0${TAB}src/a.c${TAB}Copyright A${TAB}https://example.org/a.c${TAB}$NA"
  echo "librecaulk.a${TAB}mp-c.o${TAB}APSL-2.0${TAB}src/c.c${TAB}Copyright C${TAB}https://example.org/c.c${TAB}$NC"
  echo "librecaulk.a${TAB}mp-m.o${TAB}MIT${TAB}src/m.c${TAB}Copyright M${TAB}https://example.org/m.c${TAB}not an APSL notice"
  echo "libRecaulkSystem.dylib${TAB}mp-b.o${TAB}APSL-2.0${TAB}src/b.c${TAB}Copyright B${TAB}https://example.org/b.c${TAB}$NB"
} > "$T/notices.tsv"
# The archive links mp-a.o (APSL), mp-m.o (a non-APSL row) and fwd-1.o (no row); mp-b.o's row is another
# artifact's, mp-c.o is in the tsv but not linked.
o() { printf '%s\n' "$2" > "$T/$1.c"; cc -arch x86_64 -mmacosx-version-min=10.9 -c "$T/$1.c" -o "$T/$1.o" || fail "cannot build $1.o"; }
o mp-a "__attribute__((used, section(\"__TEXT,__recaulk_apsl\"))) static const char n[] = \"$NA\"; int a(void) { return 1; }"
o mp-m 'int m(void) { return 2; }'
o fwd-1 'int f(void) { return 3; }'
( cd "$T" && ar rcs sub.a fwd-1.o mp-a.o mp-m.o ) || fail "cannot build sub.a"
cc -arch x86_64 -mmacosx-version-min=10.9 -dynamiclib -Wl,-dead_strip "$T/mp-a.o" -o "$T/with.dylib" || fail "cannot link with.dylib"
cc -arch x86_64 -mmacosx-version-min=10.9 -dynamiclib "$T/mp-m.o" -o "$T/without.dylib" || fail "cannot link without.dylib"
# NOTICE wraps the notice across lines, as a hand-edited NOTICE does.
printf '%s\n' "Preamble." "$NA" | fold -s -w 60 > "$T/NOTICE"
grep -qF "$NA" "$T/NOTICE" && fail "the fixture NOTICE did not wrap the notice, so it tests nothing"

echo "-- the linked APSL member's notice is in the dylib and in NOTICE: passes, naming it"
out="$(recaulk_notices "$T/notices.tsv" "$T/sub.a" "$T/with.dylib" "$T/NOTICE")" || fail "refused a dylib and NOTICE that carry mp-a.o's notice"
[ "$out" = "mp-a.o" ] || fail "checked '$out', not just mp-a.o"

echo "-- the dylib lacks it: refused, naming the member"
if recaulk_notices "$T/notices.tsv" "$T/sub.a" "$T/without.dylib" "$T/NOTICE" > /dev/null 2> "$T/err"; then fail "accepted a dylib without mp-a.o's notice"; fi
grep -q "without.dylib.*mp-a.o" "$T/err" || fail "did not name the dylib and mp-a.o: $(cat "$T/err")"

echo "-- NOTICE lacks it: refused, naming the member"
echo "Preamble only." > "$T/NOTICE-short"
if recaulk_notices "$T/notices.tsv" "$T/sub.a" "$T/with.dylib" "$T/NOTICE-short" > /dev/null 2> "$T/err"; then fail "accepted a NOTICE without mp-a.o's notice"; fi
grep -q "NOTICE-short.*mp-a.o" "$T/err" || fail "did not name NOTICE-short and mp-a.o: $(cat "$T/err")"

echo "-- an archive with no APSL member needs no notice"
( cd "$T" && ar rcs plain.a fwd-1.o mp-m.o ) || fail "cannot build plain.a"
out="$(recaulk_notices "$T/notices.tsv" "$T/plain.a" "$T/without.dylib" "$T/NOTICE-short")" || fail "refused an archive with no APSL member"
[ -z "$out" ] || fail "checked '$out' for an archive with no APSL member"

echo "-- refused: a tsv whose columns moved, an APSL row with no notice, a missing tsv"
{ echo "# artifact${TAB}member${TAB}copyright${TAB}licence${TAB}covered-files${TAB}source-urls${TAB}notice"; sed 1d "$T/notices.tsv"; } > "$T/moved.tsv"
if recaulk_notices "$T/moved.tsv" "$T/sub.a" "$T/with.dylib" "$T/NOTICE" > /dev/null 2> "$T/err"; then fail "accepted a tsv with moved columns"; fi
grep -q "columns" "$T/err" || fail "did not say the columns are wrong: $(cat "$T/err")"
{ echo "$HDR"; echo "librecaulk.a${TAB}mp-a.o${TAB}APSL-2.0${TAB}src/a.c${TAB}Copyright A${TAB}https://example.org/a.c${TAB}"; } > "$T/empty.tsv"
if recaulk_notices "$T/empty.tsv" "$T/sub.a" "$T/with.dylib" "$T/NOTICE" > /dev/null 2> "$T/err"; then fail "accepted an APSL row with no notice"; fi
grep -q "mp-a.o" "$T/err" || fail "did not name mp-a.o's empty notice: $(cat "$T/err")"
if recaulk_notices "$T/none.tsv" "$T/sub.a" "$T/with.dylib" "$T/NOTICE" > /dev/null 2>&1; then fail "accepted a missing tsv"; fi
echo "PASS"
