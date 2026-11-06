#!/bin/sh
# platform: host-agnostic -- python3 (standard library only)
# usage: sh tests/upstream-tests-test.sh
#   scripts/upstream-tests.py against a fixture tree. survey must print each test with a RUN: line that a
#   layer's classifier picks (Darwin: imports Darwin, or is one of upstream's Darwin-named files;
#   ObjectiveC: imports ObjectiveC or REQUIRES objc_interop), from test/stdlib, test/Concurrency/Runtime and
#   validation-test/stdlib, and nothing without a RUN: line. check must pass a list naming every candidate
#   once (include, or exclude with a reason), and fail on a missing candidate, a duplicate, a stray path, an
#   exclude without a reason, an unknown verb, and an include whose compile-line refuses. compile-line must
#   translate each RUN form it knows into swiftc arguments, one per line, and refuse FileCheck, an unknown
#   substitution, arguments or input handed to the test, and more than one executable step.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UT="$REPO/scripts/upstream-tests.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 -- skipping"; exit 77; }
[ -f "$UT" ] || fail "no $UT"
T="$(mktemp -d "${TMPDIR:-/tmp}/upstream-tests.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ut() { python3 -I "$UT" "$@"; }

R="$T/tree"
mkdir -p "$R/utils" "$R/test/stdlib/Inputs" "$R/test/Concurrency/Runtime" "$R/validation-test/stdlib"
printf '%s\n' '# comment' '' 'SwiftStdlib 5.1:macOS 10.15, iOS 13.0' 'SwiftStdlib 6.2:macOS 26.0' \
  'SwiftStdlib 9999:macOS 9999' > "$R/utils/availability-macros.def"
t() {  # t <path> <line>... -- writes a fixture test
  f="$R/$1"; shift; printf '%s\n' "$@" > "$f"
}
t test/stdlib/Simple.swift '// RUN: %target-run-simple-swift' '// REQUIRES: executable_test' 'import Darwin'
t test/stdlib/Flags.swift '// RUN: %target-run-simple-swift(-Xfrontend -disable-availability-checking -parse-as-library -swift-version 5)' \
  'import StdlibUnittest' 'import Darwin'
t test/stdlib/Triple.swift '// RUN: %target-run-simple-swift(-target %target-swift-5.1-abi-triple)' 'import Darwin'
t test/stdlib/Built.swift '// RUN: %empty-directory(%t)' '// RUN: %target-build-swift -g %s -o %t/a.out -module-name a' \
  '// RUN: %target-codesign %t/a.out' '// RUN: %target-run %t/a.out' 'import Darwin'
t test/stdlib/Gybbed.swift.gyb '// RUN: %target-run-simple-swiftgyb(-parse-stdlib)' 'import Darwin'
t test/stdlib/GybBuilt.swift.gyb '// RUN: %empty-directory(%t)' '// RUN: %gyb %s -o %t/G.swift' \
  '// RUN: %line-directive %t/G.swift -- %target-build-swift %t/G.swift -o %t/a.out' '// RUN: %target-codesign %t/a.out' \
  '// RUN: %line-directive %t/G.swift -- %target-run %t/a.out' 'import Darwin'
t test/stdlib/Continued.swift '// RUN: %target-run-simple-swift( \' '// RUN:   -parse-as-library)' 'import Darwin'
t test/stdlib/Checked.swift '// RUN: %target-run-simple-swift | %FileCheck %s' 'import Darwin'
t test/stdlib/Unknown.swift '// RUN: %target-run-simple-swift(%import-libdispatch)' 'import Darwin'
t test/stdlib/Args.swift '// RUN: %target-run-simple-swift %t' 'import Darwin'
t test/stdlib/Stdin.swift '// RUN: %empty-directory(%t)' '// RUN: %target-build-swift %s -o %t/a.out' \
  '// RUN: %target-run %t/a.out < %S/Inputs/in.txt' 'import Darwin'
t test/stdlib/Twice.swift '// RUN: %target-run-simple-swift' '// RUN: %target-run-simple-swift(-O)' 'import Darwin'
t test/stdlib/Verify.swift '// RUN: %target-typecheck-verify-swift' 'import Darwin'
t test/stdlib/tgmath.swift '// RUN: %target-run-simple-swift' 'import StdlibUnittest'
t test/stdlib/Runtime.swift '// RUN: %target-run-simple-swift' '// REQUIRES: objc_interop' 'import StdlibUnittest'
t test/stdlib/NoRun.swift '// REQUIRES: executable_test' 'import Darwin' 'import ObjectiveC'
t test/stdlib/Inputs/Helper.swift '// RUN: %target-run-simple-swift' 'import Darwin'
t test/Concurrency/Runtime/Objc.swift '// RUN: %target-run-simple-swift' 'import ObjectiveC'
t validation-test/stdlib/Both.swift '// RUN: %target-run-simple-swift' '// REQUIRES: executable_test' \
  '// REQUIRES: objc_interop' 'import Darwin'
t validation-test/stdlib/Neither.swift '// RUN: %target-run-simple-swift' 'import Swift'

# (compile-line only: these import Swift, so they are no survey candidates)
t test/stdlib/FlagExt.swift '// RUN: %target-run-simple-swift(-enable-experimental-feature Extern -Ounchecked)' 'import Swift'
t test/stdlib/FlagExp.swift '// RUN: %target-run-simple-swift(-enable-experimental-feature Lifetimes)' 'import Swift'
t test/stdlib/FlagLlvm.swift '// RUN: %target-run-simple-swift(-Xllvm -sil-print-all)' 'import Swift'
t test/stdlib/FlagD.swift '// RUN: %target-run-simple-swift(-DFOO)' 'import Swift'
t test/stdlib/StrictArg.swift '// RUN: %target-run-simple-swift -strict-concurrency=complete' 'import Swift'
t test/stdlib/CondOk.swift '// RUN: %target-run-simple-swift' '// REQUIRES: executable_test' \
  '// REQUIRES: VENDOR=apple || OS=linux-gnu' '// UNSUPPORTED: freestanding' '// UNSUPPORTED: CPU=arm64 && OS=macosx' 'import Swift'
t test/stdlib/ReqLinux.swift '// RUN: %target-run-simple-swift' '// REQUIRES: OS=linux-gnu' 'import Swift'
t test/stdlib/ReqUnknown.swift '// RUN: %target-run-simple-swift' '// REQUIRES: some_feature_we_lack' 'import Swift'
t test/stdlib/UnsMac.swift '// RUN: %target-run-simple-swift' '// UNSUPPORTED: OS=macosx' 'import Swift'
t test/stdlib/UnsNeg.swift '// RUN: %target-run-simple-swift' '// UNSUPPORTED: !freestanding' 'import Swift'
t test/stdlib/UnsBack.swift '// RUN: %target-run-simple-swift' '// UNSUPPORTED: back_deployment_runtime' 'import Swift'
t test/stdlib/ReqBad.swift '// RUN: %target-run-simple-swift' '// REQUIRES: (executable_test' 'import Swift'

echo "-- survey: each layer's candidates, sorted; nothing without a RUN: line, nothing in Inputs/"
ut survey "$R" darwin > "$T/d" || fail "survey darwin failed"
ut survey "$R" objectivec > "$T/o" || fail "survey objectivec failed"
printf '%s\n' test/stdlib/Args.swift test/stdlib/Built.swift test/stdlib/Checked.swift test/stdlib/Continued.swift \
  test/stdlib/Flags.swift test/stdlib/GybBuilt.swift.gyb test/stdlib/Gybbed.swift.gyb test/stdlib/Simple.swift \
  test/stdlib/Stdin.swift test/stdlib/Triple.swift test/stdlib/Twice.swift test/stdlib/Unknown.swift \
  test/stdlib/Verify.swift test/stdlib/tgmath.swift validation-test/stdlib/Both.swift > "$T/d.want"
printf '%s\n' test/Concurrency/Runtime/Objc.swift test/stdlib/Runtime.swift validation-test/stdlib/Both.swift > "$T/o.want"
diff "$T/d.want" "$T/d" > "$T/diff" || fail "survey darwin: $(cat "$T/diff")"
diff "$T/o.want" "$T/o" > "$T/diff" || fail "survey objectivec: $(cat "$T/diff")"
if ut survey "$R" nosuchlayer > /dev/null 2>&1; then fail "survey accepted an unknown layer"; fi

echo "-- check: every candidate once, include or exclude -- reason"
{ echo '# objectivec, a comment'; echo
  echo 'include test/Concurrency/Runtime/Objc.swift'
  echo 'exclude test/stdlib/Runtime.swift -- needs Foundation, which no 10.9 pkg ships'
  echo 'include validation-test/stdlib/Both.swift'; } > "$T/o.list"
ut check "$R" objectivec "$T/o.list" > "$T/out" 2>&1 || fail "check refused a good list: $(cat "$T/out")"
bad() {  # bad <what> <sed> <expected message>
  sed "$2" "$T/o.list" > "$T/b.list"
  if ut check "$R" objectivec "$T/b.list" > "$T/out" 2>&1; then fail "check passed a list where $1"; fi
  grep -q -- "$3" "$T/out" || fail "check did not say '$3' where $1: $(cat "$T/out")"
}
bad "a candidate is missing" '/Objc.swift/d' 'test/Concurrency/Runtime/Objc.swift: not in the list'
bad "a candidate is listed twice" '$a\
exclude validation-test/stdlib/Both.swift -- again' 'validation-test/stdlib/Both.swift: listed more than once'
bad "a path is no candidate" '$a\
include test/stdlib/Simple.swift' 'test/stdlib/Simple.swift: not a objectivec candidate'
bad "an exclude has no reason" 's/ -- needs Foundation.*//' 'test/stdlib/Runtime.swift: an exclude needs " -- <reason>"'
bad "an exclude has an empty reason" 's/ -- needs Foundation.*/ -- /' 'test/stdlib/Runtime.swift: an exclude needs " -- <reason>"'
bad "a verb is unknown" 's/^include validation/skip validation/' "unknown line"
{ echo 'include test/stdlib/Checked.swift'; ut survey "$R" darwin | grep -v Checked | sed 's/$/ -- fixture/; s/^/exclude /'; } > "$T/d.list"
if ut check "$R" darwin "$T/d.list" > "$T/out" 2>&1; then fail "check passed an include whose compile-line refuses"; fi
grep -q 'test/stdlib/Checked.swift: an include whose compile-line refuses: needs FileCheck' "$T/out" || fail "check did not name the refusal: $(cat "$T/out")"

echo "-- compile-line: the forms it knows"
AV='-Xfrontend
-define-availability
-Xfrontend
SwiftStdlib 5.1:macOS 10.15, iOS 13.0
-Xfrontend
-define-availability
-Xfrontend
StdlibDeploymentTarget 5.1:macOS 10.9
-Xfrontend
-define-availability
-Xfrontend
SwiftStdlib 6.2:macOS 26.0
-Xfrontend
-define-availability
-Xfrontend
StdlibDeploymentTarget 6.2:macOS 10.9
-Xfrontend
-define-availability
-Xfrontend
SwiftStdlib 9999:macOS 9999
-Xfrontend
-define-availability
-Xfrontend
StdlibDeploymentTarget 9999:macOS 9999'
cl() {  # cl <path> <expected tail, one argument per line, after lit's -swift-version 4 and the availability list>
  ut compile-line "$R" "$1" > "$T/cl" 2> "$T/err" || fail "compile-line refused $1: $(cat "$T/err")"
  printf '%s\n%s\n%s\n' '-swift-version' 4 "$AV" > "$T/want"
  [ -z "$2" ] || printf '%s\n' "$2" >> "$T/want"
  diff "$T/want" "$T/cl" > "$T/diff" || fail "compile-line $1: $(cat "$T/diff")"
}
cl test/stdlib/Simple.swift '-module-name
main'
cl test/stdlib/Flags.swift '-Xfrontend
-disable-availability-checking
-parse-as-library
-swift-version
5
-module-name
main'
cl test/stdlib/Triple.swift '-target
x86_64-apple-macosx10.15
-module-name
main'
cl test/stdlib/Built.swift '-g
-module-name
a'
cl test/stdlib/Gybbed.swift.gyb '-parse-stdlib
-module-name
main'
cl test/stdlib/GybBuilt.swift.gyb ''
cl test/stdlib/FlagExt.swift '-enable-experimental-feature
Extern
-Ounchecked
-module-name
main'
cl test/stdlib/StrictArg.swift '-module-name
main'
cl test/stdlib/CondOk.swift '-module-name
main'
cl test/stdlib/Continued.swift '-parse-as-library
-module-name
main'

echo "-- compile-line: what it refuses, and why"
refuse() {  # refuse <path> <expected message>
  if ut compile-line "$R" "$1" > "$T/cl" 2> "$T/err"; then fail "compile-line translated $1: $(cat "$T/cl")"; fi
  grep -q -- "$2" "$T/err" || fail "compile-line $1: wanted '$2', got: $(cat "$T/err")"
}
refuse test/stdlib/Checked.swift 'needs FileCheck, which no 10.9 pkg ships'
refuse test/stdlib/Unknown.swift 'RUN uses %import-libdispatch'
refuse test/stdlib/Args.swift 'RUN hands the test arguments'
refuse test/stdlib/Stdin.swift 'RUN redirects the test'
refuse test/stdlib/Twice.swift 'more than one executable step'
refuse test/stdlib/Verify.swift 'RUN uses %target-typecheck-verify-swift'
refuse test/stdlib/NoRun.swift 'no RUN: line'
refuse test/stdlib/FlagExp.swift 'RUN uses -enable-experimental-feature Lifetimes'
refuse test/stdlib/FlagLlvm.swift 'RUN uses the flag -Xllvm'
refuse test/stdlib/FlagD.swift 'RUN uses the flag -DFOO'
refuse test/stdlib/ReqLinux.swift 'REQUIRES: OS=linux-gnu does not hold on 10.9'
refuse test/stdlib/ReqUnknown.swift 'REQUIRES: some_feature_we_lack does not hold on 10.9'
refuse test/stdlib/UnsMac.swift 'UNSUPPORTED: OS=macosx holds on 10.9'
refuse test/stdlib/UnsNeg.swift 'holds on 10.9'
refuse test/stdlib/UnsBack.swift 'UNSUPPORTED: back_deployment_runtime holds on 10.9'
refuse test/stdlib/ReqBad.swift 'does not parse'
echo "PASS"
