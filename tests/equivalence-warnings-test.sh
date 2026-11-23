#!/bin/sh
# platform: host-agnostic
# usage: sh tests/equivalence-warnings-test.sh
#   scripts/equivalence-warnings.sh A B runs shipyard's build-equivalence.sh --repo <this repo> A B, prints its report,
#   and turns each unexcused difference and each unused entry into a GitHub ::warning::, and a comparison it could
#   not make (exit 2) into one more; it exits 0 whatever build-equivalence.sh said, since collect only warns for now.
#   build-equivalence.sh is faked here: its output lines are "<level>TAB<path>TAB<excusing glob or ->", detail lines
#   indented under an interface line, and "unused TAB - TAB <glob>".
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
[ "$rc" -eq 0 ] || fail "it exited $rc on differences; collect only warns"
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

fake 2
rc=0; SHIPYARD_SCRIPTS="$T/sy" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "it exited $rc when the comparison could not be made"
grep -q '^::warning::build-equivalence could not compare' "$T/got" || fail "a comparison that could not be made was not warned about"

rc=0; SHIPYARD_SCRIPTS="$T/nowhere" sh "$S" a.pkg b.pkg > "$T/got" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q '^::warning::' "$T/got" || fail "no shipyard should warn, not fail"
echo "PASS: equivalence-warnings"
