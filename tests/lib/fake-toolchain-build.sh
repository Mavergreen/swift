# platform: host-agnostic
#   usage: . tests/lib/fake-toolchain-build.sh; fake_toolchain_build <work-dir> [x86_64|arm64]
#          Lays out, under <work-dir>, a fake of every build output scripts/stage-toolchain.sh reads for
#          that toolchain host (default x86_64): build.sh's stdlib-build, build-toolchain.sh's swift-x86
#          and llvm-x86 (arm64: swift-arm64 and llvm-arm64), build-builtins.sh's builtins-x86, the
#          llvm-project checkout; each file holds its own relative path. Called for both hosts, the two
#          share the rest. Run stage-toolchain.sh over it with SWIFT_WORK=<work-dir>. Shared, so a test
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
    "$_fw/stdlib-build/lib/swift/shims" "$_fw/llvm-project/llvm" "$_fw/builtins-x86/lib/darwin"
  for _ff in $_fs/bin/swift-frontend $_fl/bin/lld $_fl/bin/clang $_fl/lib/clang/21/include/stdint.h \
    stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftSwiftOnoneSupport.dylib \
    stdlib-build/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/layouts-x86_64.yaml stdlib-build/lib/swift/shims/module.modulemap \
    $_fs/share/swift/compatibility-symbols $_fs/share/swift/diagnostics/en.db \
    $_fs/share/swift/diagnostics/en.strings $_fs/share/swift/diagnostics/.gitkeep \
    $_fs/share/swift/diagnostics/generated llvm-project/llvm/LICENSE.TXT \
    builtins-x86/lib/darwin/libclang_rt.osx.a; do
    echo "$_ff" > "$_fw/$_ff"
  done
  unset _fw _ff _fs _fl
}
