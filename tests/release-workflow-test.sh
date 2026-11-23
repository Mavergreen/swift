#!/bin/sh
# platform: host-agnostic
# usage: sh tests/release-workflow-test.sh
#   .github/workflows/release.yml's build job is main's required check, and GitHub counts a skipped required
#   check as passed. So build must run whatever its needs did (if: !cancelled()), and its first step must fail
#   unless version and build-cross both succeeded: a failed build-cross must fail the check, never skip it
#   (PR 9 automerged 6.4.1 with 6.4.0's tarball pins that way). Each check is run against a workflow mutated to
#   break it, and must refuse it. Its guard steps (build-cross's and build's) must guard the payload's
#   builtins archive and its Recaulk archive (lib/recaulk/librecaulk.a, linked whole) by name, and the payload's
#   Mach-O files exactly: build-cross wants and guards the four tools and the nine stdlib dylibs by name, and
#   build counts thirteen.
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

# The Mach-O files of each toolchain payload: build-cross names its thirteen in the want list and guards the nine
# dylibs among them; build, which finds its own, wants thirteen.
STDLIB_DYLIBS="libswiftCore libswiftSwiftOnoneSupport libswiftDarwin libswiftObjectiveC libswiftDispatch libswift_Concurrency libswiftCoreFoundation libswiftCoreGraphics libswiftFoundation"
machos() {
  awk '$0 == "  build-cross:" { on = 1; next } /^  [a-z-]+:$/ { on = 0 } on' "$1" > "$T/bc"
  awk '/^      - name: Compat guard over the cross toolchain payload/ { on = 1; next } on && /^      - / { exit } on' "$T/bc" > "$T/bcg"
  grep -qx '          # Exactly these thirteen, so nothing new in the payload goes unguarded.' "$T/bcg" \
    || { echo "build-cross's want list does not say thirteen"; return 1; }
  sed -n '/^          printf /,/cross-want"$/p' "$T/bcg" > "$T/want"
  sed -n '/^          \.\/scripts\/guard\.sh "\$P\/lib\/swift\/macosx/,/[^\\]$/p' "$T/bcg" > "$T/gd"
  for l in $STDLIB_DYLIBS; do
    grep -q "\"\$P/lib/swift/macosx/$l\.dylib\"" "$T/want" || { echo "build-cross's want list lacks $l.dylib"; return 1; }
    grep -q "\"\$P/lib/swift/macosx/$l\.dylib\"" "$T/gd" || { echo "build-cross does not guard $l.dylib"; return 1; }
  done
  [ "$(grep -o '"\$P/[^"]*"' "$T/want" | wc -l | tr -d ' ')" = 13 ] || { echo "build-cross's want list does not name 13 files"; return 1; }
  awk '$0 == "  build:" { on = 1; next } /^  [a-z-]+:$/ { on = 0 } on' "$1" > "$T/b"
  grep -q '^          \[ "\$n" -eq 13 \] ||' "$T/b" || { echo "build does not want 13 Mach-O files"; return 1; }
}
machos "$W" > "$T/why" || fail "release.yml: $(cat "$T/why")"
for m in 's/ "\$P\/lib\/swift\/macosx\/libswiftFoundation\.dylib"//' 's/-eq 13 /-eq 12 /' 's/Exactly these thirteen/Exactly these/'; do
  sed "$m" "$W" > "$T/mutant-m.yml"
  if machos "$T/mutant-m.yml" > "$T/why"; then fail "accepted a payload list mutated by $m"; fi
  echo "  refused $m: $(cat "$T/why")"
done

mutant() {
  sed "$2" "$W" > "$T/mutant.yml"
  if check "$T/mutant.yml" > "$T/why"; then fail "accepted $1"; fi
  echo "  refused $1: $(cat "$T/why")"
}
mutant "a build skipped on a failed need" '/^    if: \${{ !cancelled() }}$/d'
mutant "a guard that only warns" '/build, the required check, must not pass/{n;s/exit 1/true/;}'
mutant "a guard after the checkout" '/^      - name: Fail unless version and build-cross succeeded$/,/^          exit 1$/d'
echo "PASS"
