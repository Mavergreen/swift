#!/bin/sh
# platform: macOS-only -- pkgbuild makes, and pkgutil, ditto and lsbom expand, the fixture installers
# usage: sh tests/expand-toolchain-test.sh
#   expand_toolchain must expand an installer's payload once, reuse it while it is whole, and expand
#   again when a file has gone (macOS's $TMPDIR cleaner) or the installer is another one (a Swift bump).
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
command -v pkgbuild >/dev/null 2>&1 || { echo "no pkgbuild (not macOS) -- skipping"; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/expand-toolchain.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mk_pkg() {  # $1 = pkg name, $2 = what its usr/bin/swiftc says
  rm -rf "$T/root"; mkdir -p "$T/root/usr/bin" "$T/root/usr/lib/swift/shims"
  printf '%s\n' "$2" > "$T/root/usr/bin/swiftc"
  : > "$T/root/usr/lib/swift/shims/module.modulemap"
  pkgbuild --quiet --root "$T/root" --identifier test.expand-toolchain --version 1 \
    --install-location / "$T/$1" >/dev/null
}
mk_pkg a.pkg A
mk_pkg b.pkg B
. "$REPO/lib.sh"
D="$T/tc"

expand_toolchain "$T/a.pkg" "$D" || fail "expanding a.pkg failed"
[ "$(cat "$D/usr/bin/swiftc")" = A ] || fail "the first expansion is not a.pkg's payload"

echo extra > "$D/usr/bin/extra"
expand_toolchain "$T/a.pkg" "$D" || fail "reusing a.pkg's expansion failed"
[ -f "$D/usr/bin/extra" ] || fail "expanded again although the expansion was whole"

rm "$D/usr/lib/swift/shims/module.modulemap"
expand_toolchain "$T/a.pkg" "$D" || fail "re-expanding a gutted expansion failed"
[ -f "$D/usr/lib/swift/shims/module.modulemap" ] || fail "a gutted expansion was not restored"
[ ! -f "$D/usr/bin/extra" ] || fail "a gutted expansion was patched up rather than expanded again"

expand_toolchain "$T/b.pkg" "$D" || fail "expanding b.pkg failed"
[ "$(cat "$D/usr/bin/swiftc")" = B ] || fail "kept a.pkg's expansion for b.pkg"
echo "PASS"
