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
#   A linux-runtime job calls linux-build.yml with the run's version and no bundle, needing only version; an
#   equivalence job, on Linux with the pinned clang22, needs it but runs whatever it did once build-cross succeeded,
#   and compares its runtime pkg with build-cross's (scripts/equivalence-warnings.sh: a ::warning:: per difference,
#   never a failure, for now), or warns that there was none to compare; neither collect nor publish waits for either.
#   Every job on a macos-* runner, in any workflow, is declared in INGREDIENTS.md as
#   `- macos-runner:<file>:<job>: <reason, exit>`, and linux-runtime.yml and the workflows it calls run on none.
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
# builds it, on the Mac (build-cross) and on Linux (linux-build.yml's runtime job) alike.
updater() {
  awk '/^  build-cross:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" \
    | awk '/^      - name: Build swift-runtime-updater\.app/ { s = 1; print; next } s && /^      - / { exit } s' > "$T/upd"
  [ -s "$T/upd" ] || { echo "build-cross has no swift-runtime-updater step"; return 1; }
  grep -qx '        run: sh scripts/build-runtime-updater.sh' "$T/upd" || { echo "build-cross does not build the updater with scripts/build-runtime-updater.sh"; return 1; }
  grep -qx '          sh scripts/build-runtime-updater.sh' "$2" || grep -qx '        run: sh scripts/build-runtime-updater.sh' "$2" \
    || { echo "linux-build.yml does not build the updater with scripts/build-runtime-updater.sh"; return 1; }
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
LBW="$REPO/.github/workflows/linux-build.yml"; UPD="$REPO/scripts/build-runtime-updater.sh"
[ -f "$LBW" ] && [ -f "$UPD" ] || fail "no linux-build.yml or no scripts/build-runtime-updater.sh"
updater "$W" "$LBW" "$UPD" > "$T/why" || fail "release.yml: $(cat "$T/why")"
upd_mutant() {
  sed "$2" "$UPD" > "$T/mutant.sh"
  if updater "$W" "$LBW" "$T/mutant.sh" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
upd_mutant "an updater built by Apple's clang" 's|-DCMAKE_OBJC_COMPILER="$CL/bin/clang"|-DCMAKE_OBJC_COMPILER=/usr/bin/clang|'
upd_mutant "an updater whose Swift link is not checked" "/grep -q 'libswift' .*updater links/d"
upd_mutant "an updater whose Swift link only warns" 's/self-update circularity)" >\&2; exit 1; }/self-update circularity)" >\&2; }/'
sed 's|^        run: sh scripts/build-runtime-updater.sh$|        run: true|' "$W" > "$T/mutant.yml"
if updater "$T/mutant.yml" "$LBW" "$UPD" > /dev/null; then fail "accepted a build-cross that builds no updater with the shared script"; fi

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
  grep -qx '    uses: ./.github/workflows/linux-build.yml' "$T/lj" || { echo "linux-runtime does not call linux-build.yml"; return 1; }
  grep -qx '    needs: \[version\]' "$T/lj" || { echo "linux-runtime does not need version alone"; return 1; }
  grep -qx '      version: ${{ needs.version.outputs.version }}' "$T/lj" || { echo "linux-runtime does not build the run's version"; return 1; }
  grep -qx '      selftest: false' "$T/lj" || { echo "linux-runtime builds a bundle no release.yml job reads"; return 1; }
  awk '/^  collect:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" > "$T/cj"
  grep -qx '    needs: \[version, build, build-cross\]' "$T/cj" || { echo "collect does not need version, build and build-cross alone"; return 1; }
  if grep -q 'linux-runtime\|swift-linux\|equivalence' "$T/cj"; then echo "collect waits for, or reads, the Linux runtime: the release's path does not"; return 1; fi
  awk '/^  publish:$/ { j = 1; next } /^  [a-z-]+:$/ { j = 0 } j' "$1" | grep '^    needs:' > "$T/pn"
  if grep -q 'equivalence\|linux-runtime' "$T/pn"; then echo "publish waits for the warn-only comparison"; return 1; fi
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
lin_mutant "a Linux build of another version" 's/^      version: \${{ needs.version.outputs.version }}$/      version: ""/'

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
  for x in "$REPO/.github/workflows/linux-runtime.yml" "$REPO/.github/workflows/linux-build.yml"; do
    if grep -q '^ *runs-on:.*macos' "$x"; then echo "${x##*/} runs on macOS"; return 1; fi
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

echo "PASS"
