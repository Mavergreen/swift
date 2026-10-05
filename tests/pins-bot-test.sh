#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pins-bot-test.sh
#   .github/workflows/pins-bot.yml fills a Swift bump's tarball pins on Renovate's branch. Its decisions are
#   scripts/pins-bot.sh's: `moved` must say yes exactly when a source pin line moved since the branch left main
#   (a Swift bump), and no for any other change (a clang22 bump, say); `values` must hand on the three pins and
#   refuse one that is not a SHA-256; `apply` must write those three lines and nothing else, report whether it
#   changed anything, and refuse another key, a bad value or a repeated key before writing. `fill` is the pins
#   job's whole decision, by scripts/pin-source-tarballs.sh's exit codes: nothing when no source pin moved or
#   --check says 0 (current); the write, then the three values, when --check says 3 (stale); a failure, with no
#   write and no values, for any other --check status (1, an error: never mistaken for stale) or a failed write.
#   The workflow must give the job that reads upstream's tarballs no write token, and the job that holds one
#   no upstream bytes.
#   Offline: a fixture repository with this repo's pins.env stands in for the Renovate branch, and a stub
#   stands in for pin-source-tarballs.sh.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
git --version >/dev/null 2>&1 || { echo "no git that runs -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pins-bot.XXXXXX")"
trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R/scripts"
cp "$REPO/scripts/pins-bot.sh" "$R/scripts/"; cp "$REPO/pins.env" "$R/"
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" add -A; git -C "$R" commit -qm main; git -C "$R" branch -m main
bot() { ( cd "$R" && sh scripts/pins-bot.sh "$@" ); }
Z=0000000000000000000000000000000000000000000000000000000000000000
edit() { sed "s|^$1=.*|$1=\"$2\"|" "$R/pins.env" > "$T/p" && cat "$T/p" > "$R/pins.env"; }

echo "-- moved: a clang22 bump is not a source pin; a Swift bump is, even after main moved on"
git -C "$R" checkout -q -b renovate/clang22; edit CLANG22_VERSION 22.1.1-mavericks.7; git -C "$R" commit -qam clang22
if bot moved main > "$T/out"; then fail "a clang22 bump counted as a moved source pin: $(cat "$T/out")"; fi
# main moves on after the branch left it, a source pin line included: only the branch's own change counts.
git -C "$R" checkout -q main; edit CMARK_TARBALL_SHA256 "$Z"; git -C "$R" commit -qam later
git -C "$R" checkout -q -b renovate/swift HEAD~1; edit SWIFT_SHA 1111111111111111111111111111111111111111; git -C "$R" commit -qam swift
bot moved main > "$T/out" || fail "a moved SWIFT_SHA was not seen"
[ "$(grep -c '^[-+]SWIFT_SHA=' "$T/out")" = 2 ] && [ "$(wc -l < "$T/out" | tr -d ' ')" = 2 ] || fail "moved printed: $(cat "$T/out")"

echo "-- values: the three pins on one line; a bad one refused"
[ "$(bot values)" = "$(. "$REPO/pins.env" && echo "LLVM_TARBALL_SHA256=$LLVM_TARBALL_SHA256 SWIFT_TARBALL_SHA256=$SWIFT_TARBALL_SHA256 CMARK_TARBALL_SHA256=$CMARK_TARBALL_SHA256")" ] \
  || fail "values: $(bot values)"
edit CMARK_TARBALL_SHA256 abc
if bot values > /dev/null 2> "$T/err"; then fail "handed on CMARK_TARBALL_SHA256=abc"; fi
grep -q "CMARK_TARBALL_SHA256 is 'abc'" "$T/err" || fail "values: $(cat "$T/err")"
cp "$REPO/pins.env" "$R/pins.env"

echo "-- apply: the three lines, nothing else; unchanged when they hold the values; refusals write nothing"
cp "$R/pins.env" "$T/before"
[ "$(bot apply LLVM_TARBALL_SHA256=$Z SWIFT_TARBALL_SHA256=$Z)" = changed ] || fail "apply did not say changed"
[ "$(diff "$T/before" "$R/pins.env" | grep -c '^>')" = 2 ] || fail "apply changed: $(diff "$T/before" "$R/pins.env")"
grep -qx "SWIFT_TARBALL_SHA256=\"$Z\"" "$R/pins.env" || fail "SWIFT_TARBALL_SHA256 not written"
[ "$(bot apply SWIFT_TARBALL_SHA256=$Z)" = unchanged ] || fail "a second apply of the same value changed pins.env"
cp "$R/pins.env" "$T/now"
for bad in "SWIFT_SHA=$Z" "SWIFT_TARBALL_SHA256=${Z%0}" "SWIFT_TARBALL_SHA256=$Z SWIFT_TARBALL_SHA256=$Z" "LLVM_TARBALL_SHA256=\$(touch $T/pwned)"; do
  # shellcheck disable=SC2086
  if bot apply $bad > /dev/null 2>&1; then fail "applied [$bad]"; fi
  cmp -s "$T/now" "$R/pins.env" || fail "a refused [$bad] wrote pins.env"
done
[ ! -e "$T/pwned" ] || fail "apply ran a value"

echo "-- fill: --check 0 nothing to do; 3 the write, then the values; anything else fails, writing nothing"
git -C "$R" checkout -q -- pins.env
E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
# The stub: logs each call; --check exits $STUB_CHECK; the write exits $STUB_WRITE, having moved
# SWIFT_TARBALL_SHA256 to $STUB_SHA when that is 0.
cat > "$R/scripts/pin-source-tarballs.sh" <<'STUB'
#!/bin/sh
echo "${1:-write}" >> "$STUB_LOG"
case "${1:-}" in --check) exit "$STUB_CHECK" ;; esac
[ "$STUB_WRITE" = 0 ] || exit "$STUB_WRITE"
p="$(dirname "$0")/../pins.env"
sed "s|^SWIFT_TARBALL_SHA256=.*|SWIFT_TARBALL_SHA256=\"$STUB_SHA\"|" "$p" > "$p.new" && mv "$p.new" "$p"
STUB
fill() {  # fill <base-ref> <--check status> <write status>: pins-bot.sh fill's status; $T/out, $T/calls
  : > "$T/calls"
  ( cd "$R" && env STUB_LOG="$T/calls" STUB_CHECK="$2" STUB_WRITE="$3" STUB_SHA="$E" sh scripts/pins-bot.sh fill "$1" ) > "$T/out" 2> "$T/err"
}
calls() { tr '\n' ' ' < "$T/calls" | sed 's/ $//'; }
cp "$R/pins.env" "$T/now"
fill main 0 0 || fail "fill, --check current: exit $? ($(cat "$T/err"))"
[ ! -s "$T/out" ] && [ "$(calls)" = --check ] || fail "fill, --check current: handed on [$(cat "$T/out")], calls [$(calls)]"
cmp -s "$T/now" "$R/pins.env" || fail "fill, --check current: pins.env changed"
fill main 3 0 || fail "fill, --check stale: exit $? ($(cat "$T/err"))"
[ "$(calls)" = "--check write" ] || fail "fill, --check stale: calls [$(calls)]"
[ "$(cat "$T/out")" = "$(. "$R/pins.env" && echo "LLVM_TARBALL_SHA256=$LLVM_TARBALL_SHA256 SWIFT_TARBALL_SHA256=$E CMARK_TARBALL_SHA256=$CMARK_TARBALL_SHA256")" ] \
  || fail "fill, --check stale: handed on [$(cat "$T/out")]"
cp "$T/now" "$R/pins.env"
for rc in 1 2 130 143 7; do
  if fill main "$rc" 0; then fail "fill, --check exit $rc: exit 0, handed on [$(cat "$T/out")]"; fi
  [ ! -s "$T/out" ] && [ "$(calls)" = --check ] || fail "fill, --check exit $rc: handed on [$(cat "$T/out")], calls [$(calls)]"
  cmp -s "$T/now" "$R/pins.env" || fail "fill, --check exit $rc: pins.env changed"
done
grep -q 'pin-source-tarballs.sh --check exited 7' "$T/err" || fail "fill, --check exit 7: said [$(cat "$T/err")]"
if fill main 3 1; then fail "fill, a failed write: exit 0"; fi
[ ! -s "$T/out" ] && [ "$(calls)" = "--check write" ] || fail "fill, a failed write: handed on [$(cat "$T/out")], calls [$(calls)]"
if fill nosuchref 3 0; then fail "fill, no merge base: exit 0"; fi
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] || fail "fill, no merge base: handed on [$(cat "$T/out")], calls [$(calls)]"
git -C "$R" checkout -q renovate/clang22
fill main 3 0 || fail "fill, a clang22 bump: exit $? ($(cat "$T/err"))"
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] || fail "fill, a clang22 bump: handed on [$(cat "$T/out")], calls [$(calls)]"

echo "-- the workflow: Renovate's branches only; the job that reads upstream has no write token, the one with it no upstream"
W="$REPO/.github/workflows/pins-bot.yml"
grep -qx "    branches: \['renovate/\*\*'\]" "$W" || fail "pins-bot.yml does not run on renovate/** pushes alone"
grep -qx 'permissions: {}' "$W" || fail "pins-bot.yml grants a default permission"
awk '/^  pins:$/ { j = "pins" } /^  push:$/ { j = "push" } j { print j ": " $0 }' "$W" > "$T/jobs"
grep -qx 'pins:       contents: read' "$T/jobs" || fail "the pins job's permissions: $(grep '^pins:' "$T/jobs" | grep -A2 permissions)"
if grep '^pins:' "$T/jobs" | grep -q 'write\|git push\|gh workflow'; then fail "the pins job can write"; fi
if grep '^push:' "$T/jobs" | grep -q 'pin-source-tarballs\|curl\|install@'; then fail "the push job touches upstream's tarballs"; fi
grep -qx 'push:       contents: write' "$T/jobs" && grep -qx 'push:       actions: write' "$T/jobs" || fail "the push job's permissions"
grep -q 'gh workflow run release.yml --ref "\$BRANCH"' "$W" || fail "the push job does not dispatch release.yml on the branch"
grep -qx 'pins:           pins="$(sh scripts/pins-bot.sh fill origin/main)"' "$T/jobs" || fail "the pins job does not decide by pins-bot.sh fill"
# A refused apply must fail the push job, not read as "unchanged": its status is taken by an assignment
# (set -e sees it there), never inside a [ "$(...)" = changed ] test, which would swallow it.
grep -qx 'push:           applied="$(sh scripts/pins-bot.sh apply $PINS)"' "$T/jobs" || fail "the push job does not fail on a refused apply"
if grep '^push:' "$T/jobs" | grep -qF '[ "$(sh scripts/pins-bot.sh apply'; then fail "the push job reads a refused apply as unchanged"; fi
if grep '^pins:' "$T/jobs" | grep -v '^pins: *#' | grep -q 'pin-source-tarballs'; then fail "the pins job runs pin-source-tarballs.sh around pins-bot.sh fill"; fi
echo "PASS"
