#!/bin/sh
# platform: host-agnostic
# usage: sh tests/stage-toolchain-test.sh
#   scripts/stage-toolchain.sh must lay out exactly the toolchain payload from a (fake) build, the
#   builtins archive in clang's resource dir included, name a missing input, and refuse an empty
#   out-dir, or / by any name, or an unknown STAGE_HOST, before writing anything; bare clang's
#   clang.cfg and clang++.cfg are toolchain/clang.cfg. With STAGE_HOST=arm64 it must lay out the cross
#   toolchain from the arm64 build dirs: the same files, the same bytes but for what each LLVM and
#   Swift build makes itself (the three binaries, clang's headers, the helper outputs). --frontend,
#   --stdlib and --builtins name those inputs elsewhere: the stdlib from a stdlib build's lib/swift or a
#   staged toolchain's (CI stages the native toolchain with the cross pkg's, self-host.sh a stage with the
#   previous stage's), the same payload either way; a --stdlib that is neither, or an unknown option, is
#   refused before anything is written.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
( . "$REPO/msc.sh" ) >/dev/null 2>&1 || { echo "no shipyard -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/stage-toolchain.XXXXXX")"
trap 'rm -rf "$T"' EXIT
W="$T/work"
. "$REPO/tests/lib/fake-toolchain-build.sh"
fake_toolchain_build "$W"

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
for f in llvm-x86/bin/lld builtins-x86/lib/darwin/libclang_rt.osx.a; do
  mv "$W/$f" "$T/away"
  if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/out" 2> "$T/err"; then fail "staged without $f"; fi
  grep -q "$f" "$T/err" || fail "did not name the missing $f: $(cat "$T/err")"
  mv "$T/away" "$W/$f"
done

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
want="$(printf '%s\n' "$P/bin/clang" "$P/bin/clang.cfg" "$P/bin/clang++.cfg" "$P/bin/ld64.lld" "$P/bin/swift-frontend" "$P/bin/swiftc" \
  "$P/lib/clang/21/include/stdint.h" "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a" \
  "$P/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule" \
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
[ "$(cat "$T/out/$P/lib/clang/21/lib/darwin/libclang_rt.osx.a")" = builtins-x86/lib/darwin/libclang_rt.osx.a ] \
  || fail "lib/clang/21/lib/darwin/libclang_rt.osx.a is not build-builtins.sh's archive"
[ "$(readlink "$T/out/$P/bin/clang++")" = clang ] || fail "bin/clang++ is not a link to clang"
for c in clang.cfg clang++.cfg; do
  cmp -s "$REPO/toolchain/clang.cfg" "$T/out/$P/bin/$c" || fail "bin/$c is not toolchain/clang.cfg"
done

echo "-- --stdlib from a staged toolchain's lib/swift, --frontend and --builtins elsewhere: the same payload"
mkdir -p "$T/fe/bin" "$T/fe/share/swift/diagnostics"
for f in bin/swift-frontend share/swift/compatibility-symbols share/swift/diagnostics/en.db share/swift/diagnostics/en.strings; do
  echo "other $f" > "$T/fe/$f"
done
echo "other archive" > "$T/other.a"
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --frontend "$T/fe" --stdlib "$T/out/$P/lib/swift" --builtins "$T/other.a" "$T/out2"
got="$(cd "$T/out2" && find usr -type f | sort)"
[ "$got" = "$want" ] || fail "payload from a toolchain's stdlib is
$got
wanted
$want"
( cd "$T/out/$P" && find lib/swift -type f ) | while IFS= read -r f; do
  cmp -s "$T/out/$P/$f" "$T/out2/$P/$f" || fail "$f, staged from the toolchain's lib/swift, differs from the stdlib build's"
done
cmp -s "$T/other.a" "$T/out2/$P/lib/clang/21/lib/darwin/libclang_rt.osx.a" || fail "--builtins did not name the staged archive"
[ "$(cat "$T/out2/$P/bin/swift-frontend")" = "other bin/swift-frontend" ] || fail "--frontend did not name the staged frontend"
[ "$(cat "$T/out2/$P/share/swift/diagnostics/en.db")" = "other share/swift/diagnostics/en.db" ] || fail "--frontend did not name the helper outputs"

echo "-- refuses a --stdlib that is no stdlib, and an unknown option, before writing anything"
mkdir -p "$T/notstdlib/macosx"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --stdlib "$T/notstdlib" "$T/out3" 2> "$T/err"; then fail "staged from a dir that is no stdlib"; fi
grep -q "$T/notstdlib is no stdlib" "$T/err" || fail "did not name the bad --stdlib: $(cat "$T/err")"
[ ! -e "$T/out3" ] || fail "wrote $T/out3 before refusing the bad --stdlib"
rc=0; SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --stdib "$T/out/$P/lib/swift" "$T/out4" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "--stdib: exit $rc, not 2"
rc=0; SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --stdlib "$T/out4" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "--stdlib with no out-dir: exit $rc, not 2"
[ ! -e "$T/out4" ] || fail "wrote $T/out4 on a usage error"

echo "-- refuses an unknown STAGE_HOST before writing anything"
rc=0; STAGE_HOST=x86 SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/bad" 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] || fail "STAGE_HOST=x86: exit $rc, not 2"
[ ! -e "$T/bad" ] || fail "STAGE_HOST=x86 wrote $T/bad before refusing"
grep -q "not 'x86'" "$T/err" || fail "did not name the bad host: $(cat "$T/err")"

echo "-- STAGE_HOST=arm64: the cross toolchain, from the arm64 build, with the native payload's stdlib, wrappers and cfgs"
fake_toolchain_build "$W" arm64
STAGE_HOST=arm64 SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" "$T/xout"
X=usr/local/mavergreen/swift-toolchain-cross
got="$(cd "$T/xout" && find usr -type f | sort)"
xwant="$(printf '%s\n' "$want" | sed "s|^$P/|$X/|" | sort)"
[ "$got" = "$xwant" ] || fail "cross payload is
$got
wanted
$xwant"
for f in bin/swift-frontend:swift-arm64/bin/swift-frontend bin/ld64.lld:llvm-arm64/bin/lld bin/clang:llvm-arm64/bin/clang \
         share/swift/compatibility-symbols:swift-arm64/share/swift/compatibility-symbols \
         share/swift/diagnostics/en.db:swift-arm64/share/swift/diagnostics/en.db; do
  [ "$(cat "$T/xout/$X/${f%%:*}")" = "${f#*:}" ] || fail "cross $X/${f%%:*} is not ${f#*:}"
done
# Everything else is the native payload's bytes: one stdlib build, one builtins archive, one set of wrappers.
( cd "$T/out/$P" && find . -type f ) | while IFS= read -r f; do
  case "$f" in ./bin/swift-frontend|./bin/ld64.lld|./bin/clang|./share/swift/*|./lib/clang/*/include/*) continue ;; esac
  cmp -s "$T/out/$P/$f" "$T/xout/$X/$f" || fail "cross $f differs from the native payload's"
done
[ "$(readlink "$T/xout/$X/lib/swift/clang")" = ../clang/21 ] || fail "cross lib/swift/clang is not a link to ../clang/21"
[ "$(readlink "$T/xout/$X/bin/clang++")" = clang ] || fail "cross bin/clang++ is not a link to clang"
[ -x "$T/xout/$X/bin/swiftc" ] || fail "cross swiftc not executable"
echo "PASS"
