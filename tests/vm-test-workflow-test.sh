#!/bin/sh
# platform: host-agnostic
# usage: sh tests/vm-test-workflow-test.sh
#   Every run is accepted on Mac OS X 10.9 by .github/workflows/vm-test.yml, which release.yml calls as its vm-test
#   job (needing version, build-cross and build; publish waits for it) in bundle_mode compile, and linux-runtime.yml
#   in prebuilt. compile, the release gate: vm-test.yml downloads swift-cross and swift-native, installs, in
#   Mavergreen/mavericks-vm's guest, libcxx22 and the previous release's runtime and native toolchain pkgs, then
#   this run's over them, holds both receipts to the run's version, runs `mavergreen check`, builds the self-test
#   bundle there with the installed swiftc, upstream's tests in it from swift-cross's selftest-support/ (which
#   build-cross uploads), installs Longboat's latest release and mavericks-clang-22 (whose pkg requires Longboat)
#   before that build, runs the bundle's --loads and then its gate, and then the native toolchain smoke, a SKIP of
#   which fails. bundle_mode is checked first, compile or prebuilt and nothing else, and a publishing run never
#   takes prebuilt. prebuilt (iteration only) downloads neither swift-cross nor swift-native nor the previous
#   release: only the artifact its caller names (a runtime pkg and the bundle built beside it, the same run's),
#   installs libcxx22 and that runtime pkg alone, holds its receipt, checks the install, launches the runtime's
#   updater once (dyld must bind every import), installs Longboat, its 10.9 SDK and clang22 (FileCheck), and runs
#   the bundle's --loads and then, only if that passed, its --gate: no compile in the guest, no toolchain, no smoke.
#   The build job runs no Rosetta smoke. Each check is run against a workflow mutated to break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vm-test-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# check <release.yml> <vm-test.yml>
check() {
  awk '/^  vm-test:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/caller"
  [ -s "$T/caller" ] || { echo "release.yml has no vm-test job"; return 1; }
  grep -qx '    uses: ./.github/workflows/vm-test.yml' "$T/caller" || { echo "release.yml's vm-test does not call vm-test.yml"; return 1; }
  grep -qx '    needs: \[version, build-cross, build\]' "$T/caller" || { echo "vm-test does not need build-cross and build"; return 1; }
  grep -qx '      bundle_mode: compile' "$T/caller" || { echo "release.yml's vm-test is not bundle_mode compile"; return 1; }
  grep -qx '      version: ${{ needs.version.outputs.version }}' "$T/caller" && grep -qx '      publish: ${{ needs.version.outputs.publish }}' "$T/caller" \
    || { echo "release.yml's vm-test is not handed the run's version and whether it publishes"; return 1; }
  grep -qx '      MAVERICKS_VM_KEY: ${{ secrets.MAVERICKS_VM_KEY }}' "$T/caller" || { echo "release.yml's vm-test is not handed the VM's key"; return 1; }
  if awk '/^  workflow_dispatch:$/ { w = 1; next } w && /^(  )?[a-z]/ { w = 0 } w' "$1" | grep -q bundle_mode; then
    echo "release.yml still takes a bundle_mode from a dispatch: its vm-test is the release gate, compile alone"; return 1; fi
  awk '/^jobs:$/ { j = 1; next } j && /^  vm-test:$/ { v = 1; next } j && /^  [a-z-]+:$/ { v = 0 } v' "$2" > "$T/job"
  [ -s "$T/job" ] || { echo "vm-test.yml has no vm-test job"; return 1; }
  grep -qx '    runs-on: ubuntu-latest' "$T/job" || { echo "vm-test.yml's job does not run on ubuntu-latest"; return 1; }
  # Each step of the job, in $T/step.<n>; the guest step of each mode is the mavericks-vm step its if: names.
  rm -f "$T"/step.*
  awk -v d="$T" '/^      - / { n++ } n { print > (d "/step." n) }' "$T/job"
  : > "$T/compile"; : > "$T/prebuilt"; : > "$T/cdl"; : > "$T/pdl"
  for f in "$T"/step.*; do
    if grep -qx "        if: env.BUNDLE_MODE == 'compile'" "$f"; then m=compile; elif grep -qx "        if: env.BUNDLE_MODE == 'prebuilt'" "$f"; then m=prebuilt; else m=both; fi
    if grep -qx '        uses: Mavergreen/mavericks-vm@v1' "$f"; then
      case "$m" in compile|prebuilt) cat "$f" >> "$T/$m" ;; *) echo "a guest step runs in both modes"; return 1 ;; esac; fi
    if grep -q 'actions/download-artifact@\|gh release download "\$prev"' "$f"; then
      case "$m" in compile) cat "$f" >> "$T/cdl" ;; prebuilt) cat "$f" >> "$T/pdl" ;; *) echo "a download runs in both modes: $(head -1 "$f")"; return 1 ;; esac; fi
  done
  [ -s "$T/compile" ] || { echo "vm-test has no guest step for bundle_mode compile"; return 1; }
  [ -s "$T/prebuilt" ] || { echo "vm-test has no guest step for bundle_mode prebuilt"; return 1; }
  # compile downloads build-cross's and build's pkgs and the previous release; prebuilt only its caller's artifact.
  grep -q 'name: swift-cross, path: dist' "$T/cdl" && grep -q 'name: swift-native, path: dist' "$T/cdl" && grep -q 'gh release download "\$prev"' "$T/cdl" \
    || { echo "compile mode does not download swift-cross, swift-native and the previous release"; return 1; }
  grep -qx '          name: ${{ inputs.prebuilt_artifact }}' "$T/pdl" && grep -qx '          path: dist' "$T/pdl" || { echo "prebuilt mode does not download its caller's artifact into dist/"; return 1; }
  if grep -q 'swift-cross\|swift-native\|\$prev' "$T/pdl"; then echo "prebuilt mode downloads a macOS job's artifact or the previous release"; return 1; fi
  # The mode: the input, an allow-list checked before anything else; never a publish.
  awk '/^  workflow_call:$/ { w = 1 } w && /^      bundle_mode:$/ { b = 1; next } b && /^      [a-z_]+:$/ { b = 0 } b' "$2" | grep -qx '        required: true' \
    || { echo "vm-test.yml has no required bundle_mode input"; return 1; }
  grep -qx '      BUNDLE_MODE: ${{ inputs.bundle_mode }}' "$T/job" || { echo "vm-test's BUNDLE_MODE is not its input"; return 1; }
  awk '/^      - / { n++ } /case "\$BUNDLE_MODE" in compile\|prebuilt\) ;; \*\) / && /exit 1/ { c = n } /actions\/download-artifact|gh release/ && !d { d = n } END { exit !(c && c < d) }' "$T/job" \
    || { echo "vm-test does not refuse a bundle_mode other than compile or prebuilt before it does anything"; return 1; }
  grep -q '\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || ' "$T/job" && grep -q 'PUBLISH: \${{ inputs.publish }}' "$T/job" \
    || { echo "vm-test lets a publishing run gate a prebuilt bundle"; return 1; }
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
    || { echo "prebuilt mode does not hold the runtime's receipt to this run's version"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --loads &&$' "$T/prebuilt" && grep -q '^ *sh swift-runtime-selftest/run-selftest\.sh --gate )$' "$T/prebuilt" \
    && awk '/run-selftest\.sh --loads/ { l = NR } /run-selftest\.sh --gate/ { g = NR } END { exit !(l && l < g) }' "$T/prebuilt" \
    || { echo "prebuilt mode does not run the bundle's --loads and then, only if it passed, its --gate"; return 1; }
  if grep -q 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt"; then
    echo "prebuilt mode compiles in the guest, installs a toolchain or runs the toolchain smoke: $(grep 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt")"; return 1; fi
  grep -q 'sudo installer -pkg' "$T/job" || { echo "vm-test installs nothing"; return 1; }
  # The order of the guest script's lines is the order things happen in.
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
  grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/compile" && grep -q 'SWIFT_FULL_VERSION: \${{ inputs.version }}' "$T/job" \
    || { echo "vm-test does not hold the upgraded receipts to this run's version"; return 1; }
  grep -q 'gh release download "\$prev" -R "\$GITHUB_REPOSITORY" -p "swift-runtime-\$prev.pkg" -p "swift-toolchain-\$prev.pkg" -p SHA256SUMS' "$T/job" \
    || { echo "vm-test does not fetch the previous release's pkgs"; return 1; }
  grep -q '\[ "\$rc" -ne 77 \]' "$T/compile" || { echo "vm-test lets the native toolchain smoke skip"; return 1; }
  grep -q 'gh release download "\$v" -R Mavergreen/clang-22 -p "libcxx22-\$v.pkg" -p SHA256SUMS' "$T/job" \
    && grep -q 'sha256sum -c -' "$T/job" || { echo "vm-test does not fetch and verify libcxx22 at the pinned release"; return 1; }
  grep -q 'gh release download "\$lb" -R Mavergreen/longboat -p "longboat-\$lb.pkg" -p SHA256SUMS' "$T/job" \
    && grep -q 'grep " longboat-\$lb.pkg\\\$" SHA256SUMS | sha256sum -c -' "$T/job" \
    || { echo "vm-test does not fetch and verify Longboat"; return 1; }
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
  if grep -qi 'rosetta\|arch -x86_64' "$1" "$2"; then echo "the workflow still runs something under Rosetta"; return 1; fi
}

R="$REPO/.github/workflows/release.yml"; V="$REPO/.github/workflows/vm-test.yml"
[ -f "$V" ] || fail "no .github/workflows/vm-test.yml"
check "$R" "$V" > "$T/why" || fail "$(cat "$T/why")"

mutant() { sed "$2" "$V" > "$T/m.yml"; if check "$R" "$T/m.yml" > "$T/why"; then fail "the check passed a vm-test.yml where $1"; fi; }
rmutant() { sed "$2" "$R" > "$T/m.yml"; if check "$T/m.yml" "$V" > "$T/why"; then fail "the check passed a release.yml where $1"; fi; }
rmutant "vm-test is gone" 's/^  vm-test:$/  vm-gone:/'
rmutant "vm-test needs only build" 's/^    needs: \[version, build-cross, build\]$/    needs: [build]/'
rmutant "release.yml gates a prebuilt bundle" 's/^      bundle_mode: compile$/      bundle_mode: prebuilt/'
rmutant "a dispatch picks the bundle again" 's/^      local_release:$/      bundle_mode:\
        type: string\
      local_release:/'
rmutant "vm-test is told the run never publishes" 's/^      publish: \${{ needs.version.outputs.publish }}$/      publish: false/'
rmutant "build-cross uploads no self-test support" '/^            \${{ env.SWIFT_BUILD }}\/dist\/selftest-support$/d'
rmutant "publish does not wait for vm-test" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan]/'
rmutant "the build job smokes under Rosetta again" 's|^      - name: Build swift-toolchain-updater.app|      - name: Toolchain smoke under Rosetta\
        run: true\
      - name: Build swift-toolchain-updater.app|'
mutant "vm-test boots no VM" 's|Mavergreen/mavericks-vm@v1|actions/checkout@v7|'
mutant "vm-test installs nothing" 's/sudo installer -pkg/echo installer -pkg/'
mutant "vm-test installs no libcxx22" 's|libcxx/libcxx22-\*\.pkg ||'
mutant "vm-test does not upgrade from the previous release" 's| prev/swift-runtime-\*\.pkg prev/swift-toolchain-\[0-9\]\*\.pkg$||'
mutant "the previous release goes unfetched" 's|gh release download "\$prev"|echo "$prev"|'
mutant "the upgraded receipts are not checked" 's/\[ "\$got" = "\$SWIFT_FULL_VERSION" \]/true/'
mutant "the family install is not checked" 's|/usr/local/bin/mavergreen check$|true|'
mutant "clang22 is installed only after the gate" '/^            install clang22\/mavericks-clang-22-native-\*\.pkg$/d; s|^\(              sh swift-runtime-selftest/run-selftest.sh --gate )\)$|\1\
            install clang22/mavericks-clang-22-native-*.pkg|'
mutant "Longboat is not installed before clang22" '/^            install longboat\/longboat-\[0-9\]\*\.pkg$/d'
mutant "the 10.9 SDK is not installed before clang22" '/longboat sdk install 10\.9$/d'
mutant "Longboat goes unfetched" 's|gh release download "\$lb"|echo "$lb"|'
mutant "Longboat goes unverified" 's/grep " longboat-\$lb.pkg\\\$" SHA256SUMS | sha256sum -c -/true/'
mutant "the native smoke does not run" 's|sh tests/toolchain-smoke-test\.sh|true|'
mutant "the native smoke may skip" 's/\[ "\$rc" -ne 77 \]/true/'
mutant "libcxx22 goes unverified" 's/| sha256sum -c -/| cat/'
mutant "the self-test is built by another swiftc" 's|SWIFTC=/usr/local/mavergreen/bin/swiftc |SWIFTC=/tmp/swiftc |'
mutant "the gate is not run" 's/run-selftest\.sh --gate/run-selftest.sh/'
mutant "the bundle has no upstream tests" 's|SELFTEST_SUPPORT="\$PWD/dist/selftest-support" ||'
mutant "--loads is not run" 's/run-selftest\.sh --loads &&/true \&\&/'
mutant "bundle_mode is optional" '/^  workflow_call:$/,/^jobs:$/ s/^        required: true$/        required: false/'
mutant "a mode outside the allow-list goes unrefused" 's/case "\$BUNDLE_MODE" in compile|prebuilt) ;; \*) /case "$BUNDLE_MODE" in *) ;; compile|prebuilt) /'
mutant "a publishing run may gate a prebuilt bundle" 's/\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || /true || /'
mutant "the compile step runs in prebuilt mode too" "/^        if: env.BUNDLE_MODE == 'compile'\$/d"
mutant "there is no prebuilt step" "s/^        if: env.BUNDLE_MODE == 'prebuilt'\$/        if: env.BUNDLE_MODE == 'never'/"
mutant "the prebuilt bundle is not downloaded" 's/^          name: \${{ inputs.prebuilt_artifact }}$/          name: swift-other/'
mutant "prebuilt mode downloads build-cross's pkgs" 's/^          name: \${{ inputs.prebuilt_artifact }}$/          name: swift-cross/'
mutant "prebuilt mode compiles in the guest" 's|^\(            mkdir gate\)$|            SWIFTC=/usr/local/mavergreen/bin/swiftc DIST="$PWD/gate" sh make-selftest.sh\
\1|'
mutant "prebuilt mode runs the toolchain smoke" 's|^\(            mkdir gate\)$|            sh tests/toolchain-smoke-test.sh\
\1|'
mutant "prebuilt mode installs a toolchain" 's|^\(            install libcxx/libcxx22-\*\.pkg dist/swift-runtime-\*\.pkg\)$|\1 dist/swift-toolchain-[0-9]*.pkg|'
mutant "prebuilt mode installs no runtime pkg" 's|^            install libcxx/libcxx22-\*\.pkg dist/swift-runtime-\*\.pkg$|            install libcxx/libcxx22-*.pkg|'
mutant "prebuilt mode skips --loads" 's|^\(              \)sh swift-runtime-selftest/run-selftest\.sh --loads &&$|\1true \&\&|'
mutant "prebuilt mode gates even when --loads fails" 's|^\(              sh swift-runtime-selftest/run-selftest\.sh --loads\) &&$|\1;|'
mutant "prebuilt mode installs no clang22 for FileCheck" "/if: env.BUNDLE_MODE == 'prebuilt'/,\$ { /^            install clang22\/mavericks-clang-22-native-\*\.pkg\$/d; }"
mutant "prebuilt mode does not hold the runtime receipt" 's/^\(            got="\$(pkgutil --pkg-info dev.mavergreen.swift-runtime\)/\1-other/'
mutant "prebuilt mode never launches the updater" '/DYLD_BIND_AT_LAUNCH=1 "\$u" --background/d'
mutant "a dyld failure of the updater passes" "/! grep -q '^dyld: '/d"
echo "PASS: vm-test-workflow"
