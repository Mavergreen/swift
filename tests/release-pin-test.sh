#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-pin-test.sh
#   check_release_pin must refuse a pin that is not the Swift release, or whose commit is not the tag's,
#   and must compare an annotated tag by its peeled commit. It reads the tags from the repository's ref
#   advertisement (<url>/info/refs) with curl, never git: offline, a fake curl serves one shaped like
#   GitHub's (pkt-lines, the first ref followed by a NUL and capabilities) and records what it was asked.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/release-pin.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# The advertisement: HEAD with capabilities, a lightweight tag 9.9.9, an annotated tag 8.8.8 (its tag
# object, then its peeled commit), and a branch whose name holds the tag's.
{ printf '001e# service=git-upload-pack\n0000'
  printf '00f5cccccccccccccccccccccccccccccccccccccccc HEAD\000multi_ack thin-pack side-band symref=HEAD:refs/heads/main\n'
  printf '004bcccccccccccccccccccccccccccccccccccccccc refs/heads/swift-9.9.9-RELEASE\n'
  printf '004a1111111111111111111111111111111111111111 refs/tags/swift-9.9.9-RELEASE\n'
  printf '004aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/tags/swift-8.8.8-RELEASE\n'
  printf '004dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/swift-8.8.8-RELEASE^{}\n'
  printf '0000'; } > "$T/refs"
# A second one whose first ref, the one that follows the flush with no newline and carries the
# capabilities, is the tag itself.
{ printf '001e# service=git-upload-pack\n0000'
  printf '0086dddddddddddddddddddddddddddddddddddddddd refs/tags/swift-9.9.9-RELEASE\000multi_ack thin-pack side-band symref=HEAD:refs/heads/main\n'
  printf '003dcccccccccccccccccccccccccccccccccccccccc refs/heads/main\n'
  printf '0000'; } > "$T/refs-first"
cat > "$T/bin/curl" <<F
#!/bin/sh
o=""; u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2 ;; -*) shift ;; *) u="\$1"; shift ;; esac; done
echo "\$u" >> "$T/curl.log"
case "\$u" in
  https://fail.invalid/*) exit 22 ;;
  https://portal.invalid/*) printf '<html><body>Sign in to the network</body></html>\n' > "\$o" ;;
  https://first.invalid/*/info/refs\?service=git-upload-pack) cp "$T/refs-first" "\$o" ;;
  */info/refs\?service=git-upload-pack) cp "$T/refs" "\$o" ;;
  *) exit 22 ;;
esac
F
printf '#!/bin/sh\necho "git $*" >> "%s/git.log"\nexit 1\n' "$T" > "$T/bin/git"
chmod +x "$T/bin/curl" "$T/bin/git"
check() {  # $1 = SWIFT_VERSION, rest = check_release_pin args; sets rc
  rc=0; ( PATH="$T/bin:$PATH"; SWIFT_VERSION="$1"; shift; . "$REPO/lib.sh"; check_release_pin "$@" ) > "$T/out" 2>&1 || rc=$?
}
U=https://github.com/acme/widget.git
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 "$U"; [ "$rc" = 0 ] || fail "matching pin refused: $(cat "$T/out")"
[ "$(tail -1 "$T/curl.log")" = "https://github.com/acme/widget.git/info/refs?service=git-upload-pack" ] || fail "asked curl for $(tail -1 "$T/curl.log")"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 https://github.com/acme/widget
[ "$rc" = 0 ] && [ "$(tail -1 "$T/curl.log")" = "$U/info/refs?service=git-upload-pack" ] || fail "a URL without .git: rc $rc, asked $(tail -1 "$T/curl.log")"
check 9.9.9 thing 9.9.8 swift-9.9.8-RELEASE 1111111111111111111111111111111111111111 "$U"; [ "$rc" = 1 ] || fail "pin at another Swift release accepted"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 2222222222222222222222222222222222222222 "$U"; [ "$rc" = 1 ] || fail "commit not at the tag accepted"
grep -q "is 1111111111111111111111111111111111111111" "$T/out" || fail "did not name the tag's commit: $(cat "$T/out")"
check 7.7.7 thing 7.7.7 swift-7.7.7-RELEASE 1111111111111111111111111111111111111111 "$U"; [ "$rc" = 1 ] || fail "missing tag accepted"
grep -q 'has no tag swift-7.7.7-RELEASE' "$T/out" || fail "a missing tag: $(cat "$T/out")"
check 8.8.8 thing 8.8.8 swift-8.8.8-RELEASE bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$U"; [ "$rc" = 0 ] || fail "annotated tag not compared by its peeled commit"
check 8.8.8 thing 8.8.8 swift-8.8.8-RELEASE aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$U"; [ "$rc" = 1 ] || fail "annotated tag compared by its tag object"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE cccccccccccccccccccccccccccccccccccccccc "$U"; [ "$rc" = 1 ] || fail "took the branch of the tag's name for the tag"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 https://fail.invalid/acme/widget.git
[ "$rc" = 1 ] || fail "passed although curl failed"
grep -q 'could not list' "$T/out" || fail "a failed curl: $(cat "$T/out")"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE dddddddddddddddddddddddddddddddddddddddd https://first.invalid/acme/widget.git
[ "$rc" = 0 ] || fail "misread the first ref, the one after the flush: $(cat "$T/out")"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 https://portal.invalid/acme/widget.git
[ "$rc" = 1 ] || fail "took a captive portal's page for a ref advertisement"
grep -q 'not a git ref advertisement' "$T/out" || fail "a captive portal's page: $(cat "$T/out")"
rc=0; ( PATH="$T/bin:$PATH"; TMPDIR="$T/absent"; SWIFT_VERSION=9.9.9; . "$REPO/lib.sh"
  check_release_pin thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 "$U" ) > "$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q 'could not make a temporary file' "$T/out" || fail "no temporary file: rc $rc, $(cat "$T/out")"
[ ! -f "$T/git.log" ] || fail "ran git: $(cat "$T/git.log")"
echo "PASS"
