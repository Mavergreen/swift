#!/bin/sh
# platform: host-agnostic
# usage: sh tests/vm-test-workflow-test.sh
#   Every run is accepted on Mac OS X 10.9 by release.yml's vm-test job (id and name vm-test, the required check;
#   needing version, build-cross and build; publish waits for it), in bundle_mode compile, and every push's Linux
#   runtime by linux-runtime.yml's vm-test-prebuilt, in prebuilt. Each job checks out, fetches what its guest
#   installs with .github/actions/vm-test, and boots Mavergreen/mavericks-vm's guest in a step of its own, so the
#   job itself holds the VM step, its key, its runner, its timeout and its permissions; the action holds no secret.
#   compile, the release gate: the action downloads swift-cross and swift-native and the previous release; the guest
#   installs libcxx22 and the previous release's runtime and native toolchain pkgs, then this run's over them, holds
#   both receipts to the run's version, runs `mavergreen check`, builds the self-test bundle there with the installed
#   swiftc, upstream's tests in it from swift-cross's selftest-support/ (which build-cross uploads), installs
#   Longboat's latest release and mavericks-clang-22 (whose pkg requires Longboat) before that build, runs the
#   bundle's --loads and then its gate, and then the native toolchain smoke, a SKIP of which fails. bundle_mode is
#   checked first, compile or prebuilt and nothing else, and a publishing run never takes prebuilt. prebuilt
#   (iteration only): the action downloads neither swift-cross nor swift-native nor the previous release, only the
#   artifact its caller names (a runtime pkg and the bundle built beside it, the same run's); the guest installs
#   libcxx22 and that runtime pkg alone, holds its receipt, checks the install, launches the runtime's updater once
#   (dyld must bind every import), installs Longboat, its 10.9 SDK and clang22 (FileCheck), and runs the bundle's
#   --loads and then, only if that passed, its --gate: no compile in the guest, no toolchain, no smoke. The build
#   job runs no Rosetta smoke. Each check is run against a file mutated to break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vm-test-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# guest <job file> <out> -- the job's Mavergreen/mavericks-vm step
guest() { awk '/^      - / { if (s) exit; buf = "" } { buf = buf $0 "\n" } /^        uses: Mavergreen\/mavericks-vm@v1$/ { s = 1; printf "%s", buf; next } s' "$1" > "$2"; }

# check <release.yml> <action.yml> <linux-runtime.yml>
check() {
  awk '/^  vm-test:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/rj"
  [ -s "$T/rj" ] || { echo "release.yml has no vm-test job"; return 1; }
  awk '/^  vm-test-prebuilt:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$3" > "$T/lj"
  [ -s "$T/lj" ] || { echo "linux-runtime.yml has no vm-test-prebuilt job"; return 1; }
  grep -qx '    name: vm-test' "$T/rj" || { echo "release.yml's vm-test job is not named vm-test, the required check"; return 1; }
  grep -qx '    needs: \[version, build-cross, build\]' "$T/rj" || { echo "vm-test does not need build-cross and build"; return 1; }
  for j in rj lj; do
    grep -qx '    runs-on: ubuntu-latest' "$T/$j" || { echo "a 10.9 gate job ($j) does not run on ubuntu-latest"; return 1; }
    grep -qE '^    timeout-minutes: 335( |$)' "$T/$j" || { echo "a 10.9 gate job ($j) has not vm-test's 335-minute timeout"; return 1; }
    grep -qx '      packages: write' "$T/$j" && grep -qx '      contents: read' "$T/$j" || { echo "a 10.9 gate job ($j) is not given contents: read and packages: write"; return 1; }
    awk '/uses: actions\/checkout@/ { c = NR } /^        uses: \.\/\.github\/actions\/vm-test$/ { a = NR } /^        uses: Mavergreen\/mavericks-vm@v1$/ { v = NR }
         END { exit !(c && c < a && a < v) }' "$T/$j" || { echo "a 10.9 gate job ($j) does not check out, fetch with .github/actions/vm-test, then boot the guest"; return 1; }
    grep -qx '          image-key: ${{ secrets.MAVERICKS_VM_KEY }}' "$T/$j" || { echo "a 10.9 gate job ($j) does not boot the VM with its key"; return 1; }
  done
  grep -qx '          bundle_mode: compile' "$T/rj" || { echo "release.yml's vm-test is not bundle_mode compile"; return 1; }
  grep -qx '          publish: ${{ needs.version.outputs.publish }}' "$T/rj" || { echo "release.yml's vm-test does not tell the action whether the run publishes"; return 1; }
  grep -qx '          bundle_mode: prebuilt' "$T/lj" || { echo "vm-test-prebuilt is not bundle_mode prebuilt"; return 1; }
  if awk '/^  workflow_dispatch:$/ { w = 1; next } w && /^(  )?[a-z]/ { w = 0 } w' "$1" | grep -q bundle_mode; then
    echo "release.yml still takes a bundle_mode from a dispatch: its vm-test is the release gate, compile alone"; return 1; fi
  guest "$T/rj" "$T/compile"; guest "$T/lj" "$T/prebuilt"
  [ -s "$T/compile" ] || { echo "release.yml's vm-test has no guest step"; return 1; }
  [ -s "$T/prebuilt" ] || { echo "vm-test-prebuilt has no guest step"; return 1; }
  # The action: what each mode fetches, the mode checked first, no VM and no secret of its own.
  awk '/^  steps:$/ { s = 1; next } s' "$2" | sed 's/^/  /' > "$T/act"
  grep -qx '  using: composite' "$2" || { echo "the vm-test action is not a composite action"; return 1; }
  if grep -q 'uses: *Mavergreen/mavericks-vm\|secrets\.' "$2"; then echo "the vm-test action boots the VM or reads a secret: the job does"; return 1; fi
  awk '/^      - / { if (s && !sh) bad = 1; s = 0; sh = 0 } /^        run: / { s = 1 } /^        shell: / { sh = 1 } END { if (s && !sh) bad = 1; exit bad }' "$T/act" \
    || { echo "a run step of the vm-test action names no shell"; return 1; }
  rm -f "$T"/step.*
  awk -v d="$T" '/^      - / { n++ } n { print > (d "/step." n) }' "$T/act"
  : > "$T/cdl"; : > "$T/pdl"
  for f in "$T"/step.*; do
    if grep -qx "        if: inputs.bundle_mode == 'compile'" "$f"; then m=compile; elif grep -qx "        if: inputs.bundle_mode == 'prebuilt'" "$f"; then m=prebuilt; else m=both; fi
    if grep -q 'actions/download-artifact@\|gh release download "\$prev"' "$f"; then
      case "$m" in compile) cat "$f" >> "$T/cdl" ;; prebuilt) cat "$f" >> "$T/pdl" ;; *) echo "a download runs in both modes: $(head -1 "$f")"; return 1 ;; esac; fi
  done
  grep -q 'name: swift-cross, path: dist' "$T/cdl" && grep -q 'name: swift-native, path: dist' "$T/cdl" && grep -q 'gh release download "\$prev"' "$T/cdl" \
    || { echo "compile mode does not download swift-cross, swift-native and the previous release"; return 1; }
  grep -qx '          name: ${{ inputs.prebuilt_artifact }}' "$T/pdl" && grep -qx '          path: dist' "$T/pdl" || { echo "prebuilt mode does not download its caller's artifact into dist/"; return 1; }
  if grep -q 'swift-cross\|swift-native\|\$prev' "$T/pdl"; then echo "prebuilt mode downloads a macOS job's artifact or the previous release"; return 1; fi
  awk '/^  bundle_mode:$/ { b = 1; next } b && /^  [a-z_]+:$/ { b = 0 } b' "$2" | grep -qx '    required: true' \
    || { echo "the vm-test action has no required bundle_mode input"; return 1; }
  grep -qx '          BUNDLE_MODE: ${{ inputs.bundle_mode }}' "$T/act" && grep -qx '          PUBLISH: ${{ inputs.publish }}' "$T/act" || { echo "the mode check does not read the action's inputs"; return 1; }
  awk '/^      - / { n++ } /case "\$BUNDLE_MODE" in compile\|prebuilt\) ;; \*\) / && /exit 1/ { c = n } /actions\/download-artifact|gh release/ && !d { d = n } END { exit !(c && c < d) }' "$T/act" \
    || { echo "the vm-test action does not refuse a bundle_mode other than compile or prebuilt before it does anything"; return 1; }
  grep -q '\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || ' "$T/act" || { echo "the vm-test action lets a publishing run gate a prebuilt bundle"; return 1; }
  grep -q 'gh release download "\$prev" -R "\$GITHUB_REPOSITORY" -p "swift-runtime-\$prev.pkg" -p "swift-toolchain-\$prev.pkg" -p SHA256SUMS' "$T/act" \
    || { echo "the vm-test action does not fetch the previous release's pkgs"; return 1; }
  grep -q 'gh release download "\$v" -R Mavergreen/clang-22 -p "libcxx22-\$v.pkg" -p SHA256SUMS' "$T/act" \
    && grep -q 'sha256sum -c -' "$T/act" || { echo "the vm-test action does not fetch and verify libcxx22 at the pinned release"; return 1; }
  grep -q 'gh release download "\$lb" -R Mavergreen/longboat -p "longboat-\$lb.pkg" -p SHA256SUMS' "$T/act" \
    && grep -q 'grep " longboat-\$lb.pkg\\\$" SHA256SUMS | sha256sum -c -' "$T/act" \
    || { echo "the vm-test action does not fetch and verify Longboat"; return 1; }
  # prebuilt: the runtime pkg alone, its receipt, the install checked, the updater launched, clang22 (FileCheck), --loads, then --gate.
  awk '/install libcxx\/libcxx22-\*\.pkg dist\/swift-runtime-\*\.pkg$/ { a = NR }
       /\/usr\/local\/bin\/mavergreen check$/ { c = NR }
       /DYLD_BIND_AT_LAUNCH=1 "\$u" --background/ { u = NR }
       /install longboat\/longboat-\[0-9\]\*\.pkg$/ { l = NR }
       /sudo \/usr\/local\/mavergreen\/bin\/longboat sdk install 10\.9$/ { d = NR }
       /install clang22\/mavericks-clang-22-native-\*\.pkg$/ { k = NR }
       /tar -xzf \.\.\/dist\/swift-runtime-selftest\.tar\.gz/ { x = NR }
       END { exit !(a && a < c && c < u && u < l && l < d && d < k && k <= x) }' "$T/prebuilt" \
    || { echo "prebuilt mode does not install libcxx22 and the runtime pkg, check the install, launch the updater, install Longboat, its 10.9 SDK and clang22, then unpack the bundle, in that order"; return 1; }
  grep -qF "pkgutil --files dev.mavergreen.swift-runtime | grep 'swift-runtime-updater\\.app/Contents/MacOS/swift-runtime-updater\$'" "$T/prebuilt" && grep -q '! grep -q .^dyld: .' "$T/prebuilt" \
    || { echo "prebuilt mode does not find the runtime's updater in its receipt and fail when dyld cannot load it"; return 1; }
  grep -qF 'got="$(pkgutil --pkg-info dev.mavergreen.swift-runtime | sed -n '"'s/^version: //p'"')"' "$T/prebuilt" && grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/prebuilt" \
    && grep -qx '          SWIFT_FULL_VERSION: ${{ needs.build.outputs.version }}' "$T/prebuilt" \
    || { echo "prebuilt mode does not hold the runtime's receipt to the build's version"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --loads &&$' "$T/prebuilt" && grep -q '^ *sh swift-runtime-selftest/run-selftest\.sh --gate )$' "$T/prebuilt" \
    && awk '/run-selftest\.sh --loads/ { l = NR } /run-selftest\.sh --gate/ { g = NR } END { exit !(l && l < g) }' "$T/prebuilt" \
    || { echo "prebuilt mode does not run the bundle's --loads and then, only if it passed, its --gate"; return 1; }
  if grep -q 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt"; then
    echo "prebuilt mode compiles in the guest, installs a toolchain or runs the toolchain smoke: $(grep 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt")"; return 1; fi
  # compile: the order of the guest script's lines is the order things happen in.
  awk '/install libcxx\/libcxx22-\*\.pkg prev\/swift-runtime-\*\.pkg prev\/swift-toolchain-\[0-9\]\*\.pkg$/ { a = NR }
       /install dist\/swift-runtime-\*\.pkg dist\/swift-toolchain-\[0-9\]\*\.pkg$/ { b = NR }
       /\/usr\/local\/bin\/mavergreen check$/ { c = NR }
       /sh make-selftest\.sh$/ { m = NR }
       /run-selftest\.sh --gate/ { g = NR }
       /install longboat\/longboat-\[0-9\]\*\.pkg$/ { l = NR }
       /sudo \/usr\/local\/mavergreen\/bin\/longboat sdk install 10\.9$/ { d = NR }
       /install clang22\/mavericks-clang-22-native-\*\.pkg$/ { k = NR }
       /sh tests\/toolchain-smoke-test\.sh/ { s = NR }
       END { exit !(a && a < b && b < c && c < l && l < d && d < k && k < m && m < g && g < s) }' "$T/compile" \
    || { echo "vm-test does not install libcxx22 and the previous release, then this run's, check the install, install Longboat, its 10.9 SDK and clang22 (FileCheck is the gate's), build the self-test, gate, then smoke, in that order"; return 1; }
  grep -q 'sudo installer -pkg' "$T/compile" || { echo "vm-test installs nothing"; return 1; }
  grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/compile" && grep -qx '          SWIFT_FULL_VERSION: ${{ needs.version.outputs.version }}' "$T/compile" \
    || { echo "vm-test does not hold the upgraded receipts to this run's version"; return 1; }
  grep -q '\[ "\$rc" -ne 77 \]' "$T/compile" || { echo "vm-test lets the native toolchain smoke skip"; return 1; }
  grep -q 'SWIFTC=/usr/local/mavergreen/bin/swiftc .*sh make-selftest\.sh' "$T/compile" || { echo "vm-test does not build the self-test with the installed swiftc"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --gate' "$T/compile" || { echo "vm-test does not run the self-test's gate"; return 1; }
  grep -q 'SELFTEST_SUPPORT="\$PWD/dist/selftest-support" .*sh make-selftest\.sh' "$T/compile" \
    || { echo "vm-test does not build upstream's tests into the bundle (SELFTEST_SUPPORT=dist/selftest-support)"; return 1; }
  awk '/run-selftest\.sh --loads/ { l = NR } /run-selftest\.sh --gate/ { g = NR } END { exit !(l && l <= g) }' "$T/compile" \
    || { echo "vm-test does not run the bundle's --loads before its --gate"; return 1; }
  awk '/^  build-cross:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" | grep -q '^            \${{ env.SWIFT_BUILD }}/dist/selftest-support$' \
    || { echo "build-cross does not upload the self-test's support in swift-cross"; return 1; }
  awk '/^  publish:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" | grep -q '^    needs: \[.*vm-test.*\]$' \
    || { echo "publish does not wait for vm-test"; return 1; }
  if grep -qi 'rosetta\|arch -x86_64' "$1" "$2" "$3"; then echo "a workflow still runs something under Rosetta"; return 1; fi
}

R="$REPO/.github/workflows/release.yml"; A="$REPO/.github/actions/vm-test/action.yml"; L="$REPO/.github/workflows/linux-runtime.yml"
[ -f "$A" ] || fail "no .github/actions/vm-test/action.yml"
[ ! -e "$REPO/.github/workflows/vm-test.yml" ] || fail ".github/workflows/vm-test.yml is still here: the action replaced it"
check "$R" "$A" "$L" > "$T/why" || fail "$(cat "$T/why")"

mk() { sed "$3" "$2" > "$T/m.yml"; cmp -s "$2" "$T/m.yml" && fail "the mutant where $1 changed nothing"; :; }
amutant() { mk "$1" "$A" "$2"; if check "$R" "$T/m.yml" "$L" > "$T/why"; then fail "the check passed an action where $1"; fi; }
rmutant() { mk "$1" "$R" "$2"; if check "$T/m.yml" "$A" "$L" > "$T/why"; then fail "the check passed a release.yml where $1"; fi; }
lmutant() { mk "$1" "$L" "$2"; if check "$R" "$A" "$T/m.yml" > "$T/why"; then fail "the check passed a linux-runtime.yml where $1"; fi; }
rmutant "vm-test is gone" 's/^  vm-test:$/  vm-gone:/'
rmutant "vm-test's check is renamed" 's/^    name: vm-test$/    name: vm-test (compile)/'
rmutant "vm-test needs only build" 's/^    needs: \[version, build-cross, build\]$/    needs: [build]/'
rmutant "release.yml gates a prebuilt bundle" 's/^          bundle_mode: compile$/          bundle_mode: prebuilt/'
rmutant "the action is told the run never publishes" 's/^          publish: \${{ needs.version.outputs.publish }}$/          publish: false/'
rmutant "a dispatch picks the bundle again" 's/^      local_release:$/      bundle_mode:\
        type: string\
      local_release:/'
rmutant "build-cross uploads no self-test support" '/^            \${{ env.SWIFT_BUILD }}\/dist\/selftest-support$/d'
rmutant "publish does not wait for vm-test" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan]/'
rmutant "the build job smokes under Rosetta again" 's|^      - name: Build swift-runtime-updater.app|      - name: Toolchain smoke under Rosetta\
        run: true\
      - name: Build swift-runtime-updater.app|'
rmutant "vm-test boots no VM" 's|Mavergreen/mavericks-vm@v1|actions/checkout@v7|'
rmutant "vm-test fetches without the action" 's|^        uses: ./.github/actions/vm-test$|        uses: ./.github/actions/other|'
rmutant "vm-test has a shorter timeout" 's/^    timeout-minutes: 335 .*/    timeout-minutes: 60/'
rmutant "vm-test installs nothing" 's/sudo installer -pkg/echo installer -pkg/'
rmutant "vm-test installs no libcxx22" 's|libcxx/libcxx22-\*\.pkg ||'
rmutant "vm-test does not upgrade from the previous release" 's| prev/swift-runtime-\*\.pkg prev/swift-toolchain-\[0-9\]\*\.pkg$||'
rmutant "the upgraded receipts are not checked" 's/\[ "\$got" = "\$SWIFT_FULL_VERSION" \]/true/'
rmutant "the family install is not checked" 's|/usr/local/bin/mavergreen check$|true|'
rmutant "clang22 is installed only after the gate" '/^            install clang22\/mavericks-clang-22-native-\*\.pkg$/d; s|^\(              sh swift-runtime-selftest/run-selftest.sh --gate )\)$|\1\
            install clang22/mavericks-clang-22-native-*.pkg|'
rmutant "Longboat is not installed before clang22" '/^            install longboat\/longboat-\[0-9\]\*\.pkg$/d'
rmutant "the 10.9 SDK is not installed before clang22" '/longboat sdk install 10\.9$/d'
rmutant "the native smoke does not run" 's|sh tests/toolchain-smoke-test\.sh|true|'
rmutant "the native smoke may skip" 's/\[ "\$rc" -ne 77 \]/true/'
rmutant "the self-test is built by another swiftc" 's|SWIFTC=/usr/local/mavergreen/bin/swiftc |SWIFTC=/tmp/swiftc |'
rmutant "the gate is not run" 's/run-selftest\.sh --gate/run-selftest.sh/'
rmutant "the bundle has no upstream tests" 's|SELFTEST_SUPPORT="\$PWD/dist/selftest-support" ||'
rmutant "--loads is not run" 's/run-selftest\.sh --loads &&/true \&\&/'
amutant "the previous release goes unfetched" 's|gh release download "\$prev"|echo "$prev"|'
amutant "Longboat goes unfetched" 's|gh release download "\$lb"|echo "$lb"|'
amutant "Longboat goes unverified" 's/grep " longboat-\$lb.pkg\\\$" SHA256SUMS | sha256sum -c -/true/'
amutant "libcxx22 goes unverified" 's/| sha256sum -c -/| cat/'
amutant "bundle_mode is optional" '/^  bundle_mode:$/,/^  publish:$/ s/^    required: true$/    required: false/'
amutant "a mode outside the allow-list goes unrefused" 's/case "\$BUNDLE_MODE" in compile|prebuilt) ;; \*) /case "$BUNDLE_MODE" in *) ;; compile|prebuilt) /'
amutant "a publishing run may gate a prebuilt bundle" 's/\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || /true || /'
# afirst <why> <line> -- the action with the first line that is exactly <line> deleted
afirst() { awk -v l="$2" '!d && $0 == l { d = 1; next } { print }' "$A" > "$T/m.yml"; cmp -s "$A" "$T/m.yml" && fail "the mutant where $1 changed nothing"
  if check "$R" "$T/m.yml" "$L" > "$T/why"; then fail "the check passed an action where $1"; fi; }
afirst "a compile download runs in prebuilt mode too" "      if: inputs.bundle_mode == 'compile'"
amutant "the prebuilt bundle is not downloaded" 's/^        name: \${{ inputs.prebuilt_artifact }}$/        name: swift-other/'
amutant "prebuilt mode downloads build-cross's pkgs" 's/^        name: \${{ inputs.prebuilt_artifact }}$/        name: swift-cross/'
amutant "the action boots the VM itself" 's|^  steps:$|  steps:\
    - uses: Mavergreen/mavericks-vm@v1|'
amutant "the action reads a secret" 's|GH_TOKEN: \${{ github.token }}|GH_TOKEN: ${{ secrets.GH }}|'
afirst "a run step names no shell" '      shell: bash'
lmutant "vm-test-prebuilt is gone" 's/^  vm-test-prebuilt:$/  other:/'
lmutant "prebuilt mode compiles in the guest" 's|^\(            mkdir gate\)$|            SWIFTC=/usr/local/mavergreen/bin/swiftc DIST="$PWD/gate" sh make-selftest.sh\
\1|'
lmutant "prebuilt mode runs the toolchain smoke" 's|^\(            mkdir gate\)$|            sh tests/toolchain-smoke-test.sh\
\1|'
lmutant "prebuilt mode installs a toolchain" 's|^\(            install libcxx/libcxx22-\*\.pkg dist/swift-runtime-\*\.pkg\)$|\1 dist/swift-toolchain-[0-9]*.pkg|'
lmutant "prebuilt mode installs no runtime pkg" 's|^            install libcxx/libcxx22-\*\.pkg dist/swift-runtime-\*\.pkg$|            install libcxx/libcxx22-*.pkg|'
lmutant "prebuilt mode skips --loads" 's|^\(              \)sh swift-runtime-selftest/run-selftest\.sh --loads &&$|\1true \&\&|'
lmutant "prebuilt mode gates even when --loads fails" 's|^\(              sh swift-runtime-selftest/run-selftest\.sh --loads\) &&$|\1;|'
lmutant "prebuilt mode installs no clang22 for FileCheck" '/^            install clang22\/mavericks-clang-22-native-\*\.pkg$/d'
lmutant "prebuilt mode does not hold the runtime receipt" 's/^\(            got="\$(pkgutil --pkg-info dev.mavergreen.swift-runtime\)/\1-other/'
lmutant "prebuilt mode never launches the updater" '/DYLD_BIND_AT_LAUNCH=1 "\$u" --background/d'
lmutant "a dyld failure of the updater passes" "/! grep -q '^dyld: '/d"
lmutant "vm-test-prebuilt has no VM key" 's/^          image-key: \${{ secrets.MAVERICKS_VM_KEY }}$/          image-key: none/'
lmutant "vm-test-prebuilt cannot pull the VM image" '/^  vm-test-prebuilt:$/,$ { /^      packages: write$/d; }'
echo "PASS: vm-test-workflow"
