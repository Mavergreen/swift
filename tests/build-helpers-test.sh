#!/bin/sh
# platform: host-agnostic
# usage: sh tests/build-helpers-test.sh
#   lib.sh's helpers for building the runtime on either host: prefix_map_flags must map both spellings of
#   a build root, clang_resource_include must find exactly one resource-header dir, clang_resource_shim
#   and native_host_shim must lay out the dirs build.sh hands the compilers, and every one must refuse
#   what it cannot use before it removes anything.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/build-helpers.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"   # physical, so a link below is the only second spelling
. "$REPO/lib.sh"

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
echo "PASS"
