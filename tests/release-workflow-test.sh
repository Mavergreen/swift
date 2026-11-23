#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-workflow-test.sh
#   .github/workflows/release.yml's build job is main's required check, and GitHub counts a skipped required
#   check as passed. So build must run whatever its needs did (if: !cancelled()), and its first step must fail
#   unless version and build-cross both succeeded: a failed build-cross must fail the check, never skip it
#   (PR 9 automerged 6.4.1 with 6.4.0's tarball pins that way). Each check is run against a workflow mutated to
#   break it, and must refuse it. Its guard steps (build-cross's and build's) must guard the payload's
#   builtins archive and its Recaulk archive (lib/recaulk/librecaulk.a, linked whole) by name. build-cross builds
#   the runtime's updater with scripts/build-runtime-updater.sh, as the Linux runtime job does: clang22
#   (fetch-clang22.sh's), never Apple's /usr/bin/clang, and a failure when that updater links a Swift runtime
#   library. build runs tests/coro-frame-order-test.sh, with CORO_FRAME_ORDER_REQUIRED=1, after the step that
#   unpacks the same run's cross toolchain and sets SWIFT_HOST_TOOLCHAIN.
#   The one Linux path per push is release.yml's own (no other workflow builds the runtime on Linux): it names the
#   compiler build's scripts once (COMPILER_BUILD, top-level env); linux-compiler-probe, -tools, -llvm and -swift run
#   exactly those, and the cache key, swift-linux-compiler-<runner.os>-x86_64-<hash>, hashes what they read
#   (scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD). The probe outputs its hash; every later Linux job
#   hashes again after installing shipyard, a compiler job stops with an ::error:: naming both when they differ,
#   linux-compiler-swift saves under the probe's, and linux-runtime says so before restoring under its own. A hit
#   skips the compiler jobs; a miss builds in three (build-llvm.sh and build-builtins.sh; build-toolchain.sh
#   --stop-after llvm; build-toolchain.sh, after logging LLVM's ninja -n), each within six hours, handing work on as
#   same-run artifacts. linux-runtime builds with the cached compiler at the run's version, runs the coroutine
#   reproducer with CORO_FRAME_ORDER_REQUIRED=1, the pkg with its updater (scripts/build-runtime-updater.sh, as
#   build-cross) and the self-test bundle, and uploads them as swift-linux, a name no other job uploads.
#   vm-test-prebuilt (needing version and linux-runtime) gates that bundle on 10.9; an equivalence job, on Linux with
#   the pinned clang22, needs linux-runtime but runs whatever it did once build-cross succeeded, and compares its
#   runtime pkg with build-cross's (scripts/equivalence-warnings.sh: a ::warning:: per difference, never a failure,
#   for now), or warns that there was none to compare; neither collect nor publish waits for any of them. A bundle
#   crossing from another run must be checked for this commit and release.yml first. Every job on a macos-* runner,
#   in any workflow, is declared in INGREDIENTS.md as `- macos-runner:<file>:<job>: <reason, exit>`, and no Linux
#   job runs on one.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/release-workflow-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The checks, on the workflow $1; the first that fails names itself on stdout.
check() {
  awk '/^  build:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/job"
  grep -qx '    needs: \[version, build-cross\]' "$T/job" || { echo "build does not need version and build-cross"; return 1; }
  grep -qx '    if: ${{ !cancelled() }}' "$T/job" || { echo "build is skipped when a need fails"; return 1; }
  awk '/^    steps:$/ { s = 1; next } s && /^      - / { print; getline; print; exit }' "$T/job" > "$T/first"
  grep -qx '      - name: Fail unless version and build-cross succeeded' "$T/first" \
    && grep -qxF "        if: \${{ needs.version.result != 'success' || needs.build-cross.result != 'success' }}" "$T/first" \
    || { echo "build's first step is not the guard"; return 1; }
  awk '/^      - name: Fail unless version and build-cross succeeded$/ { g = 1; next } g && /^      - / { exit } g' "$T/job" > "$T/guard"
  grep -qx '          exit 1' "$T/guard" || { echo "the guard does not fail"; return 1; }
}

W="$REPO/.github/workflows/release.yml"
check "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"

# The archives each toolchain bundles are not executable, so the guard steps' Mach-O lists miss them: each
# step guards its payload's builtins archive and Recaulk's (linked whole) by name.
archives() {
  for job in build-cross build; do
    awk -v j="  $job:" '$0 == j { on = 1; next } /^  [a-z-]+:$/ { on = 0 } on' "$1" > "$T/$job"
    grep -q '^          \./scripts/guard\.sh .*/lib/clang/\*/lib/darwin/libclang_rt\.osx\.a$' "$T/$job" \
      || { echo "$job does not guard its builtins archive by name"; return 1; }
    grep -A1 '^          \./scripts/guard\.sh --linked-with ".*/bin/ld64\.lld"' "$T/$job" | grep -q '/lib/recaulk/librecaulk\.a"$' \
      || { echo "$job does not guard its Recaulk archive by name, linked whole"; return 1; }
  done
}
archives "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"
for job in build-cross build; do
  sed "/^  $job:\$/,/^  [a-z-]*:\$/{/--linked-with/d;}" "$W" > "$T/no-rk.yml"
  if archives "$T/no-rk.yml" > /dev/null; then fail "a $job without Recaulk's guard passed"; fi
done

# The runtime's updater: clang22 builds it on every host (shipyard's convention), with clang22's own target and
# linker flags; its load commands, read with clang22's llvm-otool, must name no Swift runtime library. One script
# builds it, on the Mac (build-cross) and on Linux (linux-runtime) alike.
updater() {
  awk '/^  build-cross:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" \
    | awk '/^      - name: Build swift-runtime-updater\.app/ { s = 1; print; next } s && /^      - / { exit } s' > "$T/upd"
  [ -s "$T/upd" ] || { echo "build-cross has no swift-runtime-updater step"; return 1; }
  grep -qx '        run: sh scripts/build-runtime-updater.sh' "$T/upd" || { echo "build-cross does not build the updater with scripts/build-runtime-updater.sh"; return 1; }
  awk '/^  linux-runtime:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$2" | grep -qx '        run: sh scripts/build-runtime-updater.sh' \
    || { echo "linux-runtime does not build the updater with scripts/build-runtime-updater.sh"; return 1; }
  U="$3"
  ! grep -v '^[[:space:]]*#' "$U" | grep -q '/usr/bin/clang' || { echo "build-runtime-updater.sh builds the runtime's updater with /usr/bin/clang"; return 1; }
  grep -q 'CL="$(sh "$HERE/fetch-clang22.sh")"' "$U" || { echo "build-runtime-updater.sh does not take clang22 from fetch-clang22.sh"; return 1; }
  for a in '-DCMAKE_OBJC_COMPILER="$CL/bin/clang"' -DCMAKE_OBJC_COMPILER_TARGET=x86_64-apple-macos10.9 \
    -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
    '-DCMAKE_TOOLCHAIN_FILE="$SHIPYARD/../MavericksToolchain.cmake"'; do
    grep -qF -- "$a" "$U" || { echo "build-runtime-updater.sh does not configure $a"; return 1; }
  done
  grep -qF '"$CL/bin/llvm-otool" -L "$B/swift-runtime-updater.app/Contents/MacOS/swift-runtime-updater"' "$U" \
    && grep -q "| grep -q 'libswift' || { echo \"::error::updater links a Swift runtime library (self-update circularity)\" >&2; exit 1; }" "$U" \
    || { echo "build-runtime-updater.sh does not fail on an updater that links a Swift runtime library"; return 1; }
}
LBW="$W"; UPD="$REPO/scripts/build-runtime-updater.sh"
[ -f "$UPD" ] || fail "no scripts/build-runtime-updater.sh"
for gone in linux-build.yml linux-runtime.yml; do
  [ ! -e "$REPO/.github/workflows/$gone" ] || fail ".github/workflows/$gone is still here: release.yml's Linux jobs are the one Linux path per push"
done
updater "$W" "$LBW" "$UPD" > "$T/why" || fail "release.yml: $(cat "$T/why")"
upd_mutant() {
  sed "$2" "$UPD" > "$T/mutant.sh"
  if updater "$W" "$LBW" "$T/mutant.sh" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
upd_mutant "an updater built by Apple's clang" 's|-DCMAKE_OBJC_COMPILER="$CL/bin/clang"|-DCMAKE_OBJC_COMPILER=/usr/bin/clang|'
upd_mutant "an updater whose Swift link is not checked" "/grep -q 'libswift' .*updater links/d"
upd_mutant "an updater whose Swift link only warns" 's/self-update circularity)" >\&2; exit 1; }/self-update circularity)" >\&2; }/'
sed '/^  build-cross:$/,/^  build:$/ s|^        run: sh scripts/build-runtime-updater.sh$|        run: true|' "$W" > "$T/mutant.yml"
if updater "$T/mutant.yml" "$T/mutant.yml" "$UPD" > /dev/null; then fail "accepted a build-cross that builds no updater with the shared script"; fi
sed '/^  linux-runtime:$/,$ s|^        run: sh scripts/build-runtime-updater.sh$|        run: true|' "$W" > "$T/mutant.yml"
if updater "$T/mutant.yml" "$T/mutant.yml" "$UPD" > /dev/null; then fail "accepted a linux-runtime that builds no updater with the shared script"; fi

# The coroutine frame reproducer runs in build, on the same run's cross toolchain once its step has set
# SWIFT_HOST_TOOLCHAIN, required: a skip there (no compiler, no stdlib) must fail the step.
coro() {
  awk '/^  build:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/cjob"
  u="$(grep -n '^      - name: Unpack the same run.s cross toolchain$' "$T/cjob" | cut -d: -f1)"
  c="$(grep -n '^          CORO_FRAME_ORDER_REQUIRED=1 sh tests/coro-frame-order-test\.sh$' "$T/cjob" | cut -d: -f1)"
  [ -n "$c" ] || { echo "build does not run tests/coro-frame-order-test.sh with CORO_FRAME_ORDER_REQUIRED=1"; return 1; }
  [ -n "$u" ] && [ "$u" -lt "$c" ] || { echo "build runs the coroutine frame test before the cross toolchain sets SWIFT_HOST_TOOLCHAIN"; return 1; }
}
coro "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"
coro_mutant() {
  sed "$2" "$W" > "$T/mutant.yml"
  if coro "$T/mutant.yml" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
coro_mutant "a coroutine frame test that may skip" 's/CORO_FRAME_ORDER_REQUIRED=1 sh tests/sh tests/'
coro_mutant "a build without the coroutine frame test" '/coro-frame-order-test/d'
coro_mutant "a coroutine frame test with no cross toolchain before it" '/^      - name: Unpack the same run.s cross toolchain$/d'

mutant() {
  sed "$2" "$W" > "$T/mutant.yml"
  if check "$T/mutant.yml" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
mutant "a build skipped on a failed need" '/^    if: \${{ !cancelled() }}$/d'
mutant "a guard that only warns" '/build, the required check, must not pass/{n;s/exit 1/true/;}'
mutant "a guard after the checkout" '/^      - name: Fail unless version and build-cross succeeded$/,/^          exit 1$/d'
# The Linux runtime beside build-cross, and the equivalence job's comparison of the two runtime pkgs: warnings, never
# a failure, and off the release's path (neither collect nor publish waits for it).
linux() {
  awk '/^  linux-runtime:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/lj"
  [ -s "$T/lj" ] || { echo "release.yml has no linux-runtime job"; return 1; }
  grep -qxF '          VERSION_IN: ${{ needs.version.outputs.version }}' "$T/lj" || { echo "linux-runtime does not build the run's version"; return 1; }
  # Its bundle's gate: vm-test-prebuilt, never on the release's path.
  awk '/^  vm-test-prebuilt:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/vp"
  [ -s "$T/vp" ] || { echo "release.yml has no vm-test-prebuilt job"; return 1; }
  grep -qx '    needs: \[version, linux-runtime\]' "$T/vp" || { echo "vm-test-prebuilt does not need version and linux-runtime"; return 1; }
  grep -qx '          prebuilt_artifact: swift-linux' "$T/vp" || { echo "vm-test-prebuilt does not gate linux-runtime's swift-linux"; return 1; }
  # Every artifact a job of the run uploads has a name of its own: swift-linux is never swift-cross or swift-native.
  grep -A3 'uses: actions/upload-artifact@' "$1" | sed -n 's/^ *name: \([^ ]*\).*/\1/p; s/^ *with: { *name: \([^,]*\),.*/\1/p' | sort > "$T/up"
  grep -qx swift-linux "$T/up" && grep -qx swift-cross "$T/up" && grep -qx swift-native "$T/up" || { echo "the run does not upload swift-linux, swift-cross and swift-native: $(tr '\n' ' ' < "$T/up")"; return 1; }
  [ -z "$(uniq -d "$T/up")" ] || { echo "two jobs upload the same artifact name: $(uniq -d "$T/up" | tr '\n' ' ')"; return 1; }
  awk '/^  collect:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/cj"
  grep -qx '    needs: \[version, build, build-cross\]' "$T/cj" || { echo "collect does not need version, build and build-cross alone"; return 1; }
  if grep -q 'linux-runtime\|swift-linux\|equivalence' "$T/cj"; then echo "collect waits for, or reads, the Linux runtime: the release's path does not"; return 1; fi
  awk '/^  publish:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" | grep '^    needs:' > "$T/pn"
  if grep -q 'equivalence\|linux-runtime' "$T/pn"; then echo "publish waits for the warn-only comparison"; return 1; fi
  if grep -q 'vm-test-prebuilt' "$T/pn"; then echo "publish waits for the Linux-built bundle's gate"; return 1; fi
  awk '/^  equivalence:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/ej"
  [ -s "$T/ej" ] || { echo "release.yml has no equivalence job"; return 1; }
  grep -qx '    needs: \[version, build-cross, linux-runtime\]' "$T/ej" || { echo "equivalence does not need version, build-cross and linux-runtime"; return 1; }
  grep -qxF "    if: \${{ !cancelled() && needs.build-cross.result == 'success' }}" "$T/ej" \
    || { echo "equivalence does not run whatever linux-runtime did, once build-cross succeeded"; return 1; }
  grep -qx '    runs-on: ubuntu-latest' "$T/ej" || { echo "equivalence does not run on Linux (build-equivalence.sh is host-agnostic)"; return 1; }
  grep -qxF '          products: clang22@${{ steps.pins.outputs.clang22 }}' "$T/ej" && grep -qF 'clang22="$(cat components/clang22/version)"' "$T/ej" \
    || { echo "equivalence does not install the pinned clang22 (its Mach-O readers)"; return 1; }
  grep -q 'name: swift-cross, path: dist' "$T/ej" && grep -q 'name: swift-linux, path: linux-dist' "$T/ej" \
    || { echo "equivalence does not download swift-cross and swift-linux"; return 1; }
  awk '/^      - name: The Linux runtime pkg against build-cross/ { s = 1; print; next } s && /^      - / { exit } s' "$T/ej" > "$T/eq"
  [ -s "$T/eq" ] || { echo "equivalence does not compare the Linux runtime pkg with build-cross's"; return 1; }
  grep -qF 'LINUX_RESULT: ${{ needs.linux-runtime.result }}' "$T/eq" && grep -q '::warning::' "$T/eq" \
    || { echo "equivalence does not warn when linux-runtime did not succeed"; return 1; }
  grep -qF 'sh scripts/equivalence-warnings.sh "$(ls dist/swift-runtime-[0-9]*.pkg)" "$(ls linux-dist/swift-runtime-[0-9]*.pkg)"' "$T/eq" \
    || { echo "equivalence does not run build-equivalence (scripts/equivalence-warnings.sh) on build-cross's runtime pkg against linux-runtime's"; return 1; }
  if grep -q 'exit 1\|build-equivalence\.sh' "$T/eq"; then echo "the comparison can fail the job"; return 1; fi
}
linux "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"
lin_mutant() { sed "$2" "$W" > "$T/mutant.yml"; cmp -s "$W" "$T/mutant.yml" && fail "the mutant where $1 changed nothing"
  if linux "$T/mutant.yml" > "$T/why"; then fail "accepted $1"; fi; echo "  refused $1: $(cat "$T/why")"; }
lin_mutant "no linux-runtime job" 's/^  linux-runtime:$/  linux-gone:/'
lin_mutant "a collect that waits for the Linux build" 's/^    needs: \[version, build, build-cross\]$/    needs: [version, build, build-cross, linux-runtime]/'
lin_mutant "a publish that waits for the comparison" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan, vm-test, equivalence]/'
lin_mutant "no equivalence job" 's/^  equivalence:$/  equivalence-gone:/'
lin_mutant "an equivalence that skips when the Linux build failed" "s/^    if: \${{ !cancelled() \&\& needs.build-cross.result == 'success' }}\$/    if: success()/"
lin_mutant "an equivalence on macOS" '/^  equivalence:$/,$ s/^    runs-on: ubuntu-latest$/    runs-on: macos-26/'
lin_mutant "a comparison that fails on a difference" 's|\(sh scripts/equivalence-warnings.sh .*\)$|\1 \&\& exit 1|'
lin_mutant "a comparison that blocks on build-equivalence.sh" 's|sh scripts/equivalence-warnings.sh |sh "$SHIPYARD_SCRIPTS/build-equivalence.sh" |'
lin_mutant "a comparison with no Linux pkg" 's/name: swift-linux, path: linux-dist/name: swift-cross, path: linux-dist/'
lin_mutant "a Linux build of another version" 's/^          VERSION_IN: \${{ needs.version.outputs.version }}$/          VERSION_IN: ""/'
lin_mutant "no gate for the Linux-built bundle" 's/^  vm-test-prebuilt:$/  vm-test-gone:/'
lin_mutant "a publish that waits for the Linux-built bundle's gate" 's/^    needs: \[collect, scan, vm-test\]$/    needs: [collect, scan, vm-test, vm-test-prebuilt]/'
lin_mutant "the Linux-built bundle's gate takes build-cross's pkgs" 's/^          prebuilt_artifact: swift-linux$/          prebuilt_artifact: swift-cross/'
lin_mutant "the Linux runtime uploads under build-cross's name" '/^  linux-runtime:$/,$ s/^          name: swift-linux$/          name: swift-cross/'

# macOS runners: every job on one declares why, and when it leaves.
macos() {
  for wf in "$REPO"/.github/workflows/*.yml; do
    [ "${wf##*/}" = release.yml ] && wf="$1"
    awk -v w="$(basename "$wf")" '/^jobs:$/ { j = 1; next } j && /^  [A-Za-z][A-Za-z0-9_-]*:$/ { id = $1; sub(/:$/, "", id) }
      j && id && /^    runs-on:.*macos-/ { print (w == "" ? "release.yml" : w) ":" id }' "$wf"
  done | sed 's|^[^:]*/||' > "$T/macjobs"
  [ -s "$T/macjobs" ] || { echo "no macOS job found at all (the parser is broken)"; return 1; }
  sed -n '/^## Conformance deviations/,/^## /p' "$2" > "$T/devs"
  while IFS= read -r k; do
    case "$k" in mutant.yml:*) k="release.yml:${k#mutant.yml:}" ;; esac
    grep -q "^- macos-runner:$k: .*exit" "$T/devs" || { echo "$k runs on macOS with no '- macos-runner:$k: <reason, exit>' in INGREDIENTS.md"; return 1; }
  done < "$T/macjobs"
  for j in linux-compiler-probe linux-compiler-tools linux-compiler-llvm linux-compiler-swift linux-runtime vm-test-prebuilt equivalence; do
    if grep -qx "release.yml:$j" "$T/macjobs"; then echo "release.yml's $j runs on macOS"; return 1; fi
  done
}
ING="$REPO/INGREDIENTS.md"
macos "$W" "$ING" > "$T/why" || fail "$(cat "$T/why")"
for j in build-cross build collect; do grep -qx "release.yml:$j" "$T/macjobs" || fail "the macOS parser missed release.yml:$j"; done
# version is shell and git: it runs on Linux.
awk '/^  version:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$W" | grep -qx '    runs-on: ubuntu-latest' || fail "release.yml's version job does not run on Linux"
for j in build-cross build collect; do
  sed "/^- macos-runner:release.yml:$j: /d" "$ING" > "$T/ing"
  if macos "$W" "$T/ing" > "$T/why"; then fail "accepted release.yml:$j on macOS undeclared"; fi
  echo "  refused $j undeclared: $(cat "$T/why")"
done
sed 's/^  scan:$/  extra:\
    runs-on: macos-26\
    steps: [{ run: true }]\
  scan:/' "$W" > "$T/mutant.yml"
if macos "$T/mutant.yml" "$ING" > "$T/why"; then fail "accepted a new macOS job undeclared"; fi
echo "  refused a new macOS job: $(cat "$T/why")"

# job <workflow> <id> -- the job's lines, without its id line
job() { awk -v j="  $2:" '/^jobs:$/ { in_ = 1; next } in_ && $0 == j { on = 1; next } in_ && /^  [A-Za-z][A-Za-z0-9_-]*:/ { on = 0 } on' "$1"; }
# step <job file> <name prefix> -- the step whose name starts so, from its "- " line to the next step's
step() { awk -v p="      - name: $2" 'index($0, p) == 1 { on = 1; print; next } on && /^      - / { exit } on' "$1"; }
# jobs <workflow> -- its job ids
jobs_of() { awk '/^jobs:$/ { in_ = 1; next } in_ && /^  [A-Za-z][A-Za-z0-9_-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$1"; }

# The compiler build: one named list, one key, three jobs on a miss, none on a hit.
check_lb() {
  for j in linux-compiler-probe linux-compiler-tools linux-compiler-llvm linux-compiler-swift linux-runtime; do
    job "$1" "$j" | grep -qx '    runs-on: ubuntu-latest' || { echo "release.yml's $j does not run on ubuntu-latest"; return 1; }
  done
  # The Linux jobs only read the repo: release.yml's own contents: write is never theirs, and no checkout leaves
  # the token behind for a later step.
  for j in linux-compiler-probe linux-compiler-tools linux-compiler-llvm linux-compiler-swift linux-runtime; do
    job "$1" "$j" > "$T/perm"
    awk '/^    permissions:/ { p = 1; sub(/^    permissions: */, ""); if ($0 != "") print; next } p && /^      / { sub(/^ +/, ""); print; next } p { exit }' "$T/perm" > "$T/perms"
    [ "$(cat "$T/perms")" = '{ contents: read }' ] || [ "$(cat "$T/perms")" = 'contents: read' ] \
      || { echo "release.yml's $j is not given contents: read alone (it would inherit the workflow's contents: write)"; return 1; }
    awk '/uses: actions\/checkout@/ { c = 1; n++ } c && /persist-credentials: false/ { ok++; c = 0 } /^      - / && !/actions\/checkout@/ { c = 0 } END { exit !(n && n == ok) }' "$T/perm" \
      || { echo "release.yml's $j checks out with persist-credentials left on"; return 1; }
  done
  [ "$(grep -c '^  COMPILER_BUILD: ' "$1")" -eq 1 ] || { echo "release.yml does not name COMPILER_BUILD once, at the top"; return 1; }
  cb="$(sed -n 's/^  COMPILER_BUILD: *//p' "$1" | tr ' ' '\n' | grep . | LC_ALL=C sort)"
  for j in linux-compiler-probe linux-compiler-tools linux-compiler-llvm linux-compiler-swift linux-runtime; do
    jobs_of "$1" | grep -qx "$j" || { echo "release.yml has no job $j"; return 1; }
  done
  # What the compiler jobs run is COMPILER_BUILD, exactly.
  for j in linux-compiler-tools linux-compiler-llvm linux-compiler-swift; do job "$1" "$j"; done \
    | sed -n 's|^ *\(run: \)\{0,1\}\./\([A-Za-z0-9_-]*\.sh\)\( .*\)\{0,1\}$|\2|p' | LC_ALL=C sort -u > "$T/ran"
  [ "$(cat "$T/ran")" = "$cb" ] || { echo "the compiler jobs run [$(tr '\n' ' ' < "$T/ran")], not COMPILER_BUILD [$(printf '%s' "$cb" | tr '\n' ' ')]"; return 1; }
  job "$1" linux-compiler-tools > "$T/j1"; job "$1" linux-compiler-llvm > "$T/j2"; job "$1" linux-compiler-swift > "$T/j3"; job "$1" linux-runtime > "$T/jr"; job "$1" linux-compiler-probe > "$T/jp"
  grep -qx '        run: ./build-toolchain.sh --host linux --stop-after llvm' "$T/j2" || { echo "linux-compiler-llvm does not stop build-toolchain.sh after LLVM"; return 1; }
  grep -qx '        run: ./build-toolchain.sh --host linux' "$T/j3" || { echo "linux-compiler-swift does not finish build-toolchain.sh"; return 1; }
  for j in j1 j2 j3; do
    grep -qx "    if: needs.linux-compiler-probe.outputs.hit != 'true'" "$T/$j" || { echo "a compiler job ($j) runs on a cache hit"; return 1; }
    t="$(sed -n 's/^    timeout-minutes: \([0-9]*\).*/\1/p' "$T/$j")"
    [ -n "$t" ] && [ "$t" -le 355 ] || { echo "a compiler job ($j) has no timeout within GitHub's 360 minutes"; return 1; }
    grep -q 'sudo apt-get install -y .*uuid-dev' "$T/$j" && grep -q 'sudo apt-get install -y .*pkg-config' "$T/$j" \
      || { echo "a compiler job ($j) does not install uuid-dev and pkg-config"; return 1; }
  done
  grep -qx '    needs: \[linux-compiler-probe\]' "$T/j1" && grep -qx '    needs: \[linux-compiler-probe, linux-compiler-tools\]' "$T/j2" \
    && grep -qx '    needs: \[linux-compiler-probe, linux-compiler-llvm\]' "$T/j3" && grep -qx '    needs: \[version, linux-compiler-probe, linux-compiler-swift\]' "$T/jr" \
    || { echo "the jobs do not run probe, tools, llvm, swift, runtime in that order"; return 1; }
  grep -qxF "    if: \${{ !cancelled() && needs.version.result == 'success' && needs.linux-compiler-probe.result == 'success' && (needs.linux-compiler-probe.outputs.hit == 'true' || needs.linux-compiler-swift.result == 'success') }}" "$T/jr" \
    || { echo "the runtime job does not run on a hit, or after a built compiler alone"; return 1; }
  # The handoffs: same-run artifacts, tools to llvm and swift, llvm to swift.
  grep -q 'name: linux-compiler-tools' "$T/j1" && grep -q 'name: linux-compiler-tools' "$T/j2" && grep -q 'name: linux-compiler-tools' "$T/j3" \
    && grep -q 'name: linux-compiler-llvm' "$T/j2" && grep -q 'name: linux-compiler-llvm' "$T/j3" \
    || { echo "the compiler jobs do not hand their work on as artifacts"; return 1; }
  # The key: the inputs script over COMPILER_BUILD. The probe's hash is the run's; every later job hashes again from
  # its own shipyard, after installing it, and a compiler job stops on a difference.
  grep -qxF '      hash: ${{ steps.inputs.outputs.hash }}' "$T/jp" || { echo "linux-compiler-probe does not output its hash"; return 1; }
  for j in jp j1 j2 j3 jr; do
    grep -qF 'h="$(sh scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD)"' "$T/$j" \
      || { echo "a job ($j) does not hash COMPILER_BUILD's inputs itself"; return 1; }
    awk '/uses: Mavergreen\/shipyard\/\.github\/actions\/install@/ { i = NR } /--hash \$COMPILER_BUILD/ && !h { h = NR } END { exit !(i && i < h) }' "$T/$j" \
      || { echo "a job ($j) hashes before it installs shipyard"; return 1; }
  done
  for j in j1 j2 j3 jr; do
    grep -qxF '          PROBE_HASH: ${{ needs.linux-compiler-probe.outputs.hash }}' "$T/$j" && grep -q '\[ "\$h" = "\$PROBE_HASH" \] ||' "$T/$j" \
      && grep '\[ "\$h" = "\$PROBE_HASH" \] ||' "$T/$j" | grep -q '::error::.*\$h.*\$PROBE_HASH' \
      || { echo "a job ($j) does not compare its hash with linux-compiler-probe's, naming both in an ::error::"; return 1; }
  done
  for j in j1 j2 j3; do
    grep '\[ "\$h" = "\$PROBE_HASH" \] ||' "$T/$j" | grep -q 'exit 1; }$' || { echo "a compiler job ($j) goes on with a hash linux-compiler-probe did not look up"; return 1; }
  done
  awk '/\[ "\$h" = "\$PROBE_HASH" \] \|\|/ { e = NR } /fail-on-cache-miss: true/ { r = NR } END { exit !(e && e < r) }' "$T/jr" \
    || { echo "the runtime job does not compare the hashes before its restore"; return 1; }
  grep -qxF '          key: swift-linux-compiler-${{ runner.os }}-x86_64-${{ steps.inputs.outputs.hash }}' "$T/jp" \
    && grep -qxF '          key: swift-linux-compiler-${{ runner.os }}-x86_64-${{ steps.inputs.outputs.hash }}' "$T/jr" \
    || { echo "the probe and the restore do not key the compiler as swift-linux-compiler-<os>-x86_64-<their inputs hash>"; return 1; }
  grep -qxF '          key: swift-linux-compiler-${{ runner.os }}-x86_64-${{ needs.linux-compiler-probe.outputs.hash }}' "$T/j3" \
    || { echo "linux-compiler-swift does not save under the probe's hash"; return 1; }
  for j in jp j3 jr; do
    awk '/^          path: \|$/ { p = 1; next } p && /^            / { print; next } p { exit }' "$T/$j" > "$T/paths.$j"
    [ -s "$T/paths.$j" ] || { echo "a job ($j) names no cache paths"; return 1; }
  done
  # linux-compiler-swift says whether LLVM's ninja has anything left to do, before build-toolchain.sh.
  awk '/ninja -C "\$SWIFT_BUILD\/work\/llvm-linux" -n / { n = NR } /^        run: \.\/build-toolchain\.sh --host linux$/ { b = NR } END { exit !(n && n < b) }' "$T/j3" \
    || { echo "linux-compiler-swift does not log LLVM's ninja -n before it builds"; return 1; }
  cmp -s "$T/paths.jp" "$T/paths.j3" && cmp -s "$T/paths.j3" "$T/paths.jr" || { echo "the probe, the save and the restore name different paths"; return 1; }
  grep -q 'uses: actions/cache/restore@' "$T/jp" && grep -qx '          lookup-only: true' "$T/jp" || { echo "the probe is not a lookup-only restore"; return 1; }
  grep -q 'uses: actions/cache/save@' "$T/j3" || { echo "linux-compiler-swift does not save the compiler"; return 1; }
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
  if step "$T/jr" 'Build the self-test bundle' | grep -q '^        if:'; then echo "the bundle vm-test-prebuilt gates is not always built"; return 1; fi
  grep -q 'name: swift-linux$' "$T/jr" && grep -qF '${{ env.SWIFT_BUILD }}/dist/swift-runtime-selftest.tar.gz' "$T/jr" \
    && grep -qF '${{ env.SWIFT_BUILD }}/dist/swift-runtime-*.pkg' "$T/jr" || { echo "the runtime job does not upload its pkg and bundle as swift-linux"; return 1; }
  grep -qxF '          VERSION_IN: ${{ needs.version.outputs.version }}' "$T/jr" && grep -qx '    needs: \[version, linux-compiler-probe, linux-compiler-swift\]' "$T/jr" \
    || { echo "the Linux runtime does not carry the run's version"; return 1; }
}
LB="$W"; VM="$REPO/.github/actions/vm-test/action.yml"
check_lb "$LB" > "$T/why" || fail "release.yml: $(cat "$T/why")"
lb_mutant() { sed "$2" "$LB" > "$T/m.yml"; if check_lb "$T/m.yml" > "$T/why"; then fail "the Linux-build check passed a release.yml where $1"; fi; }
# lb_first <why> <line> <replacement lines...> -- the first line from the Linux jobs on that is exactly <line>, replaced
lb_first() {
  why="$1"; line="$2"; shift 2
  R="$(printf '%s\n' "$@")" awk -v l="$line" '/^  linux-compiler-probe:$/ { on = 1 } on && !d && $0 == l { print ENVIRON["R"]; d = 1; next } { print }' "$LB" > "$T/m.yml"
  cmp -s "$LB" "$T/m.yml" && fail "the mutant where $why changed nothing"
  if check_lb "$T/m.yml" > "$T/why"; then fail "the Linux-build check passed a release.yml where $why"; fi
}
lb_first "a job runs on macOS" '    runs-on: ubuntu-latest' '    runs-on: macos-26'
lb_first "a compiler job runs a script COMPILER_BUILD does not name" '        run: ./build-builtins.sh' '        run: ./build-builtins.sh' '      - name: x' '        run: ./mirror-toolchain.sh'
lb_mutant "COMPILER_BUILD omits a script the jobs run" 's/^  COMPILER_BUILD: build-llvm.sh build-builtins.sh build-toolchain.sh$/  COMPILER_BUILD: build-llvm.sh build-toolchain.sh/'
lb_mutant "linux-compiler-llvm builds the whole compiler" 's/ --stop-after llvm$//'
lb_first "a compiler job runs on a hit" "    if: needs.linux-compiler-probe.outputs.hit != 'true'" '    if: true'
lb_mutant "the key forgets the inputs" 's/-x86_64-\${{ steps.inputs.outputs.hash }}$/-x86_64-v1/'
lb_mutant "the key hashes the runner image" 's/-x86_64-\${{ steps.inputs.outputs.hash }}$/-x86_64-${{ steps.inputs.outputs.hash }}-${{ env.ImageVersion }}/'
lb_first "a job takes the hash from another job's shipyard" '          h="$(sh scripts/compiler-cache-inputs.sh --hash $COMPILER_BUILD)"' '          h="${{ needs.linux-compiler-probe.outputs.hash }}"'
lb_mutant "the probe does not output its hash" '/^      hash: \${{ steps.inputs.outputs.hash }}$/d'
lb_mutant "linux-compiler-swift saves under its own hash" 's/^          key: swift-linux-compiler-\${{ runner.os }}-x86_64-\${{ needs.linux-compiler-probe.outputs.hash }}$/          key: swift-linux-compiler-${{ runner.os }}-x86_64-${{ steps.inputs.outputs.hash }}/'
lb_mutant "a compiler job only warns of a hash that moved" '/^  linux-compiler-llvm:$/,/^  linux-compiler-swift:$/ s/; exit 1; }$/; }/'
lb_mutant "no job compares the hashes" '/\[ "\$h" = "\$PROBE_HASH" \] ||/d'
lb_mutant "the runtime job says nothing of a hash that moved" '/^  linux-runtime:$/,/^  [a-z-]*:$/ { /\[ "\$h" = "\$PROBE_HASH" \] ||/d; }'
lb_mutant "linux-compiler-swift does not log LLVM's ninja -n" '/ninja -C "\$SWIFT_BUILD\/work\/llvm-linux" -n /d'

lb_mutant "the save names other paths" '/^  linux-compiler-swift:$/,/^  linux-runtime:$/ s|/mm-build/swift/out/llvm$|/mm-build/swift/out|'
lb_mutant "the runtime job builds on a miss with no compiler" '/^          fail-on-cache-miss: true$/d'
lb_mutant "the probe restores the whole compiler" '/^          lookup-only: true$/d'
lb_mutant "uuid-dev is not installed" 's/ uuid-dev//'
lb_mutant "clang22 is not the pinned one" 's/^          products: clang22@\${{ steps.pins.outputs.clang22 }}$/          products: clang22/'
lb_mutant "the reproducer may skip" 's/^          CORO_FRAME_ORDER_REQUIRED=1 sh tests/          sh tests/'
lb_mutant "build.sh runs on another compiler" 's|echo "SWIFT_HOST_TOOLCHAIN=$SWIFT_BUILD/work/toolchain-linux"|echo "SWIFT_HOST_TOOLCHAIN=/opt/swift"|'
lb_mutant "the bundle is built only when asked" 's|^      - name: Build the self-test bundle with the Linux-hosted compiler$|&\
        if: inputs.selftest|'
lb_first "a compiler job may outrun GitHub's limit" '    timeout-minutes: 355' '    timeout-minutes: 400'
lb_first "a Linux job may write the repo" '    permissions: { contents: read }' '    permissions: { contents: write }'
lb_mutant "a Linux job inherits the workflow's permissions" '/^  linux-compiler-llvm:$/,/^  linux-compiler-swift:$/ { /^    permissions: { contents: read }$/d; }'
lb_mutant "a Linux checkout keeps the token" '/^  linux-runtime:$/,/^  vm-test-prebuilt:$/ s/persist-credentials: false/persist-credentials: true/'
lb_mutant "a Linux checkout says nothing of the token" '/^  linux-compiler-tools:$/,/^  linux-compiler-llvm:$/ s/^        with: { persist-credentials: false }$//'
lb_mutant "the runtime job runs whatever the compiler did" "s/ || needs.linux-compiler-swift.result == 'success'//"

# Same-run bundle: a download from another run must be checked for this commit and release.yml first.
crossrun() {
  awk -v d="$T" '/^      - / { n++ } n { print > (d "/cs." n) }' "$1"
  prev=""
  for f in $(ls "$T"/cs.* 2>/dev/null | sort -t. -k2 -n); do
    if grep -q 'uses: actions/download-artifact@' "$f" && grep -q '^ *run-id:' "$f"; then
      { [ -n "$prev" ] && grep -q 'gh api "repos/$GITHUB_REPOSITORY/actions/runs/' "$prev" \
        && grep -q '\.head_sha' "$prev" && grep -q '\.path' "$prev" && grep -q '\$GITHUB_SHA ' "$prev" && grep -q '\.github/workflows/release\.yml' "$prev"; } \
        || { echo "a download from another run is not checked for this commit and release.yml first"; rm -f "$T"/cs.*; return 1; }
    fi
    prev="$f"
  done
  rm -f "$T"/cs.*
}
# The action's steps, at a job's indentation.
awk '/^  steps:$/ { s = 1; next } s' "$VM" | sed 's/^/  /' > "$T/vmjob"
crossrun "$T/vmjob" > "$T/why" || fail "the vm-test action: $(cat "$T/why")"
grep -q 'name: ${{ inputs.prebuilt_artifact }}' "$T/vmjob" || fail "the vm-test action does not download the prebuilt artifact by name"
awk '{ print } $0 == "          name: ${{ inputs.prebuilt_artifact }}" {
       print "          run-id: ${{ inputs.run_id }}"; print "          github-token: ${{ github.token }}" }' "$T/vmjob" > "$T/xrun"
grep -q '^ *run-id:' "$T/xrun" || fail "the test could not make a cross-run download"
if crossrun "$T/xrun" > /dev/null; then fail "the check passed a cross-run download nobody checked"; fi
awk '/^      - name: Fetch the prebuilt/ && !d { print "      - name: Check the run the bundle comes from"
       print "        run: |"
       print "          r=\"$(gh api \"repos/$GITHUB_REPOSITORY/actions/runs/$RUN\" --jq '"'"'.head_sha + \" \" + .path'"'"')\""
       print "          [ \"$r\" = \"$GITHUB_SHA .github/workflows/release.yml\" ] || exit 1"; d = 1 } { print }' "$T/xrun" > "$T/xrun-ok"
grep -q 'Check the run the bundle comes from' "$T/xrun-ok" || fail "the test could not add the run check"
crossrun "$T/xrun-ok" > "$T/why" || fail "the check refused a cross-run download checked for its commit and workflow: $(cat "$T/why")"

echo "PASS"
