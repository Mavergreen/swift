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
set -eu

. "$(dirname "$0")/../msc.sh"   # -> $SHIPYARD (shipyard scripts dir)
SHARED="$SHIPYARD/assert_binary_compatible.sh"
[ -f "$SHARED" ] || { echo "guard: shipyard at $SHIPYARD has no assert_binary_compatible.sh" >&2; exit 4; }

# Full post-10.9 os_* family, tolerant of the one/two leading-underscore SPI naming.
export MAVERICKS_POST_10_9_SYMBOLS='__?os_signpost.*|__?os_log.*|_os_system_version_get_current_version|__?os_availability.*'
# Guarded-weak allowlist: OK only when weak. (os_unfair_lock intentionally absent.)
export MAVERICKS_ALLOW_GUARDED_WEAK='_objc_realizeClassFromSwift|_objc_setHook_.*|_objc_addLoadImageFunc|__?os_log.*|__?os_signpost.*|__availability_version_check|__dyld_is_objc_constant'

exec sh "$SHARED" "$@"
