#!/bin/sh
# platform: macOS-only -- shipyard's cmake materializer, the cached 10.9 SDK and its with-sdk-settings-json view
# usage: sh tests/sdk-metadata-vfs-test.sh
#   lib.sh's recaulk_sdk_metadata_vfs materializes Recaulk's sdk-metadata recipes (shipyard's
#   mavericks_materialize_sdk_metadata) for the SDK view build.sh compiles the overlays against: a clang
#   VFS overlay whose every header is named under that view, none under the plain SDK it links to, each
#   mapped onto an edited copy that exists. It refuses a view whose System is not the plain SDK's, and
#   leaves no output for a recipe id the file lacks. Skips, saying so, without the SDKs, Recaulk or shipyard.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"
SHIPYARD="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
[ -f "$SHIPYARD/../MavericksSDKMetadata.cmake" ] || { echo "no shipyard MavericksSDKMetadata.cmake under $SHIPYARD/.. -- skipping"; exit 77; }
CACHE="${MAVERICKS_SDK_CACHE:-$HOME/Library/Caches/mavericks-sdk}"
PLAIN="$CACHE/MacOSX10.9.sdk"; VIEW="$CACHE/with-sdk-settings-json/MacOSX10.9.sdk"
[ -d "$PLAIN/System" ] && [ -d "$VIEW/System" ] || { echo "no 10.9 SDK and its with-sdk-settings-json view under $CACHE -- skipping"; exit 77; }
RECIPES=""
for d in /usr/local/mavergreen/recaulk "$HOME/Library/Caches/mavergreen-recaulk"/*/recaulk; do
  [ -f "$d/share/sdk-metadata/recipes.json" ] && RECIPES="$d/share/sdk-metadata/recipes.json"
done
[ -n "$RECIPES" ] || { echo "no Recaulk share/sdk-metadata/recipes.json -- skipping"; exit 77; }
command -v "${CMAKE:-shipyard-cmake}" >/dev/null 2>&1 || { echo "no ${CMAKE:-shipyard-cmake} -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sdk-metadata-vfs.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "-- every header named under the view, mapped onto an edited copy"
recaulk_sdk_metadata_vfs "$PLAIN" "$VIEW" "$RECIPES" "$T/vfs" foundation-array-generics-v2 foundation-objcruntime-macros-v1 \
  > "$T/log" 2>&1 || { cat "$T/log" >&2; fail "recaulk_sdk_metadata_vfs failed"; }
J="$T/vfs/overlay.json"; [ -s "$J" ] || fail "no $J"
grep -q "\"name\" : \"$VIEW/System/Library/Frameworks/Foundation.framework/Headers/NSArray.h\"" "$J" || fail "NSArray.h is not named under the view"
grep -q "\"name\" : \"$PLAIN/" "$J" && fail "a header is still named under the plain SDK"
n=0
for f in $(sed -n 's/^ *"external-contents" : "\(.*\)",$/\1/p' "$J"); do
  [ -f "$f" ] || fail "the overlay maps onto $f, which does not exist"; n=$((n + 1))
done
[ "$n" -ge 2 ] || fail "only $n headers in the overlay"

echo "-- a view whose System is another SDK's is refused, before anything is written"
mkdir -p "$T/other/System" "$T/fakeview" && ln -s "$T/other/System" "$T/fakeview/System"
rc=0; recaulk_sdk_metadata_vfs "$PLAIN" "$T/fakeview" "$RECIPES" "$T/vfs2" foundation-array-generics-v2 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted a view of another SDK"; [ ! -e "$T/vfs2" ] || fail "wrote $T/vfs2 for a refused view"

echo "-- an unknown recipe id fails and leaves no output"
rc=0; recaulk_sdk_metadata_vfs "$PLAIN" "$VIEW" "$RECIPES" "$T/vfs3" no-such-recipe-v1 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted an unknown recipe id"; [ ! -e "$T/vfs3" ] || fail "left $T/vfs3 for an unknown recipe"
echo "PASS"
