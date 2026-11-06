#!/bin/sh
# platform: host-agnostic
#   usage: stage-runtime.sh <built-lib-dir> <out-dir> <license-file> <notice-file>
#          Lays out the runtime .pkg's payload under <out-dir>: libswiftCore.dylib,
#          libswiftSwiftOnoneSupport.dylib, libswiftDarwin.dylib and libswiftObjectiveC.dylib (the
#          overlays every program importing Darwin or ObjectiveC loads) from <built-lib-dir> in
#          usr/local/mavergreen/swift-runtime/lib/swift/, and <license-file> as
#          usr/local/mavergreen/swift-runtime/share/doc/LICENSE.txt, and <notice-file> beside it as NOTICE (it
#          names what the runtime holds besides Swift, Recaulk among them, whose license asks for its
#          notice in every copy). Only the dylibs: the overlays' swiftmodules ship in the toolchains.
#          <out-dir> persists between builds, so everything an earlier layout left under usr/ (and a stray LICENSE.txt at
#          the payload root) is removed first; <out-dir>/Library belongs to package.sh and is
#          left alone.
set -eu
[ $# -eq 4 ] || { echo "usage: stage-runtime.sh <built-lib-dir> <out-dir> <license-file> <notice-file>" >&2; exit 2; }
BUILT="$1"; OUT="$2"; LICENSE="$3"; NOTICE="$4"
. "$(dirname "$0")/outdir.sh"
refuse_root_outdir stage-runtime "$OUT"
# One list for the refusal and the copy. build.sh's SHIPPED_DYLIBS names the same four by path, for its
# pre-flight; it reads them from two places, so it stays its own variable.
RUNTIME_DYLIBS="libswiftCore.dylib libswiftSwiftOnoneSupport.dylib libswiftDarwin.dylib libswiftObjectiveC.dylib"
for lib in $RUNTIME_DYLIBS; do
  [ -f "$BUILT/$lib" ] || { echo "stage-runtime: $BUILT has no $lib" >&2; exit 1; }
done
[ -f "$LICENSE" ] || { echo "stage-runtime: no license at $LICENSE" >&2; exit 1; }
[ -f "$NOTICE" ] || { echo "stage-runtime: no notice at $NOTICE" >&2; exit 1; }

PREFIX="$OUT/usr/local/mavergreen/swift-runtime"
rm -rf "$OUT/usr" "$OUT/LICENSE.txt"
mkdir -p "$PREFIX/lib/swift" "$PREFIX/share/doc"
for lib in $RUNTIME_DYLIBS; do cp "$BUILT/$lib" "$PREFIX/lib/swift/"; done
cp "$LICENSE" "$PREFIX/share/doc/LICENSE.txt"
cp "$NOTICE" "$PREFIX/share/doc/NOTICE"
