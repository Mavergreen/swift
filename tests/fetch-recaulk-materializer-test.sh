#!/bin/sh
# platform: host-agnostic
# usage: sh tests/fetch-recaulk-materializer-test.sh
#   fetch-recaulk.sh --materializer prints the recaulk-materialize this host runs: on a Mac (a faked uname)
#   the fetched pkg prefix's, and on Linux, which cannot run that Mach-O, the one in the same release's
#   linux-x86_64 archive, which shipyard's fetch_product_tar.sh unpacks under the Recaulk cache; a shipyard
#   without fetch_product_tar.sh is refused, naming it. With no argument it prints the pkg's prefix, as
#   before, on both hosts; any other argument is a usage error (2). Everything is faked.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-recaulk-materializer.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/pins.env"   # -> RECAULK_VERSION
mkdir -p "$T/shipyard" "$T/fakebin"
# The pkg: a prefix with the files fetch-recaulk.sh checks, and a recaulk-materialize.
cat > "$T/shipyard/fetch_product_pkg.sh" <<'F'
#!/bin/sh
d="$3"; mkdir -p "$d/lib" "$d/share/recaulk" "$d/bin"
: > "$d/lib/librecaulk.a"; : > "$d/share/recaulk/notices.tsv"; : > "$d/share/recaulk/image-local-shadows.txt"
printf '#!/bin/sh\necho mach-o\n' > "$d/bin/recaulk-materialize"; chmod +x "$d/bin/recaulk-materialize"
F
# The Linux archive: says what it was asked for, then its prefix last, as shipyard's does.
cat > "$T/shipyard/fetch_product_tar.sh" <<F
#!/bin/sh
echo "tar \$*" >> "$T/log"
mkdir -p "\$3/bin"; printf '#!/bin/sh\necho elf\n' > "\$3/bin/recaulk-materialize"; chmod +x "\$3/bin/recaulk-materialize"
echo "\$3"
F
printf '#!/bin/sh\n[ "$1" = -s ] && echo "$FAKE_UNAME" || exec /usr/bin/uname "$@"\n' > "$T/fakebin/uname"
printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/pkgutil"
chmod +x "$T/fakebin/uname" "$T/fakebin/pkgutil"
run() { # <uname> <args...> -> OUT, RC
  _u="$1"; shift; rm -rf "$T/cache"; rc=0
  OUT="$(PATH="$T/fakebin:$PATH" FAKE_UNAME="$_u" SHIPYARD_SCRIPTS="$T/shipyard" MAVERGREEN_RECAULK_CACHE="$T/cache" \
    sh "$REPO/fetch-recaulk.sh" "$@" 2>&1)" || rc=$?
  RC=$rc
}

echo "-- a Mac: the pkg prefix's recaulk-materialize; no archive fetched"
: > "$T/log"; run Darwin --materializer
[ "$RC" = 0 ] && [ "$OUT" = "$T/cache/$RECAULK_VERSION/recaulk/bin/recaulk-materialize" ] || fail "Mac: rc=$RC: $OUT"
[ ! -s "$T/log" ] || fail "Mac: fetched the Linux archive: $(cat "$T/log")"

echo "-- Linux: the linux-x86_64 archive's, at the pinned release, under the Recaulk cache"
: > "$T/log"; run Linux --materializer
[ "$RC" = 0 ] && [ "$OUT" = "$T/cache/$RECAULK_VERSION/recaulk-linux/bin/recaulk-materialize" ] || fail "Linux: rc=$RC: $OUT"
[ "$("$OUT")" = elf ] || fail "Linux: not the archive's binary"
grep -qx "tar recaulk $RECAULK_VERSION $T/cache/$RECAULK_VERSION/recaulk-linux" "$T/log" || fail "Linux: asked for [$(cat "$T/log")]"

echo "-- no argument: the pkg's prefix, on both hosts"
for u in Darwin Linux; do
  run "$u"
  [ "$RC" = 0 ] && [ "$OUT" = "$T/cache/$RECAULK_VERSION/recaulk" ] || fail "$u prefix: rc=$RC: $OUT"
done

echo "-- Linux with a shipyard that has no fetch_product_tar.sh: refused, naming it"
mv "$T/shipyard/fetch_product_tar.sh" "$T/fpt"
run Linux --materializer
[ "$RC" != 0 ] || fail "no fetch_product_tar.sh: accepted: $OUT"
case "$OUT" in *fetch_product_tar.sh*) ;; *) fail "no fetch_product_tar.sh: not named: $OUT" ;; esac
mv "$T/fpt" "$T/shipyard/fetch_product_tar.sh"

echo "-- any other argument: usage, 2"
run Darwin --nonesuch
[ "$RC" = 2 ] || fail "--nonesuch: rc=$RC: $OUT"

echo "PASS: fetch-recaulk-materializer-test"
