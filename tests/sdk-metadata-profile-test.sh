#!/bin/sh
# platform: macOS-only -- shipyard's cmake (shipyard-cmake), which the overlay build already runs, reads the JSON
# usage: sh tests/sdk-metadata-profile-test.sh
#   lib.sh's recaulk_sdk_metadata_profile prints the recipe ids of one profile in Recaulk's
#   share/sdk-metadata/profiles.json (schema 1), one per line, in the file's order. It fails, printing
#   nothing, when the file is missing or is not JSON, the schema is missing or not the number 1, the profile
#   is missing, or its recipes are missing, empty, or hold anything but a plain recipe id. build.sh names the
#   Foundation overlay's profile once, and copies no recipe id of its own. With the released Recaulk in
#   place, its swift-foundation profile is read too.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"
# Static checks of build.sh first: they need no cmake, so they run where the reader's checks skip.
echo "-- build.sh names the profile once, by one name, and copies no recipe id"
[ "$(grep -c '^FOUNDATION_SDK_METADATA_PROFILE="swift-foundation"' "$REPO/build.sh")" -eq 1 ] \
  || fail "build.sh does not set FOUNDATION_SDK_METADATA_PROFILE=\"swift-foundation\" exactly once"
[ "$(grep -c 'swift-foundation' "$REPO/build.sh")" -eq 1 ] || fail "build.sh names swift-foundation more than once"
grep -nE '(foundation|coregraphics|corefoundation|cf|cg)-[a-z0-9.-]*-v[0-9]+' "$REPO/build.sh" \
  && fail "build.sh holds a recipe id of its own"
grep -nE '(^|[^A-Za-z_])FSM([^A-Za-z_]|$)' "$REPO/build.sh" && fail "build.sh names the profile by an alias, FSM"
echo "-- build.sh's failure to read the profile names the file and what is wrong with it, not only a missing profile"
FL="$(grep -A1 'recaulk_sdk_metadata_profile "' "$REPO/build.sh" | grep 'FAIL:' || :)"
[ -n "$FL" ] || fail "build.sh has no FAIL after reading the profile"
printf '%s\n' "$FL" | grep -q 'profiles\.json' || fail "build.sh's FAIL does not name profiles.json: $FL"
printf '%s\n' "$FL" | grep -q 'schema' || fail "build.sh's FAIL does not cover a profiles.json of another schema: $FL"
printf '%s\n' "$FL" | grep -q 'has no sdk-metadata profile' && fail "build.sh's FAIL says only that the profile is missing: $FL"

CMAKE="${CMAKE:-shipyard-cmake}"
command -v "$CMAKE" >/dev/null 2>&1 || { echo "no $CMAKE -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sdk-metadata-profile.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# refuses <what> <json>: the profile p of <json> must fail and print nothing.
refuses() {
  printf '%s\n' "$2" > "$T/p.json"
  rc=0; out="$(recaulk_sdk_metadata_profile "$T/p.json" p 2> "$T/err")" || rc=$?
  [ "$rc" -ne 0 ] || fail "accepted $1: printed '$out'"
  [ -z "$out" ] || fail "printed '$out' for $1"
  [ -s "$T/err" ] || fail "said nothing on stderr for $1"
}

echo "-- a named profile's ids, one per line, in order"
printf '%s\n' '{"schema":1,"profiles":{"other":{"recipes":["z-v1"]},' \
  '"p":{"description":"d","recipes":["foundation-b-v2","foundation-a-v1","cf.c-v10"]}}}' > "$T/p.json"
out="$(recaulk_sdk_metadata_profile "$T/p.json" p)" || fail "could not read profile p"
[ "$out" = "foundation-b-v2
foundation-a-v1
cf.c-v10" ] || fail "profile p read as '$out'"

echo "-- the profile missing"
refuses "a missing profile" '{"schema":1,"profiles":{"other":{"recipes":["z-v1"]}}}'
refuses "no profiles at all" '{"schema":1}'
echo "-- the schema wrong"
refuses "schema 2" '{"schema":2,"profiles":{"p":{"recipes":["a-v1"]}}}'
refuses "no schema" '{"profiles":{"p":{"recipes":["a-v1"]}}}'
refuses "the schema as a string" '{"schema":"1","profiles":{"p":{"recipes":["a-v1"]}}}'
echo "-- the recipes missing, empty or not ids"
refuses "no recipes" '{"schema":1,"profiles":{"p":{"description":"d"}}}'
refuses "empty recipes" '{"schema":1,"profiles":{"p":{"recipes":[]}}}'
refuses "recipes not a list" '{"schema":1,"profiles":{"p":{"recipes":"a-v1"}}}'
refuses "an id with a space" '{"schema":1,"profiles":{"p":{"recipes":["a-v1","b v1"]}}}'
refuses "an id with a semicolon" '{"schema":1,"profiles":{"p":{"recipes":["a-v1;b-v1"]}}}'
refuses "an id that is a number" '{"schema":1,"profiles":{"p":{"recipes":["a-v1",3]}}}'
refuses "not JSON" 'schema: 1'
echo "-- no profiles.json"
rc=0; out="$(recaulk_sdk_metadata_profile "$T/none.json" p 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] || fail "accepted a missing profiles.json"

for d in /usr/local/mavergreen/recaulk "$HOME/Library/Caches/mavergreen-recaulk/$(sed -n 's/^RECAULK_VERSION="\([^"]*\)".*/\1/p' "$REPO/pins.env")/recaulk"; do
  [ -f "$d/share/sdk-metadata/profiles.json" ] || continue
  echo "-- $d's swift-foundation profile"
  ids="$(recaulk_sdk_metadata_profile "$d/share/sdk-metadata/profiles.json" swift-foundation)" || fail "could not read $d's swift-foundation"
  printf '%s\n' "$ids" | grep -qx 'foundation-array-v[0-9]*' || fail "$d's swift-foundation has no foundation-array recipe"
done
echo "PASS"
