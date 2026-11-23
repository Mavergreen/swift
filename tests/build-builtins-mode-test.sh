#!/bin/sh
# platform: host-agnostic
# usage: sh tests/build-builtins-mode-test.sh
#   build-builtins.sh must build the same archive in both modes: cross (a modern Mac) with
#   mavericks-clang-22's CROSS toolchain from fetch-clang22.sh, native (OS X 10.9) with its NATIVE
#   toolchain (CLANG22_PREFIX), and in both the archive made by that toolchain's llvm-libtool-darwin and
#   llvm-lipo and read back by its llvm-nm, llvm-lipo and llvm-ar, never by the host's Apple tools. On a
#   Linux host (a faked uname) it builds as cross mode does, with the clang22 fetch-clang22.sh prints
#   there, whose Linux archive has no llvm-libtool-darwin: CMake told the target is Darwin, the host's
#   own cmake, and each slice archived by that clang22's llvm-ar in place of llvm-libtool-darwin. Its
#   check must refuse an archive whose members keep a date or owner, or that lacks a symbol the runtime
#   links, and run the compat guard with that toolchain's readers. It must refuse an llvm-project that is
#   not build-llvm.sh's extraction of LLVM_SHA, and never run git. In both modes no configure probe may ask
#   xcrun or run a Command Line Tools ld: CMake's answered (apple_probe_answers), clang22's lld as the
#   linker, every SDK but macOS named as an empty directory, the macOS SDK's version given (the pinned
#   10.9 SDK's), and patches/llvm 0005 in the tree. Nothing is built: every tool is a fake
#   that records its arguments.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-builtins-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"

R="$T/repo"; mkdir -p "$R/scripts"
cp "$REPO/build-builtins.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
printf '#!/bin/sh\necho "fetch-clang22" >> "%s/log"\necho "${FAKE_CLANG22:-%s/cross}"\n' "$T" "$T" > "$R/fetch-clang22.sh"
printf '#!/bin/sh\necho "guard LIPO=$LIPO OTOOL=$OTOOL NM=$NM STRINGS=$STRINGS $*" >> "%s/log"\n' "$T" > "$R/scripts/guard.sh"
mkdir -p "$T/bin" "$T/shipyard"
printf '#!/bin/sh\necho "%s/sdk/MacOSX10.9.sdk"\n' "$T" > "$T/shipyard/fetch_sdk.sh"
printf '#!/bin/sh\necho "git $*" >> "%s/log"\nexit 1\n' "$T" > "$T/bin/git"
for c in shipyard-cmake cmake ninja; do
  printf '#!/bin/sh\n{ echo "%s"; for a in "$@"; do echo "  $a"; done; } >> "%s/log"\n' "$c" "$T" > "$T/bin/$c"
done
# ninja "builds" the archive the check then reads.
printf 'mkdir -p "%s/w/builtins-x86/lib/darwin" && echo archive > "%s/w/builtins-x86/lib/darwin/libclang_rt.osx.a"\n' "$T" "$T" >> "$T/bin/ninja"
# uname is the host's unless FAKE_UNAME names another kernel for -s.
printf '#!/bin/sh\nif [ -n "${FAKE_UNAME:-}" ] && [ "$1" = -s ]; then echo "$FAKE_UNAME"; else exec /usr/bin/uname "$@"; fi\n' > "$T/bin/uname"
# The host's Apple archive tools must never run: each fake fails, recording the call.
for c in ar lipo nm libtool ranlib; do
  printf '#!/bin/sh\necho "APPLE %s $*" >> "%s/log"\nexit 1\n' "$c" "$T" > "$T/bin/$c"
done
for P in "$T/cross" "$T/native" "$T/linux"; do
  mkdir -p "$P/bin"
  for t in clang clang++ ld64.lld llvm-ranlib llvm-libtool-darwin llvm-otool llvm-strings; do printf '#!/bin/sh\n' > "$P/bin/$t"; done
  cat > "$P/bin/llvm-nm" <<'F'
#!/bin/sh
for s in ___isPlatformVersionAtLeast ___isPlatformOrVariantPlatformVersionAtLeast ___divti3 ___modti3 ___udivti3 ___umodti3; do
  [ "$s" = "${FAKE_MISSING:-}" ] || echo "0000000000000000 T $s"
done
F
  printf '#!/bin/sh\necho "%s/bin/llvm-lipo $*" >> "%s/log"\n: > "$5"\n' "$P" "$T" > "$P/bin/llvm-lipo"
  cat > "$P/bin/llvm-ar" <<'F'
#!/bin/sh
case "$1" in
  tv) echo "rw-r--r-- ${FAKE_OWNER:-0/0}    856 Jan  1 00:00 1970 absvdi2.c.o" ;;
  t) echo absvdi2.c.o ;;
  *) echo "llvm-ar $*" >> "$FAKE_AR_LOG" ;;
esac
F
  chmod +x "$P/bin/"*
done
# clang22's Linux archive: no llvm-libtool-darwin.
rm "$T/linux/bin/llvm-libtool-darwin"
FAKE_AR_LOG="$T/ar.log"; export FAKE_AR_LOG
chmod +x "$T/bin/"* "$T/shipyard/"* "$R/fetch-clang22.sh" "$R/scripts/guard.sh"
W="$T/w"; mkdir -p "$W/llvm-project/lld/MachO" "$W/llvm-project/compiler-rt/cmake/Modules"
echo "swiftlang's fork refuses every Apple-platform input" > "$W/llvm-project/lld/MachO/InputFiles.cpp"
echo 'Mavergreen: extra flags for the Darwin builtins' > "$W/llvm-project/compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake"
echo 'Mavergreen: a configure that names the macOS SDK' > "$W/llvm-project/compiler-rt/cmake/base-config-ix.cmake"
echo "https://github.com/swiftlang/llvm-project.git $LLVM_SHA $LLVM_TARBALL_SHA256" > "$W/llvm-project/.mavergreen-source"
run() {  # run <log-name> <mode> -- a fresh log each time; the host is a Mac unless FAKE_UNAME says otherwise
  _n="$1"; rm -f "$T/log"; : > "$T/log"; _rc=0
  FAKE_UNAME="${FAKE_UNAME:-Darwin}" PATH="$T/bin:$PATH" SHIPYARD_SCRIPTS="$T/shipyard" SWIFT_WORK="$W" MAVERICKS_MODE="$2" CLANG22_PREFIX="$T/native" \
    sh "$R/build-builtins.sh" > "$T/$_n.out" 2>&1 || _rc=$?
  sed "s|$T|<T>|g" "$T/log" > "$T/$_n.log"
  return "$_rc"
}
has() { grep -qxF -- "$2" "$T/$1.log" || fail "$1: never ran [$2]: $(cat "$T/$1.out")"; }
lacks() { if grep -qF -- "$2" "$T/$1.log"; then fail "$1: ran [$2]"; fi; }

for m in cross native; do
  echo "-- $m: clang22's $m toolchain compiles, and its llvm tools make and read the archive"
  run "$m" "$m" || fail "the $m build failed: $(cat "$T/$m.out")"
  has "$m" "  -DCMAKE_C_COMPILER=<T>/$m/bin/clang"
  has "$m" "  -DCMAKE_ASM_COMPILER=<T>/$m/bin/clang"
  has "$m" "  -DCMAKE_LIBTOOL=<T>/$m/bin/llvm-libtool-darwin"
  has "$m" "  -DCMAKE_LIPO=<T>/$m/bin/llvm-lipo"
  has "$m" "  -DCMAKE_OSX_SYSROOT=<T>/sdk/MacOSX10.9.sdk"
  for a in -DCMAKE_TAPI=/usr/bin/false "-DCMAKE_STRIP=<T>/$m/bin/llvm-strip" -DLD64_EXECUTABLE=/usr/bin/false \
           "-DCMAKE_LINKER=<T>/$m/bin/ld64.lld" -DDARWIN_macosx_OVERRIDE_SDK_VERSION=10.9 \
           -DDARWIN_macosx_CACHED_SYSROOT=\<T\>/sdk/MacOSX10.9.sdk; do has "$m" "  $a"; done
  for s in iphoneos iphonesimulator watchos watchsimulator appletvos appletvsimulator xros xrsimulator; do
    has "$m" "  -DDARWIN_${s}_CACHED_SYSROOT=/var/empty"
  done
  has "$m" "<T>/$m/bin/llvm-lipo -thin x86_64 <T>/w/builtins-x86/lib/darwin/libclang_rt.osx.a -output <T>/w/builtins-x86/thin.a"
  has "$m" "guard LIPO=<T>/$m/bin/llvm-lipo OTOOL=<T>/$m/bin/llvm-otool NM=<T>/$m/bin/llvm-nm STRINGS=<T>/$m/bin/llvm-strings <T>/w/builtins-x86/lib/darwin/libclang_rt.osx.a"
  lacks "$m" "APPLE"
  lacks "$m" "-DCMAKE_SYSTEM_NAME"
  has "$m" "shipyard-cmake"
  if grep -q "^git " "$T/$m.log"; then fail "$m ran git"; fi
  grep -qx "OK: $W/builtins-x86/lib/darwin/libclang_rt.osx.a (8 bytes)" "$T/$m.out" || fail "$m did not finish OK: $(cat "$T/$m.out")"
done
lacks native "fetch-clang22"
has cross "fetch-clang22"

echo "-- linux (a Linux uname): clang22's Linux archive, CMake told the target is Darwin, llvm-ar archives each slice"
FAKE_UNAME=Linux FAKE_CLANG22="$T/linux" run linux cross || fail "the linux build failed: $(cat "$T/linux.out")"
has linux "fetch-clang22"
has linux "cmake"
lacks linux "shipyard-cmake"
for a in -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
         "-DCMAKE_C_COMPILER=<T>/linux/bin/clang" "-DCMAKE_LIPO=<T>/linux/bin/llvm-lipo" "-DCMAKE_LINKER=<T>/linux/bin/ld64.lld" \
         "-DCMAKE_LIBTOOL=<T>/w/builtins-x86/llvm-ar-as-libtool"; do has linux "  $a"; done
lacks linux "llvm-libtool-darwin"
lacks linux "APPLE"
has linux "guard LIPO=<T>/linux/bin/llvm-lipo OTOOL=<T>/linux/bin/llvm-otool NM=<T>/linux/bin/llvm-nm STRINGS=<T>/linux/bin/llvm-strings <T>/w/builtins-x86/lib/darwin/libclang_rt.osx.a"
grep -qx "OK: $W/builtins-x86/lib/darwin/libclang_rt.osx.a (8 bytes)" "$T/linux.out" || fail "linux did not finish OK: $(cat "$T/linux.out")"
# The stand-in takes llvm-libtool-darwin's command line (UseLibtool.cmake's -static -o <target> <objects>), and
# appends the objects, in order, to a new darwin-format archive with a symbol table, every member owned and dated 0.
LT="$W/builtins-x86/llvm-ar-as-libtool"
[ -x "$LT" ] || fail "no stand-in at $LT"
: > "$T/ar.log"; echo old > "$T/slice.a"
"$LT" -static -o "$T/slice.a" a/x.o b/x.o || fail "the stand-in failed"
[ ! -e "$T/slice.a" ] || fail "the stand-in kept the old archive (it appends, so it starts from none)"
[ "$(cat "$T/ar.log")" = "llvm-ar --format=darwin qcsD $T/slice.a a/x.o b/x.o" ] || fail "the stand-in ran: $(cat "$T/ar.log")"
"$LT" -V > /dev/null || fail "the stand-in refused UseLibtool.cmake's -V probe"
if "$LT" -o "$T/slice.a" a.o 2> "$T/err"; then fail "the stand-in took a command line that is not -static -o"; fi

echo "-- the check refuses a member that keeps a date or owner, and a missing symbol"
if (FAKE_OWNER=501/20 run dated native); then fail "passed an archive whose member is owned 501/20"; fi
grep -q 'keep a date or owner' "$T/dated.out" || fail "dated: $(cat "$T/dated.out")"
if (FAKE_MISSING=___divti3 run missing cross); then fail "passed an archive without ___divti3"; fi
grep -q 'does not define ___divti3' "$T/missing.out" || fail "missing: $(cat "$T/missing.out")"

echo "-- an llvm-project that is not build-llvm.sh's extraction of LLVM_SHA is refused before anything runs"
echo "https://github.com/swiftlang/llvm-project.git 0000000000000000000000000000000000000000 x" > "$W/llvm-project/.mavergreen-source"
if run other native; then fail "built from llvm-project at another commit"; fi
grep -q "no patched llvm-project at $LLVM_SHA" "$T/other.out" || fail "other: $(cat "$T/other.out")"
lacks other "shipyard-cmake"
rm "$W/llvm-project/.mavergreen-source"
if run nostamp native; then fail "built from an llvm-project no fetch stamped"; fi
echo "https://github.com/swiftlang/llvm-project.git $LLVM_SHA $LLVM_TARBALL_SHA256" > "$W/llvm-project/.mavergreen-source"
mv "$W/llvm-project/compiler-rt/cmake/base-config-ix.cmake" "$T/bci"
if run no0005 native; then fail "built from an llvm-project without patches/llvm 0005"; fi
lacks no0005 "shipyard-cmake"
mv "$T/bci" "$W/llvm-project/compiler-rt/cmake/base-config-ix.cmake"

echo "-- a mode that is neither is refused before anything runs"
if run bad sideways; then fail "ran in mode 'sideways'"; fi
grep -q "mode 'sideways' is neither cross nor native" "$T/bad.out" || fail "bad mode: $(cat "$T/bad.out")"
[ ! -s "$T/bad.log" ] || fail "ran [$(head -1 "$T/bad.log")] before refusing"
echo "PASS"
