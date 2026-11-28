#!/bin/sh
# platform: host-agnostic
# usage: sh tests/make-selftest-importer-test.sh
#   make-selftest.sh's default mode (the swift.org compiler, whose swiftc is not this repo's wrapper) must hand
#   the compiler `-Xcc -ivfsoverlay -Xcc <yaml>` when RECAULK_IMPORTER names a toolchain's
#   lib/swift/recaulk-importer, the YAML lib.sh's recaulk_vfs_yaml writes for the 10.9 SDK and that directory,
#   then `-Xcc -ivfsoverlay -Xcc <json>` when SDK_VIEW names the SDK view the overlays were built with (a directory
#   recaulk-materialize made: -sdk its sdk/MacOSX10.9.sdk, which the YAML is then written for, and its overlay.json;
#   unset, the build root's overlays/sdk-view, when there; when not, a one-line warning naming it), and
#   `-Xcc -iapinotes-modules -Xcc <dir>` when APINOTES does, on every compile; none, when none is set and the build root has no overlays/ (else that root's importer directory, SDK view and apinotes); every compile has its own private -module-cache-path, which is removed;
#   a name that is no directory (no SDK view, for SDK_VIEW) is refused before anything is compiled; and no temporary YAML is left behind.
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
y=""; while [ \$# -gt 0 ]; do case "\$1" in -ivfsoverlay) [ -n "\$y" ] || y="\$3"; shift ;; -o) printf '#!/bin/sh\nexit 0\n' > "\$2"; chmod +x "\$2"; shift ;; esac; shift; done
[ -z "\$y" ] || cp "\$y" "$T/yaml-seen"
EOF2
chmod +x "$T/tc/usr/bin/swiftc"
# platform: the default mode with TC= is a Mac's (on Linux it takes SWIFT_HOST_TOOLCHAIN, whose importer flags are
#           the same); a fake uname makes it one on either host
unset SWIFT_HOST_TOOLCHAIN
mkdir -p "$T/darwin"; printf '#!/bin/sh\necho Darwin\n' > "$T/darwin/uname"; chmod +x "$T/darwin/uname"
run() {  # run <env assignments>... -- the default mode over the fake toolchain
  env PATH="$T/darwin:$PATH" TC="$T/tc/usr" SWIFT_WORK="$T/work" DIST="$T/dist" SELFTEST_SRC="$T/src" TMPDIR="$T/tmp" "$@" sh "$REPO/make-selftest.sh" > "$T/log" 2>&1
}

rm -f "$T/argv"
run || { cat "$T/log"; fail "make-selftest.sh failed with no importer"; }
! grep -q -e '-ivfsoverlay\|-iapinotes-modules' "$T/argv" || fail "importer flags without the variables: $(cat "$T/argv")"
[ "$(grep -c "$T/work/overlays/sdk-view" "$T/log")" = 1 ] \
  || fail "no one-line warning naming the missing SDK view: $(cat "$T/log")"

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

# Unset, the build root's own (build.sh leaves them under work/overlays), and always a private module cache.
grep -q '<-module-cache-path><' "$T/argv" || fail "no private -module-cache-path: $(cat "$T/argv")"
mkdir -p "$T/work/overlays/recaulk-importer" "$T/work/overlays/src/apinotes"
rm -f "$T/argv" "$T/yaml-seen"
run || { cat "$T/log"; fail "make-selftest.sh failed with the build root's importer"; }
while IFS= read -r line; do
  case "$line" in *"<-Xcc><-ivfsoverlay><-Xcc><"*"><-Xcc><-iapinotes-modules><-Xcc><$T/work/overlays/src/apinotes>"*) ;; *) fail "a compile lacks the build root's importer flags: $line" ;; esac
done < "$T/argv"
[ -s "$T/yaml-seen" ] || fail "the compiler read no YAML from the build root's importer"
[ -z "$(ls -A "$T/tmp")" ] || fail "a temporary file is left in TMPDIR: $(ls -A "$T/tmp")"
grep -q "$T/work/overlays/sdk-view" "$T/log" || fail "no warning naming the build root's missing SDK view: $(cat "$T/log")"

# The SDK view the overlays were built with: the build root's, its SDK the compile's and the YAML's, its overlay
# after the importer's YAML; SDK_VIEW overrides it.
V="$T/work/overlays/sdk-view"; OV="$T/other-view"
mkdir -p "$V/sdk/MacOSX10.9.sdk" "$OV/sdk/MacOSX10.9.sdk"; echo '{}' > "$V/overlay.json"; echo '{}' > "$OV/overlay.json"
rm -f "$T/argv" "$T/yaml-seen"
run || { cat "$T/log"; fail "make-selftest.sh failed with the build root's SDK view"; }
[ "$(grep -c . "$T/argv")" = 2 ] || fail "not two compiles (-O, -Onone): $(cat "$T/argv")"
while IFS= read -r line; do
  case "$line" in *"<-sdk><$V/sdk/MacOSX10.9.sdk>"*) ;; *) fail "a compile is not against the view's SDK: $line" ;; esac
  case "$line" in *"<-Xcc><-ivfsoverlay><-Xcc><"*"><-Xcc><-ivfsoverlay><-Xcc><$V/overlay.json><-Xcc><-iapinotes-modules><-Xcc><$T/work/overlays/src/apinotes>"*) ;;
    *) fail "a compile lacks the build root's SDK view after the importer's YAML: $line" ;; esac
done < "$T/argv"
recaulk_vfs_yaml "$V/sdk/MacOSX10.9.sdk" "$T/work/overlays/recaulk-importer" "$T/want-view.yaml" || fail "recaulk_vfs_yaml failed"
cmp -s "$T/want-view.yaml" "$T/yaml-seen" || fail "the importer's YAML is not lib.sh's for the view's SDK: $(cat "$T/yaml-seen")"
! grep -q "warning" "$T/log" || fail "warned of an SDK view that is there: $(cat "$T/log")"
rm -f "$T/argv"
run SDK_VIEW="$OV" || { cat "$T/log"; fail "make-selftest.sh failed with SDK_VIEW"; }
while IFS= read -r line; do
  case "$line" in *"<-sdk><$OV/sdk/MacOSX10.9.sdk>"*"<-ivfsoverlay><-Xcc><$OV/overlay.json>"*) ;; *) fail "SDK_VIEW did not override the build root's: $line" ;; esac
  case "$line" in *"$V/"*) fail "the build root's SDK view, though SDK_VIEW names another: $line" ;; esac
done < "$T/argv"
rm -rf "$T/work/overlays"

for v in RECAULK_IMPORTER APINOTES; do
  rm -f "$T/argv"
  if run "$v=$T/no-such-dir"; then fail "$v naming no directory was accepted"; fi
  grep -q "$T/no-such-dir" "$T/log" || fail "$v's missing directory was not named: $(cat "$T/log")"
  [ ! -e "$T/argv" ] || fail "compiled with $v naming no directory"
done
rm -f "$T/argv"
mkdir -p "$T/no-view"; echo '{}' > "$T/no-view/overlay.json"
if run SDK_VIEW="$T/no-view"; then fail "SDK_VIEW naming no SDK view was accepted"; fi
grep -q "$T/no-view" "$T/log" || fail "SDK_VIEW's missing view was not named: $(cat "$T/log")"
[ ! -e "$T/argv" ] || fail "compiled with SDK_VIEW naming no SDK view"
echo PASS
