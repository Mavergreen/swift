#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pin-source-tarballs-test.sh
#   scripts/pin-source-tarballs.sh must write into pins.env the SHA-256 of each pinned commit's tarball,
#   leaving every other line as it was; with --check, write nothing and fail naming a pin that is not its
#   tarball's; and refuse, writing nothing, a tarball that does not hold exactly its commit's files --
#   a changed byte, a .git anywhere (a directory or a gitdir file), an empty directory, a name that
#   differs only in case. pins.env is written once, after every row is verified: a later row's failure,
#   or a TERM, leaves it byte for byte as it was even when an earlier row's pin had moved, and leaves no
#   temp file behind. Its exits, which the pins bot relies on: 0 current (or written), 3 stale (--check),
#   1 any failure (a refused tarball, a failed fetch, a bad digest, an unset pin, a git failure), 2 usage,
#   143 TERM.
#   Offline: three fixture git repositories stand in for llvm-project, swift and swift-cmark, a fake
#   shipyard serves their tarballs (made as GitHub makes them, `git archive --prefix=<name>-<commit>/`)
#   and clones them, and a copy of the repo's pins.env names the fixtures' commits.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# platform: OS X 10.9's /usr/bin/git is a Command Line Tools stub, there whether or not they are installed.
git --version >/dev/null 2>&1 || { echo "no git that runs -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-source-tarballs.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
R="$T/repo"; mkdir -p "$R/scripts" "$T/shipyard" "$T/tarballs" "$T/tmp"
cp "$REPO/scripts/pin-source-tarballs.sh" "$R/scripts/"; cp "$REPO/lib.sh" "$REPO/msc.sh" "$R/"
for n in llvm-project swift swift-cmark; do
  g="$T/up/$n"; mkdir -p "$g/sub"
  git -C "$g" init -q; git -C "$g" config user.email t@t; git -C "$g" config user.name t
  echo "$n" > "$g/sub/file.txt"; printf '#!/bin/sh\n' > "$g/run.sh"; chmod +x "$g/run.sh"; ln -s sub/file.txt "$g/link"
  git -C "$g" add -A; git -C "$g" commit -qm "$n"
  c="$(git -C "$g" rev-parse HEAD)"
  git -C "$g" archive --format=tar --prefix="$n-$c/" HEAD | gzip -n > "$T/tarballs/$n-$c.tar.gz"
  eval "C_$(echo "$n" | tr '-' '_')=$c"
done
# pins.env as the repo has it, its three commits the fixtures'.
sed -e "s/^LLVM_SHA=\"[0-9a-f]*\"/LLVM_SHA=\"$C_llvm_project\"/" -e "s/^SWIFT_SHA=\"[0-9a-f]*\"/SWIFT_SHA=\"$C_swift\"/" \
    -e "s/^CMARK_SHA=\"[0-9a-f]*\"/CMARK_SHA=\"$C_swift_cmark\"/" "$REPO/pins.env" > "$R/pins.env"
# shipyard's --url exits 2 for a digest that is not 40 hex digits, as the real one does.
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
[ "\$1" = --url ] || exit 9
case "\$3" in *[!0-9a-f]*|'') echo "fetch_pinned_source: '\$3' is not a commit (40 hex digits)" >&2; exit 2 ;; esac
n="\${2##*/}"; n="\${n%.git}"
echo "file://$T/tarballs/\$n-\$3.tar.gz"
F
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
n="\${1##*/}"; n="\${n%.git}"
git clone -q "$T/up/\$n" "\$4" && [ "\$(git -C "\$4" rev-parse HEAD)" = "\$3" ]
F
cp "$T/shipyard/clone_pinned.sh" "$T/clone_pinned.sh"
pins() { TMPDIR="$T/tmp" SHIPYARD_SCRIPTS="$T/shipyard" sh "$R/scripts/pin-source-tarballs.sh" "$@"; }
run() { rc=0; pins "$@" > "$T/out" 2>&1 || rc=$?; }
want() { [ "$rc" = "$1" ] || fail "$2: exit $rc, not $1: $(cat "$T/out")"; }
sum() { shasum -a 256 < "$T/tarballs/$1-$2.tar.gz" | cut -c1-64; }
# What a run left behind: anything in its TMPDIR, or beside pins.env.
left() { ls -A "$T/tmp"; ls -A "$R" | grep -vx -e scripts -e lib.sh -e msc.sh -e pins.env || true; }
# swift's tarball: its commit's tree, changed by the shell command $1 run in it.
swift_tarball() {
  rm -rf "$T/fake"; mkdir -p "$T/fake"
  git -C "$T/up/swift" archive --format=tar --prefix="swift-$C_swift/" HEAD | tar xf - -C "$T/fake"
  ( cd "$T/fake/swift-$C_swift" && eval "$1" )
  ( cd "$T/fake" && tar cf - "swift-$C_swift" | gzip -n > "$T/tarballs/swift-$C_swift.tar.gz" )
}
Z=0000000000000000000000000000000000000000000000000000000000000000

echo "-- usage: exit 2, nothing written"
cp "$R/pins.env" "$T/before"
for a in --bogus "--check --check" "--check extra" -- -; do
  # shellcheck disable=SC2086  # the words are the arguments
  run $a; want 2 "usage [$a]"
  grep -q "^usage: " "$T/out" || fail "usage [$a] printed: $(cat "$T/out")"
done
cmp -s "$T/before" "$R/pins.env" || fail "a usage error wrote pins.env"

echo "-- writes each tarball's SHA-256, and nothing else: exit 0; again, unchanged: exit 0"
run; want 0 "a first run"
grep -qx "LLVM_TARBALL_SHA256=\"$(sum llvm-project "$C_llvm_project")\"" "$R/pins.env" || fail "LLVM_TARBALL_SHA256: $(grep LLVM_TARBALL "$R/pins.env")"
grep -qx "SWIFT_TARBALL_SHA256=\"$(sum swift "$C_swift")\"" "$R/pins.env" || fail "SWIFT_TARBALL_SHA256: $(grep SWIFT_TARBALL "$R/pins.env")"
grep -qx "CMARK_TARBALL_SHA256=\"$(sum swift-cmark "$C_swift_cmark")\"" "$R/pins.env" || fail "CMARK_TARBALL_SHA256: $(grep CMARK_TARBALL "$R/pins.env")"
[ "$(diff "$T/before" "$R/pins.env" | grep -c '^[<>]')" = 6 ] || fail "changed more than the three pins: $(diff "$T/before" "$R/pins.env")"
cp "$R/pins.env" "$T/after"; touch -t 200001010000 "$R/pins.env"
run; want 0 "a second run"
cmp -s "$T/after" "$R/pins.env" && [ -z "$(find "$R/pins.env" -newer "$T/after")" ] || fail "a second run, the pins current, rewrote pins.env"

echo "-- --check: exit 0 on current pins; exit 3 naming a stale one, writing nothing"
run --check; want 0 "--check on current pins"
sed "s/^SWIFT_TARBALL_SHA256=\"[0-9a-f]*\"/SWIFT_TARBALL_SHA256=\"$Z\"/" "$R/pins.env" > "$T/stale"
cp "$T/stale" "$R/pins.env"
run --check; want 3 "--check on a stale SWIFT_TARBALL_SHA256"
grep -q "pins.env's SWIFT_TARBALL_SHA256 is 0000" "$T/out" || fail "did not name the stale pin: $(cat "$T/out")"
cmp -s "$T/stale" "$R/pins.env" || fail "--check wrote pins.env"

echo "-- a tarball that is not its commit's tree is refused: exit 1, nothing written, nothing left"
# Each a tarball git status alone (with a macOS git's defaults) passes but for the first.
missed=""
while IFS= read -r m; do
  swift_tarball "$m"
  for mode in "" --check; do
    # shellcheck disable=SC2086  # "" is no argument
    run $mode
    if [ "$rc" != 1 ] || ! grep -q "is not commit $C_swift's tree" "$T/out"; then missed="$missed
  [$m] ${mode:-write}: exit $rc: $(tail -1 "$T/out")"; fi
    cmp -s "$T/stale" "$R/pins.env" || { missed="$missed
  [$m] ${mode:-write}: wrote pins.env"; cp "$T/stale" "$R/pins.env"; }
    [ -z "$(left)" ] || fail "[$m] $mode: left $(left)"
  done
done <<'M'
echo "not swift" > sub/file.txt
mkdir -p .git/hooks && echo x > .git/hooks/x
mkdir sub/.git && echo x > sub/.git/config
echo "gitdir: /elsewhere" > sub/.git
mkdir empty
mv run.sh RUN.sh
M
[ -z "$missed" ] || fail "tarballs not their commit's tree, not refused:$missed"

echo "-- a later row's failure writes nothing, though an earlier row's pin had moved"
sed "s/^LLVM_TARBALL_SHA256=\"[0-9a-f]*\"/LLVM_TARBALL_SHA256=\"$Z\"/" "$T/stale" > "$T/stale2"
cp "$T/stale2" "$R/pins.env"
swift_tarball "echo 'not swift' > sub/file.txt"
run; want 1 "swift's tarball not its commit's, after a moved LLVM pin"
grep -q "is not commit $C_swift's tree" "$T/out" || fail "swift's tarball, after a moved LLVM pin: $(cat "$T/out")"
cmp -s "$T/stale2" "$R/pins.env" || fail "wrote LLVM's pin although swift's tarball was not its commit's: $(diff "$T/stale2" "$R/pins.env")"
[ -z "$(left)" ] || fail "a failed run left $(left)"
# swift's real tarball back; swift-cmark's (the last row) gone, so its fetch fails after two pins moved.
swift_tarball true
mv "$T/tarballs/swift-cmark-$C_swift_cmark.tar.gz" "$T/cmark.tar.gz"
run; want 1 "swift-cmark's tarball unfetchable"
grep -q "could not fetch .*swift-cmark-$C_swift_cmark" "$T/out" || fail "swift-cmark's fetch: $(cat "$T/out")"
cmp -s "$T/stale2" "$R/pins.env" || fail "wrote pins.env although swift-cmark's fetch failed: $(diff "$T/stale2" "$R/pins.env")"
[ -z "$(left)" ] || fail "a failed run left $(left)"
mv "$T/cmark.tar.gz" "$T/tarballs/swift-cmark-$C_swift_cmark.tar.gz"

echo "-- every other failure is exit 1 too, never a command's own 2 or 128: nothing written, nothing left"
# shipyard's --url refuses a digest (its exit 2).
sed 's/^CMARK_SHA="[0-9a-f]*"/CMARK_SHA="nope"/' "$T/stale2" > "$T/bad"; cp "$T/bad" "$R/pins.env"
run; want 1 "a malformed CMARK_SHA"
grep -q "'nope' is not a commit" "$T/out" || fail "a malformed CMARK_SHA: $(cat "$T/out")"
cmp -s "$T/bad" "$R/pins.env" || fail "a malformed CMARK_SHA: wrote pins.env"
# A pin line missing.
grep -v '^CMARK_TARBALL_SHA256=' "$T/stale2" > "$T/bad"; cp "$T/bad" "$R/pins.env"
for mode in "" --check; do
  # shellcheck disable=SC2086  # "" is no argument
  run $mode; want 1 "no CMARK_TARBALL_SHA256 line ${mode:-write}"
  cmp -s "$T/bad" "$R/pins.env" || fail "no CMARK_TARBALL_SHA256 line: wrote pins.env"
done
cp "$T/stale2" "$R/pins.env"
# git fails (its exit 128): the clone is no repository.
printf '#!/bin/sh\nmkdir -p "$4"\n' > "$T/shipyard/clone_pinned.sh"
run; want 1 "git status with no repository"
cmp -s "$T/stale2" "$R/pins.env" || fail "a git failure: wrote pins.env"
[ -z "$(left)" ] || fail "a git failure left $(left)"
# A pins.env the shell cannot finish: an unset name under set -u, a fatal error whose own status is 2
# in dash and, by the time an EXIT trap reads it, 0 in macOS's bash 3.2 sh -- "current", unless mapped.
{ cat "$T/stale2"; echo 'X="${NOT_SET_ANYWHERE}"'; } > "$T/bad"; cp "$T/bad" "$R/pins.env"
for mode in "" --check; do
  # shellcheck disable=SC2086  # "" is no argument
  run $mode; want 1 "an unset name in pins.env ${mode:-write}"
  cmp -s "$T/bad" "$R/pins.env" || fail "an unset name in pins.env: wrote pins.env"
done
cp "$T/stale2" "$R/pins.env"

echo "-- a TERM ends it at once: exit 143, nothing written though LLVM's pin had moved, no temp file left"
# LLVM's row runs whole; the TERM comes in swift's (the second) row.
{ printf '#!/bin/sh\ncase "$1" in */swift.git) kill -TERM $PPID; sleep 1; exit 1 ;; esac\n'; sed 1d "$T/clone_pinned.sh"; } > "$T/shipyard/clone_pinned.sh"
run; want 143 "a TERM"
[ "$(grep -c "(the commit's tree, file for file)" "$T/out")" = 1 ] || fail "a TERM: LLVM's row did not run first: $(cat "$T/out")"
cmp -s "$T/stale2" "$R/pins.env" || fail "a TERM: wrote pins.env: $(diff "$T/stale2" "$R/pins.env")"
[ -z "$(left)" ] || fail "a TERM left $(left)"
echo "PASS"
