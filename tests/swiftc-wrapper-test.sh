#!/bin/sh
# platform: host-agnostic
# usage: sh tests/swiftc-wrapper-test.sh
#   toolchain/swiftc must find its prefix through links -- the family link farm's relative one, an
#   absolute one, a chain -- put the 10.9 defaults before the user's arguments, honour SDKROOT without
#   fetching, ask the fetch for the SDK that has SDKSettings.json, and refuse to run on a failed SDK
#   fetch or an SDK that is not a directory. The driver's linker, libexec/mavergreen-swift/ld, must run
#   ld64.lld with the toolchain's Recaulk archive (lib/recaulk/librecaulk.a) just before the driver's
#   -lobjc and -lSystem, so that every program and dylib swiftc links defines the Recaulk fixes and
#   back-fills it uses; leave a line without -lSystem as it was; and refuse to link without the archive,
#   or a line with a response file (@file), which could hide the -lSystem.
#   The driver is also given the importer's view of Recaulk's dispatch declarations: -Xcc -ivfsoverlay
#   with a YAML that names the SDK it was given, each of that SDK's usr/include/dispatch/*.h, and the
#   toolchain's lib/swift/recaulk-importer, byte for byte the YAML lib.sh's recaulk_vfs_yaml writes. The YAML is kept in a per-user, per-SDK, per-toolchain
#   cache, written whole (atomically) before the driver replaces the shell, so no temporary file is left
#   behind, whether the exec succeeds or fails; a toolchain without the importer's directory, or an SDK
#   path the YAML could not quote, is refused before the driver runs. With HOME unset, not a directory or
#   read-only the cache is ${TMPDIR:-/tmp}/mavergreen-swift-<uid> (mode 700) instead, and the compile goes on.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-wrapper.XXXXXX")"
trap 'rm -rf "$T"' EXIT
# platform: macOS's TMPDIR lives under /var, a symlink to /private/var; swiftc resolves its prefix
#           physically (pwd -P), so compare against the physical path.
T="$(cd "$T" && pwd -P)"
P="$T/mg/swift-toolchain"; mkdir -p "$P/bin" "$P/libexec/mavergreen-swift" "$T/mg/bin" "$T/links/deeper" \
  "$T/fake-sdk" "$T/other-sdk"
cp "$REPO/toolchain/swiftc" "$P/bin/swiftc"
mkdir -p "$P/lib/swift/recaulk-importer" "$T/fake-sdk/usr/include/dispatch"
# The SDK's own dispatch headers, each of which the YAML names (lib.sh's recaulk_vfs_yaml), beside files it does not.
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
chmod +x "$P/bin/"*

out="$("$P/bin/swiftc" foo.swift -o foo)"
# The importer's flags are the one thing whose value (the cache's YAML) the test reads back from the argv.
VFS="$(printf '%s\n' "$out" | awk 'prev == "-ivfsoverlay" { getline; print; exit } { prev = $0 }')"
[ -n "$VFS" ] || fail "no -ivfsoverlay in the driver's argv: $out"
want="OLD_DRIVER_QUIET=1
--driver-mode=swiftc
-target
x86_64-apple-macosx10.9
-sdk
$T/fake-sdk
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
foo.swift
-o
foo"
[ "$out" = "$want" ] || fail "argv is
$out
wanted
$want"
# Swift's driver reads the SDK version only from SDKSettings.json: without it every link records SDK 0.
[ "$(cat "$T/fetched")" = 1 ] || fail "fetched the SDK with MAVERICKS_SDK_SETTINGS_JSON=$(cat "$T/fetched"), not 1"

echo "-- the importer's overlay: the SDK it was given, lib.sh's YAML, one cached file, no temporary left"
case "$VFS" in "$CACHE"/*) ;; *) fail "the YAML is at $VFS, not in $CACHE" ;; esac
[ -f "$VFS" ] || fail "the YAML $VFS is not there afterwards"
grep -qF "'$T/fake-sdk/usr/include/dispatch'" "$VFS" || fail "the YAML does not name the SDK's usr/include/dispatch: $(cat "$VFS")"
grep -qF "'$P/lib/swift/recaulk-importer/dispatch/dispatch.h'" "$VFS" || fail "the YAML does not name the toolchain's importer: $(cat "$VFS")"
for f in base.h dispatch.h queue.h; do
  grep -qF "{ 'name': '$f', 'type': 'file', 'external-contents': '$T/fake-sdk/usr/include/dispatch/$f' }" "$VFS" \
    || fail "the YAML does not name the SDK's dispatch/$f, which a case-sensitive filesystem would not find as Dispatch/$f: $(cat "$VFS")"
done
. "$REPO/lib.sh"
recaulk_vfs_yaml "$T/fake-sdk" "$P/lib/swift/recaulk-importer" "$T/lib.yaml" || fail "recaulk_vfs_yaml failed"
cmp -s "$T/lib.yaml" "$VFS" || fail "the wrapper's YAML is not recaulk_vfs_yaml's:
$(diff "$T/lib.yaml" "$VFS")"
[ "$(ls -A "$CACHE" | wc -l | tr -d ' ')" = 1 ] || fail "the cache holds more than the YAML: $(ls -A "$CACHE")"
"$P/bin/swiftc" foo.swift | awk 'prev == "-ivfsoverlay" { getline; print; exit } { prev = $0 }' | grep -qxF "$VFS" || fail "a second run named another YAML"
[ "$(ls -A "$CACHE" | wc -l | tr -d ' ')" = 1 ] || fail "a second run left more in the cache: $(ls -A "$CACHE")"
VFS2="$(SDKROOT="$T/other-sdk" "$P/bin/swiftc" foo.swift | awk 'prev == "-ivfsoverlay" { getline; print; exit } { prev = $0 }')"
[ -n "$VFS2" ] && [ "$VFS2" != "$VFS" ] || fail "another SDK shares the first's YAML ($VFS2)"
grep -qF "'$T/other-sdk/usr/include/pthread'" "$VFS2" || fail "the other SDK's YAML does not name it: $(cat "$VFS2")"
[ "$(ls -A "$CACHE" | wc -l | tr -d ' ')" = 2 ] || fail "two SDKs, not two files: $(ls -A "$CACHE")"
# Whether or not exec succeeds, nothing but the cached YAMLs is left: it is written before the exec.
chmod -x "$P/bin/swift-frontend"; rc=0
"$P/bin/swiftc" foo.swift > "$T/out" 2> "$T/err" || rc=$?
chmod +x "$P/bin/swift-frontend"
[ "$rc" != 0 ] || fail "a swiftc whose driver cannot run succeeded"
[ "$(ls -A "$CACHE" | wc -l | tr -d ' ')" = 2 ] || fail "a failed exec left a file in the cache: $(ls -A "$CACHE")"
# A path with a quote would end the YAML's string early; refused, as a missing importer is, before the driver.
mkdir "$T/it's-sdk"; rm -f "$T/frontend-ran"; rc=0
SDKROOT="$T/it's-sdk" "$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver with a quote in the SDK's path"
grep -q "quote" "$T/err" || fail "a quoted SDK path was not explained: $(cat "$T/err")"
mv "$P/lib/swift/recaulk-importer" "$T/importer-away"; rc=0
"$P/bin/swiftc" x.swift > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver without the importer's directory"
grep -qF "no $P/lib/swift/recaulk-importer" "$T/err" || fail "a missing importer was not explained: $(cat "$T/err")"
mv "$T/importer-away" "$P/lib/swift/recaulk-importer"
# Without a usable HOME (unset, no directory, read-only) the cache moves to ${TMPDIR:-/tmp}/mavergreen-swift-<uid>,
# mode 700, and the compile goes on, with the same YAML and nothing else left there.
mkdir -p "$T/tmpdir"; U="$(id -u)"; FB="$T/tmpdir/mavergreen-swift-$U"
fallback_check() {  # fallback_check <what> <command>... -- runs swiftc under it; the YAML must be in $FB
  _fc_w="$1"; shift
  rm -rf "$FB" "$T/frontend-ran"; rc=0
  "$@" > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" = 0 ] || fail "$_fc_w: swiftc failed: $(cat "$T/err")"
  [ -f "$T/frontend-ran" ] || fail "$_fc_w: the driver did not run"
  _fc_y="$(awk 'prev == "-ivfsoverlay" { getline; print; exit } { prev = $0 }' "$T/out")"
  case "$_fc_y" in "$FB"/importer-*.yaml) ;; *) fail "$_fc_w: the YAML is at '$_fc_y', not in $FB" ;; esac
  cmp -s "$T/lib.yaml" "$_fc_y" || fail "$_fc_w: the fallback YAML is not lib.sh's"
  [ "$(ls -A "$FB" | wc -l | tr -d ' ')" = 1 ] || fail "$_fc_w: more than the YAML in $FB: $(ls -A "$FB")"
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
[ "$rc" != 0 ] && [ ! -f "$T/frontend-ran" ] || fail "ran the driver with no place to cache the YAML"
grep -q "could not write the importer's overlay" "$T/err" || fail "no cache place was not explained: $(cat "$T/err")"

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
SDKROOT="$T/other-sdk" "$P/bin/swiftc" x.swift | grep -qx -- "$T/other-sdk" || fail "SDKROOT not used"
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
