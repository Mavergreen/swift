#!/bin/sh
# platform: macOS-only -- cc builds the arm64 Mach-O fixtures that dyld_info reads
# usage: sh tests/audit-imports-test.sh
#   scripts/audit-imports.py, build-toolchain.sh --host arm64's macOS 11 check, must pass a binary whose
#   every hard Swift import a fixture SDK's .tbd exports for the binary's own arch, allow a weak import
#   the .tbd lacks, and fail -- naming the symbol -- on a hard import the .tbd exports only for another
#   arch, on one it does not list at all, and on one from a Swift library the SDK has no .tbd for. It
#   must also fail a binary that links libswiftCore but reads zero hard imports from it (a misread, not
#   a clean binary).
#   SKIPs (77) without python3, dyld_info or an arm64-capable cc.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 -- skipping"; exit 77; }
xcrun -f dyld_info >/dev/null 2>&1 || { echo "no dyld_info -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/audit-imports.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lib" "$T/sdk/usr/lib/swift"
printf '%s\n' 'int mav_both(void) { return 1; }' 'int mav_x86only(void) { return 2; }' \
  'int mav_absent(void) { return 3; }' 'int mav_weak(void) { return 4; }' > "$T/core.c"
cc -arch arm64 -dynamiclib -install_name /usr/lib/swift/libswiftCore.dylib "$T/core.c" -o "$T/lib/libswiftCore.dylib" \
  || { echo "cc cannot build arm64 here -- skipping"; exit 77; }
printf 'int mav_foo(void) { return 5; }\n' > "$T/foo.c"
cc -arch arm64 -dynamiclib -install_name /usr/lib/swift/libswiftFoo.dylib "$T/foo.c" -o "$T/lib/libswiftFoo.dylib"
cat > "$T/sdk/usr/lib/swift/libswiftCore.tbd" <<'TBD'
--- !tapi-tbd
tbd-version:     4
targets:         [ x86_64-macos, arm64-macos ]
install-name:    '/usr/lib/swift/libswiftCore.dylib'
exports:
  - targets:         [ x86_64-macos ]
    symbols:         [ _mav_x86only ]
  - targets:         [ x86_64-macos, arm64-macos ]
    symbols:         [ '_mav_both',
                       _unrelated ]
...
TBD
# prog <name> <C calls...>: an arm64 program calling those, weak_import'ing mav_weak.
prog() {
  _n="$1"; shift
  { printf '%s\n' 'extern int mav_both(void), mav_x86only(void), mav_absent(void), mav_foo(void);' \
      'extern int mav_weak(void) __attribute__((weak_import));' 'int main(void) { int r = 0;'
    for _c in "$@"; do printf '  r += %s();\n' "$_c"; done
    printf '%s\n' '  if (mav_weak) r += mav_weak();' '  return r; }'; } > "$T/$_n.c"
  cc -arch arm64 "$T/$_n.c" "$T/lib/libswiftCore.dylib" "$T/lib/libswiftFoo.dylib" -o "$T/$_n"
}
A="$REPO/scripts/audit-imports.py"

echo "-- passes: every hard import exported for arm64, a weak one absent"
prog ok mav_both
python3 "$A" "$T/ok" "$T/sdk" > "$T/out" || fail "failed a clean binary: $(cat "$T/out")"
grep -qx 'libswiftCore: 1 imports, 0 not exported for arm64-macos by sdk' "$T/out" || fail "did not count the one import: $(cat "$T/out")"
grep -q '_mav_weak (libswiftCore)' "$T/out" || fail "did not list the weak import: $(cat "$T/out")"

echo "-- fails, naming it: a hard import the .tbd exports only for x86_64"
prog x86 mav_both mav_x86only
if python3 "$A" "$T/x86" "$T/sdk" > "$T/out"; then fail "passed an x86_64-only export: $(cat "$T/out")"; fi
grep -qx '   missing: _mav_x86only' "$T/out" || fail "did not name _mav_x86only: $(cat "$T/out")"

echo "-- fails, naming it: a hard import the .tbd does not list"
prog absent mav_absent
if python3 "$A" "$T/absent" "$T/sdk" > "$T/out"; then fail "passed an unlisted import: $(cat "$T/out")"; fi
grep -qx '   missing: _mav_absent' "$T/out" || fail "did not name _mav_absent: $(cat "$T/out")"

echo "-- fails: a hard import from a Swift library the SDK has no .tbd for"
prog foo mav_both mav_foo
if python3 "$A" "$T/foo" "$T/sdk" > "$T/out"; then fail "passed an import from libswiftFoo: $(cat "$T/out")"; fi
grep -q '^libswiftFoo: 1 imports, and .* has no .*/usr/lib/swift/libswiftFoo.tbd$' "$T/out" || fail "did not name libswiftFoo's missing .tbd: $(cat "$T/out")"

echo "-- fails: a binary that links libswiftCore but reads zero hard imports from it"
prog zero
if python3 "$A" "$T/zero" "$T/sdk" > "$T/out"; then fail "passed a binary with no hard libswiftCore imports: $(cat "$T/out")"; fi
grep -qx 'libswiftCore: 0 imports read -- nothing audited (a misread binary is not a clean one)' "$T/out" || fail "did not report the zero-imports misread: $(cat "$T/out")"
echo "PASS"
