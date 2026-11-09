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
#   refused before anything is written. Recaulk's librecaulk.a and notices.tsv (--recaulk, a prefix
#   fetch-recaulk.sh prints) go to lib/recaulk with its version, which must be pins.env's RECAULK_VERSION.
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
  rc=0; PATH="$T/fakebin:$PATH" SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$bad" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "out-dir '$bad': exit $rc, not 2 (refused)"
  [ ! -f "$T/writes.log" ] || fail "tried to write, with out-dir '$bad': $(cat "$T/writes.log")"
done

echo "-- names a missing input"
for f in llvm-x86/bin/lld builtins-x86/lib/darwin/libclang_rt.osx.a; do
  mv "$W/$f" "$T/away"
  if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/out" 2> "$T/err"; then fail "staged without $f"; fi
  grep -q "$f" "$T/err" || fail "did not name the missing $f: $(cat "$T/err")"
  mv "$T/away" "$W/$f"
done

echo "-- refuses a stdlib missing an overlay's or Concurrency's module or dylib, naming it, before writing anything"
for f in stdlib-build/lib/swift/macosx/Darwin.swiftmodule stdlib-build/lib/swift/macosx/ObjectiveC.swiftmodule \
         stdlib-build/lib/swift/macosx/x86_64/libswiftDarwin.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftObjectiveC.dylib \
         stdlib-build/lib/swift/macosx/_Concurrency.swiftmodule stdlib-build/lib/swift/macosx/_Builtin_float.swiftmodule \
         stdlib-build/lib/swift/macosx/x86_64/libswift_Concurrency.dylib; do
  mv "$W/$f" "$T/away"
  if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/out-missing" 2> "$T/err"; then fail "staged without $f"; fi
  grep -q "${f##*/}" "$T/err" || fail "did not name the missing ${f##*/}: $(cat "$T/err")"
  [ ! -e "$T/out-missing" ] || fail "wrote a payload before refusing the missing ${f##*/}"
  mv "$T/away" "$W/$f"
done

echo "-- refuses a Recaulk that is not pins.env's, or not whole, naming it, before writing anything"
. "$REPO/pins.env"
cp -R "$W/recaulk" "$T/rk-old"; fake_recaulk_plist 19990101.1 > "$T/rk-old/mavergreen.plist"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$T/rk-old" "$T/out-rk" 2> "$T/err"; then fail "staged Recaulk 19990101.1"; fi
grep -q "19990101.1" "$T/err" && grep -q "$RECAULK_VERSION" "$T/err" || fail "did not name both Recaulk versions: $(cat "$T/err")"
[ ! -e "$T/out-rk" ] || fail "wrote a payload before refusing Recaulk 19990101.1"
for f in lib/librecaulk.a share/recaulk/notices.tsv mavergreen.plist; do
  rm -rf "$T/rk-part"; cp -R "$W/recaulk" "$T/rk-part"; rm "$T/rk-part/$f"
  if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$T/rk-part" "$T/out-rk" 2> "$T/err"; then fail "staged a Recaulk without $f"; fi
  grep -q "$T/rk-part/$f" "$T/err" || fail "did not name the missing $f: $(cat "$T/err")"
  [ ! -e "$T/out-rk" ] || fail "wrote a payload before refusing a Recaulk without $f"
done

echo "-- refuses, naming them, when a reused build root holds more than one clang resource dir"
mkdir -p "$W/llvm-x86/lib/clang/22/include"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/out" 2> "$T/err"; then
  fail "staged with two clang resource dirs, picking one"
fi
grep -q 'lib/clang/21/include' "$T/err" && grep -q 'lib/clang/22/include' "$T/err" \
  || fail "did not name both clang resource dirs: $(cat "$T/err")"
[ ! -d "$T/out/usr" ] || fail "wrote a payload before refusing"
rm -r "$W/llvm-x86/lib/clang/22"

echo "-- lays out exactly the payload, replacing an earlier one, leaving Library/ alone"
mkdir -p "$T/out/usr/stale" "$T/out/Library/keep"
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/out"
P=usr/local/mavergreen/swift-toolchain
got="$(cd "$T/out" && find usr Library -type f | sort)"
want="$(printf '%s\n' "$P/bin/clang" "$P/bin/clang.cfg" "$P/bin/clang++.cfg" "$P/bin/ld64.lld" "$P/bin/swift-frontend" "$P/bin/swiftc" \
  "$P/lib/clang/21/include/stdint.h" "$P/lib/clang/21/lib/darwin/libclang_rt.osx.a" \
  "$P/lib/recaulk/librecaulk.a" "$P/lib/recaulk/notices.tsv" "$P/lib/recaulk/VERSION" \
  "$P/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/Darwin.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/ObjectiveC.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/_Concurrency.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/_Builtin_float.swiftmodule/x86_64-apple-macos.swiftmodule" \
  "$P/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule" "$P/lib/swift/macosx/layouts-x86_64.yaml" \
  "$P/lib/swift/macosx/libswiftCore.dylib" "$P/lib/swift/macosx/libswiftDarwin.dylib" \
  "$P/lib/swift/macosx/libswiftObjectiveC.dylib" "$P/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib" \
  "$P/lib/swift/macosx/libswift_Concurrency.dylib" \
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
cmp -s "$W/recaulk/lib/librecaulk.a" "$T/out/$P/lib/recaulk/librecaulk.a" || fail "lib/recaulk/librecaulk.a is not --recaulk's archive"
cmp -s "$W/recaulk/share/recaulk/notices.tsv" "$T/out/$P/lib/recaulk/notices.tsv" || fail "lib/recaulk/notices.tsv is not --recaulk's notices"
[ "$(cat "$T/out/$P/lib/recaulk/VERSION")" = "$RECAULK_VERSION" ] || fail "lib/recaulk/VERSION is $(cat "$T/out/$P/lib/recaulk/VERSION"), not $RECAULK_VERSION"
for c in clang.cfg clang++.cfg; do
  cmp -s "$REPO/toolchain/clang.cfg" "$T/out/$P/bin/$c" || fail "bin/$c is not toolchain/clang.cfg"
done
# clang links Recaulk through its cfg (link-only, relative to the cfg's directory), once: the archive is where
# the cfg says, and the linker wrapper that adds it for swiftc is not clang's linker.
[ "$(grep -c '^\$-Wl,<CFGDIR>/\.\./lib/recaulk/librecaulk\.a$' "$REPO/toolchain/clang.cfg")" = 1 ] \
  || fail "toolchain/clang.cfg does not pass \$-Wl,<CFGDIR>/../lib/recaulk/librecaulk.a exactly once"

# _Builtin_float is a module only: its dylib is a stub of symbols libswiftDarwin defines, which no toolchain
# or runtime ships (the build's step 7 checks that). The fake build holds one, as the real one does.
[ -f "$W/stdlib-build/lib/swift/macosx/x86_64/libswift_Builtin_float.dylib" ] || fail "the fake build has no libswift_Builtin_float.dylib to leave out"
[ -z "$(cd "$T/out" && find usr -name 'libswift_Builtin_float*')" ] || fail "staged libswift_Builtin_float.dylib"

echo "-- --stdlib from a staged toolchain's lib/swift, --frontend and --builtins elsewhere: the same payload"
mkdir -p "$T/fe/bin" "$T/fe/share/swift/diagnostics"
for f in bin/swift-frontend share/swift/compatibility-symbols share/swift/diagnostics/en.db share/swift/diagnostics/en.strings; do
  echo "other $f" > "$T/fe/$f"
done
echo "other archive" > "$T/other.a"
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --frontend "$T/fe" --stdlib "$T/out/$P/lib/swift" --builtins "$T/other.a" "$T/out2"
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

echo "-- --overlays-optional (self-host.sh's pre toolchain): a seed's stdlib without overlays stages, without them"
# A release before the overlays (6.4.1-mavericks.8) seeds self-host.sh: its stdlib only makes the stage's
# compiler run, and build.sh compiles the overlays against the stdlib it builds, never the seed's.
cp -R "$T/out/$P/lib/swift" "$T/seedlib"
rm -r "$T/seedlib/macosx/Darwin.swiftmodule" "$T/seedlib/macosx/ObjectiveC.swiftmodule" \
  "$T/seedlib/macosx/libswiftDarwin.dylib" "$T/seedlib/macosx/libswiftObjectiveC.dylib" \
  "$T/seedlib/macosx/_Concurrency.swiftmodule" "$T/seedlib/macosx/_Builtin_float.swiftmodule" "$T/seedlib/macosx/libswift_Concurrency.dylib"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --stdlib "$T/seedlib" "$T/out-seed" 2> "$T/err"; then
  fail "staged a stdlib without overlays, without --overlays-optional"
fi
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --overlays-optional --stdlib "$T/seedlib" "$T/out-seed" > "$T/seed.log" 2>&1 \
  || fail "--overlays-optional refused a stdlib without overlays: $(cat "$T/seed.log")"
[ -f "$T/out-seed/$P/lib/swift/macosx/libswiftCore.dylib" ] || fail "--overlays-optional staged no libswiftCore"
[ -z "$(cd "$T/out-seed/$P" && find . -name '*Darwin*' -o -name '*ObjectiveC*' -o -name '*Concurrency*' -o -name '*Builtin_float*')" ] || fail "--overlays-optional staged an overlay it was not given"
SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --overlays-optional --frontend "$T/fe" --stdlib "$T/out/$P/lib/swift" --builtins "$T/other.a" "$T/out-opt" \
  || fail "--overlays-optional refused a stdlib with overlays"
[ "$(cd "$T/out-opt" && find usr -type f | sort)" = "$want" ] || fail "--overlays-optional over a stdlib with overlays staged another payload"

echo "-- refuses a --stdlib that is no stdlib, and an unknown option, before writing anything"
mkdir -p "$T/notstdlib/macosx"
if SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --stdlib "$T/notstdlib" "$T/out3" 2> "$T/err"; then fail "staged from a dir that is no stdlib"; fi
grep -q "$T/notstdlib is no stdlib" "$T/err" || fail "did not name the bad --stdlib: $(cat "$T/err")"
[ ! -e "$T/out3" ] || fail "wrote $T/out3 before refusing the bad --stdlib"
rc=0; SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --stdib "$T/out/$P/lib/swift" "$T/out4" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "--stdib: exit $rc, not 2"
rc=0; SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" --stdlib "$T/out4" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "--stdlib with no out-dir: exit $rc, not 2"
[ ! -e "$T/out4" ] || fail "wrote $T/out4 on a usage error"

echo "-- refuses an unknown STAGE_HOST before writing anything"
rc=0; STAGE_HOST=x86 SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/bad" 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] || fail "STAGE_HOST=x86: exit $rc, not 2"
[ ! -e "$T/bad" ] || fail "STAGE_HOST=x86 wrote $T/bad before refusing"
grep -q "not 'x86'" "$T/err" || fail "did not name the bad host: $(cat "$T/err")"

echo "-- STAGE_HOST=arm64: the cross toolchain, from the arm64 build, with the native payload's stdlib, wrappers and cfgs"
fake_toolchain_build "$W" arm64
STAGE_HOST=arm64 SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$T/xout"
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
