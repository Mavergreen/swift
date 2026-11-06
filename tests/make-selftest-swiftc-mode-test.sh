#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-swiftc-mode-test.sh
#   make-selftest.sh with SWIFTC= must invoke that compiler with nothing but -O|-Onone, the source and
#   -o, for every tests/*.swift (this repo's toolchain has the Darwin and ObjectiveC overlays, so none is
#   skipped). With SWIFT_RUNTIME_PREFIX set too, each
#   compile must also ask for header padding, and each binary's installed-runtime rpath must be replaced
#   by the prefix's; a replacement that fails must fail the bundle, and a prefix that is relative or holds
#   no libswiftCore.dylib is refused before anything is compiled. The replacement is INSTALL_NAME_TOOL's,
#   else clang22's llvm-install-name-tool where CLANG22_PREFIX has one (OS X 10.9's install_name_tool is a
#   Command Line Tools stub), else install_name_tool's from PATH. With SELFTEST_SUPPORT=<dir> too
#   (scripts/stage-selftest-support.sh's layout), each upstream/<layer>/<path>.args test must also be built,
#   at -O and -Onone, with its compile-line's arguments kept one apiece and the support modules and
#   libraries searched, into upstream/bin/<layer>-<name>[-Onone], whose rpath reaches the bundle's lib/,
#   where <dir>/lib is copied; two tests of one name, or a <dir> without lib/, are refused before anything
#   is compiled. A fake compiler and fake install_name_tools record their calls.
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
SELFTEST_SRC="$T/src"; export SELFTEST_SRC

echo "-- SWIFTC alone: exactly -O|-Onone <file> -o <out>, no rpath rewrite"
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball (got '$tarball')"
for src in "$T/src"/*.swift; do
  n="$(basename "$src" .swift)"
  grep -qx -- "-O $src -o $B/$n" "$T/calls" || fail "no exact -O call for $n: $(cat "$T/calls")"
  grep -qx -- "-Onone $src -o $B/$n-Onone" "$T/calls" || fail "no exact -Onone call for $n"
done
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
  n="$(basename "$src" .swift)"
  for o in O Onone; do
    out="$B/$n"; [ "$o" = O ] || out="$B/$n-Onone"
    grep -qx -- "-$o -Xlinker -headerpad_max_install_names $src -o $out" "$T/calls" || fail "no padded -$o call for $n: $(cat "$T/calls")"
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
done
grep -qF '<-define-availability><-Xfrontend><SwiftStdlib 5.1:macOS 10.15><-module-name>' "$T/argv" || fail "an argument with spaces was split: $(cat "$T/argv")"
for f in upstream/bin/darwin-Foo upstream/bin/darwin-Foo-Onone upstream/bin/objectivec-Bar upstream/bin/objectivec-Bar-Onone \
         lib/libswiftStdlibUnittest.dylib lib/libswiftSwiftPrivate.dylib; do
  tar -tzf "$tarball" | grep -q "swift-runtime-selftest/$f\$" || fail "bundle lacks $f: $(tar -tzf "$tarball")"
done
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
if tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/upstream/\|swift-runtime-selftest/lib/'; then fail "a bundle without SELFTEST_SUPPORT has upstream/ or lib/"; fi

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
