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
foo.swift
-o
foo"
[ "$out" = "$want" ] || fail "argv is
$out
wanted
$want"
# Swift's driver reads the SDK version only from SDKSettings.json: without it every link records SDK 0.
[ "$(cat "$T/fetched")" = 1 ] || fail "fetched the SDK with MAVERICKS_SDK_SETTINGS_JSON=$(cat "$T/fetched"), not 1"

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
