#!/bin/sh
# platform: host-agnostic
# usage: sh tests/fetch-linux-seed-test.sh
#   fetch_linux_seed must fail closed: a tarball whose SHA-256 is not the pin is FAIL ...sha256 and is
#   removed; one whose hash is right but whose signature is not by the pinned key (even a good signature
#   by another key in the keyring) is FAIL ...signature; a good pair prints the extracted toolchain's usr.
#   Runs with no network, against throwaway keys and a stubbed shipyard_curl that copies from a directory.
#   SKIPs (77) without gpg.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "no gpg -- skipping"; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-linux-seed-test.XXXXXX")"
# platform: gpg-agent listens on a unix socket under GNUPGHOME, and a macOS $TMPDIR is too long for one
#           (sun_path is 104 bytes), so the throwaway keys live under a short /tmp path.
G="$(mktemp -d /tmp/fls.XXXXXX)"
cleanup() { for h in "$G"/*; do [ -d "$h" ] && GNUPGHOME="$h" gpgconf --kill gpg-agent >/dev/null 2>&1 || :; done; rm -rf "$T" "$G"; }
trap cleanup EXIT INT TERM
SRV="$T/srv"; mkdir -p "$SRV" "$T/tar/swift-x/usr/bin"
printf '#!/bin/sh\n' > "$T/tar/swift-x/usr/bin/swiftc"; chmod +x "$T/tar/swift-x/usr/bin/swiftc"
tar -czf "$SRV/seed.tar.gz" -C "$T/tar" swift-x

# two throwaway keys: "good" is the pinned one, "other" is a second key that is in the keyring too
mkkey() { # <name> -> prints the primary fingerprint, exports the public key to $SRV/<name>.asc
  mkdir -m 700 "$G/gh-$1"
  GNUPGHOME="$G/gh-$1" gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@example.invalid>" rsa2048 sign 1d >/dev/null 2>&1
  GNUPGHOME="$G/gh-$1" gpg --batch --armor --export > "$SRV/$1.asc" 2>/dev/null
  GNUPGHOME="$G/gh-$1" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}
GOOD_FPR="$(mkkey good)"; mkkey other >/dev/null
cat "$SRV/good.asc" "$SRV/other.asc" > "$SRV/keys.asc"
sign() { GNUPGHOME="$G/gh-$1" gpg --batch --yes --detach-sign --output "$SRV/$2" "$SRV/seed.tar.gz" >/dev/null 2>&1; }
HASH="$( (sha256sum "$SRV/seed.tar.gz" 2>/dev/null || shasum -a 256 "$SRV/seed.tar.gz") | awk '{print $1}')"

# the stub honours shipyard_curl's (url, dest) form with a path as the url; extra flags are skipped
shipyard_curl() { while [ $# -gt 2 ]; do shift; done; cp "$1" "$2"; }

KEYRING="$SRV/keys.asc"
run() { # <sigfile> <sha256> -> sets OUT and RC
  MAVERICKS_BUILD_ROOT="$T/build"; export MAVERICKS_BUILD_ROOT; rm -rf "$T/dest" "$T/build"
  set +e
  OUT="$( HERE="$REPO" TEST_ONLY_LINUX_SEED_URL="$SRV/seed.tar.gz" TEST_ONLY_LINUX_SEED_SIG_URL="$SRV/$1" TEST_ONLY_LINUX_SEED_SHA256="$2" \
          TEST_ONLY_LINUX_SEED_KEYRING_URL="$KEYRING" TEST_ONLY_LINUX_SEED_KEY_FPR="$GOOD_FPR" \
          . "$REPO/fetch-linux-seed.sh" && fetch_linux_seed "$T/dest" 2>&1 )"; RC=$?
  set -e
}

echo "-- a signature by another key in the keyring is a FAIL, though it is a good signature"
sign other bad.sig
run bad.sig "$HASH"
[ "$RC" -ne 0 ] || fail "a signature by an unpinned key was accepted"
case "$OUT" in *"FAIL:"*signature*) ;; *) fail "no 'FAIL: ...signature' in: $OUT" ;; esac
[ ! -e "$T/dest" ] || fail "an unverified seed was extracted"

echo "-- a hash that is not the pin is a FAIL, and the download is removed"
sign good good.sig
run good.sig "0000000000000000000000000000000000000000000000000000000000000000"
[ "$RC" -ne 0 ] || fail "a wrong hash was accepted"
case "$OUT" in *"FAIL:"*sha256*) ;; *) fail "no 'FAIL: ...sha256' in: $OUT" ;; esac
[ -z "$(find "$T/build" -name '*.tar.gz' 2>/dev/null)" ] || fail "the bad download was kept"

echo "-- a good pair prints the extracted usr"
run good.sig "$HASH"
[ "$RC" -eq 0 ] || fail "a good pair failed: $OUT"
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "$T/dest/swift-x/usr" ] || fail "last line is not the usr path: $OUT"
[ -x "$T/dest/swift-x/usr/bin/swiftc" ] || fail "swiftc was not extracted"
echo "-- a keyring served gzip-encoded, as swift.org's is to a client that did not ask, still verifies"
gzip -c "$SRV/keys.asc" > "$SRV/keys.asc.gz"; KEYRING="$SRV/keys.asc.gz"
run good.sig "$HASH"
[ "$RC" -eq 0 ] || fail "a gzip-encoded keyring was not read: $OUT"
echo "PASS"
