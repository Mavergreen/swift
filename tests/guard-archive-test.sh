#!/bin/sh
# platform: macOS-only -- compiles a small x86_64 archive with the host's cc and links it with the host's ld
# usage: sh tests/guard-archive-test.sh
#   scripts/guard.sh --linked-with <linker> guards an archive whose members call each other, as Recaulk's
#   librecaulk.a does (an mp member calls Recaulk's own clock_gettime): the guard reads an archive's
#   undefined symbols member by member, so it would refuse those calls, which a link resolves in the
#   archive. The archive is linked whole into a dylib (lld's or ld64's -all_load, every outside symbol
#   looked up at load time) and that is guarded: a post-10.9 call one member makes and another defines
#   passes; one nothing in the archive defines fails, naming the archive. release.yml guards the bundled
#   lib/recaulk/librecaulk.a so, by name.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 && command -v ld >/dev/null 2>&1 && command -v ar >/dev/null 2>&1 \
  || { echo "no cc, ld and ar -- skipping"; exit 77; }
. "$REPO/msc.sh"
[ -f "$SHIPYARD/assert_binary_compatible.sh" ] || { echo "no shipyard guard at $SHIPYARD -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/guard-archive.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cc_x() { cc -c -arch x86_64 -mmacosx-version-min=10.9 -Xclang -target-sdk-version=10.9 "$@"; }
printf 'int clock_gettime(int c, void *t) { return c + (t != 0); }\n' > "$T/def.c"
printf 'int clock_gettime(int, void *);\nint uses(void) { return clock_gettime(0, 0); }\n' > "$T/use.c"
printf 'void os_unfair_lock_lock(void *);\nvoid locks(void *l) { os_unfair_lock_lock(l); }\n' > "$T/leak.c"
for f in def use leak; do cc_x "$T/$f.c" -o "$T/$f.o" || fail "could not compile $f.c"; done
ar rcs "$T/ok.a" "$T/def.o" "$T/use.o" 2>/dev/null
# platform: Apple's ld links no dylib without libSystem, which ld64.lld (release.yml's linker) does not ask
#           for: the stand-in adds the host SDK's, whose imports the guard reads as it reads any others.
SDK="$(xcrun --show-sdk-path 2>/dev/null)" || { echo "no host SDK (xcrun) -- skipping"; exit 77; }
printf '#!/bin/sh
exec ld "$@" -syslibroot "%s" -lSystem
' "$SDK" > "$T/ld"; chmod +x "$T/ld"
ar rcs "$T/leak.a" "$T/def.o" "$T/use.o" "$T/leak.o" 2>/dev/null

echo "-- a member's post-10.9 call another member defines: refused by the plain guard, passed linked whole"
if sh "$REPO/scripts/guard.sh" "$T/ok.a" > "$T/out" 2>&1; then fail "the plain guard passed the archive's own call: $(cat "$T/out")"; fi
sh "$REPO/scripts/guard.sh" --linked-with "$T/ld" "$T/ok.a" > "$T/out" 2>&1 || fail "linked whole, the archive failed: $(cat "$T/out")"
grep -q "$T/ok.a" "$T/out" || fail "did not name the archive: $(cat "$T/out")"

echo "-- a post-10.9 call nothing in the archive defines: refused, naming the archive"
if sh "$REPO/scripts/guard.sh" --linked-with "$T/ld" "$T/leak.a" > "$T/out" 2>&1; then fail "passed an archive that calls os_unfair_lock_lock: $(cat "$T/out")"; fi
grep -q '_os_unfair_lock_lock' "$T/out" && grep -q "$T/leak.a" "$T/out" || fail "did not name the call and the archive: $(cat "$T/out")"

echo "-- a linker that fails, or no archive: refused"
if sh "$REPO/scripts/guard.sh" --linked-with false "$T/ok.a" > "$T/out" 2>&1; then fail "passed when the link failed"; fi
if sh "$REPO/scripts/guard.sh" --linked-with "$T/ld" > "$T/out" 2>&1; then fail "passed with no archive named"; fi
echo "PASS"
