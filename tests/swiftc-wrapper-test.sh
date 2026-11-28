#!/bin/sh
# platform: host-agnostic
# usage: sh tests/swiftc-wrapper-test.sh
#   toolchain/swiftc must find its prefix through links -- the family link farm's relative one, an
#   absolute one, a chain -- put the 10.9 defaults before the user's arguments, honour SDKROOT without
#   fetching, ask the fetch for the plain SDK, and refuse to run on a failed SDK fetch or an SDK that is not a
#   directory. The driver's linker, libexec/mavergreen-swift/ld, must run ld64.lld with the toolchain's
#   Recaulk archive (lib/recaulk/librecaulk.a) just before the driver's -lobjc and -lSystem, so that every
#   program and dylib swiftc links defines the Recaulk fixes and back-fills it uses; leave a line without
#   -lSystem as it was; and refuse to link without the archive, or a line with a response file (@file),
#   which could hide the -lSystem.
#   The driver reads the SDK through the view the overlays were built against: -sdk its sdk/MacOSX10.9.sdk and
#   -Xcc -ivfsoverlay its overlay.json, which the toolchain's lib/swift/sdk-view/bin/recaulk-materialize makes,
#   given that directory's recipes.json and profiles.json by absolute path, in the per-user cache's
#   sdk-view/<sha256 of the toolchain's swift-foundation.stamp and the SDK's real path> -- once: a miss first
#   checks that the tool prints that stamp, a hit lets the tool check the view's. A view of another stamp, a
#   tool of another stamp, a view the tool cannot make, or a toolchain without the stamp is refused before the
#   driver runs, the first naming the stamp and the view to delete. The tool is given the plain SDK by its real
#   path (it writes the view's SDKSettings.json itself). Before the view's overlay the driver is given the importer's view
#   of Recaulk's dispatch declarations: -Xcc -ivfsoverlay with a YAML that names the view's SDK, each of
#   that SDK's usr/include/dispatch/*.h, and the toolchain's lib/swift/recaulk-importer, byte for byte the YAML lib.sh's recaulk_vfs_yaml writes, kept in
#   the cache beside the views, written whole (atomically) before the driver replaces the shell, so no
#   temporary file is left behind, whether the exec succeeds or fails; a toolchain without the importer's
#   directory, or a cache path the YAML could not quote, is refused before the driver runs. With HOME unset,
#   not a directory or read-only the cache is ${TMPDIR:-/tmp}/mavergreen-swift-<uid> (mode 700) instead, and
#   the compile goes on. The toolchain may be read-only: nothing is written under it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-wrapper.XXXXXX")"
trap 'rm -rf "$T"' EXIT
# platform: macOS's TMPDIR lives under /var, a symlink to /private/var; swiftc resolves its prefix
#           physically (pwd -P), so compare against the physical path.
T="$(cd "$T" && pwd -P)"
P="$T/mg/swift-toolchain"; mkdir -p "$P/bin" "$P/libexec/mavergreen-swift" "$T/mg/bin" "$T/links/deeper" \
  "$T/fake-sdk/System" "$T/fake-sdk/usr/include" "$T/other-sdk/System" "$T/other-sdk/usr/include" \
  "$P/lib/swift/sdk-view/bin" "$P/lib/swift/sdk-view/share/sdk-metadata"
cp "$REPO/toolchain/swiftc" "$P/bin/swiftc"
mkdir -p "$P/lib/swift/recaulk-importer" "$T/fake-sdk/usr/include/dispatch"
# The SDK's own dispatch headers, which the view copies and the YAML names, the view's copies (lib.sh's recaulk_vfs_yaml),
# beside files it does not.
for f in base.h dispatch.h queue.h introspection.d module.map; do : > "$T/fake-sdk/usr/include/dispatch/$f"; done
HOME="$T/home"; export HOME; CACHE="$HOME/Library/Caches/mavergreen-swift"
cat > "$P/bin/swift-frontend" <<EOF
#!/bin/sh
: > "$T/frontend-ran"
echo "OLD_DRIVER_QUIET=\${SWIFT_AVOID_WARNING_USING_OLD_DRIVER:-unset}"
for a in "\$@"; do echo "\$a"; done
EOF
cat > "$P/libexec/mavergreen-swift/fetch_sdk.sh" <<EOF
#!/bin/sh
echo "\${MAVERICKS_SDK_SETTINGS_JSON:-unset}" > "$T/fetched"
[ -f "$T/fetch-fails" ] && exit 1
[ -f "$T/fetch-empty" ] && exit 0
echo "$T/fake-sdk"
EOF
# A recaulk-materialize as Recaulk's answers: --print-stamp prints the stamp (the file $T/tool-stamp, which a case
# changes to make the tool disagree with the staged one); --sdk S --out O makes O (sdk/MacOSX10.9.sdk, overlay.json
# and stamp.json, the stamp and S), or, for an O that exists, exits 0 if its stamp.json is that and 1 if not.
# Each run's arguments go to $T/mat.log, one run a line; $T/mat-fails makes a materialization fail.
cat > "$P/lib/swift/sdk-view/bin/recaulk-materialize" <<EOF
#!/bin/sh
echo "\$*" >> "$T/mat.log"
sdk=""; out=""; ps=""; prof=""; rec=""; pro=""
while [ \$# -gt 0 ]; do case "\$1" in
  --print-stamp) ps=1; shift ;; --sdk) sdk="\$2"; shift 2 ;; --out) out="\$2"; shift 2 ;;
  --profile) prof="\$2"; shift 2 ;; --recipes) rec="\$2"; shift 2 ;; --profiles) pro="\$2"; shift 2 ;;
  *) echo "recaulk-materialize: \$1?" >&2; exit 2 ;; esac; done
case "\$prof:\$rec:\$pro" in swift-foundation:/*/recipes.json:/*/profiles.json) ;; *) echo "recaulk-materialize: usage" >&2; exit 2 ;; esac
if [ -n "\$ps" ]; then cat "$T/tool-stamp"; exit 0; fi
want="\$(cat "$T/tool-stamp") \$sdk"
if [ -e "\$out" ]; then
  [ "\$(cat "\$out/stamp.json")" = "\$want" ] && exit 0
  echo "recaulk-materialize: --out \$out holds a tree made for another stamp" >&2; exit 1
fi
[ ! -f "$T/mat-fails" ] || { echo "recaulk-materialize: recipe x does not apply" >&2; exit 1; }
mkdir -p "\$out/sdk/MacOSX10.9.sdk" && echo '{}' > "\$out/overlay.json" && echo "\$want" > "\$out/stamp.json"
# The view's SDK holds the plain SDK's headers, as Recaulk's does (copies): here, its dispatch dir.
if [ -d "\$sdk/usr/include/dispatch" ]; then mkdir -p "\$out/sdk/MacOSX10.9.sdk/usr/include" && cp -R "\$sdk/usr/include/dispatch" "\$out/sdk/MacOSX10.9.sdk/usr/include/"; fi
EOF
echo '{"profile":"swift-foundation","ids":["a-v1"]}' > "$T/tool-stamp"
cp "$T/tool-stamp" "$P/lib/swift/sdk-view/swift-foundation.stamp"
echo '{}' > "$P/lib/swift/sdk-view/share/sdk-metadata/recipes.json"; echo '{}' > "$P/lib/swift/sdk-view/share/sdk-metadata/profiles.json"
chmod +x "$P/bin/"* "$P/lib/swift/sdk-view/bin/recaulk-materialize"
# The view's key: sha256 of the stamp line and the SDK's real path, a line each.
sha() { printf '%s\n%s\n' "$(cat "$P/lib/swift/sdk-view/swift-foundation.stamp")" "$1" | shasum -a 256 | awk '{ print $1 }'; }
# What the driver was handed: the value after the first <flag>, past a -Xcc (the frontend's flags come as pairs).
argv_after() { awk -v f="$1" 'prev == f && $0 != "-Xcc" { print; exit } $0 != "-Xcc" { prev = $0 }'; }
# The toolchain is read-only, as an installed one may be: the view and YAML are written in the cache, never there.
chmod -R a-w "$P"; trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT

out="$("$P/bin/swiftc" foo.swift -o foo)"
VIEW="$CACHE/sdk-view/$(sha "$T/fake-sdk")"
VFS="$(printf '%s\n' "$out" | argv_after -ivfsoverlay)"
[ -n "$VFS" ] || fail "no -ivfsoverlay in the driver's argv: $out"
want="OLD_DRIVER_QUIET=1
--driver-mode=swiftc
-target
x86_64-apple-macosx10.9
-sdk
$VIEW/sdk/MacOSX10.9.sdk
-tools-directory
$P/libexec/mavergreen-swift
-runtime-compatibility-version
none
-Xfrontend
-disable-implicit-string-processing-module-import
-no-stdlib-rpath
-Xlinker
-rpath
-Xlinker
/usr/local/mavergreen/swift-runtime/lib/swift
-Xcc
-ivfsoverlay
-Xcc
$VFS
-Xcc
-ivfsoverlay
-Xcc
$VIEW/overlay.json
foo.swift
-o
foo"
[ "$out" = "$want" ] || fail "argv is
$out
wanted
$want"
# The view brings its own SDKSettings.json, so the plain SDK is fetched.
[ "$(cat "$T/fetched")" = unset ] || fail "fetched the SDK with MAVERICKS_SDK_SETTINGS_JSON=$(cat "$T/fetched"), not unset"

echo "-- the SDK view: made once per stamp and SDK by the toolchain's tool, with its data, and held to the stamp"
SV="$P/lib/swift/sdk-view"
[ "$(sed -n 1p "$T/mat.log")" = "--print-stamp --profile swift-foundation --recipes $SV/share/sdk-metadata/recipes.json --profiles $SV/share/sdk-metadata/profiles.json" ] \
  || fail "a miss did not first ask the tool for its stamp, with the toolchain's data: $(cat "$T/mat.log")"
[ "$(sed -n 2p "$T/mat.log")" = "--sdk $T/fake-sdk --out $VIEW --profile swift-foundation --recipes $SV/share/sdk-metadata/recipes.json --profiles $SV/share/sdk-metadata/profiles.json" ] \
  || fail "the view was not made from the SDK into $VIEW with the toolchain's data: $(cat "$T/mat.log")"
[ -f "$VIEW/stamp.json" ] || fail "no view at $VIEW"
: > "$T/mat.log"
"$P/bin/swiftc" foo.swift | argv_after -sdk | grep -qxF "$VIEW/sdk/MacOSX10.9.sdk" || fail "a second run named another view"
[ "$(wc -l < "$T/mat.log" | tr -d ' ')" = 1 ] && grep -q "^--sdk $T/fake-sdk --out $VIEW " "$T/mat.log" \
  || fail "a second run did not take the tool's one-read path: $(cat "$T/mat.log")"
# The SDK is handed to the tool as it is, by its real path: a link to it gets its view, and nothing else is resolved.
ln -s "$T/fake-sdk" "$T/sdk-link"; : > "$T/mat.log"
SDKROOT="$T/sdk-link" "$P/bin/swiftc" foo.swift | argv_after -sdk | grep -qxF "$VIEW/sdk/MacOSX10.9.sdk" \
  || fail "a link to the SDK did not get its view"
grep -q "^--sdk $T/fake-sdk --out $VIEW " "$T/mat.log" || fail "the tool was not given the SDK's real path: $(cat "$T/mat.log")"
# A stamp mismatch inside the cache: refused before the driver, naming the stamp and the view to delete.
echo "another" > "$VIEW/stamp.json"; rm -f "$T/frontend-ran"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver over a view made for another stamp"
grep -qF "delete $VIEW" "$T/err" && grep -qF "$SV/swift-foundation.stamp" "$T/err" \
  || fail "a mismatched view was not explained, naming the stamp and the view to delete: $(cat "$T/err")"
rm -rf "$VIEW"
# A tool whose stamp is not the staged one (its data changed under it): refused, before any view is made.
echo '{"profile":"swift-foundation","ids":["b-v1"]}' > "$T/tool-stamp"; rm -f "$T/frontend-ran"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] && [ ! -e "$VIEW" ] || fail "made a view with a tool whose stamp is not the staged one"
grep -qF "reinstall" "$T/err" || fail "a tool of another stamp was not explained: $(cat "$T/err")"
cp "$SV/swift-foundation.stamp" "$T/tool-stamp"
# A view the tool cannot make: refused, before the driver.
: > "$T/mat-fails"; rm -f "$T/frontend-ran"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver when the view could not be made"
grep -q "recipe x does not apply" "$T/err" && grep -q "could not make the SDK view of $T/fake-sdk" "$T/err" \
  || fail "a failed view was not explained: $(cat "$T/err")"
rm -f "$T/mat-fails"
# A toolchain without the stamp: refused, before the driver.
chmod u+w "$SV"; mv "$SV/swift-foundation.stamp" "$T/stamp-away"; rm -f "$T/frontend-ran"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver without the toolchain's stamp"
grep -qF "no $SV/swift-foundation.stamp" "$T/err" || fail "a missing stamp was not explained: $(cat "$T/err")"
mv "$T/stamp-away" "$SV/swift-foundation.stamp"; chmod a-w "$SV"
# Deleting the view, as the refusal says, is the fix: the next compile makes it again.
"$P/bin/swiftc" x.swift > /dev/null && [ -f "$VIEW/stamp.json" ] || fail "the next compile did not make the deleted view again"

echo "-- the importer's overlay: the view's SDK, lib.sh's YAML, one cached file a view, no temporary left"
case "$VFS" in "$CACHE"/importer-*.yaml) ;; *) fail "the YAML is at $VFS, not in $CACHE" ;; esac
[ -f "$VFS" ] || fail "the YAML $VFS is not there afterwards"
grep -qF "'$VIEW/sdk/MacOSX10.9.sdk/usr/include/dispatch'" "$VFS" || fail "the YAML does not name the view's usr/include/dispatch: $(cat "$VFS")"
grep -qF "'$P/lib/swift/recaulk-importer/dispatch/dispatch.h'" "$VFS" || fail "the YAML does not name the toolchain's importer: $(cat "$VFS")"
for f in base.h dispatch.h queue.h; do
  grep -qF "{ 'name': '$f', 'type': 'file', 'external-contents': '$VIEW/sdk/MacOSX10.9.sdk/usr/include/dispatch/$f' }" "$VFS" \
    || fail "the YAML does not name the SDK's dispatch/$f, which a case-sensitive filesystem would not find as Dispatch/$f: $(cat "$VFS")"
done
. "$REPO/lib.sh"
recaulk_vfs_yaml "$VIEW/sdk/MacOSX10.9.sdk" "$P/lib/swift/recaulk-importer" "$T/lib.yaml" || fail "recaulk_vfs_yaml failed"
cmp -s "$T/lib.yaml" "$VFS" || fail "the wrapper's YAML is not recaulk_vfs_yaml's:
$(diff "$T/lib.yaml" "$VFS")"
yamls() { ls -A "$CACHE" | grep -v '^sdk-view$' | wc -l | tr -d ' '; }
[ "$(yamls)" = 1 ] || fail "the cache holds more than the YAML and the views: $(ls -A "$CACHE")"
VFS2="$(SDKROOT="$T/other-sdk" "$P/bin/swiftc" foo.swift | argv_after -ivfsoverlay)"
[ -n "$VFS2" ] && [ "$VFS2" != "$VFS" ] || fail "another SDK's view shares the first's YAML ($VFS2)"
grep -qF "'$CACHE/sdk-view/$(sha "$T/other-sdk")/sdk/MacOSX10.9.sdk/usr/include/pthread'" "$VFS2" || fail "the other SDK's YAML does not name its view: $(cat "$VFS2")"
[ "$(yamls)" = 2 ] || fail "two views, not two YAMLs: $(ls -A "$CACHE")"
[ "$(ls -A "$CACHE/sdk-view" | wc -l | tr -d ' ')" = 2 ] || fail "two SDKs, not two views: $(ls -A "$CACHE/sdk-view")"
# Whether or not exec succeeds, nothing but the cached YAMLs and views is left: they are written before the exec.
chmod u+w "$P/bin" "$P/bin/swift-frontend"; chmod -x "$P/bin/swift-frontend"; rc=0
"$P/bin/swiftc" foo.swift > "$T/out" 2> "$T/err" || rc=$?
chmod +x "$P/bin/swift-frontend"; chmod a-w "$P/bin" "$P/bin/swift-frontend"
[ "$rc" != 0 ] || fail "a swiftc whose driver cannot run succeeded"
[ "$(yamls)" = 2 ] || fail "a failed exec left a file in the cache: $(ls -A "$CACHE")"
# A cache path with a quote would end the YAML's string early; refused, as a missing importer is, before the driver.
mkdir "$T/it's-home"; rm -f "$T/frontend-ran"; rc=0
HOME="$T/it's-home" "$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver with a quote in the YAML's paths"
grep -q "quote" "$T/err" || fail "a quoted path was not explained: $(cat "$T/err")"
chmod u+w "$P/lib/swift" "$P/lib/swift/recaulk-importer"; mv "$P/lib/swift/recaulk-importer" "$T/importer-away"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver without the importer's directory"
grep -qF "$P/lib/swift/recaulk-importer" "$T/err" || fail "a missing importer was not explained: $(cat "$T/err")"
mv "$T/importer-away" "$P/lib/swift/recaulk-importer"; chmod a-w "$P/lib/swift" "$P/lib/swift/recaulk-importer"
# Without a usable HOME (unset, no directory, read-only) the cache moves to ${TMPDIR:-/tmp}/mavergreen-swift-<uid>,
# mode 700, and the compile goes on, with the same YAML and nothing else there but the view.
mkdir -p "$T/tmpdir"; U="$(id -u)"; FB="$T/tmpdir/mavergreen-swift-$U"
fallback_check() {  # fallback_check <what> <command>... -- runs swiftc under it; the YAML and view must be in $FB
  _fc_w="$1"; shift
  rm -rf "$FB" "$T/frontend-ran"; rc=0
  "$@" > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" = 0 ] || fail "$_fc_w: swiftc failed: $(cat "$T/err")"
  [ -f "$T/frontend-ran" ] || fail "$_fc_w: the driver did not run"
  _fc_y="$(argv_after -ivfsoverlay < "$T/out")"
  case "$_fc_y" in "$FB"/importer-*.yaml) ;; *) fail "$_fc_w: the YAML is at '$_fc_y', not in $FB" ;; esac
  _fc_v="$FB/sdk-view/$(sha "$T/fake-sdk")"
  [ "$(argv_after -sdk < "$T/out")" = "$_fc_v/sdk/MacOSX10.9.sdk" ] || fail "$_fc_w: the view is not $_fc_v"
  recaulk_vfs_yaml "$_fc_v/sdk/MacOSX10.9.sdk" "$P/lib/swift/recaulk-importer" "$T/fb.yaml"
  cmp -s "$T/fb.yaml" "$_fc_y" || fail "$_fc_w: the fallback YAML is not lib.sh's"
  [ "$(ls -A "$FB" | wc -l | tr -d ' ')" = 2 ] || fail "$_fc_w: more than the YAML and the views in $FB: $(ls -A "$FB")"
  [ "$(ls -ld "$FB" | cut -c1-10)" = drwx------ ] || fail "$_fc_w: $FB is not mode 700: $(ls -ld "$FB")"
}
fallback_check "HOME unset" env -u HOME TMPDIR="$T/tmpdir" "$P/bin/swiftc" x.swift
echo "not a directory" > "$T/home-file"
fallback_check "HOME a file" env HOME="$T/home-file" TMPDIR="$T/tmpdir" "$P/bin/swiftc" x.swift
mkdir -p "$T/ro-home"; chmod 555 "$T/ro-home"
if [ "$U" != 0 ]; then fallback_check "HOME read-only" env HOME="$T/ro-home" TMPDIR="$T/tmpdir" "$P/bin/swiftc" x.swift; fi
chmod 755 "$T/ro-home"
# With a usable HOME the fallback is not touched.
rm -rf "$FB"; "$P/bin/swiftc" x.swift > /dev/null
[ ! -e "$FB" ] || fail "a usable HOME still made $FB"
# Neither usable: refused, naming it, before the driver.
rm -f "$T/frontend-ran"; rc=0
env -u HOME TMPDIR="$T/home-file" "$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver with no place to cache the view"
grep -q "could not write the SDK view or the importer's overlay" "$T/err" || fail "no cache place was not explained: $(cat "$T/err")"
chmod -R u+w "$P"

ln -s ../swift-toolchain/bin/swiftc "$T/mg/bin/swiftc"
ln -s "$P/bin/swiftc" "$T/links/abs-swiftc"
ln -s ../abs-swiftc "$T/links/deeper/chained-swiftc"
for s in "$T/mg/bin/swiftc" "$T/links/abs-swiftc" "$T/links/deeper/chained-swiftc"; do
  "$s" x.swift | grep -qx -- "$P/libexec/mavergreen-swift" || fail "through $s the prefix was not found"
done

# A relative link inside a directory reached through a symlinked directory: its ".." is the physical
# parent (real/), not the lexical one ($T), so a lexical cd walks out of the tree.
mkdir -p "$T/real/links"
ln -s ../../mg/swift-toolchain/bin/swiftc "$T/real/links/swiftc"
ln -s real/links "$T/alias"
"$T/alias/swiftc" x.swift | grep -qx -- "$P/libexec/mavergreen-swift" \
  || fail "through a symlinked directory ($T/alias/swiftc) the prefix was not found"

# An exported CDPATH makes a cd to a relative directory print where it went, into BIN.
( cd "$T" && CDPATH="$T" && export CDPATH && mg/bin/swiftc x.swift ) | grep -qx -- "$P/libexec/mavergreen-swift" \
  || fail "with CDPATH exported, run by a relative path, the prefix was not found"

rm -f "$T/fetched"
SDKROOT="$T/other-sdk" "$P/bin/swiftc" x.swift | grep -qx -- "$CACHE/sdk-view/$(sha "$T/other-sdk")/sdk/MacOSX10.9.sdk" \
  || fail "SDKROOT's view not used"
[ ! -f "$T/fetched" ] || fail "fetched the SDK although SDKROOT was set"

: > "$T/fetch-fails"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] || fail "ran the compiler after a failed SDK fetch: $(cat "$T/out")"
grep -q 'could not obtain the Mac OS X 10.9 SDK' "$T/err" || fail "failed fetch not explained"
rm -f "$T/fetch-fails"

# Neither a fetcher that succeeds without naming an SDK, nor an SDKROOT naming no directory, may reach
# the compiler, whose own complaint would not say that the SDK is what is missing.
: > "$T/fetch-empty"; rm -f "$T/frontend-ran"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the compiler although the fetcher named no SDK: $(cat "$T/out")"
grep -q "no Mac OS X 10.9 SDK at ''" "$T/err" || fail "an empty fetch was not explained: $(cat "$T/err")"
rm -f "$T/fetch-empty" "$T/frontend-ran"; rc=0
SDKROOT="$T/no-such-sdk" "$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the compiler with SDKROOT naming no directory: $(cat "$T/out")"
grep -q "no Mac OS X 10.9 SDK at '$T/no-such-sdk'" "$T/err" || fail "a missing SDKROOT was not explained: $(cat "$T/err")"

echo "-- the driver's linker: Recaulk's archive before the driver's -lobjc -lSystem, nowhere else"
cp "$REPO/toolchain/ld" "$P/libexec/mavergreen-swift/ld"; chmod +x "$P/libexec/mavergreen-swift/ld"
cat > "$P/bin/ld64.lld" <<EOF
#!/bin/sh
: > "$T/lld-ran"
for a in "\$@"; do echo "\$a"; done
EOF
chmod +x "$P/bin/ld64.lld"
mkdir -p "$P/lib/recaulk"; : > "$P/lib/recaulk/librecaulk.a"
RK="$P/lib/recaulk/librecaulk.a"
LD="$P/libexec/mavergreen-swift/ld"
# The swift driver's line for a program (-dylib for -emit-library): its objects, the user's inputs, the
# builtins, -lobjc -lSystem, then the user's -L, -framework, -l and -Xlinker arguments.
got="$("$LD" /t/p.o u.o rt.a -syslibroot /sdk -lobjc -lSystem -arch x86_64 -L mydir -framework Foo -lfoo -lSystem -XL -o main)"
want="/t/p.o
u.o
rt.a
-syslibroot
/sdk
$RK
-lobjc
-lSystem
-arch
x86_64
-L
mydir
-framework
Foo
-lfoo
-lSystem
-XL
-o
main"
[ "$got" = "$want" ] || fail "ld's argv is
$got
wanted
$want"
got="$("$LD" /t/p.o -dylib rt.a -syslibroot /sdk -lSystem -o libp.dylib | tr '\n' ' ')"
[ "$got" = "/t/p.o -dylib rt.a -syslibroot /sdk $RK -lSystem -o libp.dylib " ] || fail "a dylib's link: $got"
# A line without -lSystem is no program the driver links (ld -v, say): it reaches lld as it was.
[ "$("$LD" -v | tr '\n' ' ')" = "-v " ] || fail "a line without -lSystem was changed: $("$LD" -v)"
[ -z "$("$LD")" ] || fail "an empty line was changed: $("$LD")"
# Through a link to the toolchain's libexec, the archive is still the toolchain's.
ln -s "$LD" "$T/links/ld"
"$T/links/ld" x.o -lSystem | grep -qxF -- "$RK" || fail "through a link, ld did not find $RK"
rm -f "$T/lld-ran"; mv "$RK" "$T/rk-away"; rc=0
"$LD" x.o -lSystem > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/lld-ran" ] || fail "linked without the Recaulk archive: $(cat "$T/out")"
grep -qF "no Recaulk archive at $RK" "$T/err" || fail "a missing archive was not explained: $(cat "$T/err")"
mv "$T/rk-away" "$RK"
# A response file (-Xlinker @file) could hide the -lSystem the archive must precede: refused, never linked.
# An @-path that names no file (an rpath's @executable_path) is no response file, to lld or here.
got="$("$LD" x.o -rpath @executable_path/../lib -lSystem | tr '\n' ' ')"
[ "$got" = "x.o -rpath @executable_path/../lib $RK -lSystem " ] || fail "an @executable_path rpath: $got"
echo '-lSystem' > "$T/rsp"
for line in "@$T/rsp" "x.o @$T/rsp -lSystem"; do
  rm -f "$T/lld-ran"; rc=0
  # shellcheck disable=SC2086  # the line's words, as the driver passes them
  "$LD" $line > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" != 0 ] && [ ! -f "$T/lld-ran" ] || fail "linked a line with a response file ($line): $(cat "$T/out")"
  grep -qF "a response file ($T/rsp)" "$T/err" || fail "a response file was not explained: $(cat "$T/err")"
done
echo "PASS"
