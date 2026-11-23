#!/bin/sh
# platform: host-agnostic
# usage: sh scripts/equivalence-warnings.sh A B
#   Compares two builds of one pkg (release.yml's collect: build-cross's runtime pkg, A, and the Linux runtime
#   job's, B) with shipyard's build-equivalence.sh, against this repo's INGREDIENTS.md entries, and prints its
#   report. Each unexcused difference and each unused entry becomes a GitHub ::warning::, as does a comparison it
#   could not make. Exits 0 whatever it found: until the Linux runtime has matched the Mac's with only declared
#   differences, a difference is reported, not a reason to stop a release. Blocking is a direct call of
#   build-equivalence.sh in its place.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 2 ] || { echo "usage: equivalence-warnings.sh A B" >&2; exit 2; }
BE="${SHIPYARD_SCRIPTS:-}/build-equivalence.sh"
[ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -f "$BE" ] || { echo "::warning::build-equivalence could not compare $1 and $2: no build-equivalence.sh in SHIPYARD_SCRIPTS (${SHIPYARD_SCRIPTS:-unset})"; exit 0; }
OUT="$(mktemp "${TMPDIR:-/tmp}/equivalence-warnings.XXXXXX")"
trap 'rm -f "$OUT"' EXIT
rc=0; sh "$BE" --repo "$REPO" "$1" "$2" > "$OUT" || rc=$?
cat "$OUT"
TAB="$(printf '\t')"
awk -F "$TAB" 'NF >= 3 && $1 == "unused" { print "::warning::build-equivalence: unused entry " $3; next }
               NF >= 3 && $3 == "-" { print "::warning::build-equivalence: " $1 " " $2 }' "$OUT"
case "$rc" in
  0|1) ;;
  *) echo "::warning::build-equivalence could not compare $1 and $2 (exit $rc)" ;;
esac
exit 0
