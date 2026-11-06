#!/bin/sh
# platform: macOS-only -- reads Mach-O with the readers OTOOL, NM and DYLDINFO name (otool and nm when unset),
#           so it runs on a modern Mac and on OS X 10.9 alike
# usage: sh scripts/imports-on-10.9.sh <sdk109-root> <allowlist> <dylib>...
#   <sdk109-root> is lib.sh's sdk109_stubs (the 10.9 SDK exactly as its tarball holds it); <allowlist>
#   is scripts/resources/weak-absent-on-10.9.txt.
#   Exits 0 when every symbol each <dylib> imports from a library under /usr/lib or
#   /System/Library/Frameworks is exported by that library's stub in the 10.9 SDK (counting what the stub
#   re-exports, as libSystem re-exports /usr/lib/system/*), or, if the import is weak, is on the allowlist
#   for that dylib's basename. Otherwise exits 1 after listing each one as
#   `<dylib>: <symbol> (<library>, strong|weak)`. Imports from @rpath/* and from libcxx22 are not its
#   business (the first is the family's own, the second is require_libcxx22's).
#
# Why: a dylib links without complaint against the 11.3 SDK it was compiled with, then dies in dyld on a
# real 10.9 box for the first OS symbol it binds that 10.9 lacks. The stubs the SDK ships for 10.9 are the
# list of what 10.9 has. A weak import binds to NULL instead, and is safe only where the code reads it
# first; the allowlist names, for each such symbol, the guard that does (`<dylib> <symbol> -- <file>:<line>`,
# a line of the 6.4.1 source, so a reviewer can look). Lines starting # and blank lines are comments.
#
# A strong import is never excused by the allowlist: nothing guards it.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"    # -> macho_imports

[ $# -ge 3 ] || { echo "usage: $0 <sdk109-root> <allowlist> <dylib>..." >&2; exit 2; }
SDK="$1"; ALLOW="$2"; shift 2
[ -d "$SDK/usr/lib" ] || { echo "FAIL: $SDK has no usr/lib -- not a 10.9 SDK root" >&2; exit 1; }
[ -f "$ALLOW" ] || { echo "FAIL: no allowlist $ALLOW" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/imports-on-109.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir "$W/exp" "$W/seen"

# Every line is a comment, blank, or `<dylib> <symbol> -- <file>:<line>`: a guard nobody can find is no guard.
BAD="$(grep -Ev '^[[:space:]]*(#.*)?$|^[^[:space:]]+ [^[:space:]]+ -- [^[:space:]]+:[0-9]+$' "$ALLOW" || :)"
if [ -n "$BAD" ]; then
  printf '%s\n' "$BAD"; echo "FAIL: $ALLOW has the lines above, each needing ' -- <file>:<line>' for its guard" >&2; exit 1
fi

# collect <install-path> <outfile> -- appends the symbols the SDK's stub for <install-path> exports, and
# those of each library it re-exports, to <outfile>. A stub the SDK lacks adds nothing: every import from
# it then reads as absent. nm and otool take -arch because the stubs are fat (x86_64 and i386).
collect() {
  _c_key="$(printf '%s' "$1" | tr '/' '_')"
  [ ! -e "$W/seen/$_c_key" ] || return 0
  : > "$W/seen/$_c_key"
  [ -f "$SDK$1" ] || return 0
  # An alias prints as `I _memcpy (indirect for __platform_memmove)`: libsystem_c's memcpy is one.
  # (nm's output is captured first: in a pipe, only awk's status would be seen.)
  _c_nm="$("${NM:-nm}" -arch x86_64 -gU "$SDK$1")" || return 1
  printf '%s\n' "$_c_nm" | awk '$1 == "I" { print $2; next } { print $NF }' >> "$2" || return 1
  "${OTOOL:-otool}" -arch x86_64 -l "$SDK$1" > "$W/lc" || return 1
  awk '$1 == "cmd" { r = ($2 == "LC_REEXPORT_DYLIB") } r && $1 == "name" { print $2 }' "$W/lc" > "$W/re.$_c_key"
  while read -r _c_re; do collect "$_c_re" "$2" || return 1; done < "$W/re.$_c_key"
}

# exports_of <install-path> -- the file of that library's exported symbols, one per line.
exports_of() {
  _e_key="$(printf '%s' "$1" | tr '/' '_')"
  if [ ! -f "$W/exp/$_e_key" ]; then
    rm -rf "$W/seen"; mkdir "$W/seen"
    : > "$W/exp/$_e_key"
    collect "$1" "$W/exp/$_e_key" || { echo "FAIL: could not read $SDK$1's exports" >&2; rm -f "$W/exp/$_e_key"; return 1; }
  fi
  printf '%s\n' "$W/exp/$_e_key"
}

STATUS=0
for D in "$@"; do
  BASE="$(basename "$D")"
  [ -f "$D" ] || { echo "FAIL: no $D to check" >&2; exit 1; }
  IMPORTS="$(macho_imports "$D")" || { echo "FAIL: could not read $D's imports" >&2; exit 1; }
  [ -n "$IMPORTS" ] || { echo "FAIL: read no imports from $D" >&2; exit 1; }
  # `(from libobjc)` names a library by its short name (the file name up to its first dot); the install
  # names a dylib records say where that library lives.
  # Captured first, for the same reason: a failed otool must not read as "links nothing".
  LINKS="$("${OTOOL:-otool}" -L "$D")" || { echo "FAIL: could not list $D's libraries" >&2; exit 1; }
  printf '%s\n' "$LINKS" | sed 1d | sed 's/^[[:space:]]*//; s/ (compat.*//' | while read -r p; do
    s="${p##*/}"; printf '%s %s\n' "${s%%.*}" "$p"
  done > "$W/deps"
  [ -s "$W/deps" ] || { echo "FAIL: $D links no libraries, yet imports symbols" >&2; exit 1; }
  N=0; ALLOWED=0
  while read -r SYM REST; do
    LIB="${REST##*\(from }"; LIB="${LIB%\)}"
    LP="$(awk -v l="$LIB" '$1 == l { print $2; exit }' "$W/deps")"
    if [ -z "$LP" ]; then
      echo "$BASE: $SYM ($LIB, library not among the dylib's own)"; echo 1 >> "$W/failed"; continue
    fi
    case "$LP" in /usr/lib/*|/System/Library/Frameworks/*) ;; *) continue ;; esac
    N=$((N + 1))
    EXP="$(exports_of "$LP")" || exit 1
    [ -s "$EXP" ] || [ ! -f "$SDK$LP" ] || { echo "FAIL: read no exports from $SDK$LP" >&2; exit 1; }
    ! grep -Fxq -- "$SYM" "$EXP" || continue
    case "$REST" in
      '[weak-import] '*)
        if awk -v b="$BASE" -v s="$SYM" '$1 == b && $2 == s && $3 == "--" { f = 1 } END { exit !f }' "$ALLOW"; then ALLOWED=$((ALLOWED + 1)); continue; fi
        echo "$BASE: $SYM ($LIB, weak)" ;;
      *) echo "$BASE: $SYM ($LIB, strong)" ;;
    esac
    echo 1 >> "$W/failed"
  done <<EOT
$IMPORTS
EOT
  [ "$N" -gt 0 ] || { echo "FAIL: $D imports nothing from /usr/lib or /System/Library/Frameworks -- a misread, not a clean dylib" >&2; exit 1; }
  if [ -e "$W/failed" ]; then STATUS=1; else echo "imports-on-10.9: $BASE OK ($N OS imports: all in the 10.9 SDK, $ALLOWED weak and absent by allowlist)"; fi
  rm -f "$W/failed"
done
exit $STATUS
