#!/bin/sh
# platform: host-agnostic
# usage: sh tests/require-libcxx22-test.sh
#   The packagers whose stdlib dylibs load on 10.9 (the runtime's, and the native toolchain's copies) require
#   libcxx22 at pins.env's CLANG22_VERSION or later through shipyard's --requires SHORT>=VERSION, quoted (an
#   unquoted >= is a redirection); the cross toolchain, which only links against its copies, requires nothing.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in package.sh package-toolchain.sh; do
  grep -qF -- '--requires "libcxx22>=$CLANG22_VERSION"' "$REPO/$f" || fail "$f does not require libcxx22>=\$CLANG22_VERSION, quoted"
  if grep -n 'libcxx22>=' "$REPO/$f" | grep -v '"libcxx22>=\$CLANG22_VERSION"'; then fail "$f names libcxx22>= unquoted or with another minimum"; fi
done
awk '/^if \[ "\$PRODUCT" = swift-toolchain \]; then$/ { n++ } END { exit n >= 2 ? 0 : 1 }' "$REPO/package-toolchain.sh" \
  || fail "package-toolchain.sh's requirement is not limited to swift-toolchain"
[ ! -e "$REPO/scripts/require-libcxx22.preinstall" ] || fail "the hand-written libcxx22 preinstall is back; shipyard's --requires checks the minimum"
echo "PASS: require-libcxx22"
