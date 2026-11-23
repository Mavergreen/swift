#!/bin/sh
# platform: host-agnostic
# usage: sh tests/vm-test-workflow-test.sh
#   .github/workflows/release.yml accepts every run on Mac OS X 10.9: its vm-test job installs, in
#   Mavergreen/mavericks-vm's guest, libcxx22 and the previous release's runtime and native toolchain pkgs, then
#   this run's over them, holds both receipts to this run's version, runs `mavergreen check`, builds the
#   self-test bundle there with the installed swiftc, upstream's tests in it from the swift-cross artifact's
#   selftest-support/ (which build-cross uploads), runs the bundle's --loads and then its gate, and only then installs
#   Longboat's latest release and mavericks-clang-22 (whose pkg requires Longboat) and runs the native
#   toolchain smoke, a SKIP of which fails; publish waits for it. That is bundle_mode compile, the default (a
#   push, a tag, a dispatch that names none) and the only mode a publishing run may take. bundle_mode, a dispatch
#   input of compile or prebuilt and nothing else, is checked first, in the version job right after it decides
#   whether the run publishes (before any build) and again in vm-test; prebuilt (iteration only) downloads a bundle
#   built elsewhere (the swift-selftest artifact), installs libcxx22 and this run's runtime pkg alone, holds its
#   receipt, checks the install, installs Longboat, its 10.9 SDK and clang22 (FileCheck), and runs the bundle's
#   --loads and then, only if that passed, its --gate: no compile in the guest, no toolchain, no smoke. The
#   build job runs no Rosetta smoke. Each check is run against a workflow mutated to break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vm-test-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

check() {
  awk '/^  vm-test:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/job"
  [ -s "$T/job" ] || { echo "there is no vm-test job"; return 1; }
  # Each step of the job, in $T/step.<n>; the guest step of each mode is the mavericks-vm step its if: names.
  rm -f "$T"/step.*
  awk -v d="$T" '/^      - / { n++ } n { print > (d "/step." n) }' "$T/job"
  : > "$T/compile"; : > "$T/prebuilt"
  for f in "$T"/step.*; do
    grep -qx '        uses: Mavergreen/mavericks-vm@v1' "$f" || continue
    if grep -qx "        if: env.BUNDLE_MODE == 'compile'" "$f"; then cat "$f" >> "$T/compile"; fi
    if grep -qx "        if: env.BUNDLE_MODE == 'prebuilt'" "$f"; then cat "$f" >> "$T/prebuilt"; fi
  done
  [ -s "$T/compile" ] || { echo "vm-test has no guest step for bundle_mode compile"; return 1; }
  [ -s "$T/prebuilt" ] || { echo "vm-test has no guest step for bundle_mode prebuilt"; return 1; }
  # The mode: a dispatch input, compile unless named; an allow-list checked before anything else; never a publish.
  awk '/^  workflow_dispatch:$/ { w = 1 } w && /^      bundle_mode:$/ { b = 1; next } b && /^      [a-z_]+:$/ { b = 0 } b' "$1" > "$T/input"
  grep -qx '        type: choice' "$T/input" && grep -qx '        options: \[compile, prebuilt\]' "$T/input" && grep -qx '        default: compile' "$T/input" \
    || { echo "release.yml has no bundle_mode dispatch input of compile or prebuilt, default compile"; return 1; }
  grep -qx "      BUNDLE_MODE: \${{ inputs.bundle_mode || 'compile' }}" "$T/job" || { echo "vm-test's BUNDLE_MODE is not the input, else compile"; return 1; }
  awk '/^      - / { n++ } /case "\$BUNDLE_MODE" in compile\|prebuilt\) ;; \*\) / && /exit 1/ { c = n } /actions\/download-artifact/ && !d { d = n } END { exit !(c && c < d) }' "$T/job" \
    || { echo "vm-test does not refuse a bundle_mode other than compile or prebuilt before it does anything"; return 1; }
  grep -q '\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || ' "$T/job" && grep -q 'PUBLISH: \${{ needs.version.outputs.publish }}' "$T/job" \
    || { echo "vm-test lets a publishing run gate a prebuilt bundle"; return 1; }
  # The version job checks the mode too, right after it decides whether the run publishes: before any build.
  awk '/^  version:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/version"
  awk '/^      - / { n++ } /^        id: ver$/ { v = n }
       /case "\$BUNDLE_MODE" in compile\|prebuilt\) ;; \*\) / && /exit 1/ { c = n }
       /\[ "\$BUNDLE_MODE" = compile \] \|\| \[ "\$PUBLISH" != true \] \|\| / { p = n }
       /^          BUNDLE_MODE: \$\{\{ inputs\.bundle_mode \|\| .compile. \}\}$/ { b = n }
       /^          PUBLISH: \$\{\{ steps\.ver\.outputs\.publish \}\}$/ { o = n }
       END { exit !(v && c == v + 1 && p == c && b == c && o == c) }' "$T/version" \
    || { echo "the version job does not refuse a bad bundle_mode, or a prebuilt one in a publishing run, right after it decides whether the run publishes"; return 1; }
  for f in "$T"/step.*; do
    if grep -q 'name: swift-selftest' "$f"; then grep -qx "        if: env.BUNDLE_MODE == 'prebuilt'" "$f" && grep -q 'path: dist' "$f" \
      || { echo "vm-test does not download the prebuilt bundle (swift-selftest) into dist/ in prebuilt mode alone"; return 1; }; fi
  done
  grep -q 'name: swift-selftest, path: dist' "$T/job" || { echo "vm-test does not download the prebuilt bundle (swift-selftest)"; return 1; }
  # prebuilt: the runtime pkg alone, its receipt, the install checked, clang22 (FileCheck), --loads, then --gate.
  awk '/install libcxx\/libcxx22-\*\.pkg dist\/swift-runtime-\*\.pkg$/ { a = NR }
       /\/usr\/local\/bin\/mavergreen check$/ { c = NR }
       /install longboat\/longboat-\[0-9\]\*\.pkg$/ { l = NR }
       /sudo \/usr\/local\/mavergreen\/bin\/longboat sdk install 10\.9$/ { d = NR }
       /install clang22\/mavericks-clang-22-native-\*\.pkg$/ { k = NR }
       /tar -xzf \.\.\/dist\/swift-runtime-selftest\.tar\.gz/ { x = NR }
       END { exit !(a && a < c && c < l && l < d && d < k && k <= x) }' "$T/prebuilt" \
    || { echo "prebuilt mode does not install libcxx22 and this run's runtime pkg, check the install, install Longboat, its 10.9 SDK and clang22, then unpack the bundle, in that order"; return 1; }
  grep -q 'pkgutil --pkg-info dev.mavergreen.swift-runtime |' "$T/prebuilt" && grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/prebuilt" \
    || { echo "prebuilt mode does not hold the runtime's receipt to this run's version"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --loads &&$' "$T/prebuilt" && grep -q '^ *sh swift-runtime-selftest/run-selftest\.sh --gate )$' "$T/prebuilt" \
    && awk '/run-selftest\.sh --loads/ { l = NR } /run-selftest\.sh --gate/ { g = NR } END { exit !(l && l < g) }' "$T/prebuilt" \
    || { echo "prebuilt mode does not run the bundle's --loads and then, only if it passed, its --gate"; return 1; }
  if grep -q 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt"; then
    echo "prebuilt mode compiles in the guest, installs a toolchain or runs the toolchain smoke: $(grep 'make-selftest\|swiftc\|toolchain-smoke-test\|swift-toolchain' "$T/prebuilt")"; return 1; fi
  grep -qx '    needs: \[version, build-cross, build\]' "$T/job" || { echo "vm-test does not need build-cross and build"; return 1; }
  grep -qx '        uses: Mavergreen/mavericks-vm@v1' "$T/job" || { echo "vm-test does not boot 10.9 with Mavergreen/mavericks-vm@v1"; return 1; }
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
  grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/compile" && grep -q 'SWIFT_FULL_VERSION: \${{ needs.version.outputs.version }}' "$T/job" \
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
  if grep -qi 'rosetta\|arch -x86_64' "$1"; then echo "the workflow still runs something under Rosetta"; return 1; fi
}

W="$REPO/.github/workflows/release.yml"
check "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"

mutant() { sed "$2" "$W" > "$T/m.yml"; if check "$T/m.yml" > "$T/why"; then fail "the check passed a workflow where $1"; fi; }
mutant "vm-test is gone" 's/^  vm-test:$/  vm-gone:/'
mutant "vm-test needs only build" 's/^    needs: \[version, build-cross, build\]$/    needs: [build]/'
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
mutant "the build job smokes under Rosetta again" 's|^      - name: Build swift-toolchain-updater.app|      - name: Toolchain smoke under Rosetta\
        run: true\
      - name: Build swift-toolchain-updater.app|'
mutant "libcxx22 goes unverified" 's/| sha256sum -c -/| cat/'
mutant "the self-test is built by another swiftc" 's|SWIFTC=/usr/local/mavergreen/bin/swiftc |SWIFTC=/tmp/swiftc |'
mutant "the gate is not run" 's/run-selftest\.sh --gate/run-selftest.sh/'
mutant "the bundle has no upstream tests" 's|SELFTEST_SUPPORT="\$PWD/dist/selftest-support" ||'
mutant "--loads is not run" 's/run-selftest\.sh --loads &&/true \&\&/'
mutant "build-cross uploads no self-test support" '/^            \${{ env.SWIFT_BUILD }}\/dist\/selftest-support$/d'
mutant "publish does not wait for vm-test" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan]/'
mutant "bundle_mode is not a dispatch input" '/^      bundle_mode:$/,/^        default: compile$/d'
mutant "bundle_mode defaults to prebuilt" 's/^        default: compile$/        default: prebuilt/'
mutant "bundle_mode takes any value" 's/^        options: \[compile, prebuilt\]$/        options: [compile, prebuilt, other]/'
mutant "a push gates a prebuilt bundle" "s/BUNDLE_MODE: \${{ inputs.bundle_mode || 'compile' }}/BUNDLE_MODE: \${{ inputs.bundle_mode || 'prebuilt' }}/"
mutant "a mode outside the allow-list goes unrefused" 's/case "\$BUNDLE_MODE" in compile|prebuilt) ;; \*) /case "$BUNDLE_MODE" in *) ;; compile|prebuilt) /'
mutant "a publishing run may gate a prebuilt bundle" 's/\[ "\$BUNDLE_MODE" = compile \] || \[ "\$PUBLISH" != true \] || /true || /'
mutant "the compile step runs in prebuilt mode too" "/^        if: env.BUNDLE_MODE == 'compile'\$/d"
mutant "there is no prebuilt step" "s/^        if: env.BUNDLE_MODE == 'prebuilt'\$/        if: env.BUNDLE_MODE == 'never'/"
mutant "the prebuilt bundle is not downloaded" 's/name: swift-selftest, path: dist/name: swift-cross, path: dist/'
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
V='/^  version:$/,/^  build-cross:$/'; VM='/^  vm-test:$/,$'
mutant "the version job does not check the mode" "$V { /^      - name: Check vm-test's bundle mode\$/,/never a prebuilt one\"; exit 1; }\$/d; }"
mutant "the version job takes any mode" "$V s/case \"\\\$BUNDLE_MODE\" in compile|prebuilt) ;; \\*) /case \"\$BUNDLE_MODE\" in *) ;; compile|prebuilt) /"
mutant "the version job lets a publishing run take prebuilt" "$V s/\\[ \"\\\$BUNDLE_MODE\" = compile \\] || \\[ \"\\\$PUBLISH\" != true \\] || /true || /"
mutant "the version job's guard does not read the publish it decided" "$V s/^          PUBLISH: \\\${{ steps.ver.outputs.publish }}\$/          PUBLISH: \${{ needs.x.outputs.publish }}/"
mutant "vm-test does not check the mode again" "$VM s/case \"\\\$BUNDLE_MODE\" in compile|prebuilt) ;; \\*) /case \"\$BUNDLE_MODE\" in *) ;; compile|prebuilt) /"
mutant "vm-test does not refuse prebuilt in a publishing run again" "$VM s/\\[ \"\\\$BUNDLE_MODE\" = compile \\] || \\[ \"\\\$PUBLISH\" != true \\] || /true || /"
echo "PASS: vm-test-workflow"
