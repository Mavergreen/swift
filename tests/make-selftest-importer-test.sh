#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-importer-test.sh
#   make-selftest.sh's default mode (the swift.org compiler, whose swiftc is not this repo's wrapper) must hand
#   the compiler `-Xcc -ivfsoverlay -Xcc <yaml>` when RECAULK_IMPORTER names a toolchain's
#   lib/swift/recaulk-importer, the YAML lib.sh's recaulk_vfs_yaml writes for the 10.9 SDK and that directory,
#   and `-Xcc -iapinotes-modules -Xcc <dir>` when APINOTES does, on every compile; neither, when neither is set;
#   a name that is no directory is refused before anything is compiled; and no temporary YAML is left behind.
#   A fake compiler records its arguments and reads the YAML while it runs. SKIPs without a shipyard.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
( . "$REPO/msc.sh" ) >/dev/null 2>&1 || { echo "no shipyard -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/make-selftest-importer.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/msc.sh"
SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || { echo "no 10.9 SDK -- skipping"; exit 77; }
mkdir -p "$T/tc/usr/bin" "$T/work/stdlib-build/lib/swift/macosx/x86_64" "$T/src" "$T/imp" "$T/apn" "$T/tmp"
: > "$T/work/stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib"
printf 'print(1)\n' > "$T/src/t.swift"
cat > "$T/tc/usr/bin/swiftc" <<EOF2
#!/bin/sh
printf '<%s>' "\$@" >> "$T/argv"; echo >> "$T/argv"
y=""; while [ \$# -gt 0 ]; do case "\$1" in -ivfsoverlay) y="\$3"; shift ;; -o) printf '#!/bin/sh\nexit 0\n' > "\$2"; chmod +x "\$2"; shift ;; esac; shift; done
[ -z "\$y" ] || cp "\$y" "$T/yaml-seen"
EOF2
chmod +x "$T/tc/usr/bin/swiftc"
run() {  # run <env assignments>... -- the default mode over the fake toolchain
  env TC="$T/tc/usr" SWIFT_WORK="$T/work" DIST="$T/dist" SELFTEST_SRC="$T/src" TMPDIR="$T/tmp" "$@" sh "$REPO/make-selftest.sh" > "$T/log" 2>&1
}

rm -f "$T/argv"
run || { cat "$T/log"; fail "make-selftest.sh failed with no importer"; }
! grep -q -e '-ivfsoverlay\|-iapinotes-modules' "$T/argv" || fail "importer flags without the variables: $(cat "$T/argv")"

rm -f "$T/argv" "$T/yaml-seen"
run RECAULK_IMPORTER="$T/imp" APINOTES="$T/apn" || { cat "$T/log"; fail "make-selftest.sh failed with the importer"; }
[ "$(grep -c . "$T/argv")" = 2 ] || fail "not two compiles (-O, -Onone): $(cat "$T/argv")"
while IFS= read -r line; do
  case "$line" in *"<-Xcc><-ivfsoverlay><-Xcc><"*"><-Xcc><-iapinotes-modules><-Xcc><$T/apn>"*) ;; *) fail "a compile lacks the flags: $line" ;; esac
done < "$T/argv"
. "$REPO/lib.sh"
recaulk_vfs_yaml "$SDK" "$T/imp" "$T/want.yaml" || fail "recaulk_vfs_yaml failed"
cmp -s "$T/want.yaml" "$T/yaml-seen" || fail "the compiler read another YAML than lib.sh's: $(cat "$T/yaml-seen")"
[ -z "$(ls -A "$T/tmp")" ] || fail "a temporary file is left in TMPDIR: $(ls -A "$T/tmp")"

for v in RECAULK_IMPORTER APINOTES; do
  rm -f "$T/argv"
  if run "$v=$T/no-such-dir"; then fail "$v naming no directory was accepted"; fi
  grep -q "$T/no-such-dir" "$T/log" || fail "$v's missing directory was not named: $(cat "$T/log")"
  [ ! -e "$T/argv" ] || fail "compiled with $v naming no directory"
done
echo PASS
