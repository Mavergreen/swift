#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-notice-test.sh
#   The toolchain pkgs require the swift-runtime of their own version (package-toolchain.sh), whoever cuts the
#   release, so the fact is standing and release-notes/swift-runtime/notice, which opens every release's footer,
#   says it once: a checked sentence naming the swift-runtime, the same version, and both toolchains' programs.
#   Auto-dispatched repackages carry no notes files, so nothing per release may be demanded.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
N="$REPO/release-notes/swift-runtime/notice"
[ -f "$N" ] || fail "no $N"
. "$REPO/msc.sh" >/dev/null 2>&1 || { echo "no shipyard -- skipping"; exit 77; }
sh "$SHIPYARD/check-release-sentence.sh" "$N" || fail "the notice is not a release sentence"
for w in swift-runtime "same version" toolchain run; do
  grep -q "$w" "$N" || fail "the notice does not say '$w': $(cat "$N")"
done
grep -q check-runtime-requires-note "$REPO/.github/workflows/release.yml" && fail "release.yml demands a per-release requires note again"
echo "PASS"
