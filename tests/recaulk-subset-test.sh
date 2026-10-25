#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 objects of the fixture archive that nm and ar read
# usage: sh tests/recaulk-subset-test.sh
#   build.sh links libswiftCore with the members of librecaulk.a that lib.sh's recaulk_subset picks: the
#   ones defining each named API, and what they need from the archive (a forwarder's ___recaulk_impl_ body,
#   ___recaulk_resolve), by symbol, never the rest. On a fixture shaped like Recaulk's (fwd-N.o forwarders,
#   their bodies, the resolver, an unasked-for API), it must pick exactly the closure, list every global it
#   defines for -unexported_symbols_list, write the same bytes whatever the members' order in the input,
#   and refuse a name no member defines or a member that defines an API nobody asked for.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/recaulk-subset.XXXXXX")"
trap 'rm -rf "$T"' EXIT
. "$REPO/lib.sh"
ZERO_AR_DATE=1; export ZERO_AR_DATE   # Apple's ar records mtimes otherwise
# Apple's ar lists its symbol table as a member; llvm-ar does not.
members() { ar t "$1" | grep -v '^__\.SYMDEF' | tr '\n' ' '; }
o() { printf '%s\n' "$2" > "$T/$1.c"; cc -arch x86_64 -mmacosx-version-min=10.9 -c "$T/$1.c" -o "$T/$1.o" || fail "cannot build $1.o"; }
o fwd-1 'extern int __recaulk_impl_api_one(void); extern void *__recaulk_resolve(const char *);
void *__recaulk_slot_api_one; int api_one(void) { __recaulk_resolve("x"); return __recaulk_impl_api_one(); }'
o body-one 'extern int open(const char *, int, ...); int __recaulk_impl_api_one(void) { return open("/", 0); }'
o fwd-resolve 'void *__recaulk_resolve(const char *n) { return (void *)n; }'
o fwd-2 'extern void *__recaulk_resolve(const char *); int api_two(void) { return __recaulk_resolve("y") != 0; }'
o greedy 'extern int __recaulk_impl_api_one(void); int api_three(void) { return __recaulk_impl_api_one(); }
int api_four(void) { return 4; }'
( cd "$T" && ar rcs in.a fwd-1.o body-one.o fwd-resolve.o fwd-2.o greedy.o && ar rcs rev.a greedy.o fwd-2.o fwd-resolve.o body-one.o fwd-1.o ) \
  || fail "cannot build the fixture archives"

echo "-- one API: its forwarder, its body and the resolver, nothing else"
recaulk_subset "$T/in.a" "$T/one.a" "$T/one.unx" _api_one || fail "refused _api_one"
[ "$(members "$T/one.a")" = "body-one.o fwd-1.o fwd-resolve.o " ] || fail "picked: $(members "$T/one.a")"
[ "$(tr '\n' ' ' < "$T/one.unx")" = "___recaulk_impl_api_one ___recaulk_resolve ___recaulk_slot_api_one _api_one " ] \
  || fail "unexported list: $(tr '\n' ' ' < "$T/one.unx")"

echo "-- the input's member order does not change the bytes"
recaulk_subset "$T/rev.a" "$T/one-rev.a" "$T/one-rev.unx" _api_one || fail "refused _api_one from the reordered archive"
cmp -s "$T/one.a" "$T/one-rev.a" || fail "the reordered archive's subset differs"

echo "-- two APIs share the resolver once; a relative output lands where it is named"
( cd "$T" && recaulk_subset in.a two.a two.unx _api_two _api_one ) || fail "refused _api_two _api_one"
[ "$(members "$T/two.a")" = "body-one.o fwd-1.o fwd-2.o fwd-resolve.o " ] || fail "picked: $(members "$T/two.a")"

echo "-- refused: a name no member defines, and a member defining an API not asked for"
if recaulk_subset "$T/in.a" "$T/x.a" "$T/x.unx" _api_one _nonesuch 2> "$T/err"; then fail "accepted _nonesuch"; fi
grep -q 'no member defines _nonesuch' "$T/err" || fail "did not name _nonesuch: $(cat "$T/err")"
if recaulk_subset "$T/in.a" "$T/x.a" "$T/x.unx" _api_three 2> "$T/err"; then fail "accepted greedy.o's _api_four"; fi
grep -q 'greedy.o also defines _api_four' "$T/err" || fail "did not name _api_four: $(cat "$T/err")"
rc=0; recaulk_subset "$T/in.a" "$T/x.a" "$T/x.unx" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ] || fail "no symbols: exit $rc, not 2"
echo "PASS"
