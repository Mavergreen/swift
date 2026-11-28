#!/bin/sh
# platform: host-agnostic
# usage: sh tests/equivalence-warnings-test.sh
#   scripts/equivalence-warnings.sh A B runs shipyard's build-equivalence.sh --repo <this repo> A B, prints its report,
#   and turns each unexcused difference and each unused entry into a GitHub ::warning::, and a comparison it could
#   not make (exit 2) into one more; it exits 0 whatever build-equivalence.sh said, since release.yml's equivalence
#   job only warns for now.
#   build-equivalence.sh is faked here: its output lines are "<level>TAB<path>TAB<excusing glob or ->", detail lines
#   indented under an interface line, and "unused TAB - TAB <glob>" (build-equivalence.sh's own usage), and an
#   exit 1 with no such line still becomes a warning.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/equivalence-warnings-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
S="$REPO/scripts/equivalence-warnings.sh"
[ -f "$S" ] || fail "no scripts/equivalence-warnings.sh"
mkdir -p "$T/sy"
TAB="$(printf '\t')"
# fake <exit> -- a build-equivalence.sh that logs its arguments, prints $T/out and exits <exit>
fake() { printf '#!/bin/sh\necho "$*" > "%s/args"\ncat "%s/out"\necho "build-equivalence: summary" >&2\nexit %s\n' "$T" "$T" "$1" > "$T/sy/build-equivalence.sh"; }
{ printf 'bytes%slib/a.dylib%s-\n' "$TAB" "$TAB"; printf 'interface%slib/b.dylib%s-\n' "$TAB" "$TAB"; printf '  only in A: _x\n'
  printf 'bytes%sshare/doc/NOTICE%sshare/doc/*\n' "$TAB" "$TAB"; printf 'unused%s-%slib/old*\n' "$TAB" "$TAB"; } > "$T/out"

fake 1
rc=0; SHIPYARD_SCRIPTS="$T/sy" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "it exited $rc on differences; the equivalence job only warns"
[ "$(cat "$T/args")" = "--repo $REPO a.pkg b.pkg" ] || fail "build-equivalence.sh got '$(cat "$T/args")', not --repo <repo> A B"
grep -qx '::warning::build-equivalence: bytes lib/a.dylib' "$T/got" || fail "no warning for the bytes difference: $(cat "$T/got")"
grep -qx '::warning::build-equivalence: interface lib/b.dylib' "$T/got" || fail "no warning for the interface difference"
grep -qx '::warning::build-equivalence: unused entry lib/old\*' "$T/got" || fail "no warning for the unused entry"
if grep -q '::warning::.*NOTICE' "$T/got"; then fail "an excused difference was warned about"; fi
if grep -q '::warning::.*only in A' "$T/got"; then fail "a detail line was warned about as a difference"; fi
grep -q '  only in A: _x' "$T/got" || fail "the report itself was not printed"
[ "$(grep -c '::warning::' "$T/got")" -eq 3 ] || fail "not one warning per unexcused difference and unused entry: $(grep '::warning::' "$T/got")"

: > "$T/out"; fake 0
rc=0; SHIPYARD_SCRIPTS="$T/sy" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ! grep -q '::warning::' "$T/got" || fail "equivalent builds were warned about, or failed"

# exit 1 with no line it can read as a difference: still a warning, never silence.
printf 'bytes%sshare/doc/NOTICE%sshare/doc/*\n' "$TAB" "$TAB" > "$T/out"; fake 1
rc=0; SHIPYARD_SCRIPTS="$T/sy" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "it exited $rc on an exit 1 it could not read"
grep -qx '::warning::build-equivalence exited 1 (a difference or an unused entry) but printed none this script reads' "$T/got" \
  || fail "an exit 1 with nothing parsed was not warned about: $(cat "$T/got")"

fake 2
rc=0; SHIPYARD_SCRIPTS="$T/sy" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "it exited $rc when the comparison could not be made"
grep -q '^::warning::build-equivalence could not compare' "$T/got" || fail "a comparison that could not be made was not warned about"

rc=0; SHIPYARD_SCRIPTS="$T/nowhere" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q '^::warning::' "$T/got" || fail "no shipyard should warn, not fail"

# The real build-equivalence.sh, when this host's shipyard has it: two staged trees, a file that differs and one
# only in A, each a warning in the form above.
REAL="$(. "$REPO/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || REAL=""
if [ -n "$REAL" ] && [ -f "$REAL/build-equivalence.sh" ]; then
  mkdir -p "$T/a/share" "$T/b/share"; echo one > "$T/a/share/x.txt"; echo two > "$T/b/share/x.txt"; echo a > "$T/a/share/only.txt"
  rc=0; SHIPYARD_SCRIPTS="$REAL" sh "$S" "$T/a" "$T/b" > "$T/got" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "it exited $rc against the real build-equivalence.sh"
  grep -qx '::warning::build-equivalence: bytes share/x.txt' "$T/got" && grep -qx '::warning::build-equivalence: only-a share/only.txt' "$T/got" \
    || fail "the real build-equivalence.sh's differences were not each warned about: $(cat "$T/got")"
  echo "PASS: equivalence-warnings (and against $REAL/build-equivalence.sh)"
else
  echo "PASS: equivalence-warnings (no build-equivalence.sh in this host's shipyard to check the real format against)"
fi
