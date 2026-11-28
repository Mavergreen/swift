#!/bin/sh
# platform: host-agnostic
# usage: sh tests/cache-key-test.sh
#   The Linux-hosted compiler is cached under a key that hashes what its build reads
#   (scripts/compiler-cache-inputs.sh over release.yml's COMPILER_BUILD), so a cached compiler can never pass
#   where a cold build would fail. Checked against a grep of its own: every file a script in the list sources
#   (`.` or `source`, by a variable or beside itself), pins.env, every file under a patches/ or components/
#   directory a script names, and every shipyard script named as $SHIPYARD/<name>, plus shipyard's pin and
#   registry tables, must be listed; so must build-toolchain.sh (whose linux host stages dsymutil), lib.sh (whose
#   patch_source picks each patch's strip level) and llvm patch 0007. Nothing the runtime alone reads is listed
#   (build.sh, patches/runtime/, tests/), so a runtime change never rebuilds the compiler. Every listed path
#   exists. In a copy of the repo, a newly sourced file joins the list, a change to build-toolchain.sh, lib.sh or
#   patch 0007 changes the hash and a change to a runtime patch or a test does not, and a missing shipyard table,
#   a missing named script or no shipyard at all fails the script.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/cache-key-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
REAL_SHIPYARD="$(. "$REPO/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || { echo "no shipyard -- skipping"; exit 77; }
[ -f "$REAL_SHIPYARD/script-closure.sh" ] || { echo "shipyard at $REAL_SHIPYARD has no script-closure.sh -- skipping"; exit 77; }
command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "no git checkout -- skipping"; exit 77; }
for d in $(sed -n 's/^SHIPYARD_DATA="\(.*\)"$/\1/p' "$REPO/scripts/compiler-cache-inputs.sh" 2>/dev/null); do
  [ -f "$REAL_SHIPYARD/$d" ] || { echo "shipyard at $REAL_SHIPYARD has no $d, so it is older than the one install@v1 gives CI -- skipping"; exit 77; }
done
mkdir -p "$T/shipyard" && cp -R "$REAL_SHIPYARD" "$T/shipyard/scripts"
SY="$T/shipyard/scripts"
I="$REPO/scripts/compiler-cache-inputs.sh"
[ -f "$I" ] || fail "no scripts/compiler-cache-inputs.sh"

W="$REPO/.github/workflows/release.yml"
[ -f "$W" ] || fail "no .github/workflows/release.yml"
CB="$(sed -n 's/^  COMPILER_BUILD: *//p' "$W")"
[ -n "$CB" ] || fail "release.yml names no COMPILER_BUILD"

# shellcheck disable=SC2086  # COMPILER_BUILD is a list of script names
SHIPYARD_SCRIPTS="$SY" sh "$I" $CB > "$T/list" 2> "$T/err" || fail "the inputs script failed: $(cat "$T/err")"
has() { grep -Fxq -- "$1" "$T/list"; }

# The grep: what the listed repo scripts source, read and run.
grep '^repo/.*\.sh$' "$T/list" | sed 's|^repo/||' > "$T/scripts"
for s in $CB; do grep -Fxq "$s" "$T/scripts" || fail "the list omits $s, a script COMPILER_BUILD names"; done
while IFS= read -r s; do
  sed '/^[[:space:]]*#/d' "$REPO/$s" > "$T/code"
  # Sourced through a variable: `. "$HERE/lib.sh"`, `. "$_fls_here/pins.env"`.
  grep -oE '(^|[;&|({[:space:]])(\.|source)[[:space:]]+"?\$\{?(HERE|REPO|_fls_here)\}?"?/[A-Za-z0-9_./-]+' "$T/code" \
    | sed -E 's/^.*\$\{?(HERE|REPO|_fls_here)\}?"?\///' > "$T/src" || :
  # Sourced beside itself: `. "$(dirname "$0")/../msc.sh"`.
  grep -oE '(\.|source)[[:space:]]+"\$\(dirname "\$0"\)/[A-Za-z0-9_./-]+' "$T/code" \
    | sed -E 's|.*\)/||' | while IFS= read -r r; do
        d="$(dirname "$s")"; while case "$r" in ../*) true ;; *) false ;; esac; do r="${r#../}"; d="$(dirname "$d")"; done
        [ "$d" = . ] && echo "$r" || echo "$d/$r"; done >> "$T/src"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    has "repo/$f" || fail "$s sources $f, which the cache key omits"
  done < "$T/src"
  if grep -q 'pins\.env' "$T/code"; then has repo/pins.env || fail "$s reads pins.env, which the cache key omits"; fi
  for d in $(grep -oE '(patches|components)/[A-Za-z0-9_-]+' "$T/code" | sort -u); do
    git -C "$REPO" ls-files -- "$d" > "$T/under"
    [ -s "$T/under" ] || fail "$s names $d, which holds no tracked file"
    while IFS= read -r f; do has "repo/$f" || fail "$s names $d, and the cache key omits $f"; done < "$T/under"
  done
  for n in $(grep -oE '\$\{?SHIPYARD(_SCRIPTS)?\}?"?/[A-Za-z0-9_./-]+' "$T/code" | sed -E 's|.*\}?"?/||; s|^SHIPYARD(_SCRIPTS)?"?/||' | sort -u); do
    has "shipyard/$n" || fail "$s runs shipyard's $n, which the cache key omits"
  done
done < "$T/scripts"

# What the compiler build is known to read, and shipyard's tables.
for l in repo/build-toolchain.sh repo/build-llvm.sh repo/build-builtins.sh repo/lib.sh repo/pins.env repo/msc.sh \
  repo/fetch-linux-seed.sh repo/fetch-clang22.sh repo/components/clang22/version repo/toolchain/clang.cfg \
  shipyard/fetch_clang22.sh shipyard/fetch_sdk.sh shipyard/sdk-pins.sh shipyard/stevedore.pin shipyard/product-names; do
  has "$l" || fail "the cache key omits $l"
done
grep -q '^repo/patches/llvm/0007-.*\.patch$' "$T/list" || fail "the cache key omits llvm patch 0007"
grep -q '^repo/patches/compiler/0001-.*\.patch$' "$T/list" || fail "the cache key omits the compiler patches"
# The runtime's own inputs stay out, or every runtime change would rebuild the compiler.
if grep -E '^repo/(build\.sh|package\.sh|make-selftest\.sh|patches/runtime/|tests/|\.github/)' "$T/list"; then
  fail "the cache key lists what only the runtime reads (above)"
fi
while IFS= read -r l; do
  case "$l" in
    repo/*) [ -f "$REPO/${l#repo/}" ] || fail "$l is listed but missing" ;;
    shipyard/*) [ -f "$SY/${l#shipyard/}" ] || fail "$l is listed but missing" ;;
    *) fail "a listed line is neither repo/ nor shipyard/: $l" ;;
  esac
done < "$T/list"

# A copy of the repo's tracked files, as a git index the inputs script reads.
R="$T/repo"; mkdir -p "$R"
git -C "$REPO" ls-files > "$T/tracked"
while IFS= read -r f; do [ -f "$REPO/$f" ] || continue; mkdir -p "$R/$(dirname "$f")"; cp -p "$REPO/$f" "$R/$f"; done < "$T/tracked"
mkdir -p "$R/scripts" "$R/.github/workflows" && cp "$I" "$R/scripts/" && cp "$W" "$R/.github/workflows/"
git -C "$R" init -q && git -C "$R" add -A
key() { SHIPYARD_SCRIPTS="${2:-$SY}" sh "$R/scripts/compiler-cache-inputs.sh" --hash $CB 2> "$T/err" || { echo "FAILED: $(cat "$T/err")"; return 1; }; }
K0="$(key)" || fail "--hash failed: $K0"
printf '%s\n' "$K0" | grep -qxE '[0-9a-f]{64}' || fail "--hash printed '$K0', not one SHA-256"
[ "$(key)" = "$K0" ] || fail "--hash is not the same twice"
changes() { printf '\n# changed\n' >> "$R/$1"; k="$(key)" || fail "--hash failed after changing $1"; cp "$REPO/$1" "$R/$1"; [ "$k" != "$K0" ]; }
for f in build-toolchain.sh lib.sh "$(cd "$REPO" && ls patches/llvm/0007-*.patch)" pins.env components/clang22/version; do
  changes "$f" || fail "a change to $f leaves the compiler's cache key as it was"
done
for f in "$(cd "$REPO" && ls patches/runtime/*.patch | head -1)" tests/cache-key-test.sh build.sh; do
  if changes "$f"; then fail "a change to $f, which only the runtime reads, changes the compiler's cache key"; fi
done
printf '#!/bin/sh\n' > "$R/new-input.sh"; git -C "$R" add new-input.sh
printf '. "$HERE/new-input.sh"\n' >> "$R/build-toolchain.sh"
SHIPYARD_SCRIPTS="$SY" sh "$R/scripts/compiler-cache-inputs.sh" $CB | grep -qx 'repo/new-input.sh' \
  || fail "a file build-toolchain.sh newly sources is not in the cache key"
cp "$REPO/build-toolchain.sh" "$R/build-toolchain.sh"
cp -R "$SY" "$T/sy-missing" && rm "$T/sy-missing/stevedore.pin"
if key x "$T/sy-missing" > /dev/null; then fail "the key was computed without shipyard's stevedore.pin"; fi
if SHIPYARD_SCRIPTS="$SY" sh "$R/scripts/compiler-cache-inputs.sh" $CB no-such-script.sh > /dev/null 2>&1; then
  fail "the inputs script accepted a script that does not exist"; fi
if SHIPYARD_SCRIPTS="$T/nowhere" sh "$R/scripts/compiler-cache-inputs.sh" $CB > /dev/null 2>&1; then
  fail "the inputs script ran without shipyard"; fi
echo "PASS: cache-key ($(wc -l < "$T/list" | tr -d ' ') inputs)"
