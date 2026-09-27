#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-swiftc-mode-test.sh
#   make-selftest.sh with SWIFTC= must invoke that compiler with nothing but -O|-Onone, the source and
#   -o, and must skip every test marked `// requires: overlays`. With SWIFT_RUNTIME_PREFIX set too, each
#   compile must also ask for header padding, and each binary's installed-runtime rpath must be replaced
#   by the prefix's; a replacement that fails must fail the bundle. A fake compiler and a fake
#   install_name_tool record their calls.
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
chmod +x "$T/fake-swiftc" "$T/bin/install_name_tool"
B="$T/dist/swift-runtime-selftest/bin"

echo "-- SWIFTC alone: exactly -O|-Onone <file> -o <out>, no rpath rewrite"
tarball="$(unset SWIFT_RUNTIME_PREFIX; PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball (got '$tarball')"
grep -q 'objc_interop_test' "$T/calls" && fail "compiled a // requires: overlays test"
for src in "$REPO"/tests/*.swift; do
  n="$(basename "$src" .swift)"
  [ "$(head -1 "$src")" = "// requires: overlays" ] && continue
  grep -qx -- "-O $src -o $B/$n" "$T/calls" || fail "no exact -O call for $n: $(cat "$T/calls")"
  grep -qx -- "-Onone $src -o $B/$n-Onone" "$T/calls" || fail "no exact -Onone call for $n"
done
[ ! -f "$T/int-calls" ] || fail "rewrote an rpath without SWIFT_RUNTIME_PREFIX: $(cat "$T/int-calls")"
tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/run-selftest.sh' || fail "bundle lacks run-selftest.sh"
tar -tzf "$tarball" | grep -q 'objc_interop_test' && fail "bundle holds a skipped test"

echo "-- SWIFTC with SWIFT_RUNTIME_PREFIX: header padding, then the prefix's rpath replaces the installed one"
rm -f "$T/calls"
P="$T/staged/usr/local/mavergreen/swift-runtime"
PATH="$T/bin:$PATH" SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" sh "$REPO/make-selftest.sh" > /dev/null
for src in "$REPO"/tests/*.swift; do
  n="$(basename "$src" .swift)"
  [ "$(head -1 "$src")" = "// requires: overlays" ] && continue
  for o in O Onone; do
    out="$B/$n"; [ "$o" = O ] || out="$B/$n-Onone"
    grep -qx -- "-$o -Xlinker -headerpad_max_install_names $src -o $out" "$T/calls" || fail "no padded -$o call for $n: $(cat "$T/calls")"
    grep -qx -- "-rpath /usr/local/mavergreen/swift-runtime/lib/swift $P/lib/swift $out" "$T/int-calls" \
      || fail "no rpath replacement for $out: $(cat "$T/int-calls" 2>/dev/null)"
  done
done

echo "-- a replacement that fails fails the bundle"
if PATH="$T/bin:$PATH" FAKE_INT_RC=1 SWIFTC="$T/fake-swiftc" SWIFT_RUNTIME_PREFIX="$P" DIST="$T/dist" \
     sh "$REPO/make-selftest.sh" > /dev/null 2>&1; then
  fail "make-selftest.sh succeeded although install_name_tool failed"
fi
echo "PASS"
