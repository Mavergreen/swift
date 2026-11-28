#!/bin/sh
# platform: host-agnostic
# usage: SWIFT_HOST_TOOLCHAIN=<prefix> [SDKROOT=<MacOSX10.9.sdk>] sh tests/objc-imported-protocol-test.sh
#   Compiler patch 0007: a program that refers to an imported Objective-C protocol in a mangled name (here an
#   escaping closure's capture of `any FixtureSource`) makes the compiler emit that protocol's ObjC record,
#   and those it refines. Below macOS 13.3 the record is built by Swift, not clang (emitObjCProtocolData),
#   and compiler patch 0003 opens ObjC protocol symbolic references at 10.9, so a 10.9 target reaches that
#   path for an imported protocol. In Swift 6 mode a property typed `NSString *` that is only forward-declared
#   imports as `String` without Foundation, which the compiler cannot lower back to an ObjC type there; the
#   frontend segfaulted ("While emitting ObjC metadata for 'FixtureBase'"), as it did on NSObjectProtocol's
#   `description` under the SDK view. With the fixture header, which refines no SDK protocol, Recaulk and the
#   view are not needed. The IR must keep both properties of FixtureBase, `description` and the optional
#   `debugDescription`, typed as the header declares them (T@"NSString"), and their getters encoded @16@0:8.
#   SWIFT_HOST_TOOLCHAIN is a prefix holding bin/swift-frontend and lib/swift/macosx (a staged cross
#   toolchain, or a Linux-hosted frontend beside a copy of one's lib/swift); its default is the staged cross
#   toolchain under MAVERICKS_BUILD_ROOT. SDKROOT defaults to shipyard's fetch_sdk.sh. SKIPs (77) with no
#   such frontend, one this host cannot run, or no SDK.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"     # -> $SWIFT_BUILD
HTC="${SWIFT_HOST_TOOLCHAIN:-$SWIFT_BUILD/payload/toolchain-cross/usr/local/mavergreen/swift-toolchain-cross}"
FE="$HTC/bin/swift-frontend"
[ -x "$FE" ] && [ -d "$HTC/lib/swift/macosx" ] || { echo "no frontend and macosx stdlib under $HTC (set SWIFT_HOST_TOOLCHAIN) -- skipping"; exit 77; }
"$FE" -version >/dev/null 2>&1 || { echo "this host cannot run $FE -- skipping"; exit 77; }
SDK="${SDKROOT:-}"
if [ -z "$SDK" ]; then
  . "$REPO/msc.sh" 2>/dev/null || { echo "no SDKROOT and no shipyard -- skipping"; exit 77; }
  SDK="$(sh "$SHIPYARD/fetch_sdk.sh")" || { echo "could not obtain the Mac OS X 10.9 SDK -- skipping"; exit 77; }
fi
[ -d "$SDK" ] || { echo "no SDK at $SDK -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/objc-imported-protocol.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir "$T/inc"
cat > "$T/inc/module.modulemap" <<'EOF'
module Fixture {
  header "fixture.h"
  export *
}
EOF
cat > "$T/inc/fixture.h" <<'EOF'
@class NSString;
@protocol FixtureBase
@property (readonly, copy) NSString *description;
@optional
@property (readonly, copy) NSString *debugDescription;
@end
@protocol FixtureSource <FixtureBase>
- (void)resume;
@end
id<FixtureSource> fixture_source(void);
EOF
cat > "$T/use.swift" <<'EOF'
import Fixture
nonisolated(unsafe) var saved: (() -> Void)?
func keep() {
  let source = fixture_source()!
  saved = { source.resume() }
}
EOF

echo "-- Swift 6: the imported protocol's ObjC record is emitted, not a crash"
rc=0
( cd "$T" && "$FE" -frontend -emit-ir -primary-file use.swift -module-name use -language-mode 6 \
    -target x86_64-apple-macosx10.9 -sdk "$SDK" -resource-dir "$HTC/lib/swift" -I inc \
    -disable-implicit-string-processing-module-import -o use.ll ) > "$T/out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "the frontend exited $rc emitting a 10.9 program that captures an imported protocol (compiler patch 0007): $(grep -m1 'While emitting' "$T/out" || tail -3 "$T/out")"

echo "-- FixtureBase keeps both properties, typed as the header declares them"
props="$(grep '^@_PROTOCOL_PROPERTIES_FixtureBase = ' "$T/use.ll")" || fail "no property list for FixtureBase: the record dropped its property requirements"
case "$props" in *"i32 16, i32 2,"*) ;; *) fail "FixtureBase's property list does not hold its two properties: $props" ;; esac
for p in description debugDescription; do
  grep -q "^@\.str\.[0-9]*\.$p = .*c\"$p\\\\00\"" "$T/use.ll" || fail "no property name $p in the IR"
done
grep -q 'c"T@\\22NSString\\22,N,R\\00"' "$T/use.ll" || fail "no property attribute T@\"NSString\",N,R: the property is not typed as the header's NSString *"

echo "-- their getters are encoded @16@0:8, not left null"
for list in '_PROTOCOL_INSTANCE_METHODS_FixtureBase' '_PROTOCOL_INSTANCE_METHODS_OPT_FixtureBase'; do
  line="$(grep "^@$list = " "$T/use.ll")" || fail "no $list in the IR"
  case "$line" in *"ptr null, ptr null"*) fail "$list holds a method with no type encoding: $line" ;; esac
done
grep "^@_PROTOCOL_INSTANCE_METHODS_FixtureBase = " "$T/use.ll" | grep -q 'selector_data(description)", ptr @".str.7.@16@0:8"' \
  || fail "description's getter is not encoded @16@0:8 in FixtureBase's methods"
grep "^@_PROTOCOL_INSTANCE_METHODS_OPT_FixtureBase = " "$T/use.ll" | grep -q 'selector_data(debugDescription)", ptr @".str.7.@16@0:8"' \
  || fail "debugDescription's getter is not encoded @16@0:8 in FixtureBase's optional methods"
echo "PASS"
