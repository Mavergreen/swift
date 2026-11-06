#!/bin/sh
# platform: macOS-only -- xcrun finds dyld_info, which reads the built Mach-O binaries
# usage: sh tests/make-selftest-test.sh
#   Builds the self-test bundle with the toolchain build.sh expanded, and checks every binary is
#   x86_64 / minOS 10.9, records the 10.9 SDK, links its libswift* only by @rpath (the stdlib build's,
#   never an SDK's /usr/lib/swift), and has exactly one rpath: the runtime prefix. Every tests/*.swift
#   must compile there, the overlays' tests included. SKIP when build.sh has not run.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
TC="$MAVERICKS_BUILD_ROOT/swift/work/toolchain/usr"
[ -x "$TC/bin/swiftc" ] || { echo "no toolchain at $TC (run build.sh) -- skipping"; exit 77; }
[ -f "$MAVERICKS_BUILD_ROOT/swift/work/stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib" ] \
  || { echo "no stdlib build under $MAVERICKS_BUILD_ROOT (run build.sh) -- skipping"; exit 77; }
DI="$(xcrun -f dyld_info)"

T="$(mktemp -d "${TMPDIR:-/tmp}/make-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

PREFIX=/opt/example-runtime-prefix
tarball="$(DIST="$T/dist" SWIFT_RUNTIME_PREFIX="$PREFIX" sh "$REPO/make-selftest.sh" | tail -1)"
[ -f "$tarball" ] || fail "make-selftest.sh did not print an existing tarball (got '$tarball')"

# 10.9's libarchive 2.8.3 chokes on the pax xattr headers a modern host's bsdtar writes (e.g.
# com.apple.provenance), and on the AppleDouble ._ sidecar members it emits for a resource fork:
# `tar -tzf` there prints "Ignoring malformed pax extended attribute" and exits 1. Neither may
# appear in the archive make-selftest.sh builds.
if gzip -dc "$tarball" | grep -aq 'LIBARCHIVE\.xattr\.\|SCHILY\.xattr\.'; then
  fail "tarball carries a pax xattr header 10.9's libarchive 2.8.3 cannot parse"
fi
if tar -tzf "$tarball" | grep -q '/\._'; then
  fail "tarball carries an AppleDouble ._ member"
fi

tar -xzf "$tarball" -C "$T"
B="$T/swift-runtime-selftest"
[ -f "$B/run-selftest.sh" ] || fail "bundle has no run-selftest.sh"
cmp -s "$B/run-selftest.sh" "$REPO/tests/run-selftest.sh" || fail "bundled run-selftest.sh differs from tests/"

for src in "$REPO"/tests/*.swift; do
  n="$(basename "$src" .swift)"
  for bin in "$B/bin/$n" "$B/bin/$n-Onone"; do
    [ -x "$bin" ] || fail "missing $bin"
    plat="$("$DI" -platform "$bin")" || fail "dyld_info -platform $bin"
    printf '%s\n' "$plat" | awk 'NR==4{ if ($2 != "10.9" || $3 != "10.9") exit 1 }' || fail "$bin is not minOS 10.9 and SDK 10.9: $plat"
    libs="$("$DI" -linked_dylibs "$bin" | tail -n +3 | awk '{ print $NF }')" || fail "dyld_info -linked_dylibs $bin"
    printf '%s\n' "$libs" | grep -qx '@rpath/libswiftCore.dylib' || fail "$bin does not link @rpath/libswiftCore.dylib: $libs"
    if printf '%s\n' "$libs" | grep 'libswift' | grep -v '^@rpath/'; then fail "$bin links a libswift* not by @rpath (listed above)"; fi
    rpaths="$("$DI" -rpaths "$bin" | tail -n +3 | sed 's/^ *//')" || fail "dyld_info -rpaths $bin"
    [ "$rpaths" = "$PREFIX/lib/swift" ] || fail "$bin rpaths are '$rpaths', wanted only $PREFIX/lib/swift"
  done
done
echo "PASS"
