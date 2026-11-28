#!/bin/sh
# platform: host-agnostic -- clang22's clang, lld and llvm-otool on a Mac and on Linux; shipyard-cmake on a Mac, the host's cmake on Linux (lib.sh's shipyard_cmake)
# usage: sh scripts/build-runtime-updater.sh
#   Builds swift-runtime-updater.app (Cocoa and Sparkle, x86_64, OS X 10.9) into $SWIFT_BUILD/build/updater, where
#   package.sh takes it, and fails when it links a Swift runtime library: the runtime's updater must never need
#   the runtime it updates. release.yml's build-cross and linux-runtime jobs both run it, so the Mac
#   and Linux runtime pkgs carry the same updater.
# spec: shipyard's "The updater builds with clang22 on every host" -- clang22's target, flags and lld, and its Mach-O
#       readers for the compat guard; mavericks_add_updater_app fetches the Sparkle framework itself.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"    # -> $SWIFT_BUILD, shipyard_cmake
. "$HERE/msc.sh"    # -> $SHIPYARD (MavericksToolchain.cmake beside its scripts)
CL="$(sh "$HERE/fetch-clang22.sh")"
LIPO="$CL/bin/llvm-lipo" OTOOL="$CL/bin/llvm-otool" NM="$CL/bin/llvm-nm" STRINGS="$CL/bin/llvm-strings"
export LIPO OTOOL NM STRINGS
B="$SWIFT_BUILD/build/updater"
# platform: Linux has no shipyard-cmake to add shipyard's prefix, so find_package(MavericksShipyard) is pointed at
#           the checkout install@v1 names (MavericksShipyard_DIR); a Mac's shipyard-cmake finds it unaided.
cd "$HERE"
shipyard_cmake -S . -B "$B" ${MavericksShipyard_DIR:+"-DMavericksShipyard_DIR=$MavericksShipyard_DIR"} \
  -DCMAKE_TOOLCHAIN_FILE="$SHIPYARD/../MavericksToolchain.cmake" \
  -DCMAKE_OBJC_COMPILER="$CL/bin/clang" -DCMAKE_OBJC_COMPILER_TARGET=x86_64-apple-macos10.9 \
  -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
shipyard_cmake --build "$B" --target swift-runtime-updater
L="$("$CL/bin/llvm-otool" -L "$B/swift-runtime-updater.app/Contents/MacOS/swift-runtime-updater")" \
  || { echo "FAIL: cannot read the updater's libraries" >&2; exit 1; }
printf '%s\n' "$L"
! printf '%s\n' "$L" | grep -q 'libswift' || { echo "::error::updater links a Swift runtime library (self-update circularity)" >&2; exit 1; }
