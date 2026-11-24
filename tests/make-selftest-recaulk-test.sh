#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-recaulk-test.sh
#   spec: INGREDIENTS.md "Recaulk in every program" -- make-selftest.sh's default mode with SWIFT_HOST_TOOLCHAIN
#   must link every test as the shipped swiftc links a user's program: toolchain/ld's line, Recaulk's archive just
#   before the driver's first -lobjc or -lSystem, so a test calls Recaulk's fma, fmal and truncl and not 10.9's
#   (whose truncl(+0) and fma(1+u, u-1, 1) come back negative). The archive is the prefix's own lib/recaulk/
#   librecaulk.a where it carries one (a shipped toolchain's), else fetch-recaulk.sh's (the Linux-hosted prefix
#   has none). A fake compiler links through the `ld` of its -tools-directory, and a fake ld64.lld records the
#   archive it was handed. SKIPs without a shipyard or the 10.9 SDK.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
( . "$REPO/msc.sh" ) >/dev/null 2>&1 || { echo "no shipyard -- skipping"; exit 77; }
. "$REPO/msc.sh"
MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh" >/dev/null 2>&1 || { echo "no 10.9 SDK -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/make-selftest-recaulk.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# A prefix as native_host_shim reads one: the fake driver links through <tools-directory>/ld with the driver's
# Darwin line; the fake lld writes the cksum of the argument just before the first -lobjc or -lSystem.
P="$T/prefix"
mkdir -p "$P/bin" "$P/lib/swift" "$T/work/stdlib-build/lib/swift/macosx/x86_64" "$T/src" "$T/tmp"
: > "$T/work/stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib"
printf 'print(1)\n' > "$T/src/t.swift"
cat > "$P/bin/swift-frontend" <<'EOF2'
#!/bin/sh
d="" o=""
while [ $# -gt 0 ]; do case "$1" in -tools-directory) d="$2"; shift ;; -o) o="$2"; shift ;; esac; shift; done
exec "$d/ld" -demangle -dynamic -arch x86_64 -o "$o" /fake/t.o -lobjc -lSystem
EOF2
cat > "$P/bin/ld64.lld" <<EOF2
#!/bin/sh
prev=""; o=""; seen=""
for a do
  case "\$a" in -lobjc|-lSystem) [ -n "\$seen" ] || { seen=1; cksum < "\$prev" > "$T/archive-seen" 2>/dev/null || echo "\$prev" > "$T/archive-seen"; } ;; esac
  [ "\$prev" != -o ] || o="\$a"
  prev="\$a"
done
printf '#!/bin/sh\nexit 0\n' > "\$o"; chmod +x "\$o"
EOF2
for t in clang dsymutil; do printf '#!/bin/sh\nexit 0\n' > "$P/bin/$t"; done
chmod +x "$P/bin/swift-frontend" "$P/bin/ld64.lld" "$P/bin/clang" "$P/bin/dsymutil"

run() {
  env SWIFT_HOST_TOOLCHAIN="$P" SWIFT_WORK="$T/work" DIST="$T/dist" SELFTEST_SRC="$T/src" TMPDIR="$T/tmp" \
    sh "$REPO/make-selftest.sh" > "$T/log" 2>&1
}

# A prefix with its own archive (a shipped toolchain's): that one.
mkdir -p "$P/lib/recaulk"; echo "the prefix's own Recaulk" > "$P/lib/recaulk/librecaulk.a"
rm -f "$T/archive-seen"
run || { cat "$T/log"; fail "make-selftest.sh failed with a prefix that carries Recaulk"; }
[ -f "$T/archive-seen" ] || fail "the link reached no -lobjc or -lSystem"
[ "$(cat "$T/archive-seen")" = "$(cksum < "$P/lib/recaulk/librecaulk.a")" ] \
  || fail "the prefix's lib/recaulk/librecaulk.a is not just before -lobjc (that argument: $(cat "$T/archive-seen"))"

# A prefix without one (the Linux-hosted compiler's): fetch-recaulk.sh's, the pinned release's.
rm -rf "$P/lib/recaulk"
RK="$(sh "$REPO/fetch-recaulk.sh" 2>/dev/null)/lib/librecaulk.a" || fail "fetch-recaulk.sh failed"
rm -f "$T/archive-seen"
run || { cat "$T/log"; fail "make-selftest.sh failed with a prefix that carries no Recaulk"; }
[ "$(cat "$T/archive-seen")" = "$(cksum < "$RK")" ] \
  || fail "fetch-recaulk.sh's librecaulk.a is not just before -lobjc (that argument: $(cat "$T/archive-seen"))"
[ -z "$(ls -A "$T/tmp")" ] || fail "a temporary file is left in TMPDIR: $(ls -A "$T/tmp")"
echo PASS
