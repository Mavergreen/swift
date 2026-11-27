#!/bin/sh
# platform: host-agnostic
# usage: sh scripts/compiler-cache-inputs.sh [--hash] SCRIPT...
#   What the Linux-hosted compiler's build reads, for the key it is cached under. SCRIPT... are the repo
#   scripts that build runs, as release.yml names them once (COMPILER_BUILD). Prints, sorted, one per line:
#     repo/<path>      every tracked file those scripts name through a variable ("$HERE/lib.sh",
#                      "$HERE"/patches/llvm/*.patch, "$HERE/patches/compiler", lib.sh's "$2/fetch-clang22.sh") or
#                      beside themselves ("$(dirname "$0")/../msc.sh"), and in turn every shell file among them
#                      names, the scripts themselves included. A variable that is not the repo's root (HERE, REPO,
#                      _fls_here) counts only when it names a tracked *.sh: a function handed the root (lib.sh's
#                      clang22_prefix "$_c22" "$HERE") runs scripts there, and a scratch dir's file
#                      ("$_msc_probe/CMakeLists.txt") is not this repo's.
#     shipyard/<path>  script-closure.sh's closure, in $SHIPYARD_SCRIPTS (the shipyard the job installed, so the
#                      shipyard the build runs), of every script they name as "$SHIPYARD/<name>", and SHIPYARD_DATA
#                      below: the data those scripts read that script-closure.sh, which follows scripts, may miss.
#   --hash prints instead one SHA-256 over every listed file's SHA-256 and label. A listed path, a named script
#   or a SHIPYARD_DATA file that is missing is exit 1: a key that describes less than the build read would let a
#   cached compiler pass where a cold build fails. Never the runner image, nor shipyard's version: a moving @v1
#   changes the key only when a file the build reads changes.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The pin and registry tables the scripts above read: the SDK pins (sdk-pins.sh), stevedore's (stevedore.pin),
# and the product registry install-products.sh and product-name.sh look clang22 up in.
SHIPYARD_DATA="sdk-pins.sh stevedore.pin product-names product-provisioners"
fail() { echo "compiler-cache-inputs: $*" >&2; exit 1; }
HASH=0
[ "${1:-}" != --hash ] || { HASH=1; shift; }
[ $# -gt 0 ] || { echo "usage: compiler-cache-inputs.sh [--hash] SCRIPT..." >&2; exit 2; }
S="${SHIPYARD_SCRIPTS:-}"
[ -n "$S" ] && [ -f "$S/script-closure.sh" ] || fail "SHIPYARD_SCRIPTS names no shipyard scripts dir with script-closure.sh (${S:-unset})"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/compiler-cache-inputs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$REPO"
git ls-files > "$WORK/tracked" 2>/dev/null && [ -s "$WORK/tracked" ] || fail "$REPO is no git checkout with tracked files"
LC_ALL=C sort -o "$WORK/tracked" "$WORK/tracked"
for n in "$@"; do grep -Fxq -- "$n" "$WORK/tracked" || fail "$n is not a tracked file in $REPO"; done

# refs <file> -- "<var> <path>" for every "$var/path" on a non-comment line; "<dir of file> <path>" beside it.
refs() {
  sed '/^[[:space:]]*#/d' "$1" | grep -oE '\$\{?[A-Za-z0-9_]+\}?"?/[A-Za-z0-9_./*-]+|\$\(dirname "\$0"\)"?/[A-Za-z0-9_./*-]+' \
    | sed -E 's|^\$\(dirname "\$0"\)"?/|. |; s|^\$\{?([A-Za-z0-9_]+)\}?"?/|\1 |; s|[./-]+$||' || :
}
# under <dir> <rel> -- <rel> resolved against <dir>, both relative to the repo, ".." folded.
under() {
  printf '%s/%s\n' "$1" "$2" | awk -F/ '{ n = 0; for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue
    if ($i == "..") { if (n) n--; continue } p[++n] = $i } s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "/" : "") p[i]; print s }'
}

printf '%s\n' "$@" > "$WORK/todo"
: > "$WORK/seen"; : > "$WORK/shipyard"
while [ -s "$WORK/todo" ]; do
  LC_ALL=C sort -u "$WORK/todo" | LC_ALL=C comm -23 - "$WORK/seen" > "$WORK/new"
  : > "$WORK/todo"
  [ -s "$WORK/new" ] || break
  cat "$WORK/new" >> "$WORK/seen"; LC_ALL=C sort -o "$WORK/seen" "$WORK/seen"
  while IFS= read -r f; do
    case "$f" in *.sh|*.env) ;; *) continue ;; esac
    refs "$f" | while read -r v p; do
      case "$v" in
        SHIPYARD|SHIPYARD_SCRIPTS) echo "$p" >> "$WORK/shipyard"; continue ;;
        .) p="$(under "$(dirname "$f")" "$p")"; root=1 ;;
        HERE|REPO|_fls_here) root=1 ;;
        *) root=0 ;;
      esac
      [ -n "$p" ] || continue
      while IFS= read -r t; do
        # shellcheck disable=SC2254  # $p is a glob on purpose: "$HERE"/patches/llvm/*.patch
        case "$t" in
          $p) [ "$root" = 1 ] || case "$t" in *.sh) ;; *) continue ;; esac; echo "$t" ;;
          $p/*) if [ "$root" = 1 ]; then echo "$t"; fi ;;
        esac
      done < "$WORK/tracked"
    done >> "$WORK/todo"
  done < "$WORK/new"
done

sed 's|^|repo/|' "$WORK/seen" > "$WORK/list"
if [ -s "$WORK/shipyard" ]; then
  # shellcheck disable=SC2046  # one shipyard script name per word
  ( cd "$S" && sh "$S/script-closure.sh" $(LC_ALL=C sort -u "$WORK/shipyard") ) > "$WORK/closure" \
    || fail "script-closure.sh refused the shipyard scripts the build names: $(LC_ALL=C sort -u "$WORK/shipyard" | tr '\n' ' ')"
  sed 's|^|shipyard/|' "$WORK/closure" >> "$WORK/list"
fi
for d in $SHIPYARD_DATA; do echo "shipyard/$d" >> "$WORK/list"; done
LC_ALL=C sort -u -o "$WORK/list" "$WORK/list"

# file <label> -- the file a label names
file() { case "$1" in repo/*) echo "$REPO/${1#repo/}" ;; shipyard/*) echo "$S/${1#shipyard/}" ;; esac; }
while IFS= read -r l; do [ -f "$(file "$l")" ] || fail "$l is missing ($(file "$l"))"; done < "$WORK/list"
[ "$HASH" = 1 ] || { cat "$WORK/list"; exit 0; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
while IFS= read -r l; do printf '%s  %s\n' "$(sha "$(file "$l")")" "$l"; done < "$WORK/list" > "$WORK/sums"
sha "$WORK/sums"
