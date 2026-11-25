#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 Mach-O fixtures that otool reads
# usage: sh tests/libcxx-rpath-test.sh
#   build.sh's step 7 holds the runtime's C++ dylibs to libcxx22's libc++ by @rpath, and
#   stage-toolchain.sh holds the toolchain's copies to it, through lib.sh's libcxx_link_check: each must
#   link @rpath/libc++.1.dylib, carry exactly the one LC_RPATH it is given, and name libcxx22 by no
#   absolute path; with no rpath given, only the last. And lib.sh's libcxx_rpath_retarget moves the
#   runtime's rpath to the toolchain's in place, writing what cctools' install_name_tool -rpath writes
#   (where it is here), and leaves any other dylib's bytes alone; stage-toolchain.sh does that to the
#   stdlib's C++ dylibs and refuses one that cannot reach libcxx22 (an earlier release's, which names it by
#   its absolute path, only under --overlays-optional). On fixture dylibs: a libc++ whose install name is
#   absolute (libcxx22 before 22.1.8-mavericks.28) and one whose name is @rpath.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/libcxx-rpath.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"
RT="$LIBCXX_RPATH_RUNTIME"; TCR="$LIBCXX_RPATH_TOOLCHAIN"
# From usr/local/mavergreen/swift-runtime/lib/swift and usr/local/mavergreen/swift-toolchain/lib/swift/macosx, to local/.
[ "$RT" = '@loader_path/../../../../mavergreen/libcxx22/lib' ] || fail "the runtime's rpath is '$RT'"
[ "$TCR" = '@loader_path/../../../../../mavergreen/libcxx22/lib' ] || fail "the toolchain's rpath is '$TCR'"
mkdir -p "$T/abs" "$T/new"
echo 'int cxx(void) { return 1; }' > "$T/cxx.c"
echo 'extern int cxx(void); int f(void) { return cxx(); }' > "$T/f.c"
# Unsigned, as ld64.lld leaves an x86_64 dylib, so cctools' edit is only the load command's too.
CC="cc -arch x86_64 -mmacosx-version-min=10.9 -dynamiclib -Wl,-no_adhoc_codesign"
$CC -install_name /usr/local/mavergreen/libcxx22/lib/libc++.1.dylib "$T/cxx.c" -o "$T/abs/libc++.1.dylib" || fail "cannot build the absolute libc++"
$CC -install_name @rpath/libc++.1.dylib "$T/cxx.c" -o "$T/new/libc++.1.dylib" || fail "cannot build the @rpath libc++"
$CC "$T/f.c" "$T/abs/libc++.1.dylib" -o "$T/old.dylib" || fail "cannot build the absolute-path consumer"
$CC "$T/f.c" "$T/new/libc++.1.dylib" -Wl,-rpath,"$RT" -o "$T/rt.dylib" || fail "cannot build the runtime consumer"
$CC "$T/f.c" "$T/new/libc++.1.dylib" -o "$T/norpath.dylib" || fail "cannot build the rpath-less consumer"
$CC "$T/f.c" "$T/new/libc++.1.dylib" -Wl,-rpath,"$RT" -Wl,-rpath,/usr/local/mavergreen/libcxx22/lib -o "$T/two.dylib" \
  || fail "cannot build the two-rpath consumer"
$CC "$T/f.c" "$T/abs/libc++.1.dylib" -Wl,-rpath,"$RT" -o "$T/absrpath.dylib" || fail "cannot build the absolute consumer with an rpath"
$CC "$T/f.c" -Wl,-U,_cxx -o "$T/none.dylib" || fail "cannot build the libc++-less dylib"

passes() { out="$(libcxx_link_check "$@" 2>&1)" || fail "libcxx_link_check $* failed: $out"; }
refuses() {  # refuses <what it must say> <dylib> [rpath]
  _w="$1"; shift
  if out="$(libcxx_link_check "$@" 2>&1)"; then fail "libcxx_link_check $* passed"; fi
  printf '%s\n' "$out" | grep -qF -- "$_w" || fail "libcxx_link_check $* said '$out', not '$_w'"
}

echo "-- the runtime's dylib: @rpath/libc++.1.dylib, and the one rpath"
passes "$T/rt.dylib" "$RT"
refuses "names libcxx22 by an absolute path" "$T/old.dylib" "$RT"
refuses "names libcxx22 by an absolute path" "$T/absrpath.dylib" "$RT"
refuses "has rpaths [], not [$RT]" "$T/norpath.dylib" "$RT"
refuses "has rpaths [$RT /usr/local/mavergreen/libcxx22/lib], not [$RT]" "$T/two.dylib" "$RT"
refuses "has rpaths [$RT], not [$TCR]" "$T/rt.dylib" "$TCR"
refuses "does not link @rpath/libc++.1.dylib" "$T/none.dylib" "$RT"
echo "-- any other dylib: no absolute libcxx22 path, whatever else"
passes "$T/none.dylib" ""
passes "$T/rt.dylib" ""
refuses "names libcxx22 by an absolute path" "$T/old.dylib" ""
refuses "no such file" "$T/missing.dylib" ""

echo "-- the toolchain's copy: the runtime's rpath moved, nothing else"
cp "$T/rt.dylib" "$T/tc.dylib"
libcxx_rpath_retarget "$T/tc.dylib" || fail "libcxx_rpath_retarget failed on the runtime's dylib"
passes "$T/tc.dylib" "$TCR"
[ "$(otool -L "$T/tc.dylib" | sed 1d)" = "$(otool -L "$T/rt.dylib" | sed 1d)" ] || fail "retargeting changed what the dylib links"
[ "$(cmp -l "$T/rt.dylib" "$T/tc.dylib" | wc -l | tr -d ' ')" -le 51 ] || fail "retargeting changed more than the rpath's bytes"
if command -v install_name_tool >/dev/null 2>&1 && install_name_tool 2>&1 | grep -q -e '-rpath'; then
  cp "$T/rt.dylib" "$T/cctools.dylib"; install_name_tool -rpath "$RT" "$TCR" "$T/cctools.dylib" 2>/dev/null || fail "install_name_tool -rpath failed"
  cmp -s "$T/cctools.dylib" "$T/tc.dylib" || fail "the retargeted dylib is not what cctools' install_name_tool -rpath writes"
else
  echo "   (no cctools install_name_tool here to compare with)"
fi
cp "$T/tc.dylib" "$T/tc2.dylib"; libcxx_rpath_retarget "$T/tc2.dylib" || fail "libcxx_rpath_retarget failed on the toolchain's dylib"
cmp -s "$T/tc.dylib" "$T/tc2.dylib" || fail "retargeting the toolchain's own dylib changed it"
for f in old none two; do
  cp "$T/$f.dylib" "$T/$f.copy"; libcxx_rpath_retarget "$T/$f.copy" || fail "libcxx_rpath_retarget failed on $f"
  cmp -s "$T/$f.dylib" "$T/$f.copy" || fail "retargeting $f, which has no runtime rpath alone, changed it"
done

if ! ( . "$REPO/msc.sh" ) >/dev/null 2>&1; then echo "-- no shipyard: stage-toolchain.sh's part skipped"; echo "PASS"; exit 0; fi
echo "-- stage-toolchain.sh: the stdlib's C++ dylibs take the toolchain's rpath; the rest stay as they are"
. "$REPO/tests/lib/fake-toolchain-build.sh"
W="$T/work"; fake_toolchain_build "$W"
OTOOL=otool   # the real one, over real dylibs (the fake finds nothing)
SL="$W/stdlib-build/lib/swift/macosx/x86_64"; PX=usr/local/mavergreen/swift-toolchain/lib/swift
CXXLIBS="libswiftCore libswiftSwiftOnoneSupport libswift_Concurrency"
for l in $CXXLIBS; do cp "$T/rt.dylib" "$SL/$l.dylib"; done
cp "$T/none.dylib" "$SL/libswiftDarwin.dylib"
stage() {  # stage <out> [stage-toolchain.sh's options]
  _o="$1"; shift
  SWIFT_WORK="$W" sh "$REPO/scripts/stage-toolchain.sh" --recaulk "$W/recaulk" "$@" "$_o" > "$T/stage.log" 2>&1
}
stage "$T/st" || { cat "$T/stage.log" >&2; fail "stage-toolchain.sh failed over runtime-rpath dylibs"; }
for l in $CXXLIBS; do passes "$T/st/$PX/macosx/$l.dylib" "$TCR"; done
cmp -s "$T/none.dylib" "$T/st/$PX/macosx/libswiftDarwin.dylib" || fail "stage-toolchain.sh changed libswiftDarwin, which links no libc++"
echo "-- from a staged toolchain's stdlib (CI stages the native toolchain with the cross one's), the same bytes"
stage "$T/st2" --stdlib "$T/st/$PX" || { cat "$T/stage.log" >&2; fail "stage-toolchain.sh failed over a staged toolchain's stdlib"; }
for l in $CXXLIBS; do cmp -s "$T/st/$PX/macosx/$l.dylib" "$T/st2/$PX/macosx/$l.dylib" || fail "restaging changed $l"; done
echo "-- refuses a dylib that loads @rpath/libc++.1.dylib through no rpath"
cp "$T/norpath.dylib" "$SL/libswiftCore.dylib"
if stage "$T/st3"; then fail "staged a libswiftCore with no rpath"; fi
grep -q "cannot reach libcxx22" "$T/stage.log" || fail "the refusal did not say why: $(cat "$T/stage.log")"
echo "-- an earlier release's (libcxx22 by its absolute path): only --overlays-optional, as it is"
cp "$T/old.dylib" "$SL/libswiftCore.dylib"
if stage "$T/st4"; then fail "staged an earlier release's libswiftCore for a toolchain that ships"; fi
grep -q "only --overlays-optional stages it" "$T/stage.log" || fail "the refusal did not say why: $(cat "$T/stage.log")"
stage "$T/st5" --overlays-optional || { cat "$T/stage.log" >&2; fail "--overlays-optional refused an earlier release's libswiftCore"; }
cmp -s "$T/old.dylib" "$T/st5/$PX/macosx/libswiftCore.dylib" || fail "--overlays-optional changed an earlier release's libswiftCore"
echo "PASS"
