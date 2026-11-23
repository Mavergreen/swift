# platform: host-agnostic
# fake-linux-seed.sh — sourced by the tests that exercise fetch-linux-seed.sh offline. fake_seed_setup <tmp>
# builds, under <tmp>/srv: seed.tar.gz (holds swift-x/usr/bin/swiftc), the keys good (the pinned one),
# other and expired (valid for a day, three days ago), keys.asc holding all three, and a signature file per
# case: good.sig, other.sig, expired.sig (made while expired's key was still valid), wrongfile.sig (the
# pinned key's, over another file), garbage.sig. It sets SRV, GOOD_FPR, HASH and defines shipyard_curl
# (a stub that copies from a path) and fake_seed_cleanup. gpg-agent's socket path must fit sun_path (104
# bytes), which a macOS $TMPDIR does not, so the keys live under a short /tmp path. Needs gpg.
fake_seed_setup() {
  FST="$1"; SRV="$FST/srv"; mkdir -p "$SRV" "$FST/tar/swift-x/usr/bin"
  G="$(mktemp -d /tmp/fls.XXXXXX)"
  printf '#!/bin/sh\n' > "$FST/tar/swift-x/usr/bin/swiftc"; chmod +x "$FST/tar/swift-x/usr/bin/swiftc"
  tar -czf "$SRV/seed.tar.gz" -C "$FST/tar" swift-x
  echo other-content > "$SRV/other-file"
  _now="$(date +%s)"; _past=$((_now - 3 * 86400))
  GOOD_FPR="$(fake_seed_mkkey good "")"; fake_seed_mkkey other "" >/dev/null
  fake_seed_mkkey expired "--faked-system-time $_past" 1d >/dev/null
  cat "$SRV/good.asc" "$SRV/other.asc" "$SRV/expired.asc" > "$SRV/keys.asc"
  fake_seed_sign good "" seed.tar.gz good.sig; fake_seed_sign other "" seed.tar.gz other.sig
  fake_seed_sign expired "--faked-system-time $((_past + 3600))" seed.tar.gz expired.sig
  fake_seed_sign good "" other-file wrongfile.sig
  echo "not a signature" > "$SRV/garbage.sig"
  HASH="$( (sha256sum "$SRV/seed.tar.gz" 2>/dev/null || shasum -a 256 "$SRV/seed.tar.gz") | awk '{print $1}')"
}
# fake_seed_mkkey <name> <gpg time flags> <expiry|""> -- prints the primary fingerprint; exports <name>.asc
fake_seed_mkkey() {
  mkdir -m 700 "$G/gh-$1"
  # shellcheck disable=SC2086  # $2 is flags
  GNUPGHOME="$G/gh-$1" gpg --batch --quiet $2 --passphrase '' --quick-gen-key "$1 <$1@example.invalid>" rsa2048 sign ${3:-1d} >/dev/null 2>&1
  GNUPGHOME="$G/gh-$1" gpg --batch --armor --export > "$SRV/$1.asc" 2>/dev/null
  GNUPGHOME="$G/gh-$1" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}
# fake_seed_sign <key> <gpg time flags> <file> <signame>
fake_seed_sign() {
  # shellcheck disable=SC2086
  GNUPGHOME="$G/gh-$1" gpg --batch --yes $2 --detach-sign --output "$SRV/$4" "$SRV/$3" >/dev/null 2>&1
}
# the stub honours shipyard_curl's (url, dest) form with a path as the url; extra flags are skipped
shipyard_curl() { while [ $# -gt 2 ]; do shift; done; cp "$1" "$2"; }
fake_seed_cleanup() {
  for h in "$G"/*; do [ -d "$h" ] && GNUPGHOME="$h" gpgconf --kill all >/dev/null 2>&1 || :; done
  rm -rf "$FST" "$G"
}
