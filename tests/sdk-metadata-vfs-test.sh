#!/bin/sh
# platform: macOS-only -- shipyard's cmake materializer, the cached 10.9 SDK and its with-sdk-settings-json view
# usage: sh tests/sdk-metadata-vfs-test.sh
#   lib.sh's recaulk_sdk_metadata_vfs materializes Recaulk's sdk-metadata recipes (shipyard's
#   mavericks_materialize_sdk_metadata) for the SDK view build.sh compiles the overlays against: a clang
#   VFS overlay whose every header is named under that view, none under the plain SDK it links to, each
#   mapped onto an edited copy that exists. It finds that plain SDK from the view's System, refuses a view whose
#   System is no SDK's, and leaves no output for a recipe id the file lacks. With a stand-in materializer, in
#   any build root: the rewrite takes any spacing around a name's colon and a path holding regex and sed
#   metacharacters, and fails, leaving nothing, when it moves no name or leaves one under the plain SDK.
#   The rest skips, saying so, without the SDKs, Recaulk or shipyard.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/sdk-metadata-vfs.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "-- the name rewrite, with a stand-in materializer writing overlay.json as \$STUB_JSON says"
mkdir -p "$T/fake/shipyard/scripts" "$T/fake/p.sdk&[x]/System" "$T/fake/p.sdk&[x]/usr/include" "$T/fake/view.sdk"
: > "$T/fake/shipyard/MavericksSDKMetadata.cmake"
ln -s "$T/fake/p.sdk&[x]/System" "$T/fake/view.sdk/System"
FP="$(CDPATH='' cd -P -- "$T/fake/p.sdk&[x]" && pwd -P)"; FV="$T/fake/view.sdk"
cat > "$T/fake/cmake" <<'STUB'
#!/bin/sh
for a; do case "$a" in -DSDK=*) sdk="${a#-DSDK=}" ;; -DOUT=*) out="${a#-DOUT=}" ;; esac; done
rep="$(printf '%s\n' "$sdk" | sed 's/[\\&|]/\\&/g')"
mkdir -p "$out" && sed "s|@PLAIN@|$rep|g" "$STUB_JSON" > "$out/overlay.json"
STUB
chmod +x "$T/fake/cmake"
# In a subshell: sh keeps a function call's prefix assignments after it returns.
stub() { ( SHIPYARD="$T/fake/shipyard/scripts"; CMAKE="$T/fake/cmake"; STUB_JSON="$T/stub.json"; export STUB_JSON
           recaulk_sdk_metadata_vfs "${1:-$FV}" r.json "$T/sout" x-v1 ); }
printf '%s\n' '{ "roots" : [' '  { "name":"@PLAIN@/System/a.h", "external-contents" : "/e/a.h" },' \
  '  { "name"   :   "@PLAIN@/usr/include/b.h", "external-contents" : "/e/b.h" } ] }' > "$T/stub.json"
stub 2> "$T/slog" || { cat "$T/slog" >&2; fail "the rewrite failed on names spaced otherwise than shipyard spaces them"; }
grep -Fq "\"name\":\"$FV/System/a.h\"" "$T/sout/overlay.json" && grep -Fq "\"name\"   :   \"$FV/usr/include/b.h\"" "$T/sout/overlay.json" \
  || fail "the names were not moved under the view: $(cat "$T/sout/overlay.json")"
grep -Fq "$FP/" "$T/sout/overlay.json" && fail "a name is still under the plain SDK $FP"
echo "-- a rewrite that moves no name fails and leaves nothing"
printf '%s\n' '{ "roots" : [ { "name" : "/elsewhere/a.h", "external-contents" : "/e/a.h" } ] }' > "$T/stub.json"
rc=0; stub 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted an overlay.json with no name under the plain SDK"; [ ! -e "$T/sout" ] || fail "left $T/sout"
echo "-- a name the rewrite leaves under the plain SDK fails and leaves nothing"
printf '%s\n' '{ "roots" : [ { "name" : "@PLAIN@/System/a.h" },' '  { "name" :' '    "@PLAIN@/usr/b.h" } ] }' > "$T/stub.json"
rc=0; stub 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted an overlay.json still naming a header under the plain SDK"; [ ! -e "$T/sout" ] || fail "left $T/sout"
echo "-- a view whose System resolves into no SDK is refused"
mkdir -p "$T/fake/bad.sdk" "$T/fake/notsdk/System"; ln -s "$T/fake/notsdk/System" "$T/fake/bad.sdk/System"
rc=0; stub "$T/fake/bad.sdk" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted a view whose System is in no SDK"; [ ! -e "$T/sout" ] || fail "left $T/sout"

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
echo "-- every header named under the view, mapped onto an edited copy"
recaulk_sdk_metadata_vfs "$VIEW" "$RECIPES" "$T/vfs" foundation-array-generics-v2 foundation-objcruntime-macros-v1 \
  > "$T/log" 2>&1 || { cat "$T/log" >&2; fail "recaulk_sdk_metadata_vfs failed"; }
J="$T/vfs/overlay.json"; [ -s "$J" ] || fail "no $J"
grep -q "\"name\" : \"$VIEW/System/Library/Frameworks/Foundation.framework/Headers/NSArray.h\"" "$J" || fail "NSArray.h is not named under the view"
grep -q "\"name\" : \"$PLAIN/" "$J" && fail "a header is still named under the plain SDK"
n=0
for f in $(sed -n 's/^ *"external-contents" : "\(.*\)",$/\1/p' "$J"); do
  [ -f "$f" ] || fail "the overlay maps onto $f, which does not exist"; n=$((n + 1))
done
[ "$n" -ge 2 ] || fail "only $n headers in the overlay"

echo "-- an unknown recipe id fails and leaves no output"
rc=0; recaulk_sdk_metadata_vfs "$VIEW" "$RECIPES" "$T/vfs3" no-such-recipe-v1 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "accepted an unknown recipe id"; [ ! -e "$T/vfs3" ] || fail "left $T/vfs3 for an unknown recipe"
echo "PASS"
