# platform: host-agnostic
#   usage: . tests/lib/fake-toolchain-build.sh; fake_toolchain_build <work-dir>
#          Lays out, under <work-dir>, a fake of every build output scripts/stage-toolchain.sh reads
#          (build.sh's stdlib-build, build-toolchain.sh's swift-x86 and llvm-x86, the llvm-project
#          checkout), each file holding its own relative path. Run stage-toolchain.sh over it with
#          SWIFT_WORK=<work-dir>. Shared, so a test that needs a staged payload gets the one
#          stage-toolchain.sh really lays out, not a copy that could drift from it.
fake_toolchain_build() {
  _fw="$1"
  mkdir -p "$_fw/swift-x86/bin" "$_fw/swift-x86/share/swift/diagnostics" "$_fw/llvm-x86/bin" \
    "$_fw/llvm-x86/lib/clang/21/include" "$_fw/stdlib-build/lib/swift/macosx/x86_64" \
    "$_fw/stdlib-build/lib/swift/macosx/Swift.swiftmodule" "$_fw/stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule" \
    "$_fw/stdlib-build/lib/swift/shims" "$_fw/llvm-project/llvm"
  for _ff in swift-x86/bin/swift-frontend llvm-x86/bin/lld llvm-x86/bin/clang llvm-x86/lib/clang/21/include/stdint.h \
    stdlib-build/lib/swift/macosx/x86_64/libswiftCore.dylib stdlib-build/lib/swift/macosx/x86_64/libswiftSwiftOnoneSupport.dylib \
    stdlib-build/lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/SwiftOnoneSupport.swiftmodule/x86_64-apple-macos.swiftmodule \
    stdlib-build/lib/swift/macosx/layouts-x86_64.yaml stdlib-build/lib/swift/shims/module.modulemap \
    swift-x86/share/swift/compatibility-symbols swift-x86/share/swift/diagnostics/en.db \
    swift-x86/share/swift/diagnostics/en.strings swift-x86/share/swift/diagnostics/.gitkeep \
    swift-x86/share/swift/diagnostics/generated llvm-project/llvm/LICENSE.TXT; do
    echo "$_ff" > "$_fw/$_ff"
  done
  unset _fw _ff
}
