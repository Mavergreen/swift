#!/bin/sh
# platform: host-agnostic
# usage: sh tests/swiftc-wrapper-test.sh
#   toolchain/swiftc must find its prefix through links -- the family link farm's relative one, an
#   absolute one, a chain -- put the 10.9 defaults before the user's arguments, honour SDKROOT without
#   fetching, and refuse to run on a failed SDK fetch or an SDK that is not a directory.
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
: > "$T/fetched"
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
-disable-implicit-concurrency-module-import
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
echo "PASS"
