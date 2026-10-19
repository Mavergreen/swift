#!/bin/sh
# platform: host-agnostic
# usage: sh tests/vm-test-workflow-test.sh
#   .github/workflows/release.yml accepts every run on Mac OS X 10.9: its vm-test job installs this run's runtime
#   and native toolchain pkgs in Mavergreen/mavericks-vm's guest, builds the self-test bundle there with the
#   installed swiftc, and runs the bundle's gate; publish waits for it. Each check is run against a workflow
#   mutated to break it, and must refuse it.
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
  grep -q 'libcxx/libcxx22-\*\.pkg dist/swift-runtime-\*\.pkg dist/swift-toolchain-\[0-9\]\*\.pkg' "$T/job" \
    && grep -q 'sudo installer -pkg' "$T/job" || { echo "vm-test does not install libcxx22, then the runtime and native toolchain pkgs"; return 1; }
  grep -q 'gh release download "\$v" -R Mavergreen/clang-22 -p "libcxx22-\$v.pkg" -p SHA256SUMS' "$T/job" \
    && grep -q 'sha256sum -c -' "$T/job" || { echo "vm-test does not fetch and verify libcxx22 at the pinned release"; return 1; }
  grep -q 'SWIFTC=/usr/local/mavergreen/bin/swiftc .*sh make-selftest\.sh' "$T/job" || { echo "vm-test does not build the self-test with the installed swiftc"; return 1; }
  grep -q 'sh swift-runtime-selftest/run-selftest\.sh --gate' "$T/job" || { echo "vm-test does not run the self-test's gate"; return 1; }
  awk '/^  publish:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" | grep -q '^    needs: \[.*vm-test.*\]$' \
    || { echo "publish does not wait for vm-test"; return 1; }
}

W="$REPO/.github/workflows/release.yml"
check "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"

mutant() { sed "$2" "$W" > "$T/m.yml"; if check "$T/m.yml" > "$T/why"; then fail "the check passed a workflow where $1"; fi; }
mutant "vm-test is gone" 's/^  vm-test:$/  vm-gone:/'
mutant "vm-test needs only build" 's/^    needs: \[version, build-cross, build\]$/    needs: [build]/'
mutant "vm-test boots no VM" 's|Mavergreen/mavericks-vm@v1|actions/checkout@v7|'
mutant "vm-test installs nothing" 's/sudo installer -pkg/echo installer -pkg/'
mutant "vm-test installs no libcxx22" 's|libcxx/libcxx22-\*\.pkg ||'
mutant "libcxx22 goes unverified" 's/| sha256sum -c -/| cat/'
mutant "the self-test is built by another swiftc" 's|SWIFTC=/usr/local/mavergreen/bin/swiftc |SWIFTC=/tmp/swiftc |'
mutant "the gate is not run" 's/run-selftest\.sh --gate/run-selftest.sh/'
mutant "publish does not wait for vm-test" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan]/'
echo "PASS: vm-test-workflow"
