#!/bin/sh
# platform: macOS-only -- runs pkgutil
# lib.sh — the build root and the swift.org installer check, shared by every build script (sourced
# after pins.env, which supplies TOOLCHAIN_SIGNER). One copy, so no two scripts disagree about where
# the build lives or what a trusted installer is.

# platform: a family checkout may live on NFS, where a build cost 11.16s wall / 25% CPU against
#           2.96s / 88% on local disk with identical user time -- the whole difference is I/O wait.
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
# work/ (sources and build trees), out/llvm (LLVM build support), cache/ (the swift.org pkg),
# payload/<pkg> (each pkg's install root -- pkgbuild ships everything in it, so no build tree may live
# there), build/updater, dist/ (release assets).
SWIFT_BUILD="$MAVERICKS_BUILD_ROOT/swift"

# verify_toolchain_signature <pkg> -- fail closed unless the installer is signed by the pinned
# identity. Replaces a per-version SHA256 pin: the identity holds across releases, so a Swift bump
# needs no human to paste a hash. Records the observed digest for provenance.
verify_toolchain_signature() {
  _pkg="$1"
  pkgutil --check-signature "$_pkg" > "$_pkg.sigcheck" 2>&1 || {
    echo "FAIL: $_pkg is not a validly signed installer" >&2; cat "$_pkg.sigcheck" >&2; return 1; }
  grep -Fq "$TOOLCHAIN_SIGNER" "$_pkg.sigcheck" || {
    echo "FAIL: signed, but not by the pinned identity" >&2
    echo "  expected: $TOOLCHAIN_SIGNER" >&2
    sed -n "s/^ *1\\. */  found:    /p" "$_pkg.sigcheck" >&2
    return 1; }
  echo "OK: signed by $TOOLCHAIN_SIGNER"
  echo "    sha256 (recorded, not pinned): $(shasum -a 256 "$_pkg" | awk '{print $1}')"
  rm -f "$_pkg.sigcheck"
}

# expand_toolchain <pkg> <dir> -- <dir> holds exactly <pkg>'s payload. Expanded again when <dir> came
# from another installer (a Swift bump in a reused build root) or has lost any file: macOS's $TMPDIR
# cleaner deletes files under the build root, and a half-deleted toolchain fails far from the cause
# ("missing required module 'SwiftShims'").
expand_toolchain() {
  _rec="$2.expanded"
  if [ -f "$_rec" ] && [ "$(sed -n 1p "$_rec")" = "$(basename "$1")" ] \
     && sed 1d "$_rec" | ( cd "$2" 2>/dev/null || exit 1
          while IFS= read -r _f; do [ -e "$_f" ] || [ -L "$_f" ] || exit 1; done ); then
    return 0
  fi
  rm -rf "$2" "$2.x" "$_rec"
  pkgutil --expand "$1" "$2.x" || return 1
  _payload="$(find "$2.x" -name Payload | head -1)"
  [ -n "$_payload" ] || { echo "expand_toolchain: $1 has no payload" >&2; return 1; }
  mkdir -p "$2" && ditto -x -z "$_payload" "$2" || return 1
  # platform: a pkg built on a macOS 27 host lists AppleDouble ._* members for files carrying
  #           com.apple.provenance; ditto folds them into xattrs, so no such file exists to check for.
  { basename "$1"; lsbom -s "$(dirname "$_payload")/Bom" | grep -v '/\._'; } > "$_rec.tmp" || return 1
  rm -rf "$2.x"
  mv "$_rec.tmp" "$_rec"
}
