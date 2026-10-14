#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-workflow-test.sh
#   .github/workflows/release.yml's build job is main's required check, and GitHub counts a skipped required
#   check as passed. So build must run whatever its needs did (if: !cancelled()), and its first step must fail
#   unless version and build-cross both succeeded: a failed build-cross must fail the check, never skip it
#   (PR 9 automerged 6.4.1 with 6.4.0's tarball pins that way). Each check is run against a workflow mutated to
#   break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/release-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The checks, on the workflow $1; the first that fails names itself on stdout.
check() {
  awk '/^  build:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/job"
  grep -qx '    needs: \[version, build-cross\]' "$T/job" || { echo "build does not need version and build-cross"; return 1; }
  grep -qx '    if: ${{ !cancelled() }}' "$T/job" || { echo "build is skipped when a need fails"; return 1; }
  awk '/^    steps:$/ { s = 1; next } s && /^      - / { print; getline; print; exit }' "$T/job" > "$T/first"
  grep -qx '      - name: Fail unless version and build-cross succeeded' "$T/first" \
    && grep -qxF "        if: \${{ needs.version.result != 'success' || needs.build-cross.result != 'success' }}" "$T/first" \
    || { echo "build's first step is not the guard"; return 1; }
  awk '/^      - name: Fail unless version and build-cross succeeded$/ { g = 1; next } g && /^      - / { exit } g' "$T/job" > "$T/guard"
  grep -qx '          exit 1' "$T/guard" || { echo "the guard does not fail"; return 1; }
}

W="$REPO/.github/workflows/release.yml"
check "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"

mutant() {
  sed "$2" "$W" > "$T/mutant.yml"
  if check "$T/mutant.yml" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
mutant "a build skipped on a failed need" '/^    if: \${{ !cancelled() }}$/d'
mutant "a guard that only warns" '/build, the required check, must not pass/{n;s/exit 1/true/;}'
mutant "a guard after the checkout" '/^      - name: Fail unless version and build-cross succeeded$/,/^          exit 1$/d'
echo "PASS"
