#!/bin/sh
# platform: host-agnostic
# usage: sh tests/source-patch-test.sh
#   The sources come as tarballs and are patched with the OS's patch, never git (OS X 10.9 has none without
#   the Command Line Tools). patch_source must apply each patch in order with this host's own patch (GNU
#   2.5.8 on 10.9, BSD 2.0 on a modern Mac), leave no backup (.orig, or GNU's .~1~) beside a file a hunk
#   reached at an offset, refuse a patch that does not apply before it changes anything, refuse a hunk
#   that applies only with fuzz (git apply refused those), refuse one already applied rather than offer
#   to reverse it, and refuse a tree a patch left a .rej, .orig or ~ backup in. fetch_source must hand shipyard's
#   fetch_pinned_source.sh the repository, commit, SHA-256 and directory, name the pins.env variable when the
#   fetch fails, and refuse a shipyard that predates it; source_commit must read back the commit the fetch
#   stamped, and nothing for a tree it did not stamp.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/source-patch.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/lib.sh"
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "git $*" >> "%s/git.log"\nexit 1\n' "$T" > "$T/bin/git"; chmod +x "$T/bin/git"
PATH="$T/bin:$PATH"

tree() {  # a fresh source tree: a.txt (ten lines, so a hunk can land at an offset) and sub/b.txt
  rm -rf "$T/src"; mkdir -p "$T/src/sub"
  printf 'pad1\npad2\npad3\none\ntwo\nthree\nfour\nfive\nsix\nseven\n' > "$T/src/a.txt"
  printf 'alpha\nbeta\ngamma\n' > "$T/src/sub/b.txt"
}
# 1-a.patch was made against a.txt when one line, not three, preceded "one": it applies at an offset of
# 2, as git apply would. (Not at line 1, and not with less context before than after: 10.9's GNU patch
# with -F 0 holds either to the start of the file, and git apply one at line 1.)
cat > "$T/1-a.patch" <<'P'
--- a.txt
+++ a.txt
@@ -2,3 +2,3 @@
 one
-two
+TWO
 three
P
cat > "$T/2-b.patch" <<'P'
--- sub/b.txt
+++ sub/b.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
P
cat > "$T/bad.patch" <<'P'
--- sub/b.txt
+++ sub/b.txt
@@ -1,3 +1,3 @@
 uno
-dos
+DOS
 tres
P
# fuzz.patch's first and last context lines have drifted: patch's default fuzz would apply it anyway.
cat > "$T/fuzz.patch" <<'P'
--- sub/b.txt
+++ sub/b.txt
@@ -1,3 +1,3 @@
 ALPHA
-beta
+BETA
 GAMMA
P

echo "-- patch_source: in order, at an offset, with no .orig left"
tree
patch_source "$T/src" "$T/1-a.patch" "$T/2-b.patch" > "$T/out" 2>&1 || fail "patch_source failed: $(cat "$T/out")"
[ "$(sed -n 5p "$T/src/a.txt")" = TWO ] || fail "1-a.patch did not apply: $(cat "$T/src/a.txt")"
[ "$(sed -n 2p "$T/src/sub/b.txt")" = BETA ] || fail "2-b.patch did not apply: $(cat "$T/src/sub/b.txt")"
[ -z "$(cd "$T/src" && find . -name '*.orig' -o -name '*.rej' -o -name '*~')" ] || fail "left $(cd "$T/src" && find . -name '*.orig' -o -name '*.rej' -o -name '*~')"

echo "-- patch_source: one that does not apply fails, naming it, and changes nothing"
tree
if patch_source "$T/src" "$T/1-a.patch" "$T/bad.patch" > "$T/out" 2>&1; then fail "applied bad.patch"; fi
grep -q "patch did not apply: $T/bad.patch" "$T/out" || fail "did not name bad.patch: $(cat "$T/out")"
[ "$(cat "$T/src/sub/b.txt")" = "$(printf 'alpha\nbeta\ngamma')" ] || fail "bad.patch changed sub/b.txt: $(cat "$T/src/sub/b.txt")"
[ -z "$(cd "$T/src" && find . -name '*.orig' -o -name '*.rej' -o -name '*~')" ] || fail "a refused patch left $(cd "$T/src" && find . -name '*.orig' -o -name '*.rej' -o -name '*~')"

echo "-- patch_source: a hunk that applies only with fuzz is refused, and changes nothing"
tree
if patch_source "$T/src" "$T/fuzz.patch" > "$T/out" 2>&1; then fail "applied fuzz.patch, whose context has drifted"; fi
grep -q "patch did not apply: $T/fuzz.patch" "$T/out" || fail "did not name fuzz.patch: $(cat "$T/out")"
[ "$(cat "$T/src/sub/b.txt")" = "$(printf 'alpha\nbeta\ngamma')" ] || fail "fuzz.patch changed sub/b.txt: $(cat "$T/src/sub/b.txt")"

echo "-- patch_source: one already applied is refused, not reversed"
tree
patch_source "$T/src" "$T/2-b.patch" > /dev/null 2>&1 || fail "the first application failed"
if patch_source "$T/src" "$T/2-b.patch" > "$T/out" 2>&1; then fail "applied 2-b.patch twice"; fi
[ "$(sed -n 2p "$T/src/sub/b.txt")" = BETA ] || fail "the second application reversed 2-b.patch"

echo "-- patch_source: a tree holding a .rej or .orig is refused; a relative patch or a missing tree too"
tree; : > "$T/src/sub/old.rej"
if patch_source "$T/src" "$T/2-b.patch" > "$T/out" 2>&1; then fail "accepted a tree holding sub/old.rej"; fi
grep -q 'old.rej' "$T/out" || fail "did not name sub/old.rej: $(cat "$T/out")"
tree
if patch_source "$T/src" 2-b.patch > /dev/null 2>&1; then fail "took a relative patch path"; fi
if patch_source "$T/absent" "$T/2-b.patch" > /dev/null 2>&1; then fail "patched a tree that is not there"; fi

echo "-- fetch_source: shipyard's fetcher with the pin, a named pin when it fails, no older shipyard"
mkdir -p "$T/shipyard"
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
echo "\$*" >> "$T/fetch.log"
[ "\$3" = good ] || exit 1
rm -rf "\$4"; mkdir -p "\$4"; echo "\$1 \$2 \$3" > "\$4/.mavergreen-source"
F
SHIPYARD="$T/shipyard"
( cd "$T" && fetch_source widget https://github.com/acme/widget.git 0123456789abcdef0123456789abcdef01234567 good WIDGET_TARBALL_SHA256 ) \
  || fail "fetch_source failed"
[ "$(cat "$T/fetch.log")" = "https://github.com/acme/widget.git 0123456789abcdef0123456789abcdef01234567 good widget" ] \
  || fail "asked shipyard for: $(cat "$T/fetch.log")"
[ "$(source_commit "$T/widget")" = 0123456789abcdef0123456789abcdef01234567 ] || fail "source_commit read '$(source_commit "$T/widget")'"
[ -z "$(source_commit "$T/src")" ] || fail "source_commit read a commit from a tree no fetch stamped"
if ( cd "$T" && fetch_source widget https://github.com/acme/widget.git 0123456789abcdef0123456789abcdef01234567 stale WIDGET_TARBALL_SHA256 ) > "$T/out" 2>&1; then
  fail "a failed fetch passed"
fi
grep -q 'pin-source-tarballs.sh and commit pins.env.s WIDGET_TARBALL_SHA256' "$T/out" || fail "did not name the pin: $(cat "$T/out")"
if ( unset SHIPYARD; cd "$T" && fetch_source widget https://github.com/acme/widget.git 0123456789abcdef0123456789abcdef01234567 good X ) > "$T/out" 2>&1; then
  fail "fetched with SHIPYARD unset"
fi
grep -q 'FAIL: fetch_source: SHIPYARD is not set' "$T/out" || fail "SHIPYARD unset: $(cat "$T/out")"
rm "$T/shipyard/fetch_pinned_source.sh"
if ( cd "$T" && fetch_source widget https://github.com/acme/widget.git 0123456789abcdef0123456789abcdef01234567 good X ) > "$T/out" 2>&1; then
  fail "fetched with a shipyard that has no fetch_pinned_source.sh"
fi
grep -q 'install a newer shipyard pkg' "$T/out" || fail "an old shipyard: $(cat "$T/out")"
[ ! -f "$T/git.log" ] || fail "ran git: $(cat "$T/git.log")"
echo "PASS"
