#!/bin/sh
# platform: host-agnostic
# usage: sh tests/stage-toolchain-test.sh
#   scripts/stage-toolchain.sh must lay out exactly the toolchain payload from a (fake) build, name a
#   missing input, and refuse an empty out-dir, or / by any name, before writing anything.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
( . "$REPO/msc.sh" ) >/dev/null 2>&1 || { echo "no shipyard -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/stage-toolchain.XXXXXX")"
trap 'rm -rf "$T"' EXIT
W="$T/work"
mkdir -p "$W/swift-x86/bin" "$W/swift-x86/share/swift/diagnostics" "$W/llvm-x86/bin" "$W/llvm-x86/lib/clang/21/include" \
  "$W/stdlib-build/lib/swift/macosx/x86_64" "$W/stdlib-build/lib/swift/macosx/Swift.swiftmodule" \
  "$W/stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule" "$W/stdlib-build/lib/swift/shims" "$W/llvm-project/llvm"
for f in swift-x86/bin/swift-frontend llvm-x86/bin/lld llvm-x86/bin/clang llvm-x86/lib/clang/21/include/stdint.h \
  stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftSwiftOnoneSupport.dylib \
  stdlib-build/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
  stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule \
  stdlib-build/lib/swift/macosx/layouts-x86_64.yaml stdlib-build/lib/swift/shims/module.modulemap \
  swift-x86/share/swift/compatibility-symbols swift-x86/share/swift/diagnostics/en.db \
  swift-x86/share/swift/diagnostics/en.strings swift-x86/share/swift/diagnostics/.gitkeep \
  swift-x86/share/swift/diagnostics/generated llvm-project/llvm/LICENSE.TXT; do
  echo "$f" > "$W/$f"
done

echo "-- refuses an empty out-dir, or / by any name, before writing anything"
# Every command that writes is faked (and fails), so a regressed guard fails this test instead of
# deleting /usr or writing into a writable /usr/local. $T/rootchild/.. is / only physically (as rm
# resolves it); /tmp/.. is / only logically on macOS, where /tmp is a symlink into /private.
mkdir -p "$T/fakebin"
for c in rm mkdir cp mv ln chmod; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/writes.log"\nexit 1\n' "$c" "$T" > "$T/fakebin/$c"; chmod +x "$T/fakebin/$c"
done
ln -s /bin "$T/rootchild"
for bad in "" // /. /tmp/.. "$T/rootchild/.."; do
  rc=0; PATH="$T/fakebin:$PATH" SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$bad" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "out-dir '$bad': exit $rc, not 2 (refused)"
  [ ! -f "$T/writes.log" ] || fail "tried to write, with out-dir '$bad': $(cat "$T/writes.log")"
done

echo "-- names a missing input"
mv "$W/llvm-x86/bin/lld" "$T/lld.away"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/out" 2> "$T/err"; then fail "staged without lld"; fi
grep -q 'llvm-x86/bin/lld' "$T/err" || fail "did not name the missing lld: $(cat "$T/err")"
mv "$T/lld.away" "$W/llvm-x86/bin/lld"

echo "-- refuses, naming them, when a reused build root holds more than one clang resource dir"
mkdir -p "$W/llvm-x86/lib/clang/22/include"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/out" 2> "$T/err"; then
  fail "staged with two clang resource dirs, picking one"
fi
grep -q 'lib/clang/21/include' "$T/err" && grep -q 'lib/clang/22/include' "$T/err" \
  || fail "did not name both clang resource dirs: $(cat "$T/err")"
[ ! -d "$T/out/usr" ] || fail "wrote a payload before refusing"
rm -r "$W/llvm-x86/lib/clang/22"

echo "-- lays out exactly the payload, replacing an earlier one, leaving Library/ alone"
mkdir -p "$T/out/usr/stale" "$T/out/Library/keep"
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/out"
P=usr/local/mavergreen/swift-toolchain
got="$(cd "$T/out" && find usr Library -type f | sort)"
want="$(printf '%s\n' "$P/bin/clang" "$P/bin/ld64.lld" "$P/bin/swift-frontend" "$P/bin/swiftc" \
  "$P/lib/clang/21/include/stdint.h" "$P/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule" "$P/lib/swift/macosx/layouts-x86_64.yaml" \
  "$P/lib/swift/macosx/libswiftCore.dylib" "$P/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib" \
  "$P/lib/swift/shims/module.modulemap" "$P/libexec/mavergreen-swift/fetch_sdk.sh" "$P/libexec/mavergreen-swift/ld" \
  "$P/libexec/mavergreen-swift/mavericks_fetch.sh" "$P/libexec/mavergreen-swift/sdk-pins.sh" \
  "$P/share/doc/LICENSE-LLVM.txt" "$P/share/doc/LICENSE.txt" "$P/share/doc/NOTICE" \
  "$P/share/swift/compatibility-symbols" "$P/share/swift/diagnostics/en.db" "$P/share/swift/diagnostics/en.strings" | sort)"
[ "$got" = "$want" ] || fail "payload is
$got
wanted
$want"
[ -d "$T/out/Library/keep" ] || fail "removed Library/, which is package-toolchain.sh's"
[ -x "$T/out/$P/bin/swiftc" ] && [ -x "$T/out/$P/libexec/mavergreen-swift/ld" ] || fail "wrappers not executable"
[ "$(readlink "$T/out/$P/lib/swift/clang")" = ../clang/21 ] || fail "lib/swift/clang is not a link to ../clang/21"
[ "$(readlink "$T/out/$P/bin/clang++")" = clang ] || fail "bin/clang++ is not a link to clang"
echo "PASS"
