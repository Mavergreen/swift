#!/bin/sh
# platform: host-agnostic -- gpg, tar and a sha256 tool; no pkgutil, no Xcode, so it runs on Linux and macOS
# fetch-linux-seed.sh — fetch swift.org's Ubuntu 24.04 toolchain, the seed that builds the Linux-hosted
# compiler's Swift half, and verify it fail closed. It ships in nothing.
#   usage: sh fetch-linux-seed.sh <dest>      prints <dest>'s extracted toolchain `usr` directory
#          . ./fetch-linux-seed.sh; fetch_linux_seed <dest>
# The tarball is cached under $SWIFT_BUILD/cache and extracted afresh into <dest> on every call.
# Also sourced by scripts/pin-source-tarballs.sh, whose Swift-bump job computes LINUX_SEED_SHA256 only for
# a tarball linux_seed_verify_signature accepts. Sourcing sets no shell options and every function returns
# a status, so a caller may use them under `if` or `||`.
# Two checks, in this order, and a failure of either removes the download:
#   1. the SHA-256 is LINUX_SEED_SHA256 (pins.env), the exact bytes someone has looked at;
#   2. its detached signature is valid AND made by the pinned key: gpg's VALIDSIG line must carry
#      LINUX_SEED_KEY_FPR as the PRIMARY key's fingerprint, and a GOODSIG must accompany it. A good
#      signature by any other key in all-keys.asc is a FAIL, and so is any REVKEYSIG, EXPKEYSIG, EXPSIG,
#      BADSIG or ERRSIG: a revoked or expired key, or an expired signature, is not trusted.
#      The fingerprint is the trust anchor, so the keyring (which swift.org rotates) is fetched fresh into a private GNUPGHOME and never pinned.
# Sourced, $0 is the caller's, so a sourcing script sets HERE to this repo's root first.
_fls_here="${HERE:-$(cd "$(dirname "$0")" && pwd)}"
. "$_fls_here/pins.env"
. "$_fls_here/lib.sh"   # -> $SWIFT_BUILD
# A caller that already has shipyard_curl (tests stub it) skips shipyard.
if ! command -v shipyard_curl >/dev/null 2>&1; then
  . "$_fls_here/msc.sh"   # -> $SHIPYARD
  . "$SHIPYARD/mavericks_fetch.sh"
fi

# ONLY tests set these: they have no network and sign with throwaway keys. A build never does, so a real
# fetch always uses the pins.env values. Setting any of them is announced loudly.
LINUX_SEED_URL="${TEST_ONLY_LINUX_SEED_URL:-$LINUX_SEED_URL}"
LINUX_SEED_SIG_URL="${TEST_ONLY_LINUX_SEED_SIG_URL:-$LINUX_SEED_SIG_URL}"
LINUX_SEED_SHA256="${TEST_ONLY_LINUX_SEED_SHA256:-$LINUX_SEED_SHA256}"
LINUX_SEED_KEYRING_URL="${TEST_ONLY_LINUX_SEED_KEYRING_URL:-$LINUX_SEED_KEYRING_URL}"
LINUX_SEED_KEY_FPR="${TEST_ONLY_LINUX_SEED_KEY_FPR:-$LINUX_SEED_KEY_FPR}"
if [ -n "${TEST_ONLY_LINUX_SEED_URL:-}${TEST_ONLY_LINUX_SEED_SIG_URL:-}${TEST_ONLY_LINUX_SEED_SHA256:-}${TEST_ONLY_LINUX_SEED_KEYRING_URL:-}${TEST_ONLY_LINUX_SEED_KEY_FPR:-}" ]; then
  echo "WARNING: TEST_ONLY_LINUX_SEED_* overrides are set: the seed is NOT being verified against swift.org's pins" >&2
fi

# linux_seed_sha256 <file> -- prints its SHA-256
linux_seed_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# linux_seed_download <url> <dest> -- through a .part, so an interrupted download is never a cached tarball
linux_seed_download() {
  shipyard_curl --progress-bar "$1" "$2.part" >&2 && mv "$2.part" "$2" || { rm -f "$2.part"; return 1; }
}

# linux_seed_verify_signature <tarball> -- 0 only when the signature is GOODSIG, made by the pinned primary
# key (VALIDSIG), with no revoked or expired key or signature among the statuses. Else FAIL ...signature, 1.
linux_seed_verify_signature() (
  tarball="$1"; gh=""
  trap '[ -z "$gh" ] || { GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || :; rm -rf "$gh"; }' EXIT
  gh="$(mktemp -d "${TMPDIR:-/tmp}/linux-seed-gnupg.XXXXXX")" && chmod 700 "$gh"     || { echo "FAIL: no private GNUPGHOME for the signature check" >&2; exit 1; }
  shipyard_curl "$LINUX_SEED_SIG_URL" "$gh/seed.sig" >&2     || { echo "FAIL: could not fetch the signature $LINUX_SEED_SIG_URL" >&2; exit 1; }
  shipyard_curl "$LINUX_SEED_KEYRING_URL" "$gh/keys.asc" >&2     || { echo "FAIL: could not fetch the keyring $LINUX_SEED_KEYRING_URL" >&2; exit 1; }
  # platform: swift.org serves all-keys.asc gzip-encoded (Content-Encoding: gzip) even to a client that sent
  #           no Accept-Encoding, and shipyard_curl does not pass --compressed, so the file lands gzipped.
  if [ "$(head -c 2 "$gh/keys.asc" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
    gzip -dc "$gh/keys.asc" > "$gh/keys.asc.d" && mv "$gh/keys.asc.d" "$gh/keys.asc" \
      || { echo "FAIL: the keyring is not valid gzip" >&2; exit 1; }
  fi
  GNUPGHOME="$gh" gpg --batch --quiet --import "$gh/keys.asc" >/dev/null 2>&1 || :
  status="$(GNUPGHOME="$gh" gpg --batch --no-tty --status-fd 1 --verify "$gh/seed.sig" "$tarball" 2>/dev/null || :)"
  # VALIDSIG <signing-subkey-fpr> ... <primary-key-fpr>: the primary is the last field
  signer="$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print toupper($NF) }')"
  good="$(printf '%s\n' "$status" | awk '$2 == "GOODSIG" { n++ } END { print n + 0 }')"
  bad="$(printf '%s\n' "$status" | awk '$2 ~ /^(REVKEYSIG|EXPKEYSIG|EXPSIG|BADSIG|ERRSIG)$/ { print $2 }' | head -n 1)"
  if [ "$signer" != "$LINUX_SEED_KEY_FPR" ] || [ "$good" -lt 1 ] || [ -n "$bad" ]; then
    echo "FAIL: $tarball has no good signature by the pinned key $LINUX_SEED_KEY_FPR (VALIDSIG primary: ${signer:-none}, GOODSIG lines: $good, ${bad:-no} bad status)" >&2
    exit 1
  fi
)

# fetch_linux_seed <dest> -- prints <dest>'s extracted toolchain usr; any failure leaves no <dest>
fetch_linux_seed() (
  dest="${1:?usage: fetch_linux_seed <dest>}"
  cache="$SWIFT_BUILD/cache"; mkdir -p "$cache" || exit 1
  tarball="$cache/${LINUX_SEED_URL##*/}"
  if [ ! -f "$tarball" ]; then
    echo "==> downloading $LINUX_SEED_URL (~1.1 GB)" >&2
    linux_seed_download "$LINUX_SEED_URL" "$tarball" || { echo "FAIL: could not fetch $LINUX_SEED_URL" >&2; exit 1; }
  fi
  got="$(linux_seed_sha256 "$tarball")" || exit 1
  if [ "$got" != "$LINUX_SEED_SHA256" ]; then
    echo "FAIL: $tarball has sha256 $got, not the pinned $LINUX_SEED_SHA256" >&2
    rm -f "$tarball"; exit 1
  fi
  linux_seed_verify_signature "$tarball" || { rm -f "$tarball"; exit 1; }
  rm -rf "$dest"; mkdir -p "$dest" || exit 1
  tar -xzf "$tarball" -C "$dest" || { echo "FAIL: could not extract $tarball" >&2; rm -rf "$dest"; exit 1; }
  usr="$(find "$dest" -maxdepth 2 -type d -name usr | head -n 1)"
  [ -n "$usr" ] || { echo "FAIL: no usr/ in $tarball" >&2; rm -rf "$dest"; exit 1; }
  echo "OK: swift.org Linux seed (sha256 and signature verified) at $usr" >&2
  echo "$usr"
)

case "${0##*/}" in
  fetch-linux-seed.sh) set -eu; fetch_linux_seed "$@" ;;
esac
