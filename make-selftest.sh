#!/bin/sh
# platform: host-agnostic -- the default mode runs on a modern Mac or Linux (there with SWIFT_HOST_TOOLCHAIN's compiler alone); SWIFTC= mode runs on OS X 10.9 itself
#   usage: make-selftest.sh
#          Compiles every tests/*.swift at -O and -Onone into a self-test bundle for a 10.9 box --
#          bin/<name> and bin/<name>-Onone, plus run-selftest.sh -- and prints the tarball's path last.
#          A test's leading comment lines may hold `// swiftc: <flags>`, flags its compiles take after the
#          compiler's own: only -parse-as-library (for @main in a one-file program), as anything else
#          (-disable-availability-checking, say) would test another program than its users compile; any
#          other flag fails the bundle. A leading comment line `// selftest: also -swift-version 6` (the one
#          language-mode change allowed, and the only flags that line may name) builds the test a second time
#          in Swift 6 mode, after the first build's flags, into bin/<name>-swift6 and bin/<name>-swift6-Onone,
#          for a test whose code must compile as a Swift 6 client too; any other flags there fail the bundle.
#          A test whose first line is `// selftest: skip: <reason>` is built
#          in neither mode, saying why (none is so marked today).
#          Two compilers:
#            default          the swift.org toolchain build.sh expanded (or, with SWIFT_HOST_TOOLCHAIN, the
#                             toolchain prefix build.sh's variable of that name names: this repo's compiler,
#                             run through lib.sh's native_host_shim, which builds every test, the ones
#                             marked below included; on Linux the only compiler, and refused without it;
#                             a prefix without bin/dsymutil, which swiftc -g links through, is refused),
#                             for x86_64-apple-macosx10.9,
#                             -no-stdlib-rpath and one rpath, $SWIFT_RUNTIME_PREFIX/lib/swift
#                             (default /usr/local/mavergreen/swift-runtime). Run after build.sh. As
#                             build-module.sh compiles the overlays: against the SDK view build.sh made
#                             (SDK_VIEW below), whose ObjC declarations the tests are written to, as the
#                             toolchain's swiftc shows them to every program, with
#                             -resource-dir the stdlib build's lib/swift, so the Swift, Darwin and
#                             ObjectiveC modules imported, and the dylibs linked, are this build's, never
#                             an SDK's; -runtime-compatibility-version none, as that tree has no
#                             compatibility archives (nor does the runtime need them). A test whose
#                             first line is `// selftest: needs this repo's compiler ...` is skipped,
#                             saying so: it uses a feature only compiler patch 0003 opens for 10.9,
#                             which the swift.org compiler refuses (typed_throws_test,
#                             parameter_packs_test, stdlib_availability_test); so, with SELFTEST_SUPPORT,
#                             are upstream's concurrency tests, saying so: their async code for 10.9
#                             needs patch 0003 too. SWIFTC= mode builds every test. RECAULK_IMPORTER=<dir>
#                             (a toolchain's lib/swift/recaulk-importer) and APINOTES=<dir> (its
#                             lib/swift/apinotes) give this compiler's importer what the toolchain's swiftc
#                             gives it, as build-module.sh's options of those names do: the VFS overlay of
#                             Recaulk's dispatch declarations, written to a temporary directory, and the
#                             overlays' API notes (Dispatch.apinotes, Foundation.apinotes and
#                             CoreGraphics.apinotes). Unset, each is what build.sh left under the build root
#                             ($WORK/overlays/recaulk-importer, $WORK/overlays/src/apinotes: the overlays'
#                             own, patched), when there; the tests that import Dispatch need both, and so do
#                             those that import Foundation, whose Swift names come from its API notes.
#                             SDK_VIEW=<dir> is the SDK view (recaulk-materialize's --out) the tests compile
#                             against: its sdk/MacOSX10.9.sdk is the SDK, and its overlay.json the clang VFS
#                             overlay the importer reads the 10.9 headers through, after Recaulk's, as the
#                             toolchain's swiftc passes them. Unset, the one every overlay was built with,
#                             $WORK/overlays/sdk-view, or, when that is not there, none: the bare 10.9 SDK
#                             (fetch_sdk.sh's, with SDKSettings.json), with a warning naming it. SWIFTC= mode
#                             passes none: that swiftc applies its own.
#                             Each run's module cache is its own, as the importer's is keyed on none of these.
#            SWIFTC=<swiftc>  exactly `$SWIFTC -O|-Onone <file> -o <out>`: this repo's own toolchain,
#                             on 10.9, whose defaults supply target, SDK and rpath. With SWIFT_RUNTIME_PREFIX
#                             also set (a staged, uninstalled runtime), each compile adds
#                             `-Xlinker -headerpad_max_install_names`, and an install_name_tool then
#                             replaces the wrapper's rpath with $SWIFT_RUNTIME_PREFIX/lib/swift:
#                             INSTALL_NAME_TOOL, else mavericks-clang-22's llvm-install-name-tool
#                             (CLANG22_PREFIX, default /usr/local/mavergreen/clang22) where it is
#                             installed, else, on a Mac, install_name_tool from PATH; on Linux, which
#                             has none, the bundle is refused without one of the first two.
#          SELFTEST_SUPPORT=<dir> (scripts/stage-selftest-support.sh's layout, which build.sh stages as
#          $SWIFT_BUILD/payload/selftest-support) adds upstream's own tests (spec: "Upstream tests"): each
#          <dir>/upstream/<layer>/<path>.args, compiled from <path> (for a .gyb, gyb's output beside it) at
#          -O and -Onone with the arguments that file lists, one per line (its compile-line), and
#          `-I <dir>/modules -L <dir>/lib -Xlinker -rpath -Xlinker @executable_path/../../lib`, into
#          upstream/bin/<layer>-<name> and <layer>-<name>-Onone, and each further variant of it (lit
#          builds it again with other flags), <path>.<n>.args, into <layer>-<name>-v<n> and
#          <layer>-<name>-v<n>-Onone; a variant with a <path>.check (<path>.<n>.check: `filecheck`, then
#          FileCheck's options, one per line) also gets upstream/check/<layer>-<name>[-v<n>].args, those
#          options, and .swift, the source FileCheck reads (for a .gyb, the .gyb, as lit's %s is that),
#          one pair for both builds; and <dir>/lib, the test-support dylibs,
#          is copied to the bundle's lib/, which that rpath reaches from upstream/bin/. The support
#          modules are binary .swiftmodule files: the compiler here must be the release that built them.
#          Env: MAVERICKS_BUILD_ROOT, SWIFT_WORK, TC (toolchain usr/), SWIFT_HOST_TOOLCHAIN, DIST (output dir), RECAULK_IMPORTER, SDK_VIEW, APINOTES,
#          SWIFT_RUNTIME_PREFIX, SWIFTC, INSTALL_NAME_TOOL, CLANG22_PREFIX, SELFTEST_SRC (the dir whose
#          *.swift are the tests, default this repo's tests/), SELFTEST_SUPPORT.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/lib.sh"    # -> $SWIFT_BUILD
DIST="${DIST:-$SWIFT_BUILD/dist}"
SKIP_MARK=""   # the default mode's: see the usage above
# platform: Linux has no install_name_tool and no swift.org compiler that targets 10.9: its rpath rewrite is
#           clang22's, and its default mode compiles with SWIFT_HOST_TOOLCHAIN's compiler alone, as build.sh does
HOST=mac; [ "$(uname -s)" != Linux ] || HOST=linux
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
      if ! [ -x "$INT" ]; then
        [ "$HOST" = mac ] || { echo "make-selftest: no $INT -- on Linux the rpath rewrite is clang22's llvm-install-name-tool (CLANG22_PREFIX, fetch-clang22.sh's) or INSTALL_NAME_TOOL's" >&2; exit 1; }
        INT=install_name_tool
      fi
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
  # platform: the clang importer's module cache is keyed on neither the apinotes' contents nor the VFS overlay's,
  #           so one shared with other compiles (the host's default) can hand these tests a Dispatch imported
  #           another way (DispatchSemaphore(value:) failable, say); a private one, afresh each run, cannot.
  VFSD="$(mktemp -d "${TMPDIR:-/tmp}/make-selftest-vfs.XXXXXX")"; trap 'rm -rf "$VFSD"' EXIT
  if [ -n "${SWIFT_HOST_TOOLCHAIN:-}" ]; then
    # platform: swiftc -g (upstream's -g tests) links through the dsymutil beside swift-frontend, and Linux has
    #           no other: a prefix staged before build-toolchain.sh --host linux staged one would fail there, late
    [ -x "$SWIFT_HOST_TOOLCHAIN/bin/dsymutil" ] || {
      echo "make-selftest: no $SWIFT_HOST_TOOLCHAIN/bin/dsymutil -- restage with build-toolchain.sh --host linux" >&2; exit 1; }
    native_host_shim "$SWIFT_HOST_TOOLCHAIN" "$VFSD/host" || { echo "make-selftest: no compiler shim from SWIFT_HOST_TOOLCHAIN=$SWIFT_HOST_TOOLCHAIN" >&2; exit 1; }
    TC="$VFSD/host/usr"
    # spec: INGREDIENTS.md "Recaulk in every program" -- a test links as a user's program does through the shipped
    #       swiftc, by toolchain/ld (Recaulk's archive before -lSystem), never by the shim's bare ld, which is the
    #       stdlib build's. Without it a test binds 10.9's libm fma, fmal and truncl, whose truncl(+0) and
    #       fma(1+u, u-1, 1) come back negative. The archive is the prefix's own (a shipped toolchain's), else
    #       fetch-recaulk.sh's: the Linux-hosted prefix carries none.
    RK="$SWIFT_HOST_TOOLCHAIN/lib/recaulk/librecaulk.a"
    if ! [ -f "$RK" ]; then
      RK="$(sh "$REPO/fetch-recaulk.sh")/lib/librecaulk.a" || { echo "make-selftest: could not fetch Recaulk, which every test links" >&2; exit 1; }
    fi
    mkdir -p "$VFSD/link/bin" "$VFSD/link/lib/recaulk" "$VFSD/link/libexec/mavergreen-swift" \
      && ln -s "$SWIFT_HOST_TOOLCHAIN/bin/ld64.lld" "$VFSD/link/bin/ld64.lld" && ln -s "$RK" "$VFSD/link/lib/recaulk/librecaulk.a" \
      && cp "$REPO/toolchain/ld" "$VFSD/link/libexec/mavergreen-swift/ld" && chmod 755 "$VFSD/link/libexec/mavergreen-swift/ld" \
      && rm -f "$TC/bin/ld" && ln -s "$VFSD/link/libexec/mavergreen-swift/ld" "$TC/bin/ld" \
      || { echo "make-selftest: could not lay out the tests' linker (toolchain/ld over $RK)" >&2; exit 1; }
    # platform: this repo's (legacy) driver runs the `ld` of -tools-directory, else /usr/bin/ld: the host's own
    #           (a GNU ld on Linux); the shim's is the prefix's ld64.lld, as build-module.sh links the overlays
    TOOLFLAGS="-tools-directory $TC/bin"
  else
    [ "$HOST" = mac ] || { echo "make-selftest: on Linux the compiler is the toolchain prefix SWIFT_HOST_TOOLCHAIN names, as build.sh's" >&2; exit 1; }
    TOOLFLAGS=""
    TC="${TC:-${SWIFT_WORK:-$SWIFT_BUILD/work}/toolchain/usr}"
    SKIP_MARK="// selftest: needs this repo's compiler"
  fi
  [ -x "$TC/bin/swiftc" ] || { echo "make-selftest: no swiftc at $TC/bin/swiftc -- run build.sh first" >&2; exit 1; }
  . "$REPO/msc.sh"   # -> $SHIPYARD (fetch_sdk.sh)
  RES="${SWIFT_WORK:-$SWIFT_BUILD/work}/stdlib-build/lib/swift"
  [ -f "$RES/macosx/x86_64/libswiftCore.dylib" ] || { echo "make-selftest: no stdlib build at $RES -- run build.sh first" >&2; exit 1; }
  RUNTIME_LIB="${SWIFT_RUNTIME_PREFIX:-/usr/local/mavergreen/swift-runtime}/lib/swift"
  IMPFLAGS="-module-cache-path $VFSD/module-cache"
  # What build.sh left for the importer, where the variables are not set: its Dispatch overlay's Recaulk importer
  # directory, the overlays' patched API notes (Dispatch's, Foundation's and CoreGraphics'), and the SDK view, the
  # ones they were built with.
  WORK="${SWIFT_WORK:-$SWIFT_BUILD/work}"
  [ -n "${RECAULK_IMPORTER:-}" ] || ! [ -d "$WORK/overlays/recaulk-importer" ] || RECAULK_IMPORTER="$WORK/overlays/recaulk-importer"
  [ -n "${APINOTES:-}" ] || ! [ -d "$WORK/overlays/src/apinotes" ] || APINOTES="$WORK/overlays/src/apinotes"
  # spec: "The overlays" -- the SDK view every overlay was built against (build.sh's SDK_VIEW): their binary
  #       swiftmodules name clang declarations as that view shows them, so a test compiled against the bare 10.9
  #       headers could fail to read them, or quietly see less API.
  [ -n "${SDK_VIEW:-}" ] || ! [ -d "$WORK/overlays/sdk-view" ] || SDK_VIEW="$WORK/overlays/sdk-view"
  if [ -n "${SDK_VIEW:-}" ]; then
    [ -d "$SDK_VIEW/sdk/MacOSX10.9.sdk" ] && [ -f "$SDK_VIEW/overlay.json" ] \
      || { echo "make-selftest: SDK_VIEW=$SDK_VIEW is no SDK view (no sdk/MacOSX10.9.sdk and overlay.json)" >&2; exit 1; }
    SDK="$SDK_VIEW/sdk/MacOSX10.9.sdk"
  else
    echo "make-selftest: warning: no $WORK/overlays/sdk-view (the overlays' SDK view), so the tests see the bare 10.9 headers" >&2
    SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || { echo "make-selftest: could not fetch the 10.9 SDK" >&2; exit 1; }
  fi
  # In the order the toolchain's swiftc passes them: the importer's overlay, rooted at that SDK, then the view's.
  if [ -n "${RECAULK_IMPORTER:-}" ]; then
    [ -d "$RECAULK_IMPORTER" ] || { echo "make-selftest: RECAULK_IMPORTER=$RECAULK_IMPORTER is no directory" >&2; exit 1; }
    recaulk_vfs_yaml "$SDK" "$RECAULK_IMPORTER" "$VFSD/recaulk-vfs.yaml" || { echo "make-selftest: could not write the importer's overlay for $SDK" >&2; exit 1; }
    IMPFLAGS="$IMPFLAGS -Xcc -ivfsoverlay -Xcc $VFSD/recaulk-vfs.yaml"
  fi
  [ -z "${SDK_VIEW:-}" ] || IMPFLAGS="$IMPFLAGS -Xcc -ivfsoverlay -Xcc $SDK_VIEW/overlay.json"
  if [ -n "${APINOTES:-}" ]; then
    [ -d "$APINOTES" ] || { echo "make-selftest: APINOTES=$APINOTES is no directory" >&2; exit 1; }
    IMPFLAGS="$IMPFLAGS -Xcc -iapinotes-modules -Xcc $APINOTES"
  fi
  compile() {
    _c_o="$1" _c_s="$2" _c_out="$3"; shift 3
    # shellcheck disable=SC2086  # IMPFLAGS' and TOOLFLAGS' words are space-free (paths, as build-module.sh's)
    "$TC/bin/swiftc" -sdk "$SDK" -resource-dir "$RES" -L "$RES/macosx/x86_64" -runtime-compatibility-version none $IMPFLAGS $TOOLFLAGS \
      -target x86_64-apple-macosx10.9 "-$_c_o" -no-stdlib-rpath \
      -Xlinker -rpath -Xlinker "$RUNTIME_LIB" "$_c_s" -o "$_c_out" "$@" >&2
  }
fi

# upstream_tests -- one line per upstream test variant of $SELFTEST_SUPPORT: <args file> <source> <binary
# name> <check file, or -> <check source, or ->, sorted; fails, naming them, on two of one name (a test of one name in two directories of a layer).
upstream_tests() {
  find "$SELFTEST_SUPPORT/upstream" -name '*.args' | LC_ALL=C sort | while IFS= read -r _u_a; do
    _u_r="${_u_a#"$SELFTEST_SUPPORT/upstream/"}"; _u_s="${_u_a%.args}"; _u_v=""
    case "$_u_s" in *.[0-9]|*.[0-9][0-9]) _u_v="-v${_u_s##*.}"; _u_s="${_u_s%.*}" ;; esac
    _u_c="${_u_a%.args}.check"; _u_k="$_u_s"; [ -f "$_u_c" ] || { _u_c=-; _u_k=-; }
    _u_s="${_u_s%.gyb}"
    _u_n="${_u_s##*/}"; printf '%s %s %s-%s%s %s %s\n' "$_u_a" "$_u_s" "${_u_r%%/*}" "${_u_n%.swift}" "$_u_v" "$_u_c" "$_u_k"
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
  also="$(sed -n '/^\/\//!q; s/^\/\/ selftest: also //p' "$src")"
  case "$also" in
    ""|"-swift-version 6") ;;
    *) echo "make-selftest: $n's // selftest: also line asks for '$also'; only -swift-version 6 is allowed (see the usage)" >&2; exit 1 ;;
  esac
  compile O "$src" "$B/bin/$n" "$@"; echo "built: $n" >&2
  compile Onone "$src" "$B/bin/$n-Onone" "$@"; echo "built: $n-Onone" >&2
  if [ -n "$also" ]; then
    compile O "$src" "$B/bin/$n-swift6" "$@" -swift-version 6; echo "built: $n-swift6" >&2
    compile Onone "$src" "$B/bin/$n-swift6-Onone" "$@" -swift-version 6; echo "built: $n-swift6-Onone" >&2
  fi
done
[ -n "$(ls -A "$B/bin")" ] || { echo "make-selftest: nothing was built" >&2; exit 1; }
if [ -n "${SELFTEST_SUPPORT:-}" ]; then
  mkdir -p "$B/upstream/bin" "$B/lib"; cp "$SELFTEST_SUPPORT"/lib/* "$B/lib/"
  printf '%s\n' "$UPSTREAM" | while read -r args src n check chksrc; do
    [ -n "$args" ] || continue
    if [ "$check" != - ]; then
      mkdir -p "$B/upstream/check"
      sed 1d "$check" > "$B/upstream/check/$n.args"; cp "$chksrc" "$B/upstream/check/$n.swift"
    fi
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
# platform: 10.9's sh (bash 3.2.53) has a set -e that does not stop for a failing ( ... ) subshell.
( cd "$DIST" && COPYFILE_DISABLE=1 tar $NOX -czf "$NAME.tar.gz" "$NAME" && rm -rf "$NAME" ) || exit 1
echo "$DIST/$NAME.tar.gz"
