#!/bin/sh
# platform: host-agnostic
# usage: sh tests/runtime-requires-note-test.sh
#   scripts/check-runtime-requires-note.sh must fail a release whose version has no
#   release-notes/swift-runtime/<version>/requires/swift-runtime naming that version, and pass one that has it;
#   and release.yml's version job must run it, for a publishing run, after the version is resolved.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/requires-note.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
C="$REPO/scripts/check-runtime-requires-note.sh"
V=6.4.1-mavericks.10
if sh "$C" "$V" "$T" 2> "$T/err"; then fail "passed with no release-notes tree"; fi
grep -q "requires/swift-runtime" "$T/err" || fail "did not name the missing file: $(cat "$T/err")"
mkdir -p "$T/release-notes/swift-runtime/$V/requires"
if sh "$C" "$V" "$T" 2>/dev/null; then fail "passed with no requires/swift-runtime"; fi
echo 6.4.1-mavericks.9 > "$T/release-notes/swift-runtime/$V/requires/swift-runtime"
if sh "$C" "$V" "$T" 2> "$T/err"; then fail "passed with a note naming another version"; fi
grep -q "not $V" "$T/err" || fail "did not say which version it wanted: $(cat "$T/err")"
if sh "$C" "$V" "$T/release-notes/../nowhere" 2>/dev/null; then fail "passed in a root without the tree"; fi
echo "$V" > "$T/release-notes/swift-runtime/$V/requires/swift-runtime"
sh "$C" "$V" "$T" || fail "refused a correct note"
rc=0; sh "$C" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ] || fail "no version: exit $rc, not 2"

# The workflow: a step in the version job runs it with the resolved version, for a publishing run only.
awk '/^  version:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$REPO/.github/workflows/release.yml" > "$T/job"
awk '/check-runtime-requires-note.sh/ { f = 1 } END { exit !f }' "$T/job" || fail "the version job does not run check-runtime-requires-note.sh"
grep -q 'sh scripts/check-runtime-requires-note.sh "${{ steps.ver.outputs.version }}"' "$T/job" || fail "the check is not given the resolved version"
grep -B6 'check-runtime-requires-note.sh' "$T/job" | grep -qF "if: steps.ver.outputs.publish == 'true'" || fail "the check does not run for publishing runs"
echo "PASS"
