#!/bin/sh
# platform: host-agnostic -- clang22's llvm-otool (fetch-clang22.sh's) reads the built Mach-O binaries, on a Mac and on Linux
# usage: sh tests/make-selftest-test.sh
#   Builds the self-test bundle with the compiler build.sh ran with -- the toolchain prefix SWIFT_HOST_TOOLCHAIN
#   names (this repo's compiler; on Linux the only one), else the swift.org toolchain build.sh expanded -- and
#   checks every binary is minOS 10.9 and records SDK 10.9, links its libswift* only by @rpath (the stdlib
#   build's, never an SDK's /usr/lib/swift), and has exactly one rpath: the runtime prefix. Every tests/*.swift
#   must compile there, the overlays' tests included, but those that skip themselves (`// selftest: skip:
#   <reason>`), and, with the swift.org compiler, those whose first line says they need this repo's compiler
#   (compiler patch 0003), which must be skipped; this repo's compiler must build those too. A test with a
#   leading `// selftest: also -swift-version 6` line must have its -swift6 and -swift6-Onone builds checked the
#   same. SKIP when build.sh has not run, or on Linux without SWIFT_HOST_TOOLCHAIN.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
export MAVERICKS_BUILD_ROOT
. "$REPO/lib.sh"   # -> macho_version, macho_rpaths
unset DYLDINFO     # macho_rpaths reads with $OTOOL alone
if [ -n "${SWIFT_HOST_TOOLCHAIN:-}" ]; then
  [ -x "$SWIFT_HOST_TOOLCHAIN/bin/swift-frontend" ] || { echo "no swift-frontend in SWIFT_HOST_TOOLCHAIN=$SWIFT_HOST_TOOLCHAIN -- skipping"; exit 77; }
  OURS=1
else
  # platform: Linux has no swift.org compiler for this; its compiler is always a named prefix, as build.sh's
  [ "$(uname -s)" != Linux ] || { echo "on Linux the compiler is the prefix SWIFT_HOST_TOOLCHAIN names (build.sh's) -- skipping"; exit 77; }
  TC="$MAVERICKS_BUILD_ROOT/swift/work/toolchain/usr"
  [ -x "$TC/bin/swiftc" ] || { echo "no toolchain at $TC (run build.sh) -- skipping"; exit 77; }
  OURS=0
fi
[ -f "$MAVERICKS_BUILD_ROOT/swift/work/stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib" ] \
  || { echo "no stdlib build under $MAVERICKS_BUILD_ROOT (run build.sh) -- skipping"; exit 77; }
X="$(sh "$REPO/fetch-clang22.sh")" || { echo "FAIL: no mavericks-clang-22 (fetch-clang22.sh), whose llvm-otool reads the bundle" >&2; exit 1; }
OTOOL="$X/bin/llvm-otool"; export OTOOL
[ -x "$OTOOL" ] || { echo "FAIL: no $OTOOL" >&2; exit 1; }

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
  case "$(sed -n 1p "$src")" in
    "// selftest: needs this repo's compiler"*)
      if [ "$OURS" = 0 ]; then
        [ ! -e "$B/bin/$n" ] && [ ! -e "$B/bin/$n-Onone" ] && [ ! -e "$B/bin/$n-swift6" ] && [ ! -e "$B/bin/$n-swift6-Onone" ] || fail "built $n, which needs this repo's compiler"
        continue
      fi ;;
    "// selftest: skip: "*)
      [ ! -e "$B/bin/$n" ] && [ ! -e "$B/bin/$n-Onone" ] && [ ! -e "$B/bin/$n-swift6" ] && [ ! -e "$B/bin/$n-swift6-Onone" ] || fail "built $n, whose first line skips it"
      continue ;;
  esac
  bins="$B/bin/$n $B/bin/$n-Onone"
  # a leading `// selftest: also -swift-version 6` line makes two more
  if [ -n "$(sed -n '/^\/\//!q; s/^\/\/ selftest: also //p' "$src")" ]; then bins="$bins $B/bin/$n-swift6 $B/bin/$n-swift6-Onone"; fi
  for bin in $bins; do
    [ -x "$bin" ] || fail "missing $bin"
    ver="$(macho_version "$bin")" || fail "$OTOOL -l $bin"
    [ "$ver" = "10.9 10.9" ] || fail "$bin is not minOS 10.9 and SDK 10.9: '$ver'"
    libs="$("$OTOOL" -L "$bin" | tail -n +2 | awk '{ print $1 }')" || fail "$OTOOL -L $bin"
    printf '%s\n' "$libs" | grep -qx '@rpath/libswiftCore.dylib' || fail "$bin does not link @rpath/libswiftCore.dylib: $libs"
    if printf '%s\n' "$libs" | grep 'libswift' | grep -v '^@rpath/'; then fail "$bin links a libswift* not by @rpath (listed above)"; fi
    rpaths="$(macho_rpaths "$bin")" || fail "$OTOOL -l $bin"
    [ "$rpaths" = "$PREFIX/lib/swift" ] || fail "$bin rpaths are '$rpaths', wanted only $PREFIX/lib/swift"
  done
done
echo "PASS"
