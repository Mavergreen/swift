#!/bin/sh
# platform: host-agnostic -- python3 (gyb, upstream-tests.py), cp
#   usage: stage-selftest-support.sh <stdlib-build> <tree> <lists-dir> <out>
#          Lays out what the self-test bundle needs to build and run upstream's tests (spec: "Upstream tests")
#          in <out>, afresh, for make-selftest.sh's SELFTEST_SUPPORT=<out>:
#            lib/       the test-support dylibs build.sh's step 5b built into <stdlib-build>/selftest-support
#                       (libswiftSwiftPrivate, libswiftSwiftPrivateLibcExtras, libswiftSwiftPrivateThreadExtras,
#                       libswiftStdlibUnittest), which the bundle carries in its own lib/; never in a pkg
#            modules/   their .swiftmodule dirs, for the tests' -I
#            upstream/<layer>/<path>       each test <lists-dir>/<layer>.list includes, copied from <tree>;
#                                          for a .gyb, beside it, gyb's output: <path> less its .gyb
#            upstream/<layer>/<path>.args  its compile-line (scripts/upstream-tests.py), one argument per line
#            upstream/<layer>/<path>.<n>.args  the compile-line of its variant n, from 2 up, where lit builds
#                                          it more than once (upstream-tests.py variants)
#          The modules are binary .swiftmodule files, which only the compiler that wrote them reads: the one
#          that built this release's stdlib. In CI that is the same run's cross toolchain (build-cross), the
#          same Swift and the same release as the native toolchain vm-test installs and builds the bundle
#          with on 10.9; a local bundle is built by the host toolchain build.sh ran with.
#   Env: PYTHON (gyb's and upstream-tests.py's python, default python3).
set -eu
[ $# -eq 4 ] || { echo "usage: stage-selftest-support.sh <stdlib-build> <tree> <lists-dir> <out>" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SB="$1"; TREE="$2"; LISTS="$3"; OUT="$4"
PY="${PYTHON:-python3}"
SUP="$SB/selftest-support"; ARCH=x86_64
MODS="SwiftPrivate SwiftPrivateLibcExtras SwiftPrivateThreadExtras StdlibUnittest"
for m in $MODS; do
  [ -f "$SUP/$ARCH/libswift$m.dylib" ] && [ -d "$SUP/$m.swiftmodule" ] \
    || { echo "stage-selftest-support.sh: no $m in $SUP (build.sh's step 5b builds it)" >&2; exit 1; }
done
[ -f "$TREE/utils/gyb" ] || { echo "stage-selftest-support.sh: $TREE is no swift tree (no utils/gyb)" >&2; exit 1; }
set -- "$LISTS"/*.list
[ -f "$1" ] || { echo "stage-selftest-support.sh: no *.list in $LISTS" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/modules" "$OUT/upstream"
for m in $MODS; do
  cp "$SUP/$ARCH/libswift$m.dylib" "$OUT/lib/"
  cp -R "$SUP/$m.swiftmodule" "$OUT/modules/"
done
n=0; builds=0
for list in "$@"; do
  layer="$(basename "$list" .list)"
  "$PY" -I "$HERE/scripts/upstream-tests.py" check "$TREE" "$layer" "$list" >/dev/null \
    || { echo "stage-selftest-support.sh: $list does not match $TREE (above)" >&2; exit 1; }
  for p in $(sed -n 's/^include \([^ ]*\)$/\1/p' "$list"); do
    d="$OUT/upstream/$layer/$p"; mkdir -p "$(dirname "$d")"
    cp "$TREE/$p" "$d"
    case "$p" in
      *.gyb)
        [ ! -e "$TREE/${p%.gyb}" ] || { echo "stage-selftest-support.sh: $p's gyb output would be $TREE's own ${p%.gyb}" >&2; exit 1; }
        PYTHONHASHSEED=0 "$PY" "$TREE/utils/gyb" --line-directive '' -o "${d%.gyb}" "$d" \
          || { echo "stage-selftest-support.sh: gyb failed on $p" >&2; exit 1; } ;;
    esac
    nv="$("$PY" -I "$HERE/scripts/upstream-tests.py" variants "$TREE" "$p")" \
      || { echo "stage-selftest-support.sh: no compile-line for $p" >&2; exit 1; }
    v=1
    while [ "$v" -le "$nv" ]; do
      a="$d.args"; [ "$v" = 1 ] || a="$d.$v.args"
      "$PY" -I "$HERE/scripts/upstream-tests.py" compile-line "$TREE" "$p" "$v" > "$a" \
        || { echo "stage-selftest-support.sh: no compile-line for $p's variant $v" >&2; exit 1; }
      v=$((v + 1))
    done
    n=$((n + 1)); builds=$((builds + nv))
  done
done
echo "staged test support in $OUT: $(ls "$OUT/lib" | tr '\n' ' ')and $n upstream tests ($builds builds)"
