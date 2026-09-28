cmake_minimum_required(VERSION 3.16)
# Builds the Cocoa/Sparkle updater .app for ONE of this repo's pkgs, chosen by SWIFT_UPDATER_PRODUCT
# (swift-runtime, the default; swift-toolchain; or swift-toolchain-cross): one updater per configure,
# each in its own build dir, as mavergreen-clang builds its two. None links libswiftCore, so none can
# break its own update. The runtime and the toolchains are built by shell scripts (build.sh,
# build-toolchain.sh); native-helpers/ is build-toolchain.sh's CMake project, and this one is only the
# updaters'.
set(SWIFT_UPDATER_PRODUCT "swift-runtime" CACHE STRING "which pkg this updater updates: swift-runtime | swift-toolchain | swift-toolchain-cross")
# Before project(): CMAKE_OSX_* take effect only when set ahead of the compiler checks. The cross
# toolchain's updater runs where that toolchain does, an Apple-silicon Mac (clang22-cross's shape,
# CLANG_VARIANT=cross); the others run on the 10.9 Mac they update.
if(SWIFT_UPDATER_PRODUCT STREQUAL "swift-toolchain-cross")
  set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "the cross toolchain's updater runs on macOS 11 or later")
  set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Apple silicon, as the cross toolchain")
else()
  set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "updater runs on 10.9")
  set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only")
endif()
project(swift-updaters LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
include(Mavericks)          # universal umbrella: AppleClang gate + build conventions
include(MavericksSparkle)   # the Sparkle updater .app builder

# Derived, never committed: UPSTREAM_VERSION (written from pins.env's SWIFT_VERSION by
# scripts/derive-upstream-version.sh) plus the shipped tags decide it.
mavericks_resolve_version(MAVSWIFT_VERSION)

if(SWIFT_UPDATER_PRODUCT STREQUAL "swift-runtime")
  set(_name "Mavericks Swift Runtime")
  set(_body "The Swift runtime in /usr/local/mavergreen/swift-runtime was updated.")
elseif(SWIFT_UPDATER_PRODUCT STREQUAL "swift-toolchain")
  set(_name "Mavericks Swift Toolchain")
  set(_body "The Swift toolchain in /usr/local/mavergreen/swift-toolchain was updated.")
elseif(SWIFT_UPDATER_PRODUCT STREQUAL "swift-toolchain-cross")
  set(_name "Mavericks Swift Toolchain (cross)")
  set(_body "The Swift cross toolchain in /usr/local/mavergreen/swift-toolchain-cross was updated.")
else()
  message(FATAL_ERROR "SWIFT_UPDATER_PRODUCT must be swift-runtime, swift-toolchain or swift-toolchain-cross (got '${SWIFT_UPDATER_PRODUCT}')")
endif()

mavericks_add_updater_app(
  PRODUCT ${SWIFT_UPDATER_PRODUCT}
  PRODUCT_NAME "${_name}"
  ICON "${CMAKE_SOURCE_DIR}/updater/swift-runtime-updater.icns"
  VERSION "${MAVSWIFT_VERSION}"
  CONFIRM_TITLE "${_name} updated"
  CONFIRM_BODY "${_body}"
  # no PANE_HINT_KEY -> background-found updates post an NSUserNotification (headless, no pane)
)
