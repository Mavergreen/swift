#!/bin/sh
# platform: macOS-only -- runs a toolchain natively: the cross one's arm64 tools on an Apple-silicon Mac, the native one's x86_64 tools on OS X 10.9
# usage: STAGE_HOST=arm64 sh tests/toolchain-smoke-test.sh   (the STAGED cross toolchain, swift-toolchain-cross)
#        sh tests/toolchain-smoke-test.sh                    (the INSTALLED native toolchain, swift-toolchain, on 10.9)
#   CI's one run of each toolchain it ships, where it runs: the cross toolchain in build-cross, on the
#   arm64 runner; the native one in vm-test, on Mac OS X 10.9 (Mavergreen/mavericks-vm), after its pkg is
#   installed. Its bin/swiftc compiles and links a hello world whose load commands record minOS 10.9 and
#   SDK 10.9 and whose one rpath is the installed runtime's; compiles and links a program that imports Dispatch
#   (a queue's sync and a group's wait), which loads libswiftDispatch through that rpath, and, on 10.9 (the
#   native toolchain, beside its installed runtime), runs it; compiles and links a program that imports Foundation
#   and calls what only the SDK view the Foundation overlays were built with declares (attributesOfItem(atPath:)'s
#   FileAttributeKey, NSURL's host property, Notification.Name), which its swiftc applies itself and which loads
#   libswiftFoundation, and on 10.9 runs it; refuses a view in its cache made for another stamp, naming the
#   stamp and the view to delete; links Recaulk (lib/recaulk, pins.env's
#   RECAULK_VERSION) into a program and a dylib, each defining Recaulk's fma, fmal and truncl, hidden,
#   the program still taking puts and malloc from libSystem, while -c compiles alone; then builds the gate corpus through
#   make-selftest.sh's SWIFTC= mode, and its clang links C that uses @available (its builtins archive is
#   where the driver looks), and, with clang++, links Recaulk (clang.cfg's link-only archive, named once, relative to
#   bin/, defining fmal hidden, also from a copied toolchain), while build.sh's host shim over it (lib.sh's
#   native_host_shim) links none. Its bare clang and clang++, given no flags, must build for 10.9 (clang.cfg and
#   clang++.cfg), and its bare clang, given only the SDK, must link C with the toolchain's own ld64.lld (its
#   default linker) and none of the flags a newer ld64 takes (its pinned host linker version):
#   6.4.0-mavericks.8's clang ran the host's ld, with -no_deduplicate, which OS X 10.9's refuses. Nothing else it
#   builds is run here: running them is the gate's job. SKIPs (77) when there is no such toolchain, or when
#   this host cannot run it natively (the cross one off Apple silicon, the native one off x86_64 or
#   translated); release.yml fails its step on that SKIP. Load commands are read with otool and nm (OTOOL
#   and NM), or where those are Command Line Tools stubs (OS X 10.9), mavericks-clang-22's llvm-otool and
#   llvm-nm (CLANG22_PREFIX).
#   Env: MAVERICKS_BUILD_ROOT, STAGE_HOST, SMOKE_TOOLCHAIN (the installed native prefix, default
#   /usr/local/mavergreen/swift-toolchain), OTOOL, NM, CLANG22_PREFIX.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$REPO/lib.sh"     # -> $SWIFT_BUILD, toolchain_host_select, macho_version, macho_rpaths
HOST="${STAGE_HOST:-x86_64}"
toolchain_host_select "$HOST" || exit 2
if [ "$HOST" = arm64 ]; then
  STAGED="$SWIFT_BUILD/payload/$TH_PAYLOAD/usr/local/mavergreen/$TH_PRODUCT/bin/swiftc"
  [ -x "$STAGED" ] || {
    echo "no staged toolchain at $STAGED (build-toolchain.sh --host arm64, then STAGE_HOST=arm64 scripts/stage-toolchain.sh) -- skipping"; exit 77; }
  [ "$(uname -m)" = arm64 ] || { echo "this host is not an Apple-silicon Mac, so it cannot run the cross toolchain -- skipping"; exit 77; }
  # The cross toolchain's frontend runs on the OS's /usr/lib/swift (no compiler patch 0002).
  TC="$(dirname "$(dirname "$STAGED")")"
  . "$REPO/msc.sh"     # -> $SHIPYARD
  CLANG_SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
else
  TC="${SMOKE_TOOLCHAIN:-/usr/local/mavergreen/$TH_PRODUCT}"
  [ -x "$TC/bin/swiftc" ] || { echo "no installed native toolchain at $TC -- skipping"; exit 77; }
  # platform: the native frontend binds its own bundled 10.9 runtime (compiler patch 0002); a modern macOS
  #           loads its own Swift runtime into the same process and crashes it, so it runs on 10.9 only.
  [ "$(uname -m)" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" != 1 ] \
    || { echo "this host does not run x86_64 code natively -- skipping"; exit 77; }
  # The toolchain's own SDK fetch, as its swiftc runs it: no shipyard on the user's Mac.
  CLANG_SDK="$(MAVERICKS_SDK_SETTINGS_JSON=1 sh "$TC/libexec/mavergreen-swift/fetch_sdk.sh")" || fail "could not obtain the Mac OS X 10.9 SDK"
fi
# spec: "The overlays" -- swiftc fetches the plain SDK itself, as on a user's Mac, and makes its view from it: the
#       materializer writes SDKSettings.json; the with-sdk-settings-json variant is not needed. clang is given
#       that variant (CLANG_SDK) by -isysroot, for the SDK version it records.
unset SDKROOT
# platform: OS X 10.9 without the Command Line Tools has only stubs for otool and nm. Never dyld_info for the
#           SDK: it shows the minOS where the SDK is 0 (lib.sh's macho_version).
if [ -z "${OTOOL:-}" ] && ! otool -l /bin/sh >/dev/null 2>&1; then
  C22="${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}/bin"
  OTOOL="$C22/llvm-otool"; NM="${NM:-$C22/llvm-nm}"
  [ -x "$OTOOL" ] && [ -x "$NM" ] || fail "no working otool and nm, and no $OTOOL and $NM (mavericks-clang-22's native pkg has them)"
fi
OTOOL="${OTOOL:-otool}"; NM="${NM:-nm}"; DYLDINFO=""
export DYLDINFO OTOOL NM
T="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT
COPY="$TC/bin/swiftc"
plat() { macho_version "$1" || fail "could not read $1's minOS and SDK"; }

echo "-- its swiftc compiles and links a hello world ($COPY; the SDK its fetch_sdk.sh gives)"
printf 'print("hello from Mavericks Swift")\n' > "$T/hello.swift"
"$COPY" "$T/hello.swift" -o "$T/hello" || fail "its swiftc could not compile and link a hello world"
[ -f "$T/hello" ] || fail "its swiftc exited 0 but wrote no $T/hello"

echo "-- for OS X 10.9, against the 10.9 SDK"
p="$(plat "$T/hello")"; echo "$p"
[ "$p" = "10.9 10.9" ] || fail "minOS and SDK are '$p', not '10.9 10.9'"

echo "-- its one rpath is the installed runtime's"
rp="$(macho_rpaths "$T/hello")" || fail "could not read $T/hello's rpaths"
echo "$rp"
[ "$rp" = /usr/local/mavergreen/swift-runtime/lib/swift ] || fail "the rpaths are [$rp], not the runtime's alone"

echo "-- its swiftc compiles and links a program that imports Dispatch, which loads libswiftDispatch"
cat > "$T/dispatch.swift" <<'F'
import Dispatch
let q = DispatchQueue(label: "dev.mavergreen.smoke")
var n = 0
q.sync { n += 1 }
let g = DispatchGroup()
DispatchQueue.global().async(group: g) { n += 1 }
print(g.wait(timeout: .now() + .seconds(5)) == .success && n == 2 ? "dispatch ok" : "dispatch FAILED")
F
"$COPY" "$T/dispatch.swift" -o "$T/dispatch" || fail "its swiftc could not compile and link a program that imports Dispatch"
"$OTOOL" -L "$T/dispatch" | grep -q '@rpath/libswiftDispatch\.dylib' || fail "$T/dispatch does not load @rpath/libswiftDispatch.dylib"
p="$(plat "$T/dispatch")"
[ "$p" = "10.9 10.9" ] || fail "the Dispatch program records minOS and SDK '$p', not '10.9 10.9'"
if [ "$HOST" = x86_64 ]; then
  out="$("$T/dispatch")" || fail "the Dispatch program failed on this 10.9, with the installed runtime: $out"
  [ "$out" = "dispatch ok" ] || fail "the Dispatch program printed '$out', not 'dispatch ok'"
fi

# spec: "The overlays" -- every client sees the SDK view the CoreFoundation, CoreGraphics and Foundation overlays
#       were built with; without it, their swiftmodules name declarations the bare 10.9 headers lack.
echo "-- its swiftc compiles and links a program that imports Foundation, through the overlays' SDK view"
cat > "$T/foundation.swift" <<'F'
import Foundation
let size = (try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0]))?[FileAttributeKey.size] as? NSNumber
let host: String? = (URL(string: "https://e.x/p")! as NSURL).host
let name = Notification.Name("dev.mavergreen.smoke")
print(size != nil && host == "e.x" && name.rawValue == "dev.mavergreen.smoke" ? "foundation ok" : "foundation FAILED")
F
"$COPY" "$T/foundation.swift" -o "$T/foundation" || fail "its swiftc could not compile and link a program that imports Foundation"
"$OTOOL" -L "$T/foundation" | grep -q '@rpath/libswiftFoundation\.dylib' || fail "$T/foundation does not load @rpath/libswiftFoundation.dylib"
p="$(plat "$T/foundation")"
[ "$p" = "10.9 10.9" ] || fail "the Foundation program records minOS and SDK '$p', not '10.9 10.9'"
if [ "$HOST" = x86_64 ]; then
  out="$("$T/foundation")" || fail "the Foundation program failed on this 10.9, with the installed runtime: $out"
  [ "$out" = "foundation ok" ] || fail "the Foundation program printed '$out', not 'foundation ok'"
fi

echo "-- its swiftc refuses an SDK view in its cache made for another stamp, naming the view to delete"
# A cache of this run's own, so the user's is never touched: the view is made there, then its stamp.json is
# changed as another toolchain's or profile's would differ.
mkdir -p "$T/home"
HOME="$T/home" "$COPY" -typecheck "$T/hello.swift" || fail "its swiftc could not make an SDK view in an empty cache"
VIEW="$(ls -d "$T/home/Library/Caches/mavergreen-swift/sdk-view"/*)" && [ -f "$VIEW/stamp.json" ] \
  || fail "its swiftc left no SDK view in $T/home/Library/Caches/mavergreen-swift/sdk-view"
sed 's/"profile":"[^"]*"/"profile":"another"/' "$VIEW/stamp.json" > "$T/stamp.json" && mv "$T/stamp.json" "$VIEW/stamp.json"
rc=0; HOME="$T/home" "$COPY" -typecheck "$T/hello.swift" > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" != 0 ] || fail "its swiftc compiled against a view made for another stamp"
grep -q "delete $VIEW" "$T/err" || fail "the refusal does not name the view to delete: $(cat "$T/err")"
grep -q "lib/swift/sdk-view/swift-foundation.stamp" "$T/err" || fail "the refusal does not name the stamp: $(cat "$T/err")"

echo "-- it links Recaulk's archive, pins.env's release, into every program and dylib"
. "$REPO/pins.env"
[ "$(cat "$TC/lib/recaulk/VERSION" 2>/dev/null)" = "$RECAULK_VERSION" ] \
  || fail "its lib/recaulk/VERSION is '$(cat "$TC/lib/recaulk/VERSION" 2>/dev/null)', not pins.env's $RECAULK_VERSION"
# Runtime values, so that the compiler emits the libm calls: fma (Double), fmal (Float80), truncl.
cat > "$T/fp.swift" <<'F'
import Darwin
let n = Double(CommandLine.arguments.count)
let l = Float80(n)
let p = malloc(16); free(p)
puts("\(n.addingProduct(n, n)) \(l.addingProduct(l, l)) \((-l / 10).rounded(.towardZero))")
F
cat > "$T/fplib.swift" <<'F'
public func f(_ n: Double, _ l: Float80) -> Float80 {
  Float80(n.addingProduct(n, n)) + l.addingProduct(l, l) + l.rounded(.towardZero)
}
F
"$COPY" -Onone "$T/fp.swift" -o "$T/fp" || fail "its swiftc could not link a program that calls fma, fmal and truncl"
( cd "$T" && "$COPY" -Onone -emit-library fplib.swift ) || fail "its swiftc could not link a dylib"
for b in "$T/fp" "$T/libfplib.dylib"; do
  m="$("$NM" -m "$b")" || fail "could not read $b's symbols"
  for s in _fma _fmal _truncl; do
    printf '%s\n' "$m" | grep -q "(__TEXT,__text) non-external (was a private external) $s\$" \
      || fail "$b does not define Recaulk's $s, hidden: $(printf '%s\n' "$m" | grep " $s\$")"
  done
done
for s in _puts _malloc; do
  "$NM" -m "$T/fp" | grep -q "(undefined) external $s (from libSystem)\$" || fail "$T/fp does not take $s from libSystem"
done
"$COPY" -c "$T/fp.swift" -o "$T/fp.o" || fail "its swiftc -c could not compile alone"

echo "-- it builds the gate corpus through make-selftest.sh"
SWIFTC="$COPY" DIST="$T/dist" sh "$REPO/make-selftest.sh" || fail "make-selftest.sh could not build the gate corpus"
tar -xzf "$T/dist/swift-runtime-selftest.tar.gz" -C "$T" || fail "cannot unpack the self-test bundle"
ls "$T/swift-runtime-selftest/bin"
for b in thorough_test thorough_test-Onone; do
  [ -f "$T/swift-runtime-selftest/bin/$b" ] || fail "make-selftest.sh built no bin/$b"
done

echo "-- its clang links C that uses @available (its builtins archive, where the driver looks)"
printf '%s\n' '#include <stdio.h>' 'int main(void) {' \
  '  if (__builtin_available(macOS 10.12, *)) puts("10.12 or later"); else puts("before 10.12");' \
  '  return 0;' '}' > "$T/avail.c"
# No -Wl,-U here: its bin/clang.cfg (toolchain/clang.cfg) lets compiler-rt's weak reference to
# _availability_version_check, which the 10.9 SDK does not declare, stay undefined.
"$TC/bin/clang" -isysroot "$CLANG_SDK" -fuse-ld=lld "$T/avail.c" -o "$T/avail" \
  || fail "its clang could not link C that uses @available"
"${NM:-nm}" "$T/avail" | grep -q ' [Tt] ___isPlatformVersionAtLeast$' \
  || fail "___isPlatformVersionAtLeast did not come from its builtins archive"
p="$(plat "$T/avail")"
[ "$p" = "10.9 10.9" ] || fail "the C program records minOS and SDK '$p', not '10.9 10.9'"

echo "-- bare clang and clang++, given no flags, build for OS X 10.9 (clang.cfg, clang++.cfg)"
printf 'int main(void) { return 0; }\n' > "$T/bare.c"
for d in clang clang++; do
  # platform: 10.9's env has no -u.
  ( "$TC/bin/$d" -x c -c "$T/bare.c" -o "$T/bare-$d.o" ) || fail "bare $d could not compile"
  v="$("${OTOOL:-otool}" -l "$T/bare-$d.o" | awk '$1 == "cmd" { c = $2 } c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }')"
  [ "$v" = 10.9 ] || fail "bare $d built for macOS '$v', not 10.9"
done
echo "-- bare clang links C with the toolchain's own ld64.lld, given only the SDK"
printf 'int main(void) { return 0; }\n' > "$T/hi.c"
LD="$("$TC/bin/clang" -isysroot "$CLANG_SDK" -### "$T/hi.c" -o "$T/hi" 2>&1 | tail -1 | sed "s/^ *//")" || fail "bare clang -### failed"
echo "$LD" | cut -c1-160
BIN="$(CDPATH='' cd -P -- "$TC/bin" && pwd -P)"
case "$LD" in "\"$BIN/ld64.lld\""*) ;; *) fail "bare clang links with $(echo "$LD" | awk '{ print $1 }'), not $BIN/ld64.lld" ;; esac
case "$LD" in *'"-no_deduplicate"'*) fail "bare clang passes -no_deduplicate, a flag for an ld64 of 262 or later" ;; esac
"$TC/bin/clang" -isysroot "$CLANG_SDK" "$T/hi.c" -o "$T/hi" || fail "bare clang could not link C"
p="$(plat "$T/hi")"
[ "$p" = "10.9 10.9" ] || fail "bare clang's program records minOS and SDK '$p', not '10.9 10.9'"

echo "-- its clang and clang++ link Recaulk too (clang.cfg's link-only \$-Wl), once, by one path"
# clang links with bin/ld64.lld itself, never through libexec/mavergreen-swift/ld (swiftc's linker, which adds
# the archive for swiftc), so the cfg is the one path for clang and the wrapper the one for swiftc.
RKA="$BIN/../lib/recaulk/librecaulk.a"     # <CFGDIR>/../lib/recaulk, as clang spells it
cat > "$T/rk.c" <<'C'
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <float.h>
int main(int argc, char **argv) {
  volatile double e = 0x1p-27 * argc;               /* fma(1+e, e-1, 1) is e*e; 10.9's gives -e*e */
  volatile long double m = LDBL_MAX, z = -0.5L * argc;
  double a = fma(1 + e, e - 1, 1);
  long double b = fmal(m, 2, -m), c = truncl(z);    /* 10.9's fmal overflows; its truncl(-0.5) lacks the sign */
  void *p = malloc(16); free(p);
  printf("%d %d %d\n", a == e * e, b == m, signbit(c) != 0);
  return !(a == e * e && b == m && signbit(c) != 0);
}
C
# C++ source with C headers only: this toolchain ships no libc++ headers (the SDK's are what a program names).
cat > "$T/rk.cc" <<'C'
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **) {
  volatile long double m = LDBL_MAX * argc;
  long double b = fmal(m, 2, -m);
  printf("%d\n", b == m);
  free(malloc(1));
  return b != m;
}
C
for d in clang clang++; do
  case "$d" in clang) src=rk.c ;; *) src=rk.cc ;; esac
  line="$("$TC/bin/$d" -isysroot "$CLANG_SDK" -### "$T/$src" -o "$T/rk-$d" 2>&1 | tail -1 | sed "s/^ *//")"
  case "$line" in "\"$BIN/ld64.lld\""*) ;; *) fail "$d links with something other than $BIN/ld64.lld" ;; esac
  n="$(printf '%s\n' "$line" | grep -o 'librecaulk\.a' | wc -l | tr -d ' ')"
  [ "$n" = 1 ] || fail "$d's link line names librecaulk.a $n times, not once"
  printf '%s\n' "$line" | grep -q "\"$RKA\"" || fail "$d's link line does not name $RKA"
  pre="${line%%\"-lSystem\"*}"
  case "$pre" in *librecaulk.a*) ;; *) fail "$d's link line puts librecaulk.a after -lSystem" ;; esac
  "$TC/bin/$d" -isysroot "$CLANG_SDK" "$T/$src" -o "$T/rk-$d" || fail "$d could not link a program that calls fmal"
  m="$("$NM" -m "$T/rk-$d")" || fail "could not read rk-$d's symbols"
  printf '%s\n' "$m" | grep -q "(__TEXT,__text) non-external (was a private external) _fmal\$" \
    || fail "rk-$d does not define Recaulk's _fmal, hidden: $(printf '%s\n' "$m" | grep ' _fmal$')"
  for sym in _malloc _printf; do
    printf '%s\n' "$m" | grep -q "(undefined) external $sym (from libSystem)\$" \
      || fail "rk-$d does not take $sym from libSystem"
  done
  # Link-only: a compile alone neither warns nor fails (an unused linker argument would warn).
  w="$("$TC/bin/$d" -isysroot "$CLANG_SDK" -Werror -c "$T/$src" -o "$T/rk-$d.o" 2>&1)" || fail "$d -c failed: $w"
  [ -z "$w" ] || fail "$d -c warned: $w"
done
echo "-- the toolchain moves: its clang finds the archive relative to bin/, not by an absolute path"
mkdir -p "$T/reloc"
cp -R "$TC/." "$T/reloc/"
"$T/reloc/bin/clang" -isysroot "$CLANG_SDK" "$T/rk.c" -o "$T/rk-reloc" -### 2>&1 | tail -1 | grep -q "\"$(CDPATH='' cd -P -- "$T/reloc/bin" && pwd -P)/../lib/recaulk/librecaulk.a\"" \
  || fail "a copied toolchain's clang does not name its own copy of the archive"
"$T/reloc/bin/clang" -isysroot "$CLANG_SDK" "$T/rk.c" -o "$T/rk-reloc" || fail "a copied toolchain's clang could not link"
rm -rf "$T/reloc"
echo "-- build.sh's host shim over this toolchain: its clang and clang++ link no Recaulk, with the cfgs' other flags"
# The runtime links its own hidden subset; the whole archive before -lSystem would bind its weak OS imports.
native_host_shim "$TC" "$T/shim" || fail "native_host_shim failed on $TC"
for d in clang clang++; do
  line="$("$T/shim/usr/bin/$d" -isysroot "$CLANG_SDK" -### -dynamiclib "$T/rk-$d.o" -o "$T/rk-$d.dylib" 2>&1 | tail -1)"
  case "$line" in *librecaulk*) fail "the shim's $d links Recaulk: $line" ;; esac
  case "$line" in *'"-platform_version" "macos" "10.9.0"'*'"-U" "__availability_version_check"'*) ;;
    *) fail "the shim's $d lost the cfg's -mmacosx-version-min=10.9 or -U: $line" ;; esac
done
echo "PASS"
