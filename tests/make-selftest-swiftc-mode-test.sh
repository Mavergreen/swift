#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-swiftc-mode-test.sh
#   make-selftest.sh with SWIFTC= must invoke that compiler with nothing but -O|-Onone, the source and
#   -o, and must skip every test marked `// requires: overlays`. A fake compiler records its calls.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cat > "$T/fake-swiftc" <<EOF
#!/bin/sh
echo "\$*" >> "$T/calls"
while [ \$# -gt 0 ]; do case "\$1" in -o) printf '#!/bin/sh\nexit 0\n' > "\$2"; chmod +x "\$2"; shift 2;; *) shift;; esac; done
EOF
chmod +x "$T/fake-swiftc"
tarball="$(SWIFTC="$T/fake-swiftc" DIST="$T/dist" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "no tarball (got '$tarball')"
grep -q 'objc_interop_test' "$T/calls" && fail "compiled a // requires: overlays test"
for src in "$REPO"/tests/*.swift; do
  n="$(basename "$src" .swift)"
  [ "$(head -1 "$src")" = "// requires: overlays" ] && continue
  grep -qx -- "-O $src -o $T/dist/swift-runtime-selftest/bin/$n" "$T/calls" || fail "no exact -O call for $n: $(cat "$T/calls")"
  grep -qx -- "-Onone $src -o $T/dist/swift-runtime-selftest/bin/$n-Onone" "$T/calls" || fail "no exact -Onone call for $n"
done
tar -tzf "$tarball" | grep -q 'swift-runtime-selftest/run-selftest.sh' || fail "bundle lacks run-selftest.sh"
tar -tzf "$tarball" | grep -q 'objc_interop_test' && fail "bundle holds a skipped test"
echo "PASS"
