#!/bin/sh
# platform: host-agnostic -- python3 (standard library only)
# usage: sh tests/stage-selftest-support-test.sh
#   scripts/stage-selftest-support.sh against a fake stdlib build and a fixture tree: each test a list
#   includes is copied to upstream/<layer>/<path> beside its compile-line, <path>.args, and each further
#   variant's (scripts/upstream-tests.py variants), <path>.<n>.args, which make-selftest.sh builds into
#   <layer>-<name>-v<n>; a test with one variant has no numbered file; the support dylibs and modules land in
#   lib/ and modules/; a list that does not match the tree stages nothing.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/stage-support.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SB="$T/stdlib-build"
for m in SwiftPrivate SwiftPrivateLibcExtras SwiftPrivateThreadExtras StdlibUnittest; do
  mkdir -p "$SB/selftest-support/x86_64" "$SB/selftest-support/$m.swiftmodule"
  : > "$SB/selftest-support/x86_64/libswift$m.dylib"; : > "$SB/selftest-support/$m.swiftmodule/x86_64-apple-macos.swiftmodule"
done
R="$T/tree"; mkdir -p "$R/utils" "$R/test/Concurrency/Runtime" "$T/lists"
: > "$R/utils/gyb"
printf '%s\n' 'SwiftStdlib 5.1:macOS 10.15' > "$R/utils/availability-macros.def"
printf '%s\n' '// RUN: %target-run-simple-swift(-parse-as-library)' \
  '// RUN: %target-run-simple-swift(-parse-as-library -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature NonisolatedNonsendingByDefault)' \
  '// REQUIRES: concurrency' 'import _Concurrency' > "$R/test/Concurrency/Runtime/Two.swift"
printf '%s\n' '// RUN: %target-run-simple-swift' '// REQUIRES: concurrency' 'import _Concurrency' > "$R/test/Concurrency/Runtime/One.swift"
printf '%s\n' '// RUN: %target-run-simple-swift | %FileCheck %s' 'import _Concurrency' > "$R/test/Concurrency/Runtime/Checked.swift"
printf '%s\n' 'exclude test/Concurrency/Runtime/Checked.swift -- needs FileCheck' 'include test/Concurrency/Runtime/One.swift' \
  'include test/Concurrency/Runtime/Two.swift' > "$T/lists/concurrency.list"
O="$T/out"
sh "$REPO/scripts/stage-selftest-support.sh" "$SB" "$R" "$T/lists" "$O" > "$T/log" 2>&1 || fail "staging failed: $(cat "$T/log")"
U="$O/upstream/concurrency/test/Concurrency/Runtime"
cl() { python3 -I "$REPO/scripts/upstream-tests.py" compile-line "$R" "test/Concurrency/Runtime/$1" "$2"; }
for f in One.swift One.swift.args Two.swift Two.swift.args Two.swift.2.args; do [ -f "$U/$f" ] || fail "no $f: $(find "$O")"; done
[ ! -e "$U/One.swift.2.args" ] && [ ! -e "$U/Two.swift.3.args" ] && [ ! -e "$U/Two.swift.1.args" ] || fail "a variant file too many: $(find "$O")"
[ ! -e "$U/Checked.swift" ] || fail "staged an excluded test"
cl Two.swift 1 | cmp -s - "$U/Two.swift.args" || fail "Two.swift.args is not variant 1's compile-line"
cl Two.swift 2 | cmp -s - "$U/Two.swift.2.args" || fail "Two.swift.2.args is not variant 2's compile-line"
grep -qx 'NonisolatedNonsendingByDefault' "$U/Two.swift.2.args" || fail "variant 2 lacks its own flags: $(cat "$U/Two.swift.2.args")"
if grep -qx 'NonisolatedNonsendingByDefault' "$U/Two.swift.args"; then fail "variant 1 has variant 2's flags"; fi
cl One.swift 1 | cmp -s - "$U/One.swift.args" || fail "One.swift.args is not its compile-line"
for m in SwiftPrivate StdlibUnittest; do
  [ -f "$O/lib/libswift$m.dylib" ] && [ -d "$O/modules/$m.swiftmodule" ] || fail "no $m in lib/ or modules/: $(find "$O")"
done
grep -q 'and 2 upstream tests (3 builds)' "$T/log" || fail "did not count the tests and their builds: $(cat "$T/log")"

echo "-- a list that does not match the tree stages nothing"
sed '/One.swift/d' "$T/lists/concurrency.list" > "$T/l2" && mkdir -p "$T/lists2" && mv "$T/l2" "$T/lists2/concurrency.list"
if sh "$REPO/scripts/stage-selftest-support.sh" "$SB" "$R" "$T/lists2" "$T/out2" > "$T/log" 2>&1; then fail "staged a list that misses a candidate"; fi
[ ! -d "$T/out2/upstream/concurrency" ] || fail "staged tests from a list that does not match"
echo "PASS"
