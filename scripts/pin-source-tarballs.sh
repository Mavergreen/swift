#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pin-source-tarballs.sh [--check]
#          Writes into pins.env the SHA-256 of GitHub's tarball of each pinned source commit: LLVM_SHA's,
#          SWIFT_SHA's and CMARK_SHA's, as LLVM_TARBALL_SHA256, SWIFT_TARBALL_SHA256 and
#          CMARK_TARBALL_SHA256, by which the builds verify the sources they fetch (lib.sh's
#          fetch_source). Renovate moves a commit but cannot compute a hash: run this on a Swift bump's
#          branch and commit pins.env. A hash is written only for a tarball that holds exactly its
#          commit's files: the commit is fetched with shipyard's clone_pinned.sh and compared, by git,
#          with the extracted tarball (so this runs where git is; the builds never run it). --check
#          writes nothing, and fails naming each pin that is not its tarball's SHA-256. pins.env is
#          written once, after every row is verified, by a rename from beside it: a failure or a
#          signal anywhere leaves it as it was, with no temp file behind.
#          Exits (the pins bot relies on them): 0 the pins are current (or were just written); 3 --check
#          found a pin that is not its tarball's; 1 any failure (a tarball not its commit's tree, a
#          failed fetch, a refused digest, a missing pin line, a failed command); 2 usage, and only
#          usage; 130/143 on INT/TERM.
#          Needs curl, git, tar, shasum and shipyard (msc.sh).
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/pin-source-tarballs.sh [--check]" >&2; exit 2 ;;
esac
# Every exit from here is one this script chose (finish), or becomes 1: a command's own status under
# set -e (shipyard's 2 for a refused digest, git's 128) or a shell's under set -u must not read as
# usage (2) or stale (3) to the bot.
T=""; NEW=""; want=""
trap 'rc=$?; [ -z "$T" ] || rm -rf "$T"; [ -z "$NEW" ] || rm -f "$NEW"; [ "$rc" = "$want" ] || rc=1; exit "$rc"' EXIT
trap 'want=130; exit 130' INT
trap 'want=143; exit 143' TERM
finish() { want=$1; exit "$1"; }
fail() { echo "FAIL: $*" >&2; finish 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> LLVM_REPO_URL, SWIFT_REPO_URL, CMARK_REPO_URL
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_pinned_source.sh --url, clone_pinned.sh)
[ -f "$SHIPYARD/fetch_pinned_source.sh" ] || fail "the shipyard at $SHIPYARD has no fetch_pinned_source.sh -- install a newer shipyard pkg"
for pin in LLVM_TARBALL_SHA256 SWIFT_TARBALL_SHA256 CMARK_TARBALL_SHA256; do
  grep -q "^$pin=\"[0-9a-f]*\"" "$HERE/pins.env" || fail "pins.env has no $pin=\"...\" line"
done
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-source-tarballs.XXXXXX")"
NEW="$HERE/pins.env.new.$$"   # beside pins.env, so the one write is a rename within a file system
cp "$HERE/pins.env" "$T/pins.env"   # the rows' new pins gather here; pins.env is untouched until all pass
rc=0
for row in "LLVM_TARBALL_SHA256 $LLVM_REPO_URL $LLVM_SHA $LLVM_TAG" "SWIFT_TARBALL_SHA256 $SWIFT_REPO_URL $SWIFT_SHA $SWIFT_TAG" \
           "CMARK_TARBALL_SHA256 $CMARK_REPO_URL $CMARK_SHA $CMARK_TAG"; do
  # shellcheck disable=SC2086  # four space-free words
  set -- $row
  pin=$1; repo=$2; commit=$3; tag=$4
  url="$(sh "$SHIPYARD/fetch_pinned_source.sh" --url "$repo" "$commit")" || fail "shipyard has no tarball URL for $repo at '$commit'"
  echo "==> $pin: $url"
  curl -fsSL --retry 3 --retry-delay 5 -o "$T/$pin.tar.gz" "$url" || fail "could not fetch $url"
  sha="$(shasum -a 256 < "$T/$pin.tar.gz" | cut -c1-64)"
  mkdir -p "$T/$pin.x" && tar xzf "$T/$pin.tar.gz" -C "$T/$pin.x" || fail "could not extract $url"
  top="$(ls -A "$T/$pin.x")"
  [ -d "$T/$pin.x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || fail "$url holds more than one directory: $top"
  tree="$T/$pin.x/$top"
  # platform: git status never looks at an entry named .git (a directory, or a gitdir file) and
  #           never reports an empty directory, so a tarball could carry either unseen. Neither is in
  #           a commit's tree: git tracks no directory, and none of the three repos has a submodule
  #           (whose gitlink git archive writes as an empty directory).
  extra="$(find "$tree" \( -name .git -o -type d -empty \) -print | head -5)"
  [ -z "$extra" ] || { printf '%s\n' "$extra" >&2; fail "$url is not commit $commit's tree: it holds the .git or empty directory above"; }
  sh "$SHIPYARD/clone_pinned.sh" "$repo" "$tag" "$commit" "$T/$pin.git" || fail "could not clone $repo at $commit"
  # Every path, mode, link and byte of the commit, compared with the tarball's: git status of the
  # tarball's tree against the commit, untracked and ignored files included.
  # platform: some macOS gits fail with iconv_open(UTF-8, UTF-8-MAC) on swift's unicode paths unless
  #           core.precomposeunicode is off. The rest make the comparison the same on every host: a
  #           macOS clone's own core.ignorecase=true would pass a name that differs only in case, and
  #           fileMode, symlinks and autocrlf are set rather than left to the host's git.
  diffs="$(git -c core.precomposeunicode=false -c core.ignorecase=false -c core.autocrlf=false -c core.fileMode=true \
    -c core.symlinks=true --git-dir="$T/$pin.git/.git" --work-tree="$tree" status --porcelain --untracked-files=all --ignored)" \
    || fail "git could not compare $url with commit $commit"
  [ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; fail "$url is not commit $commit's tree (the differences above)"; }
  echo "    $sha (the commit's tree, file for file)"
  eval "pinned=\${$pin}"
  if [ "$CHECK" = 1 ]; then
    [ "$pinned" = "$sha" ] || { echo "FAIL: pins.env's $pin is $pinned, but $url is $sha -- run sh scripts/pin-source-tarballs.sh and commit pins.env" >&2; rc=3; }
  elif [ "$pinned" != "$sha" ]; then
    awk -v k="$pin" -v v="$sha" 'index($0, k "=\"") == 1 { sub(/="[0-9a-f]*"/, "=\"" v "\"") } { print }' \
      "$T/pins.env" > "$T/pins.env.next" && mv "$T/pins.env.next" "$T/pins.env" || fail "could not write $pin"
    grep -q "^$pin=\"$sha\"" "$T/pins.env" || fail "could not write $pin into pins.env"
    echo "    $pin moves"
  fi
  rm -rf "$T/$pin.tar.gz" "$T/$pin.x" "$T/$pin.git"
done
[ "$CHECK" = 0 ] || finish "$rc"
if cmp -s "$T/pins.env" "$HERE/pins.env"; then echo "pins.env: unchanged"; finish 0; fi
cp "$T/pins.env" "$NEW" && mv "$NEW" "$HERE/pins.env" || fail "could not write pins.env"
echo "pins.env: wrote the moved pins"
finish 0
