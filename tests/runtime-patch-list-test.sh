#!/bin/sh
# platform: host-agnostic
# usage: sh tests/runtime-patch-list-test.sh
#   build.sh applies an explicit list of runtime patches, RUNTIME_PATCHES (a number can be retired: 0006
#   was). Every patches/runtime/*.patch must be on it, every number on it must name exactly one patch, and
#   each must have its marker grep in build.sh's step 3: a patch added without its entry was once skipped
#   in silence, by a local build and by CI's alike. lib.sh's runtime_patches_unlisted, which build.sh's
#   step 3 runs, must name each patch the list lacks, and fail on a dir with none.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/runtime-patch-list.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"

echo "-- runtime_patches_unlisted: names each patch the list lacks"
mkdir -p "$T/p"; : > "$T/p/0001-a.patch"; : > "$T/p/0003-c.patch"
runtime_patches_unlisted "$T/p" 0001 0003 > "$T/out" || fail "refused a dir whose every patch is listed: $(cat "$T/out")"
[ ! -s "$T/out" ] || fail "named a listed patch: $(cat "$T/out")"
: > "$T/p/0009-new.patch"; : > "$T/p/unnumbered.patch"
if runtime_patches_unlisted "$T/p" 0001 0003 > "$T/out"; then fail "passed a dir holding unlisted patches"; fi
[ "$(cat "$T/out")" = "$T/p/0009-new.patch
$T/p/unnumbered.patch" ] || fail "did not name exactly the unlisted two: $(cat "$T/out")"
if runtime_patches_unlisted "$T/p" 00 0001 0003 > /dev/null; then fail "a number's prefix listed one it is not"; fi
mkdir -p "$T/empty"
if runtime_patches_unlisted "$T/empty" 0001 2>/dev/null; then fail "passed a dir holding no patch"; fi

echo "-- build.sh's RUNTIME_PATCHES: every patch in patches/runtime, one patch per number, a marker grep each"
list="$(sed -n 's/^RUNTIME_PATCHES="\([0-9 ]*\)"$/\1/p' "$REPO/build.sh")"
[ -n "$list" ] || fail "read no RUNTIME_PATCHES from build.sh"
runtime_patches_unlisted "$REPO/patches/runtime" $list > "$T/out" || fail "build.sh's RUNTIME_PATCHES ($list) lacks: $(cat "$T/out")"
for n in $list; do
  c=0; for p in "$REPO/patches/runtime/$n"-*.patch; do [ -f "$p" ] && c=$((c + 1)); done
  [ "$c" -eq 1 ] || fail "RUNTIME_PATCHES' $n names $c patches in patches/runtime, not one"
  grep -Eq "\"patch $n( \([^)]*\))? not applied\"" "$REPO/build.sh" || fail "build.sh has no marker grep for patch $n (\"patch $n ... not applied\")"
done
echo "PASS"
