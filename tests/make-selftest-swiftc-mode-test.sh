#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-swiftc-mode-test.sh
#   make-selftest.sh with SWIFTC= must invoke that compiler with nothing but -O|-Onone, the source and
#   -o, and must skip every test marked `// requires: overlays`. With SWIFT_RUNTIME_PREFIX set too, each
#   compile must also ask for header padding, and each binary's installed-runtime rpath must be replaced
#   by the prefix's; a replacement that fails must fail the bundle, and a prefix that is relative or holds
#   no libswiftCore.dylib is refused before anything is compiled. The replacement is INSTALL_NAME_TOOL's,
#   else clang22's llvm-install-name-tool where CLANG22_PREFIX has one (OS X 10.9's install_name_tool is a
#   Command Line Tools stub), else install_name_tool's from PATH. A fake compiler and fake
#   install_name_tools record their calls.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cat > "$T/fake-swiftc" <<EOF2
#!/bin/sh
echo "\$*" >> "$T/calls"
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
# The corpus, and one test only an overlay-carrying compiler builds.
mkdir -p "$T/src"; cp "$REPO"/tests/*.swift "$T/src/"
printf '%s\n' '// requires: overlays' 'import Foundation' > "$T/src/overlay_only_test.swift"
SELFTEST_SRC="$T/src"; export SELFTEST_SRC

echo "-- SWIFTC alone: exactly -O|-Onone <file> -o <out>, no rpath rewrite"
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball (got '$tarball')"
grep -q 'overlay_only_test' "$T/calls" && fail "compiled a // requires: overlays test"
for src in "$T/src"/*.swift; do
  n="$(basename "$src" .swift)"
  [ "$(head -1 "$src")" = "// requires: overlays" ] && continue
  grep -qx -- "-O $src -o $B/$n" "$T/calls" || fail "no exact -O call for $n: $(cat "$T/calls")"
  grep -qx -- "-Onone $src -o $B/$n-Onone" "$T/calls" || fail "no exact -Onone call for $n"
done
[ ! -f "$T/int-calls" ] || fail "rewrote an rpath without SWIFT_RUNTIME_PREFIX: $(cat "$T/int-calls")"
tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/run-selftest.sh' || fail "bundle lacks run-selftest.sh"
tar -tzf "$tarball" | grep -q 'overlay_only_test' && fail "bundle holds a skipped test"
tar -tzf "$tarball" | grep -q 'bin/objc_interop_test$' || fail "bundle lacks objc_interop_test, which needs no overlay"

echo "-- SWIFTC with SWIFT_RUNTIME_PREFIX: header padding, then the prefix's rpath replaces the installed one"
rm -f "$T/calls"
P="$T/staged/usr/local/mavergreen/swift-runtime"
mkdir -p "$P/lib/swift"; : > "$P/lib/swift/libswiftCore.dylib"
PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" sh "$REPO/make-selftest.sh" > /dev/null
for src in "$T/src"/*.swift; do
  n="$(basename "$src" .swift)"
  [ "$(head -1 "$src")" = "// requires: overlays" ] && continue
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
echo "PASS"
