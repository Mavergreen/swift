#!/bin/sh
# platform: host-agnostic
# usage: sh tests/build-helpers-test.sh
#   lib.sh's helpers for building the runtime on either host: prefix_map_flags must map both spellings of
#   a build root, clang_resource_include must find exactly one resource-header dir, clang_resource_shim
#   and native_host_shim must lay out the dirs build.sh hands the compilers, and every one must refuse
#   what it cannot use before it removes anything. apple_probe_answers must answer CMake's and LLVM's Apple
#   probes (tapi, strip, ld64) without xcrun or a Command Line Tools name, and HOST_LINK_VERSION be 10.9's ld64.
#   source_stamp must name each source tree's commit, so a build dir stamped with it starts afresh when
#   another commit's tarball is extracted, and is kept when the same one is.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-helpers.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"   # physical, so a link below is the only second spelling
. "$REPO/lib.sh"

echo "-- apple_probe_answers: tapi, strip and ld64 named, none of them xcrun or a Command Line Tools tool"
[ "$(apple_probe_answers /c22/bin)" = "-DCMAKE_TAPI=/usr/bin/false -DCMAKE_STRIP=/c22/bin/llvm-strip -DLD64_EXECUTABLE=/usr/bin/false" ] \
  || fail "apple_probe_answers: $(apple_probe_answers /c22/bin)"
[ "$HOST_LINK_VERSION" = 241.9 ] || fail "HOST_LINK_VERSION: $HOST_LINK_VERSION"

echo "-- prefix_map_flags: both spellings of the root, physical first, the logical one normalized"
mkdir -p "$T/real"; ln -s real "$T/link"
got="$(prefix_map_flags c "$T//link")"
[ "$got" = "-ffile-prefix-map=$T/real=/mavergreen-build -ffile-prefix-map=$T/link=/mavergreen-build" ] || fail "c flags: $got"
got="$(prefix_map_flags swift "$T//link/")"
[ "$got" = "-file-prefix-map;$T/real=/mavergreen-build;-file-prefix-map;$T/link=/mavergreen-build" ] || fail "swift flags: $got"
rc=0; prefix_map_flags c real 2>/dev/null || rc=$?; [ "$rc" -ne 0 ] || fail "accepted a relative root"
rc=0; prefix_map_flags c "$T/absent" 2>/dev/null || rc=$?; [ "$rc" -ne 0 ] || fail "accepted a root that does not exist"
rc=0; prefix_map_flags ld "$T/real" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ] || fail "kind 'ld': exit $rc, not 2"

echo "-- clang_resource_include: exactly one, or refused naming them"
mkdir -p "$T/tc/lib/clang/21/include"
[ "$(clang_resource_include "$T/tc")" = "$T/tc/lib/clang/21/include" ] || fail "did not find lib/clang/21/include"
mkdir -p "$T/tc/lib/clang/22/include"
if clang_resource_include "$T/tc" > /dev/null 2> "$T/err"; then fail "picked one of two resource dirs"; fi
grep -q 'lib/clang/21/include' "$T/err" && grep -q 'lib/clang/22/include' "$T/err" || fail "did not name both: $(cat "$T/err")"
if clang_resource_include "$T/real" > /dev/null 2>&1; then fail "found a resource dir where there is none"; fi
rm -r "$T/tc/lib/clang/22"

echo "-- clang_resource_shim: include and the archive, replacing the dir"
: > "$T/libclang_rt.osx.a"
mkdir -p "$T/rd/stale"
clang_resource_shim "$T/tc/lib/clang/21/include" "$T/libclang_rt.osx.a" "$T/rd" || fail "clang_resource_shim failed"
[ "$(readlink "$T/rd/include")" = "$T/tc/lib/clang/21/include" ] || fail "include is not a link to the headers"
[ "$(readlink "$T/rd/lib/darwin/libclang_rt.osx.a")" = "$T/libclang_rt.osx.a" ] || fail "lib/darwin/libclang_rt.osx.a is not a link to the archive"
[ ! -e "$T/rd/stale" ] || fail "kept what the dir held before"
mkdir -p "$T/rd/stale"
if clang_resource_shim "$T/tc/lib/clang/21/include" "$T/absent.a" "$T/rd" 2> "$T/err"; then fail "accepted a missing archive"; fi
grep -q 'absent.a' "$T/err" || fail "did not name the missing archive: $(cat "$T/err")"
[ -d "$T/rd/stale" ] || fail "removed the dir before refusing"
if clang_resource_shim "$T/tc/lib/clang/21/include" "$T/libclang_rt.osx.a" rd 2>/dev/null; then fail "accepted a relative dir"; fi

echo "-- native_host_shim: the bare frontend, clang, lld under both names, lib"
H="$T/toolchain"; mkdir -p "$H/bin" "$H/lib/swift/macosx"
: > "$H/bin/swift-frontend"; : > "$H/bin/clang"
printf '#!/bin/sh\necho "$(basename "$0") $*"\n' > "$H/bin/ld64.lld"; chmod +x "$H/bin/ld64.lld"
mkdir -p "$T/host/stale"
native_host_shim "$H" "$T/host" || fail "native_host_shim failed"
for n in swiftc swift-frontend; do
  [ "$(readlink "$T/host/usr/bin/$n")" = "$H/bin/swift-frontend" ] || fail "bin/$n is not the bare swift-frontend"
done
for n in clang clang++; do [ "$(readlink "$T/host/usr/bin/$n")" = "$H/bin/clang" ] || fail "bin/$n is not clang"; done
[ "$(readlink "$T/host/usr/bin/ld64.lld")" = "$H/bin/ld64.lld" ] || fail "bin/ld64.lld is not lld"
[ "$(readlink "$T/host/usr/lib")" = "$H/lib" ] || fail "usr/lib is not the toolchain's lib"
[ "$("$T/host/usr/bin/ld" -arch x86_64 'a b.o')" = "ld64.lld -arch x86_64 a b.o" ] || fail "bin/ld does not exec ld64.lld with its arguments"
[ ! -e "$T/host/stale" ] || fail "kept what the dir held before"
mkdir -p "$T/host/stale"; rm "$H/bin/clang"
if native_host_shim "$H" "$T/host" 2> "$T/err"; then fail "accepted a toolchain without clang"; fi
grep -q 'bin/clang' "$T/err" || fail "did not name the missing clang: $(cat "$T/err")"
[ -d "$T/host/stale" ] || fail "removed the dir before refusing"
if native_host_shim toolchain "$T/host" 2>/dev/null; then fail "accepted a relative toolchain prefix"; fi
echo "-- lib.sh's build root: a relative one made absolute, before anything cds; one with whitespace refused"
mkdir -p "$T/cwd"
got="$(cd "$T/cwd" && MAVERICKS_BUILD_ROOT=rel sh -c '. "$1/lib.sh" && echo "$MAVERICKS_BUILD_ROOT $SWIFT_BUILD"' sh "$REPO")"
[ "$got" = "$T/cwd/rel $T/cwd/rel/swift" ] || fail "a relative root read as: $got"
TAB="$(printf '\t')"
for bad in "$T/a b" "$T/a${TAB}b"; do
  if MAVERICKS_BUILD_ROOT="$bad" sh -c '. "$1/lib.sh" && echo sourced' sh "$REPO" > "$T/out" 2> "$T/err"; then
    fail "sourced lib.sh with the root '$bad': $(cat "$T/out")"
  fi
  grep -q 'whitespace' "$T/err" || fail "did not say why '$bad' was refused: $(cat "$T/err")"
done

echo "-- prefix_map_flags: refuses a root with whitespace in either spelling"
mkdir -p "$T/sp ace"; ln -s "sp ace" "$T/nospace"
if prefix_map_flags c "$T/sp ace" > /dev/null 2>&1; then fail "mapped a root holding a space"; fi
if prefix_map_flags swift "$T/nospace" > /dev/null 2>&1; then fail "mapped a link whose physical spelling holds a space"; fi

echo "-- host_inputs_stamp: the inputs' sha256s by role, clang's cfgs beside its real binary; one it cannot hash is refused"
printf a > "$T/fe"; printf b > "$T/cl"; printf c > "$T/bi"
s1="$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi")" || fail "host_inputs_stamp failed"
[ "$(printf '%s\n' "$s1" | sed -n 1p)" = "swift-frontend ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb" ] || fail "stamp line 1: $s1"
[ "$(printf '%s\n' "$s1" | awk '{ print $1 }' | tr '\n' ' ')" = "swift-frontend clang clang.cfg clang++.cfg builtins " ] || fail "stamp roles: $s1"
[ "$(printf '%s\n' "$s1" | sed -n '3,4p' | tr '\n' ' ')" = "clang.cfg none clang++.cfg none " ] || fail "no cfgs beside clang, yet: $s1"
# The native host shim links its clang, and clang reads <driver>.cfg from its real binary's directory.
mkdir -p "$T/tc/bin" "$T/shim"; printf b > "$T/tc/bin/clang"; printf d > "$T/tc/bin/clang.cfg"; printf e > "$T/tc/bin/clang++.cfg"
ln -s "$T/tc/bin/clang" "$T/shim/clang"
s3="$(host_inputs_stamp "$T/fe" "$T/shim/clang" "$T/bi")" || fail "host_inputs_stamp failed on a linked clang"
[ "$(printf '%s\n' "$s3" | sed -n 3p)" = "clang.cfg 18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4" ] || fail "the linked clang's clang.cfg: $s3"
[ "$(printf '%s\n' "$s3" | sed -n 4p)" = "clang++.cfg 3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea" ] || fail "the linked clang's clang++.cfg: $s3"
printf D > "$T/tc/bin/clang.cfg"; s4="$(host_inputs_stamp "$T/fe" "$T/shim/clang" "$T/bi")"
[ "$s4" != "$s3" ] || fail "a changed clang.cfg left the stamp as it was"
if host_inputs_stamp "$T/fe" "$T/absent" "$T/bi" > /dev/null 2> "$T/err"; then fail "stamped a missing clang"; fi
grep -q "$T/absent" "$T/err" || fail "did not name the missing input: $(cat "$T/err")"
printf B > "$T/cl"; s2="$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi")"
[ "$s2" != "$s1" ] || fail "a changed clang left the stamp as it was"
printf e > "$T/ar"; s5="$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi" "$T/ar")" || fail "host_inputs_stamp failed with an archiver"
[ "$(printf '%s\n' "$s5" | awk '{ print $1 }' | tr '\n' ' ')" = "swift-frontend clang clang.cfg clang++.cfg builtins archiver " ] || fail "stamp roles with an archiver: $s5"
[ "$(printf '%s\n' "$s5" | sed 6d)" = "$s2" ] || fail "an archiver changed the other lines: $s5"
# Each further input is a line of its own: libcxx22 and the Recaulk archive once went unhashed.
printf f > "$T/in1"; printf g > "$T/in2"
s6="$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi" "$T/ar" "$T/in1" "$T/in2")" || fail "host_inputs_stamp failed with further inputs"
[ "$(printf '%s\n' "$s6" | sed -n '7,8p' | awk '{ print $1 }' | tr '\n' ' ')" = "input input " ] || fail "further inputs' roles: $s6"
[ "$(printf '%s\n' "$s6" | sed '7,8d')" = "$s5" ] || fail "further inputs changed the other lines: $s6"
printf G > "$T/in2"; [ "$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi" "$T/ar" "$T/in1" "$T/in2")" != "$s6" ] || fail "a changed further input left the stamp as it was"
if host_inputs_stamp "$T/fe" "$T/cl" "$T/bi" "$T/ar" "$T/absent" > /dev/null 2>&1; then fail "stamped a missing further input"; fi
printf E > "$T/ar"; s6="$(host_inputs_stamp "$T/fe" "$T/cl" "$T/bi" "$T/ar")"
[ "$s6" != "$s5" ] || fail "a changed archiver left the stamp as it was"

echo "-- reuse_build_dir: kept with the same stamp; removed with another, or none; an empty stamp refused"
rc=0; reuse_build_dir "$T/sb" "$s1" > /dev/null || rc=$?; [ "$rc" -eq 0 ] || fail "failed on a dir that does not exist"
mkdir -p "$T/sb"; : > "$T/sb/obj"
reuse_build_dir "$T/sb" "$s1" > /dev/null || fail "reuse_build_dir failed"
[ ! -d "$T/sb" ] || fail "kept a dir that records no stamp"
mkdir -p "$T/sb"; : > "$T/sb/obj"; printf '%s\n' "$s1" > "$T/sb/mavergreen-inputs.stamp"
reuse_build_dir "$T/sb" "$s1" > /dev/null || fail "reuse_build_dir failed"
[ -f "$T/sb/obj" ] || fail "removed a dir whose stamp is the same"
reuse_build_dir "$T/sb" "$s2" > "$T/out" || fail "reuse_build_dir failed"
[ ! -d "$T/sb" ] || fail "kept a dir whose stamp differs"
grep -q 'removing' "$T/out" || fail "removed the dir without saying so"
mkdir -p "$T/sb"
if reuse_build_dir "$T/sb" "" 2>/dev/null; then fail "accepted an empty stamp"; fi
[ -d "$T/sb" ] || fail "removed the dir before refusing an empty stamp"

echo "-- source_stamp: each tree's .mavergreen-source line, by name; a tree with none refused. In a build dir's"
echo "   stamp, the same commit extracted again keeps the dir; another commit's tarball over it removes it"
mkdir -p "$T/src/llvm-project" "$T/src/cmark"
echo "https://x/llvm-project.git aaaa 1111" > "$T/src/llvm-project/.mavergreen-source"
echo "https://x/swift-cmark.git bbbb 2222" > "$T/src/cmark/.mavergreen-source"
got="$(source_stamp "$T/src/llvm-project" "$T/src/cmark")" || fail "source_stamp failed"
[ "$got" = "source llvm-project https://x/llvm-project.git aaaa 1111
source cmark https://x/swift-cmark.git bbbb 2222" ] || fail "source_stamp: $got"
mkdir -p "$T/src/bare"
if source_stamp "$T/src/llvm-project" "$T/src/bare" > /dev/null 2> "$T/err"; then fail "stamped a tree with no .mavergreen-source"; fi
grep -q "no $T/src/bare/.mavergreen-source" "$T/err" || fail "source_stamp, no stamp: $(cat "$T/err")"
: > "$T/src/bare/.mavergreen-source"
if source_stamp "$T/src/bare" > /dev/null 2>&1; then fail "stamped a tree whose .mavergreen-source is empty"; fi
mkdir -p "$T/lb"; : > "$T/lb/obj.o"; printf '%s\n' "$got" > "$T/lb/mavergreen-inputs.stamp"
# fetch_source extracts afresh on every run: the same commit, the same line.
echo "https://x/llvm-project.git aaaa 1111" > "$T/src/llvm-project/.mavergreen-source"
reuse_build_dir "$T/lb" "$(source_stamp "$T/src/llvm-project" "$T/src/cmark")" > /dev/null || fail "reuse_build_dir failed"
[ -f "$T/lb/obj.o" ] || fail "the same source extracted again removed the build dir"
# An older commit's tarball: every file dated before the objects, so only the stamp can tell.
echo "https://x/llvm-project.git cccc 3333" > "$T/src/llvm-project/.mavergreen-source"
reuse_build_dir "$T/lb" "$(source_stamp "$T/src/llvm-project" "$T/src/cmark")" > "$T/out" || fail "reuse_build_dir failed"
[ ! -d "$T/lb" ] || fail "a build dir stamped with another commit's source was kept"
grep -q 'removing' "$T/out" || fail "removed the build dir without saying so"

echo "-- macho_links_none_under: fails on a library under the dir, and on an otool that read nothing"
mkdir -p "$T/fakebin"
printf '#!/bin/sh\nprintf "%%s" "$FAKE_OTOOL_OUT"\nexit "${FAKE_OTOOL_RC:-0}"\n' > "$T/fakebin/otool"; chmod +x "$T/fakebin/otool"
LIBS="$T/lld:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
	/usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 1900.0.0)"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT="$LIBS"; macho_links_none_under "$T/lld" /opt/pkg/ ) > /dev/null || fail "refused a clean lld"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT="$LIBS
	/opt/pkg/lib/libz.1.dylib (compatibility version 1.0.0)"; macho_links_none_under "$T/lld" /opt/pkg/ ) > "$T/out" 2>&1 \
  && fail "accepted an lld linking /opt/pkg"
grep -q '/opt/pkg/lib/libz.1.dylib' "$T/out" || fail "did not list the /opt/pkg library: $(cat "$T/out")"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT="" FAKE_OTOOL_RC=1; macho_links_none_under "$T/lld" /opt/pkg/ ) > /dev/null 2>&1 \
  && fail "passed although otool failed"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT=""; macho_links_none_under "$T/lld" /opt/pkg/ ) > /dev/null 2>&1 \
  && fail "passed although otool printed nothing (10.9's stub, without the Command Line Tools)"
# OTOOL names the reader (clang22's llvm-otool on 10.9): here one that sees /opt/pkg, beside a clean otool on PATH.
cp "$T/fakebin/otool" "$T/llvm-otool"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT="$LIBS
    /opt/pkg/lib/libz.1.dylib (compatibility version 1.0.0)"; OTOOL=false macho_links_none_under "$T/lld" /opt/pkg/ ) > "$T/out" 2>&1 \
  && fail "passed although OTOOL could not read"
grep -q '(false)' "$T/out" || fail "did not name OTOOL's reader: $(cat "$T/out")"
( export PATH="$T/fakebin:$PATH" FAKE_OTOOL_OUT="$LIBS"; OTOOL="$T/llvm-otool" macho_links_none_under "$T/lld" /opt/pkg/ ) > /dev/null \
  || fail "refused a clean lld read by OTOOL"

echo "-- host_toolchain_release: the receipt's release, of SWIFT_VERSION, whatever the pkg id"
SWIFT_VERSION=6.4.0; mkdir -p "$T/fakebin"
printf '#!/bin/sh\n[ "$1" = --file-info ] || exit 2\necho "$2" > "%s/pkgutil-arg"\ncat "%s/receipt"\nexit "${FAKE_PKGUTIL_RC:-0}"\n' "$T" "$T" > "$T/fakebin/pkgutil"
chmod +x "$T/fakebin/pkgutil"
receipt() {  # $1 = pkgid, $2... = pkg-versions (none: no receipt)
  _id="$1"; shift
  { echo "volume: /"; echo "path: $T/tc/bin/swift-frontend"
    for _v in "$@"; do printf '\npkgid: %s\npkg-version: %s\ninstall-time: 1790384965\n' "$_id" "$_v"; done; } > "$T/receipt"
}
release() { ( PATH="$T/fakebin:$PATH"; host_toolchain_release "$T/tc" ) > "$T/out" 2> "$T/err"; }
receipt dev.mavergreen.swift-toolchain 6.4.0-mavericks.7
release || fail "refused 6.4.0-mavericks.7: $(cat "$T/err")"
[ "$(cat "$T/out")" = "6.4.0-mavericks.7 (pkg dev.mavergreen.swift-toolchain)" ] || fail "printed: $(cat "$T/out")"
[ "$(cat "$T/pkgutil-arg")" = "$T/tc/bin/swift-frontend" ] || fail "looked up $(cat "$T/pkgutil-arg"), not the frontend"
receipt dev.mavergreen.swift-toolchain-cross 6.4.0-mavericks.8
release || fail "refused the cross toolchain's receipt: $(cat "$T/err")"
[ "$(cat "$T/out")" = "6.4.0-mavericks.8 (pkg dev.mavergreen.swift-toolchain-cross)" ] || fail "printed: $(cat "$T/out")"
for v in 6.4.1-mavericks.1 6.3.3-mavericks.6 6.4.0 6.4.0- 6.4.01-mavericks.1; do
  receipt dev.mavergreen.swift-toolchain "$v"
  if release; then fail "accepted release $v for Swift 6.4.0"; fi
  grep -q "$v" "$T/err" && grep -q 'Swift 6.4.0' "$T/err" || fail "did not name $v and 6.4.0: $(cat "$T/err")"
done
receipt dev.mavergreen.swift-toolchain 6.4.0-mavericks.7 6.4.0-mavericks.8
if release; then fail "accepted a frontend two releases claim"; fi
receipt dev.mavergreen.swift-toolchain 6.4.0-mavericks.7
if ( export FAKE_PKGUTIL_RC=1; release ); then fail "passed although pkgutil failed"; fi

echo "-- host_toolchain_release: a copy no pkg installed needs its release declared, under the same rule"
receipt none
if release; then fail "accepted a toolchain with no receipt"; fi
grep -q 'SWIFT_HOST_TOOLCHAIN_VERSION' "$T/err" || fail "did not name the override: $(cat "$T/err")"
( SWIFT_HOST_TOOLCHAIN_VERSION=6.4.0-mavericks.7; release ) || fail "refused a declared 6.4.0-mavericks.7: $(cat "$T/err")"
grep -q '^6.4.0-mavericks.7 (declared' "$T/out" || fail "printed: $(cat "$T/out")"
if ( SWIFT_HOST_TOOLCHAIN_VERSION=6.3.3-mavericks.6; release ); then fail "accepted a declared 6.3.3 release"; fi
receipt dev.mavergreen.swift-toolchain 6.4.0-mavericks.7
if ( SWIFT_HOST_TOOLCHAIN_VERSION=6.4.0-mavericks.8; release ); then fail "accepted a declaration the receipt contradicts"; fi
( SWIFT_HOST_TOOLCHAIN_VERSION=6.4.0-mavericks.7; release ) || fail "refused a declaration the receipt agrees with"
echo "PASS"
