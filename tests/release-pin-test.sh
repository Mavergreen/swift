#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-pin-test.sh
#   check_release_pin must refuse a pin that is not the Swift release, or whose commit is not the
#   tag's, and must compare an annotated tag by its peeled commit. Offline: a fake git answers.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/release-pin.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
[ "$1" = ls-remote ] || exit 2
case "$3" in
  refs/tags/swift-9.9.9-RELEASE) printf '1111111111111111111111111111111111111111\trefs/tags/swift-9.9.9-RELEASE\n' ;;
  refs/tags/swift-8.8.8-RELEASE) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/swift-8.8.8-RELEASE\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/swift-8.8.8-RELEASE^{}\n' ;;
esac
EOF
chmod +x "$T/bin/git"
check() {  # $1 = SWIFT_VERSION, rest = check_release_pin args; sets rc
  rc=0; ( PATH="$T/bin:$PATH"; SWIFT_VERSION="$1"; shift; . "$REPO/lib.sh"; check_release_pin "$@" ) >/dev/null 2>&1 || rc=$?
}
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 1111111111111111111111111111111111111111 u; [ "$rc" = 0 ] || fail "matching pin refused"
check 9.9.9 thing 9.9.8 swift-9.9.8-RELEASE 1111111111111111111111111111111111111111 u; [ "$rc" = 1 ] || fail "pin at another Swift release accepted"
check 9.9.9 thing 9.9.9 swift-9.9.9-RELEASE 2222222222222222222222222222222222222222 u; [ "$rc" = 1 ] || fail "commit not at the tag accepted"
check 7.7.7 thing 7.7.7 swift-7.7.7-RELEASE 1111111111111111111111111111111111111111 u; [ "$rc" = 1 ] || fail "missing tag accepted"
check 8.8.8 thing 8.8.8 swift-8.8.8-RELEASE bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb u; [ "$rc" = 0 ] || fail "annotated tag not compared by its peeled commit"
check 8.8.8 thing 8.8.8 swift-8.8.8-RELEASE aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa u; [ "$rc" = 1 ] || fail "annotated tag compared by its tag object"
echo "PASS"
