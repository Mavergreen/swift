#!/bin/sh
# platform: macOS-only -- runs build-builtins.sh, a macOS-only script, with every tool it calls faked
# usage: sh tests/build-builtins-mode-test.sh
#   build-builtins.sh must build the same archive in both modes: cross (a modern Mac) with
#   mavericks-clang-22's CROSS toolchain from fetch-clang22.sh, native (OS X 10.9) with its NATIVE
#   toolchain (CLANG22_PREFIX), and in both the archive made by that toolchain's llvm-libtool-darwin and
#   llvm-lipo and read back by its llvm-nm, llvm-lipo and llvm-ar, never by the host's Apple tools. Its
#   check must refuse an archive whose members keep a date or owner, or that lacks a symbol the runtime
#   links. Nothing is built: every tool is a fake that records its arguments.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-builtins-mode.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
. "$REPO/pins.env"

R="$T/repo"; mkdir -p "$R/scripts"
cp "$REPO/build-builtins.sh" "$REPO/lib.sh" "$REPO/pins.env" "$REPO/msc.sh" "$R/"
printf '#!/bin/sh\necho "fetch-clang22" >> "%s/log"\necho "%s/cross"\n' "$T" "$T" > "$R/fetch-clang22.sh"
printf '#!/bin/sh\necho "guard $*" >> "%s/log"\n' "$T" > "$R/scripts/guard.sh"
mkdir -p "$T/bin" "$T/shipyard"
printf '#!/bin/sh\necho "%s/sdk/MacOSX10.9.sdk"\n' "$T" > "$T/shipyard/fetch_sdk.sh"
printf '#!/bin/sh\necho "git $*" >> "%s/log"\necho %s\n' "$T" "$LLVM_SHA" > "$T/bin/git"
for c in shipyard-cmake ninja; do
  printf '#!/bin/sh\n{ echo "%s"; for a in "$@"; do echo "  $a"; done; } >> "%s/log"\n' "$c" "$T" > "$T/bin/$c"
done
# ninja "builds" the archive the check then reads.
printf 'mkdir -p "%s/w/builtins-x86/lib/darwin" && echo archive > "%s/w/builtins-x86/lib/darwin/libclang_rt.osx.a"\n' "$T" "$T" >> "$T/bin/ninja"
# The host's Apple archive tools must never run: each fake fails, recording the call.
for c in ar lipo nm libtool ranlib; do
  printf '#!/bin/sh\necho "APPLE %s $*" >> "%s/log"\nexit 1\n' "$c" "$T" > "$T/bin/$c"
done
for P in "$T/cross" "$T/native"; do
  mkdir -p "$P/bin"
  for t in clang clang++ ld64.lld llvm-ranlib llvm-libtool-darwin; do printf '#!/bin/sh\n' > "$P/bin/$t"; done
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
esac
F
  chmod +x "$P/bin/"*
done
chmod +x "$T/bin/"* "$T/shipyard/"* "$R/fetch-clang22.sh" "$R/scripts/guard.sh"
W="$T/w"; mkdir -p "$W/llvm-project/lld/MachO" "$W/llvm-project/compiler-rt/cmake/Modules"
echo "swiftlang's fork refuses every Apple-platform input" > "$W/llvm-project/lld/MachO/InputFiles.cpp"
echo 'Mavergreen: extra flags for the Darwin builtins' > "$W/llvm-project/compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake"
run() {  # run <log-name> <mode> -- a fresh log each time
  _n="$1"; rm -f "$T/log"; : > "$T/log"; _rc=0
  PATH="$T/bin:$PATH" SHIPYARD_SCRIPTS="$T/shipyard" SWIFT_WORK="$W" MAVERICKS_MODE="$2" CLANG22_PREFIX="$T/native" \
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
  has "$m" "<T>/$m/bin/llvm-lipo -thin x86_64 <T>/w/builtins-x86/lib/darwin/libclang_rt.osx.a -output <T>/w/builtins-x86/thin.a"
  lacks "$m" "APPLE"
  grep -qx "OK: $W/builtins-x86/lib/darwin/libclang_rt.osx.a (8 bytes)" "$T/$m.out" || fail "$m did not finish OK: $(cat "$T/$m.out")"
done
lacks native "fetch-clang22"
has cross "fetch-clang22"

echo "-- the check refuses a member that keeps a date or owner, and a missing symbol"
if (FAKE_OWNER=501/20 run dated native); then fail "passed an archive whose member is owned 501/20"; fi
grep -q 'keep a date or owner' "$T/dated.out" || fail "dated: $(cat "$T/dated.out")"
if (FAKE_MISSING=___divti3 run missing cross); then fail "passed an archive without ___divti3"; fi
grep -q 'does not define ___divti3' "$T/missing.out" || fail "missing: $(cat "$T/missing.out")"

echo "-- a mode that is neither is refused before anything runs"
if run bad sideways; then fail "ran in mode 'sideways'"; fi
grep -q "mode 'sideways' is neither cross nor native" "$T/bad.out" || fail "bad mode: $(cat "$T/bad.out")"
[ ! -s "$T/bad.log" ] || fail "ran [$(head -1 "$T/bad.log")] before refusing"
echo "PASS"
