# platform: host-agnostic
#   usage: . tests/lib/fake-toolchain-build.sh; fake_toolchain_build <work-dir> [x86_64|arm64]
#          Lays out, under <work-dir>, a fake of every build output scripts/stage-toolchain.sh reads for
#          that toolchain host (default x86_64): build.sh's stdlib-build, build-toolchain.sh's swift-x86
#          and llvm-x86 (arm64: swift-arm64 and llvm-arm64), build-builtins.sh's builtins-x86, the
#          llvm-project checkout, overlays/src/apinotes (overlay-sources.sh's Dispatch.apinotes, Foundation.apinotes and CoreGraphics.apinotes); each file holds its own relative path. Called for both hosts, the two
#          share the rest. And <work-dir>/recaulk, a Recaulk prefix as fetch-recaulk.sh prints one, at
#          $REPO/pins.env's RECAULK_VERSION, with its include/recaulk/dispatch/dispatch.h and pthread/qos.h, its
#          share/sdk-metadata's recipes.json and profiles.json, and a bin/recaulk-materialize that answers only
#          --print-stamp (fake_recaulk_materialize) (the caller sets REPO). Run stage-toolchain.sh over it with
#          SWIFT_WORK=<work-dir> and --recaulk <work-dir>/recaulk. Shared, so a test
#          that needs a staged payload gets the one stage-toolchain.sh really lays out, not a copy that
#          could drift from it.
fake_toolchain_build() {
  _fw="$1"
  case "${2:-x86_64}" in
    x86_64) _fs=swift-x86; _fl=llvm-x86 ;;
    arm64) _fs=swift-arm64; _fl=llvm-arm64 ;;
    *) echo "fake_toolchain_build: no host '$2'" >&2; return 2 ;;
  esac
  mkdir -p "$_fw/$_fs/bin" "$_fw/$_fs/share/swift/diagnostics" "$_fw/$_fl/bin" \
    "$_fw/$_fl/lib/clang/21/include" "$_fw/stdlib-build/lib/swift/macosx/x86_64" \
    "$_fw/stdlib-build/lib/swift/macosx/Swift.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/macosx/Darwin.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/ObjectiveC.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/macosx/Dispatch.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/CoreFoundation.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/macosx/CoreGraphics.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/Foundation.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/macosx/_Concurrency.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/_Builtin_float.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/shims" "$_fw/llvm-project/llvm" "$_fw/builtins-x86/lib/darwin"
  for _ff in $_fs/bin/swift-frontend $_fl/bin/lld $_fl/bin/clang $_fl/bin/dsymutil $_fl/lib/clang/21/include/stdint.h \
    stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftSwiftOnoneSupport.dylib \
    stdlib-build/lib/swift/macosx/x86_64/libswiftDarwin.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftObjectiveC.dylib \
    stdlib-build/lib/swift/macosx/x86_64/libswiftDispatch.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftCoreFoundation.dylib \
    stdlib-build/lib/swift/macosx/x86_64/libswiftCoreGraphics.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftFoundation.dylib \
    stdlib-build/lib/swift/macosx/x86_64/libswift_Concurrency.dylib stdlib-build/lib/swift/macosx/x86_64/libswift_Builtin_float.dylib \
    stdlib-build/lib/swift/macosx/_Concurrency.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/_Builtin_float.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/Darwin.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/ObjectiveC.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/Dispatch.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/CoreFoundation.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/CoreGraphics.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/Foundation.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/layouts-x86_64.yaml stdlib-build/lib/swift/shims/module.modulemap \
    $_fs/share/swift/compatibility-symbols $_fs/share/swift/diagnostics/en.db \
    $_fs/share/swift/diagnostics/en.strings $_fs/share/swift/diagnostics/.gitkeep \
    $_fs/share/swift/diagnostics/generated llvm-project/llvm/LICENSE.TXT \
    builtins-x86/lib/darwin/libclang_rt.osx.a recaulk/lib/librecaulk.a recaulk/share/recaulk/notices.tsv \
    recaulk/include/recaulk/dispatch/dispatch.h recaulk/include/recaulk/pthread/qos.h \
    recaulk/share/sdk-metadata/recipes.json recaulk/share/sdk-metadata/profiles.json \
    overlays/src/apinotes/Dispatch.apinotes overlays/src/apinotes/Foundation.apinotes overlays/src/apinotes/CoreGraphics.apinotes; do
    mkdir -p "$(dirname "$_fw/$_ff")"; echo "$_ff" > "$_fw/$_ff"
  done
  fake_recaulk_plist "$(sed -n 's/^RECAULK_VERSION="\([^"]*\)".*/\1/p' "$REPO/pins.env")" > "$_fw/recaulk/mavergreen.plist"
  mkdir -p "$_fw/recaulk/bin" && fake_recaulk_materialize > "$_fw/recaulk/bin/recaulk-materialize" && chmod 755 "$_fw/recaulk/bin/recaulk-materialize"
  unset _fw _ff _fs _fl
}

# fake_recaulk_plist <version> -- a Recaulk prefix's mavergreen.plist, as its pkg installs it, of <version>.
fake_recaulk_plist() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0">' '<dict>' \
    '  <key>identifier</key>' '  <string>dev.mavergreen.recaulk</string>' \
    '  <key>version</key>' "  <string>$1</string>" '</dict>' '</plist>'
}

# fake_recaulk_materialize -- a bin/recaulk-materialize that answers --print-stamp --profile <name> --recipes <abs>
# --profiles <abs> with one line naming the profile and both files' contents; any other use, or a relative path,
# is a usage error (2), as the real one's.
fake_recaulk_materialize() {
  printf '%s\n' '#!/bin/sh' 'p=""; r=""; f=""; s=""' \
    'while [ $# -gt 0 ]; do case "$1" in --print-stamp) s=1; shift ;; --profile) p="$2"; shift 2 ;;' \
    '  --recipes) r="$2"; shift 2 ;; --profiles) f="$2"; shift 2 ;; *) echo "recaulk-materialize: $1?" >&2; exit 2 ;; esac; done' \
    'case "$s:$r:$f" in 1:/*:/*) ;; *) echo "recaulk-materialize: usage" >&2; exit 2 ;; esac' \
    'printf "{\"profile\":\"%s\",\"recipes\":\"%s\",\"profiles\":\"%s\"}\n" "$p" "$(cat "$r")" "$(cat "$f")"'
}
