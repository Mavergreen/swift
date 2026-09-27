#!/bin/sh
# platform: macOS-only -- xcrun finds the SDK for the default compiler; SWIFTC= mode runs on OS X 10.9 itself
#   usage: make-selftest.sh
#          Compiles every tests/*.swift at -O and -Onone into a self-test bundle for a 10.9 box --
#          bin/<name> and bin/<name>-Onone, plus run-selftest.sh -- and prints the tarball's path last.
#          Two compilers:
#            default          the swift.org toolchain build.sh expanded, for x86_64-apple-macosx10.9,
#                             -no-stdlib-rpath and one rpath, $SWIFT_RUNTIME_PREFIX/lib/swift
#                             (default /usr/local/mavergreen/swift-runtime). Run after build.sh.
#            SWIFTC=<swiftc>  exactly `$SWIFTC -O|-Onone <file> -o <out>`: this repo's own toolchain,
#                             on 10.9, whose defaults supply target, SDK and rpath. Skips every test
#                             whose first line is `// requires: overlays`. With SWIFT_RUNTIME_PREFIX
#                             also set (a staged, uninstalled runtime), each compile adds
#                             `-Xlinker -headerpad_max_install_names`, and install_name_tool then
#                             replaces the wrapper's rpath with $SWIFT_RUNTIME_PREFIX/lib/swift.
#          Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, TC (toolchain usr/), DIST (output dir),
#          SWIFT_RUNTIME_PREFIX, SWIFTC.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/lib.sh"    # -> $SWIFT_BUILD
DIST="${DIST:-$SWIFT_BUILD/dist}"
if [ -n "${SWIFTC:-}" ]; then
  [ -x "$SWIFTC" ] || { echo "make-selftest: SWIFTC=$SWIFTC is not executable" >&2; exit 1; }
  if [ -n "${SWIFT_RUNTIME_PREFIX:-}" ]; then
    # platform: the toolchain's swiftc always adds the INSTALLED runtime's rpath, first, so an added
    #           rpath would lose to it; so it is replaced. 10.9's install_name_tool refuses to grow the
    #           load commands without the header padding the first line asks the linker for.
    compile() {
      "$SWIFTC" "-$1" -Xlinker -headerpad_max_install_names "$2" -o "$3" >&2 &&
        install_name_tool -rpath /usr/local/mavergreen/swift-runtime/lib/swift "$SWIFT_RUNTIME_PREFIX/lib/swift" "$3" >&2
    }
  else
    compile() { "$SWIFTC" "-$1" "$2" -o "$3" >&2; }
  fi
else
  TC="${TC:-${SWIFT_WORK:-$SWIFT_BUILD/work}/toolchain/usr}"
  [ -x "$TC/bin/swiftc" ] || { echo "make-selftest: no swiftc at $TC/bin/swiftc -- run build.sh first" >&2; exit 1; }
  SDK="$(xcrun --show-sdk-path)"
  RUNTIME_LIB="${SWIFT_RUNTIME_PREFIX:-/usr/local/mavergreen/swift-runtime}/lib/swift"
  compile() {
    "$TC/bin/swiftc" -sdk "$SDK" -target x86_64-apple-macosx10.9 "-$1" -no-stdlib-rpath \
      -Xlinker -rpath -Xlinker "$RUNTIME_LIB" "$2" -o "$3" >&2
  }
fi

NAME=swift-runtime-selftest
B="$DIST/$NAME"; rm -rf "$B"; mkdir -p "$B/bin"
for src in "$REPO"/tests/*.swift; do
  [ -f "$src" ] || continue
  n="$(basename "$src" .swift)"
  if [ -n "${SWIFTC:-}" ] && [ "$(head -1 "$src")" = "// requires: overlays" ]; then
    echo "skipped (needs the overlays): $n" >&2; continue
  fi
  compile O "$src" "$B/bin/$n"; echo "built: $n" >&2
  compile Onone "$src" "$B/bin/$n-Onone"; echo "built: $n-Onone" >&2
done
[ -n "$(ls -A "$B/bin")" ] || { echo "make-selftest: nothing was built" >&2; exit 1; }
cp "$REPO/tests/run-selftest.sh" "$B/run-selftest.sh"; chmod +x "$B/run-selftest.sh"

# A modern host's bsdtar tags most files with com.apple.provenance and packs it as a pax
# LIBARCHIVE.xattr./SCHILY.xattr. header; 10.9's libarchive 2.8.3 can't parse that ("Ignoring
# malformed pax extended attribute") and `tar -xzf` there exits 1. COPYFILE_DISABLE keeps
# AppleDouble ._ sidecar members out of the archive too. --no-xattrs suppresses the pax header, but
# 10.9's own bsdtar (this script also runs ON 10.9) doesn't know that flag and would abort under
# set -eu, so probe for support first instead of passing it unconditionally.
NOX=""
if tar --no-xattrs -cf /dev/null "$REPO/make-selftest.sh" >/dev/null 2>&1; then NOX="--no-xattrs"; fi
( cd "$DIST" && COPYFILE_DISABLE=1 tar $NOX -czf "$NAME.tar.gz" "$NAME" && rm -rf "$NAME" )
echo "$DIST/$NAME.tar.gz"
