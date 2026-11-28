#!/bin/sh
# platform: host-agnostic
# usage: sh tests/fetch-linux-seed-test.sh
#   fetch_linux_seed must fail closed: a tarball whose SHA-256 is not the pin is FAIL ...sha256 and is
#   removed; one whose hash is right but whose signature is not good and by the pinned key is FAIL
#   ...signature -- another key's good signature, the pinned key's signature over other bytes, an expired
#   key, a missing or garbage .sig; a good pair prints the extracted toolchain's usr. Sourcing it sets no
#   shell option, and a failure leaves no <dest>. Offline, against throwaway keys (tests/lib/fake-linux-seed.sh).
#   SKIPs (77) without gpg.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "no gpg -- skipping"; exit 77; }
. "$REPO/tests/lib/fake-linux-seed.sh"
T0="$(mktemp -d "${TMPDIR:-/tmp}/fetch-linux-seed-test.XXXXXX")"
trap fake_seed_cleanup EXIT INT TERM
fake_seed_setup "$T0"; FST="$T0"
[ -n "$GOOD_FPR" ] || fail "no throwaway key"

KEYRING="$SRV/keys.asc"
run() { # <sigfile-path> <sha256> -> sets OUT and RC
  MAVERICKS_BUILD_ROOT="$FST/build"; export MAVERICKS_BUILD_ROOT; rm -rf "$FST/dest" "$FST/build"
  if [ "${run_pre:-}" = 1 ]; then mkdir -p "$FST/dest/stale"; echo old > "$FST/dest/stale/f"; fi
  set +e
  OUT="$( HERE="$REPO"; TEST_ONLY_LINUX_SEED_URL="$SRV/seed.tar.gz"; TEST_ONLY_LINUX_SEED_SIG_URL="$1"; TEST_ONLY_LINUX_SEED_SHA256="$2"
          TEST_ONLY_LINUX_SEED_KEYRING_URL="$KEYRING"; TEST_ONLY_LINUX_SEED_KEY_FPR="$GOOD_FPR"
          { . "$REPO/fetch-linux-seed.sh" && fetch_linux_seed "$FST/dest"; } 2>&1 )"; RC=$?
  set -e
}
expect_sigfail() { # <label> <sigfile>
  run "$2" "$HASH"
  [ "$RC" -ne 0 ] || fail "$1: accepted"
  case "$OUT" in *"FAIL:"*) ;; *) fail "$1: no FAIL line in: $OUT" ;; esac
  [ ! -e "$FST/dest" ] || fail "$1: an unverified seed was extracted"
  [ -z "$(find "$FST/build" -name '*.tar.gz' 2>/dev/null)" ] || fail "$1: the rejected download was kept"
}

echo "-- a good signature by another key in the keyring is a FAIL ...signature"
run "$SRV/other.sig" "$HASH"
[ "$RC" -ne 0 ] || fail "a signature by an unpinned key was accepted"
case "$OUT" in *"FAIL:"*signature*) ;; *) fail "no 'FAIL: ...signature' in: $OUT" ;; esac
[ ! -e "$FST/dest" ] || fail "an unverified seed was extracted"

echo "-- the pinned key's signature over other bytes is a FAIL (BADSIG)"
expect_sigfail "a bad signature by the pinned key" "$SRV/wrongfile.sig"

echo "-- an expired key is a FAIL, though it is the pinned one"
saved="$GOOD_FPR"; GOOD_FPR="$(GNUPGHOME="$G/gh-expired" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
expect_sigfail "an expired pinned key" "$SRV/expired.sig"
case "$OUT" in *EXPKEYSIG*) ;; *) fail "the expired key was not named EXPKEYSIG: $OUT" ;; esac
GOOD_FPR="$saved"

echo "-- a garbage or missing .sig is a FAIL"
expect_sigfail "a garbage .sig" "$SRV/garbage.sig"
expect_sigfail "a missing .sig" "$SRV/no-such.sig"
case "$OUT" in *"could not fetch the signature"*) ;; *) fail "a missing .sig named no fetch failure: $OUT" ;; esac

echo "-- a keyring that cannot be fetched is a FAIL"
KEYRING="$SRV/no-such.asc"; expect_sigfail "a missing keyring" "$SRV/good.sig"
case "$OUT" in *"could not fetch the keyring"*) ;; *) fail "a missing keyring named no fetch failure: $OUT" ;; esac
KEYRING="$SRV/keys.asc"

echo "-- a hash that is not the pin is a FAIL ...sha256, and the download is removed"
# a tree left by an earlier fetch must not survive a failed verification
run_pre=1
run "$SRV/good.sig" "0000000000000000000000000000000000000000000000000000000000000000"
[ "$RC" -ne 0 ] || fail "a wrong hash was accepted"
case "$OUT" in *"FAIL:"*sha256*) ;; *) fail "no 'FAIL: ...sha256' in: $OUT" ;; esac
[ -z "$(find "$FST/build" -name '*.tar.gz*' 2>/dev/null)" ] || fail "the bad download was kept"
[ ! -e "$FST/dest" ] || fail "a failed verification left the earlier $FST/dest"
run_pre=""

echo "-- a good pair prints the extracted usr; the test-only overrides are announced"
run "$SRV/good.sig" "$HASH"
[ "$RC" -eq 0 ] || fail "a good pair failed: $OUT"
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "$FST/dest/swift-x/usr" ] || fail "last line is not the usr path: $OUT"
[ -x "$FST/dest/swift-x/usr/bin/swiftc" ] || fail "swiftc was not extracted"
case "$OUT" in *"WARNING: TEST_ONLY_LINUX_SEED_"*) ;; *) fail "no warning that the test-only overrides are set: $OUT" ;; esac

echo "-- a keyring served gzip-encoded, as swift.org's is, still verifies"
gzip -c "$SRV/keys.asc" > "$SRV/keys.asc.gz"; KEYRING="$SRV/keys.asc.gz"
run "$SRV/good.sig" "$HASH"
[ "$RC" -eq 0 ] || fail "a gzip-encoded keyring was not read: $OUT"
KEYRING="$SRV/keys.asc"

echo "-- sourcing sets no shell option, and the functions are safe under if and ||"
( set +eu; HERE="$REPO" . "$REPO/fetch-linux-seed.sh"; case "$-" in *e*|*u*) exit 1 ;; esac ) || fail "sourcing fetch-linux-seed.sh set -e or -u"
( set +e; MAVERICKS_BUILD_ROOT="$FST/build2"; export MAVERICKS_BUILD_ROOT
  HERE="$REPO" TEST_ONLY_LINUX_SEED_URL="$SRV/seed.tar.gz" TEST_ONLY_LINUX_SEED_SIG_URL="$SRV/garbage.sig" TEST_ONLY_LINUX_SEED_SHA256="$HASH" \
  TEST_ONLY_LINUX_SEED_KEYRING_URL="$KEYRING" TEST_ONLY_LINUX_SEED_KEY_FPR="$GOOD_FPR" . "$REPO/fetch-linux-seed.sh" 2>/dev/null
  if fetch_linux_seed "$FST/dest2" >/dev/null 2>&1; then exit 1; fi
  fetch_linux_seed "$FST/dest2" >/dev/null 2>&1 || exit 0; exit 1 ) || fail "a failing fetch_linux_seed under if/|| did not return a status"
echo "PASS"
