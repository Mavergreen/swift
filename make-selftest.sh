#!/bin/sh
# platform: macOS-only -- the default compiler runs on a modern Mac; SWIFTC= mode runs on OS X 10.9 itself
#   usage: make-selftest.sh
#          Compiles every tests/*.swift at -O and -Onone into a self-test bundle for a 10.9 box --
#          bin/<name> and bin/<name>-Onone, plus run-selftest.sh -- and prints the tarball's path last.
#          A test's leading comment lines may hold `// swiftc: <flags>`, flags its compiles take after the
#          compiler's own: only -parse-as-library (for @main in a one-file program), as anything else
#          (-disable-availability-checking, say) would test another program than its users compile; any
#          other flag fails the bundle. A test whose first line is `// selftest: skip: <reason>` is built
#          in neither mode, saying why. The one so marked: concurrency_isolation_test, whose
#          MainActor.assumeIsolated and preconditionIsolated call dispatch_assert_queue$V2, which 10.9's
#          libdispatch lacks and Recaulk does not provide yet (requested: INGREDIENTS.md's Owed list);
#          its marker goes when Recaulk ships it.
#          Two compilers:
#            default          the swift.org toolchain build.sh expanded, for x86_64-apple-macosx10.9,
#                             -no-stdlib-rpath and one rpath, $SWIFT_RUNTIME_PREFIX/lib/swift
#                             (default /usr/local/mavergreen/swift-runtime). Run after build.sh. As
#                             build-module.sh compiles the overlays: against the 10.9 SDK (shipyard's
#                             fetch_sdk.sh, with SDKSettings.json), whose ObjC declarations the tests are
#                             written to (-hash is a method there, a property in a modern SDK), with
#                             -resource-dir the stdlib build's lib/swift, so the Swift, Darwin and
#                             ObjectiveC modules imported, and the dylibs linked, are this build's, never
#                             an SDK's; -runtime-compatibility-version none, as that tree has no
#                             compatibility archives (nor does the runtime need them). A test whose
#                             first line is `// selftest: needs this repo's compiler ...` is skipped,
#                             saying so: it uses a feature only compiler patch 0003 opens for 10.9,
#                             which the swift.org compiler refuses (typed_throws_test,
#                             parameter_packs_test, stdlib_availability_test); so, with SELFTEST_SUPPORT,
#                             are upstream's concurrency tests, saying so: their async code for 10.9
#                             needs patch 0003 too. SWIFTC= mode builds every test.
#            SWIFTC=<swiftc>  exactly `$SWIFTC -O|-Onone <file> -o <out>`: this repo's own toolchain,
#                             on 10.9, whose defaults supply target, SDK and rpath. With SWIFT_RUNTIME_PREFIX
#                             also set (a staged, uninstalled runtime), each compile adds
#                             `-Xlinker -headerpad_max_install_names`, and an install_name_tool then
#                             replaces the wrapper's rpath with $SWIFT_RUNTIME_PREFIX/lib/swift:
#                             INSTALL_NAME_TOOL, else mavericks-clang-22's llvm-install-name-tool
#                             (CLANG22_PREFIX, default /usr/local/mavergreen/clang22) where it is
#                             installed, else install_name_tool from PATH.
#          SELFTEST_SUPPORT=<dir> (scripts/stage-selftest-support.sh's layout, which build.sh stages as
#          $SWIFT_BUILD/payload/selftest-support) adds upstream's own tests (spec: "Upstream tests"): each
#          <dir>/upstream/<layer>/<path>.args, compiled from <path> (for a .gyb, gyb's output beside it) at
#          -O and -Onone with the arguments that file lists, one per line (its compile-line), and
#          `-I <dir>/modules -L <dir>/lib -Xlinker -rpath -Xlinker @executable_path/../../lib`, into
#          upstream/bin/<layer>-<name> and <layer>-<name>-Onone, and each further variant of it (lit
#          builds it again with other flags), <path>.<n>.args, into <layer>-<name>-v<n> and
#          <layer>-<name>-v<n>-Onone; and <dir>/lib, the test-support dylibs,
#          is copied to the bundle's lib/, which that rpath reaches from upstream/bin/. The support
#          modules are binary .swiftmodule files: the compiler here must be the release that built them.
#          Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, TC (toolchain usr/), DIST (output dir),
#          SWIFT_RUNTIME_PREFIX, SWIFTC, INSTALL_NAME_TOOL, CLANG22_PREFIX, SELFTEST_SRC (the dir whose
#          *.swift are the tests, default this repo's tests/), SELFTEST_SUPPORT.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/lib.sh"    # -> $SWIFT_BUILD
DIST="${DIST:-$SWIFT_BUILD/dist}"
SKIP_MARK=""   # the default mode's: see the usage above
if [ -n "${SWIFTC:-}" ]; then
  [ -x "$SWIFTC" ] || { echo "make-selftest: SWIFTC=$SWIFTC is not executable" >&2; exit 1; }
  if [ -n "${SWIFT_RUNTIME_PREFIX:-}" ]; then
    # The prefix becomes every test's rpath, so a mistyped one (an unset MAVERICKS_BUILD_ROOT made it
    # /swift/payload/...) would surface only on the box, as a dyld failure in every test.
    case "$SWIFT_RUNTIME_PREFIX" in /*) ;; *) echo "make-selftest: SWIFT_RUNTIME_PREFIX=$SWIFT_RUNTIME_PREFIX is not an absolute path" >&2; exit 1 ;; esac
    [ -f "$SWIFT_RUNTIME_PREFIX/lib/swift/libswiftCore.dylib" ] || {
      echo "make-selftest: SWIFT_RUNTIME_PREFIX=$SWIFT_RUNTIME_PREFIX has no lib/swift/libswiftCore.dylib -- run build.sh, or name the staged runtime" >&2; exit 1; }
    # platform: the toolchain's swiftc always adds the INSTALLED runtime's rpath, first, so an added
    #           rpath would lose to it; so it is replaced. 10.9's install_name_tool refuses to grow the
    #           load commands without the header padding the first line asks the linker for, and is the
    #           Command Line Tools', a stub without them: clang22's llvm-install-name-tool does the same.
    INT="${INSTALL_NAME_TOOL:-}"
    if [ -z "$INT" ]; then
      INT="${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}/bin/llvm-install-name-tool"
      [ -x "$INT" ] || INT=install_name_tool
    fi
    compile() {
      _c_o="$1" _c_s="$2" _c_out="$3"; shift 3
      "$SWIFTC" "-$_c_o" -Xlinker -headerpad_max_install_names "$_c_s" -o "$_c_out" "$@" >&2 &&
        "$INT" -rpath /usr/local/mavergreen/swift-runtime/lib/swift "$SWIFT_RUNTIME_PREFIX/lib/swift" "$_c_out" >&2
    }
  else
    compile() { _c_o="$1" _c_s="$2" _c_out="$3"; shift 3; "$SWIFTC" "-$_c_o" "$_c_s" -o "$_c_out" "$@" >&2; }
  fi
else
  TC="${TC:-${SWIFT_WORK:-$SWIFT_BUILD/work}/toolchain/usr}"
  [ -x "$TC/bin/swiftc" ] || { echo "make-selftest: no swiftc at $TC/bin/swiftc -- run build.sh first" >&2; exit 1; }
  . "$REPO/msc.sh"   # -> $SHIPYARD (fetch_sdk.sh)
  SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || { echo "make-selftest: could not fetch the 10.9 SDK" >&2; exit 1; }
  RES="${SWIFT_WORK:-$SWIFT_BUILD/work}/stdlib-build/lib/swift"
  [ -f "$RES/macosx/x86_64/libswiftCore.dylib" ] || { echo "make-selftest: no stdlib build at $RES -- run build.sh first" >&2; exit 1; }
  RUNTIME_LIB="${SWIFT_RUNTIME_PREFIX:-/usr/local/mavergreen/swift-runtime}/lib/swift"
  SKIP_MARK="// selftest: needs this repo's compiler"
  compile() {
    _c_o="$1" _c_s="$2" _c_out="$3"; shift 3
    "$TC/bin/swiftc" -sdk "$SDK" -resource-dir "$RES" -L "$RES/macosx/x86_64" -runtime-compatibility-version none \
      -target x86_64-apple-macosx10.9 "-$_c_o" -no-stdlib-rpath \
      -Xlinker -rpath -Xlinker "$RUNTIME_LIB" "$_c_s" -o "$_c_out" "$@" >&2
  }
fi

# upstream_tests -- one line per upstream test variant of $SELFTEST_SUPPORT: <args file> <source> <binary
# name>, sorted; fails, naming them, on two of one name (a test of one name in two directories of a layer).
upstream_tests() {
  find "$SELFTEST_SUPPORT/upstream" -name '*.args' | LC_ALL=C sort | while IFS= read -r _u_a; do
    _u_r="${_u_a#"$SELFTEST_SUPPORT/upstream/"}"; _u_s="${_u_a%.args}"; _u_v=""
    case "$_u_s" in *.[0-9]|*.[0-9][0-9]) _u_v="-v${_u_s##*.}"; _u_s="${_u_s%.*}" ;; esac
    _u_s="${_u_s%.gyb}"
    _u_n="${_u_s##*/}"; printf '%s %s %s-%s%s\n' "$_u_a" "$_u_s" "${_u_r%%/*}" "${_u_n%.swift}" "$_u_v"
  done
}
if [ -n "${SELFTEST_SUPPORT:-}" ]; then
  for d in lib modules upstream; do
    [ -d "$SELFTEST_SUPPORT/$d" ] || {
      echo "make-selftest: SELFTEST_SUPPORT=$SELFTEST_SUPPORT has no $d/ -- stage it with scripts/stage-selftest-support.sh" >&2; exit 1; }
  done
  UPSTREAM="$(upstream_tests)"
  # The default mode's swift.org compiler refuses upstream's concurrency tests, 10.9 async code (see the usage).
  if [ -n "$SKIP_MARK" ] && printf '%s\n' "$UPSTREAM" | grep -q '^[^ ]* [^ ]* concurrency-'; then
    UPSTREAM="$(printf '%s\n' "$UPSTREAM" | grep -v '^[^ ]* [^ ]* concurrency-' || :)"
    echo "skipped: upstream's concurrency tests (they need this repo's compiler, not the swift.org one)" >&2
  fi
  DUP="$(printf '%s\n' "$UPSTREAM" | awk '{ print $3 }' | LC_ALL=C sort | uniq -d)"
  [ -z "$DUP" ] || { echo "make-selftest: two upstream tests would be named $DUP" | tr '\n' ' ' >&2; echo >&2; exit 1; }
fi

NAME=swift-runtime-selftest
B="$DIST/$NAME"; rm -rf "$B"; mkdir -p "$B/bin"
for src in "${SELFTEST_SRC:-$REPO/tests}"/*.swift; do
  [ -f "$src" ] || continue
  n="$(basename "$src" .swift)"
  first="$(sed -n 1p "$src")"
  case "$first" in "// selftest: skip: "*) echo "skipped: $n (${first#"// selftest: skip: "})" >&2; continue ;; esac
  if [ -n "$SKIP_MARK" ]; then
    case "$(sed -n 1p "$src")" in
      "$SKIP_MARK"*) echo "skipped: $n (needs this repo's compiler, not the swift.org one)" >&2; continue ;;
    esac
  fi
  # shellcheck disable=SC2046  # the // swiftc: line's flags, one word apiece (each checked below)
  set -- $(sed -n '/^\/\//!q; s/^\/\/ swiftc: //p' "$src")
  for w in "$@"; do
    case "$w" in
      -parse-as-library) ;;
      *) echo "make-selftest: $n's // swiftc: line asks for $w; only -parse-as-library is allowed (see the usage)" >&2; exit 1 ;;
    esac
  done
  compile O "$src" "$B/bin/$n" "$@"; echo "built: $n" >&2
  compile Onone "$src" "$B/bin/$n-Onone" "$@"; echo "built: $n-Onone" >&2
done
[ -n "$(ls -A "$B/bin")" ] || { echo "make-selftest: nothing was built" >&2; exit 1; }
if [ -n "${SELFTEST_SUPPORT:-}" ]; then
  mkdir -p "$B/upstream/bin" "$B/lib"; cp "$SELFTEST_SUPPORT"/lib/* "$B/lib/"
  printf '%s\n' "$UPSTREAM" | while read -r args src n; do
    [ -n "$args" ] || continue
    # The compile-line, one argument per line (an availability macro holds spaces), becomes "$@".
    set --; while IFS= read -r a; do set -- "$@" "$a"; done < "$args"
    for o in O Onone; do
      out="$B/upstream/bin/$n"; [ "$o" = O ] || out="$out-Onone"
      compile "$o" "$src" "$out" "$@" -I "$SELFTEST_SUPPORT/modules" -L "$SELFTEST_SUPPORT/lib" \
        -Xlinker -rpath -Xlinker @executable_path/../../lib || exit 1
      echo "built: upstream/bin/${out##*/}" >&2
    done
  done || { echo "make-selftest: an upstream test did not build" >&2; exit 1; }
fi
cp "$REPO/tests/run-selftest.sh" "$B/run-selftest.sh"; chmod +x "$B/run-selftest.sh"

# A modern host's bsdtar tags most files with com.apple.provenance and packs it as a pax
# LIBARCHIVE.xattr./SCHILY.xattr. header; 10.9's libarchive 2.8.3 can't parse that ("Ignoring
# malformed pax extended attribute") and `tar -xzf` there exits 1. COPYFILE_DISABLE keeps
# AppleDouble ._ sidecar members out of the archive too. --no-xattrs suppresses the pax header, but
# 10.9's own bsdtar (this script also runs ON 10.9) doesn't know that flag and would abort under
# set -eu, so probe for support first instead of passing it unconditionally.
NOX=""
if tar --no-xattrs -cf /dev/null "$REPO/make-selftest.sh" >/dev/null 2>&1; then NOX="--no-xattrs"; fi
( cd "$DIST" && COPYFILE_DISABLE=1 tar $NOX -czf "$NAME.tar.gz" "$NAME" && rm -rf "$NAME" )
echo "$DIST/$NAME.tar.gz"
