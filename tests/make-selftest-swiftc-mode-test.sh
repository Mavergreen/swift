#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-swiftc-mode-test.sh
#   make-selftest.sh with SWIFTC= must invoke that compiler with nothing but -O|-Onone, the source and
#   -o, for every tests/*.swift (this repo's toolchain has the Darwin and ObjectiveC overlays), and after
#   them the flags of a `// swiftc: <flags>` line among the test's leading comment lines, which may name
#   only -parse-as-library (any other flag fails the bundle); a test whose first line is
#   `// selftest: skip: <reason>` is not built, in any mode, and the reason is printed. With
#   SWIFT_RUNTIME_PREFIX set too, each
#   compile must also ask for header padding, and each binary's installed-runtime rpath must be replaced
#   by the prefix's; a replacement that fails must fail the bundle, and a prefix that is relative or holds
#   no libswiftCore.dylib is refused before anything is compiled. The replacement is INSTALL_NAME_TOOL's,
#   else clang22's llvm-install-name-tool where CLANG22_PREFIX has one (OS X 10.9's install_name_tool is a
#   Command Line Tools stub), else install_name_tool's from PATH. With SELFTEST_SUPPORT=<dir> too
#   (scripts/stage-selftest-support.sh's layout), each upstream/<layer>/<path>.args test must also be built,
#   at -O and -Onone, with its compile-line's arguments kept one apiece and the support modules and
#   libraries searched, into upstream/bin/<layer>-<name>[-Onone], whose rpath reaches the bundle's lib/
#   (a test's further variants, <path>.<n>.args, into <layer>-<name>-v<n>[-Onone]),
#   where <dir>/lib is copied; two tests of one name, or a <dir> without lib/, are refused before anything
#   is compiled. Upstream's concurrency layer is built in SWIFTC= mode and skipped, saying so, in the default
#   mode, whose swift.org compiler refuses its 10.9 async code. A fake compiler and fake install_name_tools
#   record their calls.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cat > "$T/fake-swiftc" <<EOF2
#!/bin/sh
echo "\$*" >> "$T/calls"
printf '<%s>' "\$@" >> "$T/argv"; echo >> "$T/argv"
while [ \$# -gt 0 ]; do case "\$1" in -o) printf '#!/bin/sh\nexit 0\n' > "\$2"; chmod +x "\$2"; shift 2;; *) shift;; esac; done
EOF2
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/int-calls"\nexit "${FAKE_INT_RC:-0}"\n' "$T" > "$T/bin/install_name_tool"
mkdir -p "$T/c22/bin"
printf '#!/bin/sh\necho "llvm $*" >> "%s/int-calls"\n' "$T" > "$T/c22/bin/llvm-install-name-tool"
printf '#!/bin/sh\necho "named $*" >> "%s/int-calls"\n' "$T" > "$T/named-int"
chmod +x "$T/fake-swiftc" "$T/bin/install_name_tool" "$T/c22/bin/llvm-install-name-tool" "$T/named-int"
# Unless a case says otherwise, no clang22 (the box has one installed, at the default prefix).
CLANG22_PREFIX="$T/no-clang22"; export CLANG22_PREFIX; unset INSTALL_NAME_TOOL
B="$T/dist/swift-runtime-selftest/bin"
# The corpus.
mkdir -p "$T/src"; cp "$REPO"/tests/*.swift "$T/src/"
printf '%s\n' '// zz_flags_test.swift -- a fixture' '// swiftc: -parse-as-library' '' '@main struct M { static func main() {} }' \
  > "$T/src/zz_flags_test.swift"
printf '%s\n' '// selftest: skip: waits for a fixture library' 'print(1)' > "$T/src/zz_skip_test.swift"
SELFTEST_SRC="$T/src"; export SELFTEST_SRC
# flags_of <src> -- what its `// swiftc:` line asks for, among its leading comment lines
flags_of() { sed -n '/^\/\//!q; s/^\/\/ swiftc: //p' "$1"; }
skipped() { sed -n 1p "$1" | grep -q '^// selftest: skip: '; }

echo "-- SWIFTC alone: exactly -O|-Onone <file> -o <out>, no rpath rewrite"
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball (got '$tarball')"
for src in "$T/src"/*.swift; do
  n="$(basename "$src" .swift)"; f="$(flags_of "$src")"
  if skipped "$src"; then
    if grep -q -- " $src " "$T/calls"; then fail "built $n, whose first line skips it: $(grep -- " $src " "$T/calls")"; fi
    continue
  fi
  grep -qx -- "-O $src -o $B/$n${f:+ $f}" "$T/calls" || fail "no exact -O call for $n: $(cat "$T/calls")"
  grep -qx -- "-Onone $src -o $B/$n-Onone${f:+ $f}" "$T/calls" || fail "no exact -Onone call for $n"
done
grep -qx -- "-O $T/src/zz_flags_test.swift -o $B/zz_flags_test -parse-as-library" "$T/calls" || fail "the // swiftc: line's flag was not passed"
tarball_err="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" 2>&1 >/dev/null)"
printf '%s\n' "$tarball_err" | grep -qxF 'skipped: zz_skip_test (waits for a fixture library)' || fail "did not say why zz_skip_test was skipped: $tarball_err"
if tar -tzf "$tarball" | grep -q 'bin/zz_skip_test'; then fail "the bundle has the skipped test"; fi
[ ! -f "$T/int-calls" ] || fail "rewrote an rpath without SWIFT_RUNTIME_PREFIX: $(cat "$T/int-calls")"
tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/run-selftest.sh' || fail "bundle lacks run-selftest.sh"
for n in objc_interop_test darwin_overlay_test objc_overlay_test; do
  tar -tzf "$tarball" | grep -q "bin/$n\$" || fail "bundle lacks $n"
done

echo "-- SWIFTC with SWIFT_RUNTIME_PREFIX: header padding, then the prefix's rpath replaces the installed one"
rm -f "$T/calls"
P="$T/staged/usr/local/mavergreen/swift-runtime"
mkdir -p "$P/lib/swift"; : > "$P/lib/swift/libswiftCore.dylib"
PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" sh "$REPO/make-selftest.sh" > /dev/null
for src in "$T/src"/*.swift; do
  n="$(basename "$src" .swift)"; f="$(flags_of "$src")"
  ! skipped "$src" || continue
  for o in O Onone; do
    out="$B/$n"; [ "$o" = O ] || out="$B/$n-Onone"
    grep -qx -- "-$o -Xlinker -headerpad_max_install_names $src -o $out${f:+ $f}" "$T/calls" || fail "no padded -$o call for $n: $(cat "$T/calls")"
    grep -qx -- "-rpath /usr/local/mavergreen/swift-runtime/lib/swift $P/lib/swift $out" "$T/int-calls" \
      || fail "no rpath replacement for $out: $(cat "$T/int-calls" 2>/dev/null)"
  done
done

echo "-- clang22's llvm-install-name-tool where CLANG22_PREFIX has one; INSTALL_NAME_TOOL before either"
rm -f "$T/int-calls"
PATH="$T/bin:$PATH" CLANG22_PREFIX="$T/c22" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" sh "$REPO/make-selftest.sh" > /dev/null
[ "$(cut -d' ' -f1 "$T/int-calls" | sort -u)" = llvm ] || fail "did not rewrite with clang22's llvm-install-name-tool: $(cat "$T/int-calls")"
rm -f "$T/int-calls"
PATH="$T/bin:$PATH" CLANG22_PREFIX="$T/c22" INSTALL_NAME_TOOL="$T/named-int" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" \
  sh "$REPO/make-selftest.sh" > /dev/null
[ "$(cut -d' ' -f1 "$T/int-calls" | sort -u)" = named ] || fail "did not rewrite with INSTALL_NAME_TOOL: $(cat "$T/int-calls")"

echo "-- a // swiftc: line naming any flag but -parse-as-library fails the bundle"
mkdir -p "$T/src2"; printf '%s\n' '// swiftc: -Xfrontend -disable-availability-checking' 'print(1)' > "$T/src2/bad_test.swift"
if ( unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SELFTEST_SRC="$T/src2" DIST="$T/dist" \
     sh "$REPO/make-selftest.sh" > /dev/null 2> "$T/err" ); then fail "made a bundle whose test asks for -disable-availability-checking"; fi
grep -q 'bad_test.*-Xfrontend' "$T/err" || fail "did not name the refused flag: $(cat "$T/err")"

echo "-- a replacement that fails fails the bundle"
if PATH="$T/bin:$PATH" FAKE_INT_RC=1 SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" \
     sh "$REPO/make-selftest.sh" > /dev/null 2>&1; then
  fail "make-selftest.sh succeeded although install_name_tool failed"
fi
echo "-- a prefix that is relative, or holds no runtime, is refused before any compile"
rm -f "$T/calls"
for bad in staged/usr/local/mavergreen/swift-runtime "$T/swift/payload/runtime/usr/local/mavergreen/swift-runtime"; do
  if ( cd "$T" && PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$bad" DIST="$T/dist" \
       sh "$REPO/make-selftest.sh" > /dev/null 2> "$T/err" ); then
    fail "made a bundle with SWIFT_RUNTIME_PREFIX=$bad"
  fi
  grep -q 'SWIFT_RUNTIME_PREFIX' "$T/err" || fail "did not say why $bad was refused: $(cat "$T/err")"
done
[ ! -f "$T/calls" ] || fail "compiled before refusing the prefix: $(cat "$T/calls")"

echo "-- SELFTEST_SUPPORT: upstream's tests too, with their compile-lines, and the support libraries in lib/"
SUP="$T/support"
mkdir -p "$SUP/lib" "$SUP/modules/StdlibUnittest.swiftmodule" "$SUP/upstream/darwin/test/stdlib" "$SUP/upstream/objectivec/validation-test/stdlib"
: > "$SUP/lib/libswiftStdlibUnittest.dylib"; : > "$SUP/lib/libswiftSwiftPrivate.dylib"
: > "$SUP/upstream/darwin/test/stdlib/Foo.swift"
printf '%s\n' -swift-version 4 -Xfrontend -define-availability -Xfrontend 'SwiftStdlib 5.1:macOS 10.15' -module-name main \
  > "$SUP/upstream/darwin/test/stdlib/Foo.swift.args"
: > "$SUP/upstream/objectivec/validation-test/stdlib/Bar.swift.gyb"; : > "$SUP/upstream/objectivec/validation-test/stdlib/Bar.swift"
printf '%s\n' -swift-version 4 -parse-stdlib > "$SUP/upstream/objectivec/validation-test/stdlib/Bar.swift.gyb.args"
printf '%s\n' -swift-version 5 -module-name main > "$SUP/upstream/darwin/test/stdlib/Foo.swift.2.args"
rm -f "$T/calls" "$T/argv"
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SELFTEST_SUPPORT="$SUP" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball with SELFTEST_SUPPORT (got '$tarball')"
U="$T/dist/swift-runtime-selftest/upstream/bin"
TAIL="-I $SUP/modules -L $SUP/lib -Xlinker -rpath -Xlinker @executable_path/../../lib"
for o in O Onone; do
  sfx=""; [ "$o" = O ] || sfx=-Onone
  grep -qxF -- "-$o $SUP/upstream/darwin/test/stdlib/Foo.swift -o $U/darwin-Foo$sfx -swift-version 4 -Xfrontend -define-availability -Xfrontend SwiftStdlib 5.1:macOS 10.15 -module-name main $TAIL" "$T/calls" \
    || fail "no -$o call for darwin's Foo: $(cat "$T/calls")"
  grep -qxF -- "-$o $SUP/upstream/objectivec/validation-test/stdlib/Bar.swift -o $U/objectivec-Bar$sfx -swift-version 4 -parse-stdlib $TAIL" "$T/calls" \
    || fail "no -$o call for objectivec's Bar (its gyb output): $(cat "$T/calls")"
  grep -qxF -- "-$o $SUP/upstream/darwin/test/stdlib/Foo.swift -o $U/darwin-Foo-v2$sfx -swift-version 5 -module-name main $TAIL" "$T/calls" \
    || fail "no -$o call for darwin's Foo, variant 2: $(cat "$T/calls")"
done
grep -qF '<-define-availability><-Xfrontend><SwiftStdlib 5.1:macOS 10.15><-module-name>' "$T/argv" || fail "an argument with spaces was split: $(cat "$T/argv")"
for f in upstream/bin/darwin-Foo upstream/bin/darwin-Foo-Onone upstream/bin/darwin-Foo-v2 upstream/bin/darwin-Foo-v2-Onone upstream/bin/objectivec-Bar upstream/bin/objectivec-Bar-Onone \
         lib/libswiftStdlibUnittest.dylib lib/libswiftSwiftPrivate.dylib; do
  tar -tzf "$tarball" | grep -q "swift-runtime-selftest/$f\$" || fail "bundle lacks $f: $(tar -tzf "$tarball")"
done
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
if tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/upstream/\|swift-runtime-selftest/lib/'; then fail "a bundle without SELFTEST_SUPPORT has upstream/ or lib/"; fi

echo "-- SELFTEST_SUPPORT: upstream's concurrency tests are built by SWIFTC= (this repo's compiler), and skipped,"
echo "   saying why, by the default mode's swift.org compiler, which refuses their 10.9 async code"
mkdir -p "$SUP/upstream/concurrency/test/Concurrency"
: > "$SUP/upstream/concurrency/test/Concurrency/Baz.swift"
printf '%s\n' -swift-version 5 -parse-as-library > "$SUP/upstream/concurrency/test/Concurrency/Baz.swift.args"
rm -f "$T/calls"
( unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SELFTEST_SUPPORT="$SUP" DIST="$T/dist" sh "$REPO/make-selftest.sh" ) > "$T/out" 2>&1 \
  || fail "SWIFTC= mode failed with a concurrency layer: $(cat "$T/out")"
grep -q -- "-O $SUP/upstream/concurrency/test/Concurrency/Baz.swift -o $U/concurrency-Baz " "$T/calls" || fail "SWIFTC= mode did not build concurrency's Baz: $(cat "$T/calls")"
mkdir -p "$T/tc/bin" "$T/work/stdlib-build/lib/swift/macosx/x86_64" "$T/shipyard"
cp "$T/fake-swiftc" "$T/tc/bin/swiftc"; : > "$T/work/stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib"
printf '#!/bin/sh\necho %s/MacOSX10.9.sdk\n' "$T" > "$T/shipyard/fetch_sdk.sh"
rm -f "$T/calls"
( unset SWIFT_RUNTIME_PREFIX SWIFTC; TC="$T/tc" SWIFT_WORK="$T/work" SHIPYARD_SCRIPTS="$T/shipyard" SELFTEST_SUPPORT="$SUP" DIST="$T/dist" \
    sh "$REPO/make-selftest.sh" ) > "$T/out" 2>&1 || fail "the default mode failed with a concurrency layer: $(cat "$T/out")"
grep -q -- "$SUP/upstream/darwin/test/stdlib/Foo.swift -o $U/darwin-Foo " "$T/calls" || fail "the default mode did not build darwin's Foo: $(cat "$T/calls")"
if grep -q 'concurrency' "$T/calls"; then fail "the default mode built an upstream concurrency test: $(grep concurrency "$T/calls")"; fi
grep -q "skipped: upstream's concurrency tests (they need this repo's compiler, not the swift.org one)" "$T/out" \
  || fail "the default mode did not say it skips upstream's concurrency tests: $(cat "$T/out")"
rm -r "$SUP/upstream/concurrency"

echo "-- SELFTEST_SUPPORT: a dir without lib/, or two tests of one name, is refused before any compile"
mkdir -p "$T/nolib/modules" "$T/nolib/upstream"
rm -f "$T/calls"
if ( unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SELFTEST_SUPPORT="$T/nolib" DIST="$T/dist" \
     sh "$REPO/make-selftest.sh" > /dev/null 2> "$T/err" ); then fail "made a bundle with a SELFTEST_SUPPORT that has no lib/"; fi
grep -q 'SELFTEST_SUPPORT' "$T/err" && grep -q 'lib/' "$T/err" || fail "did not say why $T/nolib was refused: $(cat "$T/err")"
[ ! -f "$T/calls" ] || fail "compiled before refusing SELFTEST_SUPPORT: $(cat "$T/calls")"
mkdir -p "$SUP/upstream/darwin/validation-test/stdlib"
: > "$SUP/upstream/darwin/validation-test/stdlib/Foo.swift"; cp "$SUP/upstream/darwin/test/stdlib/Foo.swift.args" "$SUP/upstream/darwin/validation-test/stdlib/"
if ( unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SELFTEST_SUPPORT="$SUP" DIST="$T/dist" \
     sh "$REPO/make-selftest.sh" > /dev/null 2> "$T/err" ); then fail "made a bundle with two darwin tests named Foo"; fi
grep -q 'darwin-Foo' "$T/err" || fail "did not name the clash: $(cat "$T/err")"
[ ! -f "$T/calls" ] || fail "compiled before refusing the clash: $(cat "$T/calls")"
echo "PASS"
