#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 Mach-O fixtures that otool and nm read
# usage: sh tests/imports-on-10.9-test.sh
#   scripts/imports-on-10.9.sh takes the dylibs a build stages and an SDK root, and fails unless every
#   symbol each imports from /usr/lib or /System/Library/Frameworks that is not weak is exported by that
#   library's stub in the SDK, and every weak one that is absent is on the allowlist, each line of which
#   names the guard that makes it safe (` -- file:line`). On fixture dylibs against a fake SDK (a libSystem
#   that exports nothing itself and re-exports a sub-library, as the real one does): a strong absent import
#   fails and is named strong; a weak absent one fails and is named weak unless allowlisted; an allowlist
#   never excuses a strong one; a symbol only a re-exported sub-library exports is present; an
#   allowlist line with no citation, and a dylib nm cannot read, fail rather than pass.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$REPO/scripts/imports-on-10.9.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/imports-on-109.XXXXXX")"
trap 'rm -rf "$T"' EXIT
[ -f "$CHECK" ] || fail "no $CHECK"

CC="cc -arch x86_64 -mmacosx-version-min=10.9"
# The fake SDK: libSystem.B exports only dyld_stub_binder and re-exports libsystem_c, which exports _malloc.
SDK="$T/sdk"
mkdir -p "$SDK/usr/lib/system"
printf '%s\n' 'void *malloc(unsigned long n) { return 0; }' > "$T/c.c"
# (ld refuses to link a library installed under /usr/lib/system, so the install name is set afterwards.)
$CC -dynamiclib "$T/c.c" -o "$SDK/usr/lib/system/libsystem_c.dylib" || fail "cannot build the fake libsystem_c"
install_name_tool -id /usr/lib/system/libsystem_c.dylib "$SDK/usr/lib/system/libsystem_c.dylib" || fail "cannot name the fake libsystem_c"
# (the real one is libdyld's, re-exported by libSystem, and is named without the C underscore)
printf '%s\n' 'void binder(void) __asm__("dyld_stub_binder");' 'void binder(void) {}' > "$T/s.c"
$CC -dynamiclib "$T/s.c" -Wl,-reexport_library,"$SDK/usr/lib/system/libsystem_c.dylib" \
  -o "$SDK/usr/lib/libSystem.B.dylib" || fail "cannot build the fake libSystem"
install_name_tool -id /usr/lib/libSystem.B.dylib "$SDK/usr/lib/libSystem.B.dylib" || fail "cannot name the fake libSystem"
ln -s libSystem.B.dylib "$SDK/usr/lib/libSystem.dylib"

# Fixtures link the real libSystem; no SDK header, so nothing is weak but by declaration. clock_gettime is
# in no 10.9 libSystem, which is the point of a fake one that lacks it.
WK='__attribute__((weak_import))'
printf '%s\n' 'extern int clock_gettime(int, void *);' 'int f(void) { return clock_gettime(0, 0); }' > "$T/strong.c"
printf '%s\n' "extern int clock_gettime(int, void *) $WK;" 'int f(void) { return clock_gettime ? clock_gettime(0, 0) : 0; }' > "$T/weak.c"
printf '%s\n' 'extern void *malloc(unsigned long);' 'void *f(void) { return malloc(8); }' > "$T/ok.c"
printf '%s\n' "extern void *malloc(unsigned long) $WK;" 'void *f(void) { return malloc ? malloc(8) : 0; }' > "$T/weakok.c"
for f in strong weak ok weakok; do
  $CC -dynamiclib "$T/$f.c" -o "$T/$f.dylib" || fail "cannot build the $f fixture"
done
: > "$T/empty.dylib"
: > "$T/none.txt"
printf '%s\n' '# a comment, then a blank line' '' 'weak.dylib _clock_gettime -- fake.h:12' 'strong.dylib _clock_gettime -- fake.h:12' > "$T/allow.txt"
printf '%s\n' 'weak.dylib _clock_gettime' > "$T/nocite.txt"

run() { sh "$CHECK" "$SDK" "$@" 2>&1; }

echo "-- a strong absent import fails, named strong, even where an allowlist line names it"
out="$(run "$T/none.txt" "$T/strong.dylib")" && fail "passed a strong import the SDK lacks"
printf '%s\n' "$out" | grep -qx 'strong.dylib: _clock_gettime (libSystem, strong)' || fail "did not name the strong import: $out"
out="$(run "$T/allow.txt" "$T/strong.dylib")" && fail "an allowlist line excused a strong import"
printf '%s\n' "$out" | grep -q '(libSystem, strong)' || fail "did not name the allowlisted strong import: $out"

echo "-- a weak absent import fails, named weak, unless it is on the allowlist for that dylib"
out="$(run "$T/none.txt" "$T/weak.dylib")" && fail "passed a weak absent import with no allowlist line"
printf '%s\n' "$out" | grep -qx 'weak.dylib: _clock_gettime (libSystem, weak)' || fail "did not name the weak import: $out"
run "$T/allow.txt" "$T/weak.dylib" > /dev/null || fail "failed a weak absent import on the allowlist: $(run "$T/allow.txt" "$T/weak.dylib")"
cp "$T/weak.dylib" "$T/other.dylib"
if run "$T/allow.txt" "$T/other.dylib" > /dev/null; then fail "an allowlist line for weak.dylib excused other.dylib"; fi

echo "-- a symbol only a re-exported sub-library exports is present, strong or weak"
run "$T/none.txt" "$T/ok.dylib" > /dev/null || fail "failed _malloc, which libSystem re-exports: $(run "$T/none.txt" "$T/ok.dylib")"
run "$T/none.txt" "$T/weakok.dylib" > /dev/null || fail "failed a weak _malloc: $(run "$T/none.txt" "$T/weakok.dylib")"

echo "-- every dylib is checked, and every failure listed"
out="$(run "$T/none.txt" "$T/ok.dylib" "$T/strong.dylib" "$T/weak.dylib")" && fail "passed with two failing dylibs among three"
printf '%s\n' "$out" | grep -q '^strong.dylib: ' && printf '%s\n' "$out" | grep -q '^weak.dylib: ' || fail "did not list both failures: $out"

echo "-- an allowlist line with no citation fails, and so does a dylib it cannot read"
if run "$T/nocite.txt" "$T/weak.dylib" > /dev/null; then fail "accepted an allowlist line with no ' -- ' citation"; fi
if run "$T/none.txt" "$T/empty.dylib" > /dev/null; then fail "passed a dylib nm cannot read"; fi
if run "$T/none.txt" "$T/nothere.dylib" > /dev/null; then fail "passed a dylib that is not there"; fi
if sh "$CHECK" "$T/nosdk" "$T/none.txt" "$T/ok.dylib" > /dev/null 2>&1; then fail "passed with no SDK"; fi
echo "-- a reader that fails, or reads nothing, never passes as a dylib with nothing to check"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-L*) exit 1 ;; esac' 'exec otool "$@"' > "$T/otool-no-L"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-gU*) exit 1 ;; esac' 'exec nm "$@"' > "$T/nm-no-exports"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-L*) otool "$@" | grep -v libSystem; echo "	/usr/lib/libother.dylib (compatibility version 1.0.0, current version 1.0.0)" ;; *) exec otool "$@" ;; esac' > "$T/otool-other-lib"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-L*) otool "$@" | sed 2,\$d ;; *) exec otool "$@" ;; esac' > "$T/otool-links-nothing"
chmod +x "$T"/otool-* "$T/nm-no-exports"
if OTOOL="$T/otool-no-L" sh "$CHECK" "$SDK" "$T/none.txt" "$T/ok.dylib" > /dev/null 2>&1; then fail "passed when otool -L failed"; fi
if OTOOL="$T/otool-links-nothing" sh "$CHECK" "$SDK" "$T/none.txt" "$T/ok.dylib" > /dev/null 2>&1; then fail "passed a dylib otool -L showed linking nothing"; fi
if NM="$T/nm-no-exports" sh "$CHECK" "$SDK" "$T/none.txt" "$T/ok.dylib" > /dev/null 2>&1; then fail "passed when nm could not read the stubs"; fi
out="$(OTOOL="$T/otool-other-lib" sh "$CHECK" "$SDK" "$T/none.txt" "$T/ok.dylib" 2>&1)" && fail "passed imports from a library the dylib does not list"
printf '%s\n' "$out" | grep -q '_malloc (libSystem, library not among' || fail "did not name the unknown library: $out"
# Only @rpath imports: nothing for this check to look at, which a misread would look like too.
printf '%s\n' 'int fakevar = 1;' > "$T/fv.c"
$CC -dynamiclib -install_name @rpath/libfv.dylib "$T/fv.c" -o "$T/libfv.dylib" || fail "cannot build the @rpath library"
printf '%s\n' 'extern int fakevar;' 'int f(void) { return fakevar; }' > "$T/rp.c"
$CC -dynamiclib "$T/rp.c" "$T/libfv.dylib" -o "$T/rp.dylib" || fail "cannot build the @rpath-only fixture"
if run "$T/none.txt" "$T/rp.dylib" > /dev/null; then fail "passed a dylib with no OS imports"; fi
# The allowlist is matched literally: a dot in a symbol is not any character.
printf '%s\n' 'weak.dylib _clock.ettime -- fake.h:12' > "$T/regex.txt"
if run "$T/regex.txt" "$T/weak.dylib" > /dev/null; then fail "an allowlist symbol was matched as a pattern"; fi

echo "-- the shipped allowlist cites a guard on every line"
run "$REPO/scripts/resources/weak-absent-on-10.9.txt" "$T/ok.dylib" > /dev/null || fail "the shipped allowlist is not well formed: $(run "$REPO/scripts/resources/weak-absent-on-10.9.txt" "$T/ok.dylib")"
echo PASS
