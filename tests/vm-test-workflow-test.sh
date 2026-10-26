#!/bin/sh
# platform: host-agnostic
# usage: sh tests/vm-test-workflow-test.sh
#   .github/workflows/release.yml accepts every run on Mac OS X 10.9: its vm-test job installs, in
#   Mavergreen/mavericks-vm's guest, libcxx22 and the previous release's runtime and native toolchain pkgs, then
#   this run's over them, holds both receipts to this run's version, runs `mavergreen check`, builds the
#   self-test bundle there with the installed swiftc, runs the bundle's gate, and only then installs
#   Longboat's latest release and mavericks-clang-22 (whose pkg requires Longboat) and runs the native
#   toolchain smoke, a SKIP of which fails; publish waits for it. The
#   build job runs no Rosetta smoke. Each check is run against a workflow mutated to break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/vm-test-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

check() {
  awk '/^  vm-test:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/job"
  [ -s "$T/job" ] || { echo "there is no vm-test job"; return 1; }
  grep -qx '    needs: \[version, build-cross, build\]' "$T/job" || { echo "vm-test does not need build-cross and build"; return 1; }
  grep -qx '        uses: Mavergreen/mavericks-vm@v1' "$T/job" || { echo "vm-test does not boot 10.9 with Mavergreen/mavericks-vm@v1"; return 1; }
  grep -q 'sudo installer -pkg' "$T/job" || { echo "vm-test installs nothing"; return 1; }
  # The order of the guest script's lines is the order things happen in.
  awk '/install libcxx\/libcxx22-\*\.pkg prev\/swift-runtime-\*\.pkg prev\/swift-toolchain-\[0-9\]\*\.pkg$/ { a = NR }
       /install dist\/swift-runtime-\*\.pkg dist\/swift-toolchain-\[0-9\]\*\.pkg$/ { b = NR }
       /\/usr\/local\/bin\/mavergreen check$/ { c = NR }
       /run-selftest\.sh --gate/ { g = NR }
       /install longboat\/longboat-\[0-9\]\*\.pkg clang22\/mavericks-clang-22-native-\*\.pkg$/ { k = NR }
       /sh tests\/toolchain-smoke-test\.sh/ { s = NR }
       END { exit !(a && a < b && b < c && c < g && g < k && k < s) }' "$T/job" \
    || { echo "vm-test does not install libcxx22 and the previous release, then this run's, check the install, gate, then install Longboat and clang22 and smoke, in that order"; return 1; }
  grep -q '\[ "\$got" = "\$SWIFT_FULL_VERSION" \]' "$T/job" && grep -q 'SWIFT_FULL_VERSION: \${{ needs.version.outputs.version }}' "$T/job" \
    || { echo "vm-test does not hold the upgraded receipts to this run's version"; return 1; }
  grep -q 'gh release download "\$prev" -R "\$GITHUB_REPOSITORY" -p "swift-runtime-\$prev.pkg" -p "swift-toolchain-\$prev.pkg" -p SHA256SUMS' "$T/job" \
    || { echo "vm-test does not fetch the previous release's pkgs"; return 1; }
  grep -q '\[ "\$rc" -ne 77 \]' "$T/job" || { echo "vm-test lets the native toolchain smoke skip"; return 1; }
  grep -q 'gh release download "\$v" -R Mavergreen/clang-22 -p "libcxx22-\$v.pkg" -p SHA256SUMS' "$T/job" \
    && grep -q 'sha256sum -c -' "$T/job" || { echo "vm-test does not fetch and verify libcxx22 at the pinned release"; return 1; }
  grep -q 'gh release download "\$lb" -R Mavergreen/longboat -p "longboat-\$lb.pkg" -p SHA256SUMS' "$T/job" \
    && grep -q 'grep " longboat-\$lb.pkg\\\$" SHA256SUMS | sha256sum -c -' "$T/job" \
    || { echo "vm-test does not fetch and verify Longboat"; return 1; }
  grep -q 'SWIFTC=/usr/local/mavergreen/bin/swiftc .*sh make-selftest\.sh' "$T/job" || { echo "vm-test does not build the self-test with the installed swiftc"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --gate' "$T/job" || { echo "vm-test does not run the self-test's gate"; return 1; }
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
mutant "clang22 is installed before the gate" '/install longboat\/longboat-.*clang22\/mavericks-clang-22-native/d; s|^\(            install dist/swift-runtime-\*\.pkg.*\)$|\1\
            install longboat/longboat-[0-9]*.pkg clang22/mavericks-clang-22-native-*.pkg|'
mutant "Longboat is not installed before clang22" 's|install longboat/longboat-\[0-9\]\*\.pkg clang22/|install clang22/|'
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
mutant "publish does not wait for vm-test" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan]/'
echo "PASS: vm-test-workflow"
