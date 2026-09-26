cmake_minimum_required(VERSION 3.20)
# The three helper programs Swift's build RUNS while building the compiler: a symbol list and the
# localized-diagnostics database. A cross build of the compiler cannot run its own x86_64 copies on the
# arm64 builder, so build-toolchain.sh builds these natively, from the same Swift sources, over the
# native LLVM tree build-llvm.sh makes. Build-only: nothing here is installed.
project(swift-native-helpers LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(LLVM REQUIRED CONFIG)
include_directories(${LLVM_INCLUDE_DIRS} "${SWIFT_SOURCE_DIR}/include")
separate_arguments(llvm_defs NATIVE_COMMAND "${LLVM_DEFINITIONS}")
add_compile_definitions(${llvm_defs})
add_compile_options(-fno-rtti)
llvm_map_components_to_libnames(llvm_libs support bitstreamreader)
add_library(helper_support STATIC
  "${SWIFT_SOURCE_DIR}/lib/Localization/LocalizationFormat.cpp"
  "${SWIFT_SOURCE_DIR}/lib/Basic/Assertions.cpp")
target_link_libraries(helper_support PUBLIC ${llvm_libs})
add_executable(swift-compatibility-symbols "${SWIFT_SOURCE_DIR}/tools/swift-compatibility-symbols/swift-compatibility-symbols.cpp")
target_link_libraries(swift-compatibility-symbols PRIVATE ${llvm_libs})
add_executable(swift-def-to-strings-converter "${SWIFT_SOURCE_DIR}/tools/swift-def-to-strings-converter/swift-def-to-strings-converter.cpp")
target_link_libraries(swift-def-to-strings-converter PRIVATE helper_support)
add_executable(swift-serialize-diagnostics "${SWIFT_SOURCE_DIR}/tools/swift-serialize-diagnostics/swift-serialize-diagnostics.cpp")
target_link_libraries(swift-serialize-diagnostics PRIVATE helper_support)
