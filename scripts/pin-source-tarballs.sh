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
#          Needs curl, git, tar, shasum and shipyard (msc.sh).
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/pin-source-tarballs.sh [--check]" >&2; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"
. "$HERE/lib.sh"    # -> LLVM_REPO_URL, SWIFT_REPO_URL, CMARK_REPO_URL
. "$HERE/msc.sh"    # -> $SHIPYARD (fetch_pinned_source.sh --url, clone_pinned.sh)
[ -f "$SHIPYARD/fetch_pinned_source.sh" ] || { echo "FAIL: the shipyard at $SHIPYARD has no fetch_pinned_source.sh -- install a newer shipyard pkg" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-source-tarballs.XXXXXX")"
NEW="$HERE/pins.env.new.$$"   # beside pins.env, so the one write is a rename within a file system
trap 'rm -rf "$T" "$NEW"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$HERE/pins.env" "$T/pins.env"   # the rows' new pins gather here; pins.env is untouched until all pass
rc=0
for row in "LLVM_TARBALL_SHA256 $LLVM_REPO_URL $LLVM_SHA $LLVM_TAG" "SWIFT_TARBALL_SHA256 $SWIFT_REPO_URL $SWIFT_SHA $SWIFT_TAG" \
           "CMARK_TARBALL_SHA256 $CMARK_REPO_URL $CMARK_SHA $CMARK_TAG"; do
  # shellcheck disable=SC2086  # four space-free words
  set -- $row
  pin=$1; repo=$2; commit=$3; tag=$4
  url="$(sh "$SHIPYARD/fetch_pinned_source.sh" --url "$repo" "$commit")"
  echo "==> $pin: $url"
  curl -fsSL --retry 3 --retry-delay 5 -o "$T/$pin.tar.gz" "$url" || { echo "FAIL: could not fetch $url" >&2; exit 1; }
  sha="$(shasum -a 256 < "$T/$pin.tar.gz" | cut -c1-64)"
  mkdir -p "$T/$pin.x" && tar xzf "$T/$pin.tar.gz" -C "$T/$pin.x" || { echo "FAIL: could not extract $url" >&2; exit 1; }
  top="$(ls -A "$T/$pin.x")"
  [ -d "$T/$pin.x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: $url holds more than one directory: $top" >&2; exit 1; }
  sh "$SHIPYARD/clone_pinned.sh" "$repo" "$tag" "$commit" "$T/$pin.git"
  # Every path, mode, link and byte of the commit, compared with the tarball's: git status of the
  # tarball's tree against the commit, untracked and ignored files included.
  # platform: some macOS gits fail with iconv_open(UTF-8, UTF-8-MAC) on swift's unicode paths unless
  #           core.precomposeunicode is off.
  diffs="$(git -c core.precomposeunicode=false --git-dir="$T/$pin.git/.git" --work-tree="$T/$pin.x/$top" status --porcelain --untracked-files=all --ignored)"
  [ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; echo "FAIL: $url is not commit $commit's tree (the differences above)" >&2; exit 1; }
  echo "    $sha (the commit's tree, file for file)"
  pinned="$(eval "printf '%s' \"\${$pin}\"")"
  if [ "$CHECK" = 1 ]; then
    [ "$pinned" = "$sha" ] || { echo "FAIL: pins.env's $pin is $pinned, but $url is $sha -- run sh scripts/pin-source-tarballs.sh and commit pins.env" >&2; rc=1; }
  elif [ "$pinned" != "$sha" ]; then
    awk -v k="$pin" -v v="$sha" 'index($0, k "=\"") == 1 { sub(/="[0-9a-f]*"/, "=\"" v "\"") } { print }' \
      "$T/pins.env" > "$T/pins.env.next" && mv "$T/pins.env.next" "$T/pins.env"
    grep -q "^$pin=\"$sha\"" "$T/pins.env" || { echo "FAIL: could not write $pin into pins.env" >&2; exit 1; }
    echo "    $pin moves"
  fi
  rm -rf "$T/$pin.tar.gz" "$T/$pin.x" "$T/$pin.git"
done
[ "$CHECK" = 0 ] || exit "$rc"
if cmp -s "$T/pins.env" "$HERE/pins.env"; then echo "pins.env: unchanged"; exit 0; fi
cp "$T/pins.env" "$NEW" && mv "$NEW" "$HERE/pins.env" || { echo "FAIL: could not write pins.env" >&2; exit 1; }
echo "pins.env: wrote the moved pins"
