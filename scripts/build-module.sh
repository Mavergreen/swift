#!/bin/sh
# platform: macOS-only -- runs a Mavergreen host toolchain's Swift driver and ld64.lld (a modern Mac or OS X 10.9)
#   usage: build-module.sh --name <Module> --link-name <swiftX> --sdk <sdk> --resource-dir <stdlib lib/swift>
#            --availability <availability-macros.def> --work <dir> --out <dir>
#            [--I <dir>]... [--link <file>]... [--unexported <list>] -- <source.swift>...
#          Compiles one Swift module beside the stdlib, as the stdlib's CMake compiles its own libraries,
#          for x86_64-apple-macosx$DEPLOYMENT (pins.env): <out>/<Module>.swiftmodule/x86_64-apple-macos.swiftmodule
#          and <out>/x86_64/lib<swiftX>.dylib, whose install name is @rpath/lib<swiftX>.dylib and whose
#          compatibility version is 1 (Concurrency, through _Builtin_float, demands 1.0.0 of libswiftDarwin).
#          build.sh's step 5b builds the Darwin and ObjectiveC overlays with it (spec: "The overlays").
#          The module imports the Swift module of <resource-dir> (the stdlib build's own, never an
#          Apple .swiftinterface: the 10.9 SDK has none) and links its libswiftCore; <sdk> is the SDK the
#          clang importer reads. --I adds an import path (a clang module map's directory, say); --link
#          names a file the link takes (an archive); --unexported, the -unexported_symbols_list that hides
#          its globals. <out> itself is an import path and <out>/x86_64 a library path, so a module built
#          into the same <out> earlier (Darwin, for ObjectiveC) is found. <work> holds the module cache and
#          the availability list, afresh on every run.
#          The flags are the stdlib's (its build.ninja: library evolution, -library-level api, no implicit
#          Concurrency or StringProcessing import, -target-min-inlining-version min, ...) and its
#          -define-availability list, from <availability-macros.def> as the stdlib's CMake reads it;
#          availability checking stays on (never -disable-availability-checking), and the stdlib's
#          -require-explicit-availability=ignore silences "public declarations should have an
#          availability attribute". No libc++ is linked: the swift driver names none, and a module here
#          has no C++.
#          The build root, ${SWIFT_WORK:-$SWIFT_BUILD/work} as build.sh's, is prefix-mapped to
#          /mavergreen-build in both spellings (lib.sh's prefix_map_flags), so two roots give the same bytes.
#   Env: SWIFTC (the host Swift driver: build.sh's $TC/bin/swiftc), LLD (the ld64.lld that links),
#        MAVERICKS_BUILD_ROOT, SWIFT_WORK.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '3,5p' "$0" | sed 's/^#   *//' >&2; exit 2; }
NAME=""; LINKNAME=""; SDK=""; RES=""; AVAIL=""; WORK=""; OUT=""; INCS=""; LINKS=""; UNX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --link-name) LINKNAME="$2"; shift 2 ;;
    --sdk) SDK="$2"; shift 2 ;;
    --resource-dir) RES="$2"; shift 2 ;;
    --availability) AVAIL="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --I) INCS="$INCS -I $2"; shift 2 ;;
    --link) LINKS="$LINKS -Xlinker $2"; shift 2 ;;
    --unexported) UNX="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "build-module.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$NAME" ] && [ -n "$LINKNAME" ] && [ -n "$SDK" ] && [ -n "$RES" ] && [ -n "$AVAIL" ] && [ -n "$WORK" ] && [ -n "$OUT" ] || usage
[ $# -gt 0 ] || { echo "build-module.sh: no sources for $NAME" >&2; usage; }
[ -n "${SWIFTC:-}" ] && [ -x "$SWIFTC" ] || { echo "build-module.sh: SWIFTC names no Swift driver ('${SWIFTC:-}')" >&2; exit 1; }
[ -n "${LLD:-}" ] && [ -x "$LLD" ] || { echo "build-module.sh: LLD names no ld64.lld ('${LLD:-}')" >&2; exit 1; }
for f in "$@"; do [ -f "$f" ] || { echo "build-module.sh: $NAME has no source $f" >&2; exit 1; }; done
[ -f "$AVAIL" ] || { echo "build-module.sh: no availability list $AVAIL" >&2; exit 1; }
[ -d "$SDK/usr/include" ] || { echo "build-module.sh: no SDK at $SDK" >&2; exit 1; }
# spec: "no Apple .swiftinterface on any search path" -- the 10.9 SDK has no usr/lib/swift; a newer one does.
[ ! -d "$SDK/usr/lib/swift" ] || { echo "build-module.sh: $SDK has usr/lib/swift, Apple's Swift modules" >&2; exit 1; }
[ -d "$RES/macosx" ] || { echo "build-module.sh: $RES has no macosx/ (the stdlib's Swift module)" >&2; exit 1; }
for v in "$UNX" ${LINKS}; do
  case "$v" in ""|-Xlinker) ;; *) [ -f "$v" ] || { echo "build-module.sh: no link input $v" >&2; exit 1; } ;; esac
done
. "$HERE/pins.env"
. "$HERE/lib.sh"   # -> $SWIFT_BUILD, prefix_map_flags
ROOT="${SWIFT_WORK:-$SWIFT_BUILD/work}"
PM="$(prefix_map_flags swift "$ROOT" | tr ';' ' ')" || exit 1

rm -rf "$WORK" "$OUT/$NAME.swiftmodule" "$OUT/$ARCH/lib$LINKNAME.dylib"
mkdir -p "$WORK/module-cache" "$WORK/tools" "$OUT/$NAME.swiftmodule" "$OUT/$ARCH"
# platform: a Mavergreen toolchain's legacy driver runs the `ld` of -tools-directory (else /usr/bin/ld, the
#           Command Line Tools', absent on OS X 10.9) and ignores -ld-path; lld takes its Mach-O
#           personality from its name, which exec keeps. The swift.org toolchain's swift-driver (CI's seed)
#           links through the clang of -tools-directory instead, handing it -ld-path: that clang is the
#           host compiler's own, beside SWIFTC, not xcrun's.
printf '#!/bin/sh\nexec "%s" "$@"\n' "$LLD" > "$WORK/tools/ld" && chmod 755 "$WORK/tools/ld"
[ ! -x "$(dirname "$SWIFTC")/clang" ] || ln -s "$(dirname "$SWIFTC")/clang" "$WORK/tools/clang"
# The stdlib's -define-availability list, as stdlib/cmake/modules/AddSwiftStdlib.cmake writes it into its
# availability-macros-*.rsp from the definitions the top CMakeLists.txt reads out of
# utils/availability-macros.def (blank and #-comment lines dropped): each definition, and for each
# SwiftStdlib x.y a StdlibDeploymentTarget x.y whose version, when it is macOS's (or anyAppleOS's, failing
# that) and not 9999 and newer than the deployment target, becomes "macOS <deployment target>" (CMake's
# regex wants a dotted version, so "macOS 9999" is never matched and stays). Read from the .def, not a
# build tree, so a patch to the .def moves the stdlib's list and this one together.
awk -v dt="$DEPLOYMENT" '
  function newer(a, b,   x, y, n, m, i) {   # CMake VERSION_GREATER for dotted versions
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if ((x[i] + 0) > (y[i] + 0)) return 1; if ((x[i] + 0) < (y[i] + 0)) return 0 }
    return 0 }
  function ver(def, os,   s) {
    if (match(def, os " [0-9]+(\\.[0-9]+)+")) { s = substr(def, RSTART, RLENGTH); sub(/^[^ ]+ /, "", s); return s }
    return "" }
  /^[ \t]*(#.*)?$/ { next }
  { printf "-Xfrontend -define-availability -Xfrontend \"%s\"\n", $0
    if ($0 !~ /SwiftStdlib /) next
    cur = $0; sub(/SwiftStdlib/, "StdlibDeploymentTarget", cur)
    v = ver($0, "macOS"); if (v == "") v = ver($0, "anyAppleOS")
    if (v != "" && v != "9999" && newer(v, dt)) sub(/:.*/, ":macOS " dt, cur)
    printf "-Xfrontend -define-availability -Xfrontend \"%s\"\n", cur }
' "$AVAIL" > "$WORK/availability-macros.rsp"
[ -s "$WORK/availability-macros.rsp" ] || { echo "build-module.sh: $AVAIL defines no availability macro" >&2; exit 1; }

# The driver's link step names the .swiftmodule by its absolute path (-add_ast_path, an N_AST stab, a
# build-root path in the dylib): -S drops debug stabs, so the dylib carries none, as libswiftCore (linked
# apart from its module) does not. No .swiftsourceinfo, which the stdlib's modules do not ship either.
UNXFLAGS=""; [ -z "$UNX" ] || UNXFLAGS="-Xlinker -unexported_symbols_list -Xlinker $UNX"
# shellcheck disable=SC2086  # every word is space-free: the build root (lib.sh refuses whitespace), the
#                              SDK cache, the toolchain prefix
"$SWIFTC" -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT" -resource-dir "$RES" \
  -I "$OUT" $INCS -L "$OUT/$ARCH" -L "$RES/macosx/$ARCH" -L "$RES/macosx" \
  -module-cache-path "$WORK/module-cache" -tools-directory "$WORK/tools" -ld-path="$LLD" \
  -O -whole-module-optimization -parse-as-library -swift-version 5 \
  -enable-library-evolution -library-level api -runtime-compatibility-version none -no-stdlib-rpath \
  -Xfrontend -disable-implicit-concurrency-module-import -Xfrontend -disable-implicit-string-processing-module-import \
  -Xfrontend -target-min-inlining-version -Xfrontend min -Xfrontend -disable-objc-attr-requires-foundation-module \
  -Xfrontend -require-explicit-availability=ignore \
  -D SWIFT_ENABLE_REFLECTION -D SWIFT_STDLIB_HAS_ENVIRON -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
  $PM "@$WORK/availability-macros.rsp" \
  -emit-library -module-name "$NAME" -module-link-name "$LINKNAME" \
  -emit-module-path "$OUT/$NAME.swiftmodule/$ARCH-apple-macos.swiftmodule" -avoid-emit-module-source-info \
  -Xlinker -S -Xlinker -install_name -Xlinker "@rpath/lib$LINKNAME.dylib" -Xlinker -compatibility_version -Xlinker 1 \
  -Xlinker -headerpad_max_install_names $LINKS $UNXFLAGS \
  -o "$OUT/$ARCH/lib$LINKNAME.dylib" "$@"
