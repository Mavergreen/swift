#!/bin/sh
# platform: host-agnostic
# usage: sh tests/toolchain-host-test.sh
#   lib.sh's helpers for building a toolchain for either host: toolchain_host_select must name each
#   host's build dirs, checkout, product and payload and refuse any other host; compiler_patches must
#   give arm64 every patch but 0002 and x86_64 every one, in order; toolchain_digest must hash every
#   file of the stdlib, shims and builtins trees the two toolchain pkgs share, sorted, and fail on a
#   missing anchor file, a link or a path with a space; toolchain_digests_agree must accept only two
#   equal, whole digest lines, and name what differs.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-host.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"

echo "-- toolchain_host_select: each host's names, and a refusal"
toolchain_host_select x86_64
[ "$TH_LLVM $TH_CMARK $TH_SWIFT $TH_CHECKOUT $TH_PRODUCT $TH_PAYLOAD" = "llvm-x86 cmark-x86 swift-x86 swift-compiler swift-toolchain toolchain" ] \
  || fail "x86_64: $TH_LLVM $TH_CMARK $TH_SWIFT $TH_CHECKOUT $TH_PRODUCT $TH_PAYLOAD"
toolchain_host_select arm64
[ "$TH_LLVM $TH_CMARK $TH_SWIFT $TH_CHECKOUT $TH_PRODUCT $TH_PAYLOAD" = "llvm-arm64 cmark-arm64 swift-arm64 swift-compiler-arm64 swift-toolchain-cross toolchain-cross" ] \
  || fail "arm64: $TH_LLVM $TH_CMARK $TH_SWIFT $TH_CHECKOUT $TH_PRODUCT $TH_PAYLOAD"
rc=0; toolchain_host_select x86 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] || fail "host 'x86': exit $rc, not 2"
grep -q "not 'x86'" "$T/err" || fail "did not name the bad host: $(cat "$T/err")"

echo "-- compiler_patches: the repo's patches/compiler, per host"
got="$(compiler_patches x86_64 "$REPO/patches/compiler" | sed 's|.*/||' | tr '\n' ' ')"
[ "$got" = "0001-accept-10.9-sdk.patch 0002-hosttools-rpath-loader-path.patch " ] || fail "x86_64 takes [$got]"
got="$(compiler_patches arm64 "$REPO/patches/compiler" | sed 's|.*/||' | tr '\n' ' ')"
[ "$got" = "0001-accept-10.9-sdk.patch " ] || fail "arm64 takes [$got]"
mkdir -p "$T/p"; for n in 0001-a 0002-b 0003-c; do : > "$T/p/$n.patch"; done
got="$(compiler_patches arm64 "$T/p" | sed 's|.*/||' | tr '\n' ' ')"
[ "$got" = "0001-a.patch 0003-c.patch " ] || fail "arm64 takes [$got] of 0001-0003: a later patch is both hosts'"
rc=0; compiler_patches ppc "$T/p" > /dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "host 'ppc': exit $rc, not 2"
mkdir -p "$T/none"
rc=0; compiler_patches x86_64 "$T/none" > /dev/null 2>&1 || rc=$?; [ "$rc" -eq 1 ] || fail "no patches: exit $rc, not 1"
rm "$T/p/0001-a.patch" "$T/p/0003-c.patch"
rc=0; compiler_patches arm64 "$T/p" > /dev/null 2>&1 || rc=$?; [ "$rc" -eq 1 ] || fail "only 0002 left, arm64: exit $rc, not 1"

echo "-- toolchain_digest: every file of the shared trees, sorted by path, or a failure naming what is wrong"
P="$T/tc"; M="$P/lib/swift/macosx"
mkdir -p "$M/Swift.swiftmodule" "$P/lib/swift/shims" "$P/lib/clang/21/include" "$P/lib/clang/21/lib/darwin" "$P/bin"
echo core > "$M/libswiftCore.dylib"; echo onone > "$M/libswiftSwiftOnoneSupport.dylib"; echo lay > "$M/layouts-x86_64.yaml"
echo mod > "$M/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"; echo api > "$M/Swift.swiftmodule/x86_64-apple-macos.swiftinterface"
echo map > "$P/lib/swift/shims/module.modulemap"; echo int > "$P/lib/swift/shims/SwiftStdint.h"
echo rt > "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a"
# Not shared, so not digested: clang's headers (each LLVM build's own), the tools, and the link to clang's dir.
echo hdr > "$P/lib/clang/21/include/stddef.h"; echo fe > "$P/bin/swift-frontend"; ln -s ../clang/21 "$P/lib/swift/clang"
h() { printf '%s\n' "$1" | shasum -a 256 | awk '{ print $1 }'; }
want="lib/clang/21/lib/darwin/libclang_rt.osx.a=$(h rt)"
want="$want lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftinterface=$(h api)"
want="$want lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule=$(h mod)"
want="$want lib/swift/macosx/layouts-x86_64.yaml=$(h lay)"
want="$want lib/swift/macosx/libswiftCore.dylib=$(h core) lib/swift/macosx/libswiftSwiftOnoneSupport.dylib=$(h onone)"
want="$want lib/swift/shims/SwiftStdint.h=$(h int) lib/swift/shims/module.modulemap=$(h map)"
got="$(toolchain_digest "$P")" || fail "toolchain_digest failed on a whole tree"
[ "$got" = "$want" ] || fail "digest is
  '$got', not
  '$want'"
echo mod2 > "$M/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
[ "$(toolchain_digest "$P")" != "$want" ] || fail "a changed swiftmodule left the digest as it was"
echo mod > "$M/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
for a in lib/clang/21/lib/darwin/libclang_rt.osx.a lib/swift/macosx/libswiftCore.dylib \
         lib/swift/macosx/libswiftSwiftOnoneSupport.dylib lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
         lib/swift/shims/module.modulemap; do
  mv "$P/$a" "$T/held"
  if toolchain_digest "$P" > "$T/out" 2> "$T/err"; then fail "digested a prefix without $a: $(cat "$T/out")"; fi
  grep -q "$P/$a" "$T/err" || fail "did not name the missing $a: $(cat "$T/err")"
  mv "$T/held" "$P/$a"
done
ln -s libswiftCore.dylib "$M/libswiftCompat.dylib"
if toolchain_digest "$P" > "$T/out" 2> "$T/err"; then fail "digested a tree holding a link: $(cat "$T/out")"; fi
grep -q 'libswiftCompat.dylib' "$T/err" || fail "did not name the link: $(cat "$T/err")"
rm "$M/libswiftCompat.dylib"
echo sp > "$P/lib/swift/shims/Sp ace.h"
if toolchain_digest "$P" > "$T/out" 2> "$T/err"; then fail "digested a path holding a space: $(cat "$T/out")"; fi
grep -q 'Sp ace.h' "$T/err" || fail "did not name the path holding a space: $(cat "$T/err")"
rm "$P/lib/swift/shims/Sp ace.h"
[ "$(toolchain_digest "$P")" = "$want" ] || fail "the restored tree's digest is not the first one"

echo "-- toolchain_digests_agree: equal whole lines only, naming what differs"
toolchain_digests_agree "$want" "$want" || fail "refused two equal lines"
other="$(printf '%s\n' "$want" | sed "s|layouts-x86_64.yaml=$(h lay)|layouts-x86_64.yaml=$(h other)|")"
[ "$other" != "$want" ] || fail "the test's other line is the same line"
if toolchain_digests_agree "$want" "$other" 2> "$T/err"; then fail "accepted two different lines"; fi
grep -q 'they differ' "$T/err" || fail "did not say they differ: $(cat "$T/err")"
grep -q "layouts-x86_64.yaml=$(h other)" "$T/err" || fail "did not name the entry that differs: $(cat "$T/err")"
if grep -q "libswiftCore.dylib=" "$T/err"; then fail "named an entry that agrees: $(cat "$T/err")"; fi
if toolchain_digests_agree "" "" 2>/dev/null; then fail "accepted two empty lines"; fi
if toolchain_digests_agree "$want x=$(h x)" "$want x=$(h x)" 2>/dev/null; then fail "accepted two equal lines with an entry outside lib/"; fi
# Partial: each anchor dropped, a hash cut short, and the three-file line this check once took.
for a in 'lib/clang/21/lib/darwin/libclang_rt.osx.a' 'lib/swift/macosx/libswiftCore.dylib' \
         'lib/swift/macosx/libswiftSwiftOnoneSupport.dylib' 'lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule' \
         'lib/swift/shims/module.modulemap'; do
  part="$(printf '%s\n' "$want" | tr ' ' '\n' | grep -v "^$a=" | tr '\n' ' ' | sed 's/ $//')"
  [ "$part" != "$want" ] || fail "the test did not drop $a"
  if toolchain_digests_agree "$part" "$part" 2> "$T/err"; then fail "accepted two equal lines without $a"; fi
  grep -q "${a##*/}" "$T/err" || fail "did not name the missing $a: $(cat "$T/err")"
done
if toolchain_digests_agree "$part" "$want" 2> "$T/err"; then fail "accepted a partial line against a whole one"; fi
grep -q "the first line is not" "$T/err" || fail "did not say the first line is partial: $(cat "$T/err")"
if toolchain_digests_agree "$want" "$part" 2> "$T/err"; then fail "accepted a whole line against a partial one"; fi
grep -q "the second line is not" "$T/err" || fail "did not say the second line is partial: $(cat "$T/err")"
cut="${want%?}"
zs="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
nothex="$(printf '%s\n' "$want" | sed "s|layouts-x86_64.yaml=$(h lay)|layouts-x86_64.yaml=$zs|")"
[ "$nothex" != "$want" ] || fail "the test did not replace a hash"
if toolchain_digests_agree "$nothex" "$nothex" 2>/dev/null; then fail "accepted two equal lines with a hash that is not hex"; fi
if toolchain_digests_agree "$cut" "$cut" 2>/dev/null; then fail "accepted two equal lines whose last hash is cut short"; fi
if toolchain_digests_agree "$want " "$want " 2>/dev/null; then fail "accepted two equal lines with an empty entry"; fi
old="libswiftCore.dylib=$(h core) libswiftSwiftOnoneSupport.dylib=$(h onone) libclang_rt.osx.a=$(h rt)"
if toolchain_digests_agree "$old" "$old" 2>/dev/null; then fail "accepted two equal three-file lines"; fi
echo "PASS"
