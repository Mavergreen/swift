#!/bin/sh
# platform: host-agnostic
#   usage: stage-runtime.sh <built-lib-dir> <out-dir> <license-file> <notice-file>
#          Lays out the runtime .pkg's payload under <out-dir>: libswiftCore.dylib and
#          libswiftSwiftOnoneSupport.dylib from <built-lib-dir> in
#          usr/local/mavergreen/swift-runtime/lib/swift/, and <license-file> as
#          usr/local/mavergreen/swift-runtime/share/doc/LICENSE.txt, and <notice-file> beside it as NOTICE (it
#          names what the runtime holds besides Swift, Recaulk among them, whose license asks for its
#          notice in every copy). <out-dir> persists between
#          builds, so everything an earlier layout left under usr/ (and a stray LICENSE.txt at
#          the payload root) is removed first; <out-dir>/Library belongs to package.sh and is
#          left alone.
set -eu
[ $# -eq 4 ] || { echo "usage: stage-runtime.sh <built-lib-dir> <out-dir> <license-file> <notice-file>" >&2; exit 2; }
BUILT="$1"; OUT="$2"; LICENSE="$3"; NOTICE="$4"
. "$(dirname "$0")/outdir.sh"
refuse_root_outdir stage-runtime "$OUT"
for lib in libswiftCore.dylib libswiftSwiftOnoneSupport.dylib; do
  [ -f "$BUILT/$lib" ] || { echo "stage-runtime: $BUILT has no $lib" >&2; exit 1; }
done
[ -f "$LICENSE" ] || { echo "stage-runtime: no license at $LICENSE" >&2; exit 1; }
[ -f "$NOTICE" ] || { echo "stage-runtime: no notice at $NOTICE" >&2; exit 1; }

PREFIX="$OUT/usr/local/mavergreen/swift-runtime"
rm -rf "$OUT/usr" "$OUT/LICENSE.txt"
mkdir -p "$PREFIX/lib/swift" "$PREFIX/share/doc"
cp "$BUILT/libswiftCore.dylib" "$BUILT/libswiftSwiftOnoneSupport.dylib" "$PREFIX/lib/swift/"
cp "$LICENSE" "$PREFIX/share/doc/LICENSE.txt"
cp "$NOTICE" "$PREFIX/share/doc/NOTICE"
