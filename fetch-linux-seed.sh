#!/bin/sh
# platform: host-agnostic -- gpg, tar and a sha256 tool; no pkgutil, no Xcode, so it runs on Linux and macOS
# fetch-linux-seed.sh — fetch swift.org's Ubuntu 24.04 toolchain, the seed that builds the Linux-hosted
# compiler's Swift half, and verify it fail closed. It ships in nothing.
#   usage: sh fetch-linux-seed.sh <dest>      prints <dest>'s extracted toolchain `usr` directory
#          . ./fetch-linux-seed.sh; fetch_linux_seed <dest>
# The tarball is cached under $SWIFT_BUILD/cache and extracted afresh into <dest> on every call.
# Two checks, in this order, and a failure of either removes the download:
#   1. the SHA-256 is LINUX_SEED_SHA256 (pins.env), the exact bytes someone has looked at;
#   2. its detached signature is valid AND made by the pinned key: gpg's VALIDSIG line must carry
#      LINUX_SEED_KEY_FPR as the PRIMARY key's fingerprint. A good signature by any other key in
#      all-keys.asc is a FAIL. The fingerprint is the trust anchor, so the keyring (which swift.org
#      rotates) is fetched fresh into a private GNUPGHOME and never pinned.
set -eu

# Sourced, $0 is the caller's, so a sourcing script sets HERE to this repo's root first.
_fls_here="${HERE:-$(cd "$(dirname "$0")" && pwd)}"
. "$_fls_here/pins.env"
. "$_fls_here/lib.sh"   # -> $SWIFT_BUILD
# A caller that already has shipyard_curl (tests/fetch-linux-seed-test.sh stubs it) skips shipyard.
if ! command -v shipyard_curl >/dev/null 2>&1; then
  . "$_fls_here/msc.sh"   # -> $SHIPYARD
  . "$SHIPYARD/mavericks_fetch.sh"
fi

# ONLY tests/fetch-linux-seed-test.sh sets these: it has no network and signs with throwaway keys.
# A build never does, so a real fetch always uses the pins.env values.
LINUX_SEED_URL="${TEST_ONLY_LINUX_SEED_URL:-$LINUX_SEED_URL}"
LINUX_SEED_SIG_URL="${TEST_ONLY_LINUX_SEED_SIG_URL:-$LINUX_SEED_SIG_URL}"
LINUX_SEED_SHA256="${TEST_ONLY_LINUX_SEED_SHA256:-$LINUX_SEED_SHA256}"
LINUX_SEED_KEYRING_URL="${TEST_ONLY_LINUX_SEED_KEYRING_URL:-$LINUX_SEED_KEYRING_URL}"
LINUX_SEED_KEY_FPR="${TEST_ONLY_LINUX_SEED_KEY_FPR:-$LINUX_SEED_KEY_FPR}"

_fls_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

fetch_linux_seed() (
  dest="${1:?usage: fetch_linux_seed <dest>}"
  cache="$SWIFT_BUILD/cache"; mkdir -p "$cache"
  tarball="$cache/${LINUX_SEED_URL##*/}"
  gh=""
  trap '[ -z "$gh" ] || rm -rf "$gh"' EXIT

  if [ ! -f "$tarball" ]; then
    echo "==> downloading $LINUX_SEED_URL (~1.1 GB)" >&2
    shipyard_curl --progress-bar "$LINUX_SEED_URL" "$tarball" >&2
  fi

  got="$(_fls_sha256 "$tarball")"
  if [ "$got" != "$LINUX_SEED_SHA256" ]; then
    echo "FAIL: $tarball has sha256 $got, not the pinned $LINUX_SEED_SHA256" >&2
    rm -f "$tarball"; exit 1
  fi

  gh="$(mktemp -d "${TMPDIR:-/tmp}/linux-seed-gnupg.XXXXXX")"; chmod 700 "$gh"
  shipyard_curl "$LINUX_SEED_SIG_URL" "$gh/seed.sig" >&2
  shipyard_curl "$LINUX_SEED_KEYRING_URL" "$gh/keys.asc" >&2
  # platform: swift.org serves all-keys.asc gzip-encoded (Content-Encoding: gzip) even to a client that sent
  #           no Accept-Encoding, and shipyard_curl does not pass --compressed, so the file lands gzipped.
  if [ "$(head -c 2 "$gh/keys.asc" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
    gzip -dc "$gh/keys.asc" > "$gh/keys.asc.d" && mv "$gh/keys.asc.d" "$gh/keys.asc"
  fi
  GNUPGHOME="$gh" gpg --batch --quiet --import "$gh/keys.asc" >/dev/null 2>&1 || :
  status="$(GNUPGHOME="$gh" gpg --batch --no-tty --status-fd 1 --verify "$gh/seed.sig" "$tarball" 2>/dev/null || :)"
  # VALIDSIG <signing-subkey-fpr> ... <primary-key-fpr>: the primary is the last field
  signer="$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print toupper($NF) }')"
  if [ "$signer" != "$LINUX_SEED_KEY_FPR" ]; then
    echo "FAIL: $tarball has no valid signature by the pinned key $LINUX_SEED_KEY_FPR (VALIDSIG primary: ${signer:-none})" >&2
    rm -f "$tarball"; exit 1
  fi

  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tarball" -C "$dest"
  usr="$(find "$dest" -maxdepth 2 -type d -name usr | head -n 1)"
  [ -n "$usr" ] || { echo "FAIL: no usr/ in $tarball" >&2; exit 1; }
  echo "OK: swift.org Linux seed (sha256 and signature verified) at $usr" >&2
  echo "$usr"
)

case "${0##*/}" in
  fetch-linux-seed.sh) fetch_linux_seed "$@" ;;
esac
