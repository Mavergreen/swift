#!/bin/sh
# platform: macOS-only -- delegates to assert_binary_compatible.sh, which reads Mach-O with the readers LIPO, OTOOL, NM and STRINGS name (lipo, otool, nm and strings when unset)
# Project wrapper around mavericks-shipyard's assert_binary_compatible.sh.
# Encodes mavericks-swift's 10.9 policy and delegates to the shared guard:
#   - EXTEND the denylist to the full post-10.9 os_* family (underscore-robust; the
#     shared default only covers os_unfair_lock + os_log single-underscore).
#   - ALLOW those families ONLY when imported *weak* (the Swift runtime NULL-checks
#     them via SWIFT_RUNTIME_WEAK_CHECK). os_unfair_lock is deliberately NOT allowed:
#     the runtime calls it UNGUARDED, so it must be built out (pthreads/patch).
# Usage: scripts/guard.sh <dylib> [<dylib> ...]
#        scripts/guard.sh --linked-with <linker> <archive> [<archive> ...]
#   The second form guards an archive whose members call each other (Recaulk's librecaulk.a: an mp member
#   calls Recaulk's own clock_gettime). The shared guard reads an archive's undefined symbols member by
#   member and would refuse those calls, which a link resolves in the archive. So each archive is linked
#   whole with <linker> (ld64.lld or ld64: -all_load, every symbol from outside looked up at load time)
#   into an x86_64 dylib recording minOS and SDK 10.9, and that dylib is guarded: what it still imports is
#   what the archive needs from the OS. The members' own minOS and SDK are not read this way.
set -eu

. "$(dirname "$0")/../msc.sh"   # -> $SHIPYARD (shipyard scripts dir)
SHARED="$SHIPYARD/assert_binary_compatible.sh"
[ -f "$SHARED" ] || { echo "guard: shipyard at $SHIPYARD has no assert_binary_compatible.sh" >&2; exit 4; }

# Full post-10.9 os_* family, tolerant of the one/two leading-underscore SPI naming.
export MAVERICKS_POST_10_9_SYMBOLS='__?os_signpost.*|__?os_log.*|_os_system_version_get_current_version|__?os_availability.*'
# Guarded-weak allowlist: OK only when weak. (os_unfair_lock intentionally absent.)
export MAVERICKS_ALLOW_GUARDED_WEAK='_objc_realizeClassFromSwift|_objc_setHook_.*|_objc_addLoadImageFunc|__?os_log.*|__?os_signpost.*|__availability_version_check|__dyld_is_objc_constant'

if [ "${1:-}" = --linked-with ]; then
  [ $# -ge 3 ] || { echo "usage: $0 --linked-with <linker> <archive> [<archive> ...]" >&2; exit 2; }
  LINKER="$2"; shift 2
  W="$(mktemp -d "${TMPDIR:-/tmp}/guard-linked.XXXXXX")"
  trap 'rm -rf "$W"' EXIT
  rc=0
  for a do
    [ -f "$a" ] || { echo "compat guard: no archive $a" >&2; exit 4; }
    "$LINKER" -dylib -arch x86_64 -platform_version macos 10.9 10.9 -all_load "$a" -undefined dynamic_lookup \
      -o "$W/whole.dylib" > "$W/link.out" 2>&1 \
      || { cat "$W/link.out" >&2; echo "compat guard CANNOT MEASURE (fail-closed): $LINKER could not link $a whole" >&2; exit 4; }
    echo "compat guard: $a, linked whole:"
    sh "$SHARED" "$W/whole.dylib" || { rc=$?; echo "compat guard: $a fails (above, as the dylib it links whole into)" >&2; }
  done
  exit "$rc"
fi
exec sh "$SHARED" "$@"
