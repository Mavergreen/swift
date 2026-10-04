#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 Mach-O fixtures that otool, nm and dyld_info read
# usage: sh tests/macho-preflight-test.sh
#   build.sh's step-7 preflight reads the runtime's minOS and imports through lib.sh's macho_minos and
#   macho_imports, and build-toolchain.sh's check reads the compiler's minOS, SDK and rpaths through
#   macho_version and macho_rpaths: dyld_info on a modern Mac, otool and nm on OS X 10.9, which has no
#   dyld_info. On fixture dylibs, the fallback must find the minOS (and SDK) in either load command, every
#   rpath in order, mark a weak import [weak-import] and a hard one not, fail when nm or otool cannot read
#   the file, and, where dyld_info exists, say exactly what dyld_info says.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/macho-preflight.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"
# No SDK header: its availability annotations would decide what is weak. atexit is weak by declaration.
printf '%s\n' 'extern int atexit(void (*)(void)) __attribute__((weak_import));' 'extern int puts(const char *);' \
  'static void bye(void) {}' 'int f(void) { if (atexit) atexit(bye); return puts("x"); }' > "$T/f.c"
cc -arch x86_64 -mmacosx-version-min=10.9 -dynamiclib "$T/f.c" -o "$T/f109.dylib" || fail "cannot build the 10.9 fixture"
cc -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib "$T/f.c" -o "$T/f11.dylib" || fail "cannot build the 11.0 fixture"
cc -arch x86_64 -mmacosx-version-min=10.9 -dynamiclib -Wl,-rpath,@loader_path/../lib/swift/macosx -Wl,-rpath,/usr/lib/swift \
  "$T/f.c" -o "$T/frp.dylib" || fail "cannot build the rpath fixture"

echo "-- the otool and nm fallback (DYLDINFO empty, as on OS X 10.9)"
[ "$(DYLDINFO='' macho_minos "$T/f109.dylib")" = 10.9 ] || fail "minOS from LC_VERSION_MIN_MACOSX is '$(DYLDINFO='' macho_minos "$T/f109.dylib")', not 10.9"
[ "$(DYLDINFO='' macho_minos "$T/f11.dylib")" = 11.0 ] || fail "minOS from LC_BUILD_VERSION is '$(DYLDINFO='' macho_minos "$T/f11.dylib")', not 11.0"
imp="$(DYLDINFO='' macho_imports "$T/f109.dylib")" || fail "macho_imports failed"
printf '%s\n' "$imp"
printf '%s\n' "$imp" | grep -qx '_atexit \[weak-import\] (from libSystem)' || fail "the weak atexit is not '_atexit [weak-import] (from libSystem)'"
printf '%s\n' "$imp" | grep -qx '_puts (from libSystem)' || fail "the hard puts is not '_puts (from libSystem)'"
: > "$T/empty"
if DYLDINFO='' macho_imports "$T/empty" > /dev/null 2>&1; then fail "macho_imports succeeded on a file nm cannot read"; fi
v="$(DYLDINFO='' macho_version "$T/f109.dylib")"
[ "${v%% *}" = 10.9 ] && [ -n "${v#* }" ] && [ "${v#* }" != "$v" ] || fail "minOS and SDK from LC_VERSION_MIN_MACOSX are '$v'"
v="$(DYLDINFO='' macho_version "$T/f11.dylib")"
[ "${v%% *}" = 11.0 ] && [ "${v#* }" != "$v" ] || fail "minOS and SDK from LC_BUILD_VERSION are '$v'"
[ "$(DYLDINFO='' macho_rpaths "$T/frp.dylib" | tr '\n' ' ')" = "@loader_path/../lib/swift/macosx /usr/lib/swift " ] \
  || fail "rpaths are '$(DYLDINFO='' macho_rpaths "$T/frp.dylib" | tr '\n' ' ')'"
[ -z "$(DYLDINFO='' macho_rpaths "$T/f109.dylib")" ] || fail "found an rpath in a dylib that has none"
if DYLDINFO='' macho_version "$T/nothere" > /dev/null 2>&1; then fail "macho_version succeeded on a file otool cannot read"; fi

DI="$(xcrun -f dyld_info 2>/dev/null || :)"
if [ -n "$DI" ]; then
  echo "-- the fallback says what dyld_info says ($DI)"
  for f in f109 f11; do
    [ "$(DYLDINFO="$DI" macho_minos "$T/$f.dylib")" = "$(DYLDINFO='' macho_minos "$T/$f.dylib")" ] || fail "$f: minOS differs from dyld_info's"
    [ "$(DYLDINFO="$DI" macho_version "$T/$f.dylib")" = "$(DYLDINFO='' macho_version "$T/$f.dylib")" ] \
      || fail "$f: minOS and SDK '$(DYLDINFO='' macho_version "$T/$f.dylib")' differ from dyld_info's '$(DYLDINFO="$DI" macho_version "$T/$f.dylib")'"
    DYLDINFO="$DI" macho_imports "$T/$f.dylib" | sort > "$T/$f.di"
    DYLDINFO='' macho_imports "$T/$f.dylib" | sort > "$T/$f.nm"
    cmp -s "$T/$f.di" "$T/$f.nm" || fail "$f: imports differ from dyld_info's: $(diff "$T/$f.di" "$T/$f.nm")"
  done
  [ "$(DYLDINFO="$DI" macho_rpaths "$T/frp.dylib")" = "$(DYLDINFO='' macho_rpaths "$T/frp.dylib")" ] \
    || fail "rpaths differ from dyld_info's: $(DYLDINFO="$DI" macho_rpaths "$T/frp.dylib" | tr '\n' ' ')"
else
  echo "-- no dyld_info here: the fallback is the only reader"
fi
echo "PASS"
