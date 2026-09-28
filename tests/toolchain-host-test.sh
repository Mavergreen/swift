#!/bin/sh
# platform: host-agnostic
# usage: sh tests/toolchain-host-test.sh
#   lib.sh's helpers for building a toolchain for either host: toolchain_host_select must name each
#   host's build dirs, checkout, product and payload and refuse any other host; compiler_patches must
#   give arm64 every patch but 0002 and x86_64 every one, in order; toolchain_digest must hash the
#   three files the two toolchain pkgs share, and fail on a missing one; toolchain_digests_agree must
#   accept only two equal, whole digest lines.
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

echo "-- toolchain_digest: the three shared files, in order, or a failure naming the missing one"
P="$T/tc"; mkdir -p "$P/lib/swift/macosx" "$P/lib/clang/21/include" "$P/lib/clang/21/lib/darwin"
echo core > "$P/lib/swift/macosx/libswiftCore.dylib"; echo onone > "$P/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib"
echo rt > "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a"
h() { printf '%s\n' "$1" | shasum -a 256 | awk '{ print $1 }'; }
want="libswiftCore.dylib=$(h core) libswiftSwiftOnoneSupport.dylib=$(h onone) libclang_rt.osx.a=$(h rt)"
got="$(toolchain_digest "$P")"
[ "$got" = "$want" ] || fail "digest is '$got', not '$want'"
rm "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a"
if toolchain_digest "$P" > "$T/out" 2> "$T/err"; then fail "digested a prefix without the builtins archive: $(cat "$T/out")"; fi
grep -q 'lib/clang/21/lib/darwin/libclang_rt.osx.a' "$T/err" || fail "did not name the missing archive: $(cat "$T/err")"

echo "-- toolchain_digests_agree: equal whole lines only"
toolchain_digests_agree "$want" "$want" || fail "refused two equal lines"
other="libswiftCore.dylib=$(h core) libswiftSwiftOnoneSupport.dylib=$(h onone) libclang_rt.osx.a=$(h other)"
if toolchain_digests_agree "$want" "$other" 2> "$T/err"; then fail "accepted two different lines"; fi
grep -q 'they differ' "$T/err" || fail "did not say they differ: $(cat "$T/err")"
if toolchain_digests_agree "" "" 2>/dev/null; then fail "accepted two empty lines"; fi
part="libswiftCore.dylib=$(h core)"
if toolchain_digests_agree "$part" "$part" 2>/dev/null; then fail "accepted two equal partial lines"; fi
echo "PASS"
