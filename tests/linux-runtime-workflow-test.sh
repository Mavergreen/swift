#!/bin/sh
# platform: host-agnostic
# usage: sh tests/linux-runtime-workflow-test.sh
#   .github/workflows/linux-runtime.yml builds the runtime and gates it on Mac OS X 10.9 with no macOS runner: on
#   every push and pull request it calls linux-build.yml (the Linux-hosted compiler, cached; build.sh; the runtime
#   pkg; the self-test bundle) and then vm-test.yml in prebuilt mode, never publishing, on that same run's
#   swift-linux artifact. Neither it nor a workflow it calls runs on a macos-* runner.
#   linux-build.yml names the compiler build's scripts once (COMPILER_BUILD): its compiler jobs run exactly those,
#   and the cache key, swift-linux-compiler-<runner.os>-x86_64-<hash>, hashes what they read
#   (scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD), computed in each job that probes, saves or restores
#   it from that job's own shipyard. The probe, the save and the restore name the same paths. A hit skips every
#   compiler job and the runtime job restores the compiler, failing on a miss; a miss builds it in three jobs
#   (build-llvm.sh and build-builtins.sh; build-toolchain.sh --stop-after llvm; build-toolchain.sh), each within
#   GitHub's six hours, each handing its work on as a same-run artifact. The runner gets uuid-dev and pkg-config
#   from apt, cmake is its own, and clang22 comes from install@v1's products at components/clang22/version's pin.
#   The runtime job runs build.sh with the cached compiler, then the coroutine frame reproducer against it,
#   required, then the pkg with its updater, and the bundle when asked.
#   A bundle crossing from another run must be checked for this commit and linux-runtime.yml before it is
#   trusted: today every download-artifact is the same run's, and a cross-run one (run-id:) without that check is
#   refused. Each check is run against a workflow mutated to break it, and must refuse it.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/linux-runtime-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
WF="$REPO/.github/workflows"
LR="$WF/linux-runtime.yml"; LB="$WF/linux-build.yml"; VM="$WF/vm-test.yml"
for f in "$LR" "$LB" "$VM"; do [ -f "$f" ] || fail "no ${f#"$REPO"/}"; done

# job <workflow> <id> -- the job's lines, without its id line
job() { awk -v j="  $2:" '/^jobs:$/ { in_ = 1; next } in_ && $0 == j { on = 1; next } in_ && /^  [A-Za-z][A-Za-z0-9_-]*:/ { on = 0 } on' "$1"; }
# step <job file> <name prefix> -- the step whose name starts so, from its "- " line to the next step's
step() { awk -v p="      - name: $2" 'index($0, p) == 1 { on = 1; print; next } on && /^      - / { exit } on' "$1"; }
# jobs <workflow> -- its job ids
jobs_of() { awk '/^jobs:$/ { in_ = 1; next } in_ && /^  [A-Za-z][A-Za-z0-9_-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$1"; }

# The iteration workflow: triggers, the two calls, nothing on macOS.
check_lr() {
  awk '/^on:$/ { o = 1; next } o && /^[a-z]/ { o = 0 } o' "$1" > "$T/on"
  grep -qx '  push:' "$T/on" && grep -qx '  pull_request:' "$T/on" || { echo "linux-runtime.yml does not run on push and pull_request"; return 1; }
  job "$1" build > "$T/b"; job "$1" vm-test > "$T/v"
  grep -qx '    uses: ./.github/workflows/linux-build.yml' "$T/b" || { echo "linux-runtime.yml's build does not call linux-build.yml"; return 1; }
  grep -qx '      selftest: true' "$T/b" || { echo "linux-runtime.yml's build does not ask for the self-test bundle"; return 1; }
  grep -qx '    uses: ./.github/workflows/vm-test.yml' "$T/v" || { echo "linux-runtime.yml's vm-test does not call vm-test.yml"; return 1; }
  grep -qx '    needs: \[build\]' "$T/v" || { echo "linux-runtime.yml's vm-test does not need build alone"; return 1; }
  grep -qx '      bundle_mode: prebuilt' "$T/v" || { echo "linux-runtime.yml's vm-test is not in prebuilt mode"; return 1; }
  grep -qx "      publish: 'false'" "$T/v" || { echo "linux-runtime.yml's vm-test may publish"; return 1; }
  grep -qx '      version: ${{ needs.build.outputs.version }}' "$T/v" || { echo "linux-runtime.yml's vm-test does not hold the receipt to the build's version"; return 1; }
  grep -qx '      prebuilt_artifact: swift-linux' "$T/v" || { echo "linux-runtime.yml's vm-test does not gate the swift-linux artifact"; return 1; }
  grep -qx '      MAVERICKS_VM_KEY: ${{ secrets.MAVERICKS_VM_KEY }}' "$T/v" || { echo "linux-runtime.yml's vm-test is not handed the VM's key"; return 1; }
  if grep -q 'publish-release\|sign_and_appcast' "$1"; then echo "linux-runtime.yml publishes or signs"; return 1; fi
  # Nothing on macOS, here or in a workflow it calls.
  for w in "$1" $(sed -n 's|^    uses: \./\.github/workflows/\(.*\.yml\)$|\1|p' "$1" | sed "s|^|$(dirname "$1")/|"); do
    if grep -nE '^ *runs-on:.*macos' "$w"; then echo "${w##*/} runs a job on a macOS runner (above)"; return 1; fi
  done
}
check_lr "$LR" > "$T/why" || fail "linux-runtime.yml: $(cat "$T/why")"
lr_mutant() { sed "$2" "$LR" > "$T/m.yml"; cp "$LB" "$VM" "$T/" 2>/dev/null; if check_lr "$T/m.yml" > "$T/why"; then fail "the check passed a linux-runtime.yml where $1"; fi; }
lr_mutant "pull requests do not run it" '/^  pull_request:$/d'
lr_mutant "vm-test publishes" "s/^      publish: 'false'\$/      publish: 'true'/"
lr_mutant "vm-test compiles in the guest" 's/^      bundle_mode: prebuilt$/      bundle_mode: compile/'
lr_mutant "vm-test gates another artifact" 's/^      prebuilt_artifact: swift-linux$/      prebuilt_artifact: swift-cross/'
lr_mutant "the build skips the bundle" 's/^      selftest: true$/      selftest: false/'
lr_mutant "vm-test does not wait for the build" 's/^    needs: \[build\]$/    needs: []/'
# A called workflow that grows a macOS job.
mkdir -p "$T/sub" && cp "$LR" "$VM" "$T/sub/" && sed 's/^    runs-on: ubuntu-latest$/    runs-on: macos-26/' "$LB" > "$T/sub/linux-build.yml"
if check_lr "$T/sub/linux-runtime.yml" > "$T/why"; then fail "the check passed a linux-runtime.yml whose linux-build.yml runs on macOS"; fi

# The compiler build: one named list, one key, three jobs on a miss, none on a hit.
check_lb() {
  for j in $(jobs_of "$1"); do
    job "$1" "$j" | grep -qx '    runs-on: ubuntu-latest' || { echo "linux-build.yml's $j does not run on ubuntu-latest"; return 1; }
  done
  [ "$(grep -c '^  COMPILER_BUILD: ' "$1")" -eq 1 ] || { echo "linux-build.yml does not name COMPILER_BUILD once, at the top"; return 1; }
  cb="$(sed -n 's/^  COMPILER_BUILD: *//p' "$1" | tr ' ' '\n' | grep . | LC_ALL=C sort)"
  for j in compiler-probe compiler-tools compiler-llvm compiler-swift runtime; do
    jobs_of "$1" | grep -qx "$j" || { echo "linux-build.yml has no job $j"; return 1; }
  done
  # What the compiler jobs run is COMPILER_BUILD, exactly.
  for j in compiler-tools compiler-llvm compiler-swift; do job "$1" "$j"; done \
    | sed -n 's|^ *\(run: \)\{0,1\}\./\([A-Za-z0-9_-]*\.sh\)\( .*\)\{0,1\}$|\2|p' | LC_ALL=C sort -u > "$T/ran"
  [ "$(cat "$T/ran")" = "$cb" ] || { echo "the compiler jobs run [$(tr '\n' ' ' < "$T/ran")], not COMPILER_BUILD [$(printf '%s' "$cb" | tr '\n' ' ')]"; return 1; }
  job "$1" compiler-tools > "$T/j1"; job "$1" compiler-llvm > "$T/j2"; job "$1" compiler-swift > "$T/j3"; job "$1" runtime > "$T/jr"; job "$1" compiler-probe > "$T/jp"
  grep -qx '        run: ./build-toolchain.sh --host linux --stop-after llvm' "$T/j2" || { echo "compiler-llvm does not stop build-toolchain.sh after LLVM"; return 1; }
  grep -qx '        run: ./build-toolchain.sh --host linux' "$T/j3" || { echo "compiler-swift does not finish build-toolchain.sh"; return 1; }
  for j in j1 j2 j3; do
    grep -qx "    if: needs.compiler-probe.outputs.hit != 'true'" "$T/$j" || { echo "a compiler job ($j) runs on a cache hit"; return 1; }
    t="$(sed -n 's/^    timeout-minutes: \([0-9]*\).*/\1/p' "$T/$j")"
    [ -n "$t" ] && [ "$t" -le 355 ] || { echo "a compiler job ($j) has no timeout within GitHub's 360 minutes"; return 1; }
    grep -q 'sudo apt-get install -y .*uuid-dev' "$T/$j" && grep -q 'sudo apt-get install -y .*pkg-config' "$T/$j" \
      || { echo "a compiler job ($j) does not install uuid-dev and pkg-config"; return 1; }
  done
  grep -qx '    needs: \[compiler-probe\]' "$T/j1" && grep -qx '    needs: \[compiler-probe, compiler-tools\]' "$T/j2" \
    && grep -qx '    needs: \[compiler-probe, compiler-llvm\]' "$T/j3" && grep -qx '    needs: \[compiler-probe, compiler-swift\]' "$T/jr" \
    || { echo "the jobs do not run probe, tools, llvm, swift, runtime in that order"; return 1; }
  grep -qxF "    if: \${{ !cancelled() && needs.compiler-probe.result == 'success' && (needs.compiler-probe.outputs.hit == 'true' || needs.compiler-swift.result == 'success') }}" "$T/jr" \
    || { echo "the runtime job does not run on a hit, or after a built compiler alone"; return 1; }
  # The handoffs: same-run artifacts, tools to llvm and swift, llvm to swift.
  grep -q 'name: linux-compiler-tools' "$T/j1" && grep -q 'name: linux-compiler-tools' "$T/j2" && grep -q 'name: linux-compiler-tools' "$T/j3" \
    && grep -q 'name: linux-compiler-llvm' "$T/j2" && grep -q 'name: linux-compiler-llvm' "$T/j3" \
    || { echo "the compiler jobs do not hand their work on as artifacts"; return 1; }
  # The key: the inputs script over COMPILER_BUILD, in every job that probes, saves or restores it.
  for j in jp j3 jr; do
    grep -qF 'h="$(sh scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD)"' "$T/$j" \
      || { echo "a job ($j) does not hash COMPILER_BUILD's inputs itself"; return 1; }
    grep -qxF '          key: swift-linux-compiler-${{ runner.os }}-x86_64-${{ steps.inputs.outputs.hash }}' "$T/$j" \
      || { echo "a job ($j) does not key the compiler as swift-linux-compiler-<os>-x86_64-<inputs hash>"; return 1; }
    awk '/^          path: \|$/ { p = 1; next } p && /^            / { print; next } p { exit }' "$T/$j" > "$T/paths.$j"
    [ -s "$T/paths.$j" ] || { echo "a job ($j) names no cache paths"; return 1; }
  done
  cmp -s "$T/paths.jp" "$T/paths.j3" && cmp -s "$T/paths.j3" "$T/paths.jr" || { echo "the probe, the save and the restore name different paths"; return 1; }
  grep -q 'uses: actions/cache/restore@' "$T/jp" && grep -qx '          lookup-only: true' "$T/jp" || { echo "the probe is not a lookup-only restore"; return 1; }
  grep -q 'uses: actions/cache/save@' "$T/j3" || { echo "compiler-swift does not save the compiler"; return 1; }
  grep -q 'uses: actions/cache/restore@' "$T/jr" && grep -qx '          fail-on-cache-miss: true' "$T/jr" || { echo "the runtime job does not fail on a missing compiler"; return 1; }
  if grep -n 'hashFiles\|github\.action_ref\|SHIPYARD_VERSION\|ImageOS\|ImageVersion' "$T/jp" "$T/j3" "$T/jr" | grep -i key; then echo "a key hashes the runner image or shipyard's version"; return 1; fi
  # clang22 at the pinned release, through install@v1.
  for j in j1 jr; do
    grep -qF 'clang22="$(cat components/clang22/version)"' "$T/$j" && grep -qxF '          products: clang22@${{ steps.pins.outputs.clang22 }}' "$T/$j" \
      || { echo "a job ($j) does not install clang22 at components/clang22/version through install@v1"; return 1; }
  done
  # The runtime: build.sh on the cached compiler, the required reproducer after it, the pkg, the bundle when asked.
  awk '/fail-on-cache-miss: true/ { r = NR } /^          SWIFT_HOST_TOOLCHAIN_VERSION="\$\(cat VERSION\)" \.\/build\.sh$/ { b = NR }
       /^          CORO_FRAME_ORDER_REQUIRED=1 sh tests\/coro-frame-order-test\.sh$/ { c = NR }
       /REQUIRE_UPDATER=1 \.\/package\.sh/ { p = NR } /\.\/make-selftest\.sh/ { m = NR }
       END { exit !(r && r < b && b < c && c < p && p < m) }' "$T/jr" \
    || { echo "the runtime job does not restore the compiler, run build.sh, the required coroutine reproducer, package.sh and make-selftest.sh, in that order"; return 1; }
  grep -q 'echo "SWIFT_HOST_TOOLCHAIN=\$SWIFT_BUILD/work/toolchain-linux"' "$T/jr" || { echo "the runtime job does not build with the cached compiler"; return 1; }
  step "$T/jr" 'Build the self-test bundle' | grep -qx '        if: inputs.selftest' || { echo "the bundle is built whether asked or not"; return 1; }
  grep -q 'name: swift-linux$' "$T/jr" && grep -qF '${{ env.SWIFT_BUILD }}/dist/swift-runtime-selftest.tar.gz' "$T/jr" \
    && grep -qF '${{ env.SWIFT_BUILD }}/dist/swift-runtime-*.pkg' "$T/jr" || { echo "the runtime job does not upload its pkg and bundle as swift-linux"; return 1; }
  grep -qx '      version: ${{ steps.version.outputs.version }}' "$T/jr" || { echo "the runtime job does not output its version"; return 1; }
}
check_lb "$LB" > "$T/why" || fail "linux-build.yml: $(cat "$T/why")"
lb_mutant() { sed "$2" "$LB" > "$T/m.yml"; if check_lb "$T/m.yml" > "$T/why"; then fail "the check passed a linux-build.yml where $1"; fi; }
# lb_first <why> <line> <replacement lines...> -- the first line that is exactly <line>, replaced
lb_first() {
  why="$1"; line="$2"; shift 2
  R="$(printf '%s\n' "$@")" awk -v l="$line" '!d && $0 == l { print ENVIRON["R"]; d = 1; next } { print }' "$LB" > "$T/m.yml"
  cmp -s "$LB" "$T/m.yml" && fail "the mutant where $why changed nothing"
  if check_lb "$T/m.yml" > "$T/why"; then fail "the check passed a linux-build.yml where $why"; fi
}
lb_first "a job runs on macOS" '    runs-on: ubuntu-latest' '    runs-on: macos-26'
lb_first "a compiler job runs a script COMPILER_BUILD does not name" '        run: ./build-builtins.sh' '        run: ./build-builtins.sh' '      - name: x' '        run: ./mirror-toolchain.sh'
lb_mutant "COMPILER_BUILD omits a script the jobs run" 's/^  COMPILER_BUILD: build-llvm.sh build-builtins.sh build-toolchain.sh$/  COMPILER_BUILD: build-llvm.sh build-toolchain.sh/'
lb_mutant "compiler-llvm builds the whole compiler" 's/ --stop-after llvm$//'
lb_first "a compiler job runs on a hit" "    if: needs.compiler-probe.outputs.hit != 'true'" '    if: true'
lb_mutant "the key forgets the inputs" 's/-x86_64-\${{ steps.inputs.outputs.hash }}$/-x86_64-v1/'
lb_mutant "the key hashes the runner image" 's/-x86_64-\${{ steps.inputs.outputs.hash }}$/-x86_64-${{ steps.inputs.outputs.hash }}-${{ env.ImageVersion }}/'
lb_first "a job takes the hash from another job's shipyard" '          h="$(sh scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD)"' '          h="${{ needs.compiler-probe.outputs.hash }}"'
lb_mutant "the save names other paths" '/^  compiler-swift:$/,/^  runtime:$/ s|/mm-build/swift/out/llvm$|/mm-build/swift/out|'
lb_mutant "the runtime job builds on a miss with no compiler" '/^          fail-on-cache-miss: true$/d'
lb_mutant "the probe restores the whole compiler" '/^          lookup-only: true$/d'
lb_mutant "uuid-dev is not installed" 's/ uuid-dev//'
lb_mutant "clang22 is not the pinned one" 's/^          products: clang22@\${{ steps.pins.outputs.clang22 }}$/          products: clang22/'
lb_mutant "the reproducer may skip" 's/^          CORO_FRAME_ORDER_REQUIRED=1 sh tests/          sh tests/'
lb_mutant "build.sh runs on another compiler" 's|echo "SWIFT_HOST_TOOLCHAIN=$SWIFT_BUILD/work/toolchain-linux"|echo "SWIFT_HOST_TOOLCHAIN=/opt/swift"|'
lb_mutant "the bundle is always built" '/^        if: inputs.selftest$/d'
lb_first "a compiler job may outrun GitHub's limit" '    timeout-minutes: 355' '    timeout-minutes: 400'
lb_mutant "the runtime job runs whatever the compiler did" "s/ || needs.compiler-swift.result == 'success'//"

# Same-run bundle: a download from another run must be checked for this commit and linux-runtime.yml first.
crossrun() {
  awk -v d="$T" '/^      - / { n++ } n { print > (d "/cs." n) }' "$1"
  prev=""
  for f in $(ls "$T"/cs.* 2>/dev/null | sort -t. -k2 -n); do
    if grep -q 'uses: actions/download-artifact@' "$f" && grep -q '^ *run-id:' "$f"; then
      { [ -n "$prev" ] && grep -q 'gh api "repos/$GITHUB_REPOSITORY/actions/runs/' "$prev" \
        && grep -q '\.head_sha' "$prev" && grep -q '\.path' "$prev" && grep -q '\$GITHUB_SHA ' "$prev" && grep -q '\.github/workflows/linux-runtime\.yml' "$prev"; } \
        || { echo "a download from another run is not checked for this commit and linux-runtime.yml first"; rm -f "$T"/cs.*; return 1; }
    fi
    prev="$f"
  done
  rm -f "$T"/cs.*
}
job "$VM" vm-test > "$T/vmjob"
crossrun "$T/vmjob" > "$T/why" || fail "vm-test.yml: $(cat "$T/why")"
grep -q 'name: ${{ inputs.prebuilt_artifact }}' "$T/vmjob" || fail "vm-test.yml does not download the prebuilt artifact by name"
awk '{ print } $0 == "          name: ${{ inputs.prebuilt_artifact }}" {
       print "          run-id: ${{ inputs.run_id }}"; print "          github-token: ${{ github.token }}" }' "$T/vmjob" > "$T/xrun"
grep -q '^ *run-id:' "$T/xrun" || fail "the test could not make a cross-run download"
if crossrun "$T/xrun" > /dev/null; then fail "the check passed a cross-run download nobody checked"; fi
awk '/^      - name: Fetch the prebuilt/ && !d { print "      - name: Check the run the bundle comes from"
       print "        run: |"
       print "          r=\"$(gh api \"repos/$GITHUB_REPOSITORY/actions/runs/$RUN\" --jq '"'"'.head_sha + \" \" + .path'"'"')\""
       print "          [ \"$r\" = \"$GITHUB_SHA .github/workflows/linux-runtime.yml\" ] || exit 1"; d = 1 } { print }' "$T/xrun" > "$T/xrun-ok"
grep -q 'Check the run the bundle comes from' "$T/xrun-ok" || fail "the test could not add the run check"
crossrun "$T/xrun-ok" > "$T/why" || fail "the check refused a cross-run download checked for its commit and workflow: $(cat "$T/why")"
echo "PASS: linux-runtime-workflow"
