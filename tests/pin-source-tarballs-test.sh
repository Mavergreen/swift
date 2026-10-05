#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pin-source-tarballs-test.sh
#   scripts/pin-source-tarballs.sh must write into pins.env the SHA-256 of each pinned commit's tarball,
#   leaving every other line as it was; with --check, write nothing and fail naming a pin that is not its
#   tarball's; and refuse, writing nothing, a tarball that does not hold exactly its commit's files.
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
R="$T/repo"; mkdir -p "$R/scripts" "$T/shipyard" "$T/tarballs"
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
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
[ "\$1" = --url ] || exit 9
n="\${2##*/}"; n="\${n%.git}"
echo "file://$T/tarballs/\$n-\$3.tar.gz"
F
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
n="\${1##*/}"; n="\${n%.git}"
git clone -q "$T/up/\$n" "\$4" && [ "\$(git -C "\$4" rev-parse HEAD)" = "\$3" ]
F
pins() { SHIPYARD_SCRIPTS="$T/shipyard" sh "$R/scripts/pin-source-tarballs.sh" "$@"; }
sum() { shasum -a 256 < "$T/tarballs/$1-$2.tar.gz" | cut -c1-64; }

echo "-- writes each tarball's SHA-256, and nothing else"
cp "$R/pins.env" "$T/before"
pins > "$T/out" 2>&1 || fail "pin-source-tarballs.sh failed: $(cat "$T/out")"
grep -qx "LLVM_TARBALL_SHA256=\"$(sum llvm-project "$C_llvm_project")\"" "$R/pins.env" || fail "LLVM_TARBALL_SHA256: $(grep LLVM_TARBALL "$R/pins.env")"
grep -qx "SWIFT_TARBALL_SHA256=\"$(sum swift "$C_swift")\"" "$R/pins.env" || fail "SWIFT_TARBALL_SHA256: $(grep SWIFT_TARBALL "$R/pins.env")"
grep -qx "CMARK_TARBALL_SHA256=\"$(sum swift-cmark "$C_swift_cmark")\"" "$R/pins.env" || fail "CMARK_TARBALL_SHA256: $(grep CMARK_TARBALL "$R/pins.env")"
[ "$(diff "$T/before" "$R/pins.env" | grep -c '^[<>]')" = 6 ] || fail "changed more than the three pins: $(diff "$T/before" "$R/pins.env")"

echo "-- --check passes on them, and fails naming a stale one, writing nothing"
pins --check > "$T/out" 2>&1 || fail "--check failed on fresh pins: $(cat "$T/out")"
sed 's/^SWIFT_TARBALL_SHA256="[0-9a-f]*"/SWIFT_TARBALL_SHA256="0000000000000000000000000000000000000000000000000000000000000000"/' "$R/pins.env" > "$T/stale"
cp "$T/stale" "$R/pins.env"
if pins --check > "$T/out" 2>&1; then fail "--check passed a stale SWIFT_TARBALL_SHA256"; fi
grep -q "pins.env's SWIFT_TARBALL_SHA256 is 0000" "$T/out" || fail "did not name the stale pin: $(cat "$T/out")"
cmp -s "$T/stale" "$R/pins.env" || fail "--check wrote pins.env"

echo "-- a tarball that is not its commit's tree is refused, and nothing is written"
g="$T/up/swift"; mkdir -p "$T/fake/swift-$C_swift/sub"
echo "not swift" > "$T/fake/swift-$C_swift/sub/file.txt"; printf '#!/bin/sh\n' > "$T/fake/swift-$C_swift/run.sh"; chmod +x "$T/fake/swift-$C_swift/run.sh"
ln -s sub/file.txt "$T/fake/swift-$C_swift/link"
( cd "$T/fake" && tar cf - "swift-$C_swift" | gzip -n > "$T/tarballs/swift-$C_swift.tar.gz" )
if pins > "$T/out" 2>&1; then fail "pinned a tarball whose sub/file.txt is not the commit's"; fi
grep -q "is not commit $C_swift's tree" "$T/out" || fail "a tarball that is not the commit: $(cat "$T/out")"
cmp -s "$T/stale" "$R/pins.env" || fail "wrote pins.env although a tarball was not its commit's"

echo "-- a TERM ends it at once: exit 143, nothing written, no temp dir left"
mkdir -p "$T/tmp"; printf '#!/bin/sh\nkill -TERM $PPID\nsleep 1\nexit 1\n' > "$T/shipyard/clone_pinned.sh"
rc=0; TMPDIR="$T/tmp" pins > "$T/out" 2>&1 || rc=$?
[ "$rc" = 143 ] || fail "a TERM: exit $rc, not 143: $(cat "$T/out")"
cmp -s "$T/stale" "$R/pins.env" || fail "a TERM: wrote pins.env"
[ -z "$(ls -A "$T/tmp")" ] || fail "a TERM left $(ls -A "$T/tmp")"
echo "PASS"
