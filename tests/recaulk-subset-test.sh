#!/bin/sh
# platform: macOS-only -- cc builds the x86_64 objects of the fixture archive that nm and ar read
# usage: sh tests/recaulk-subset-test.sh
#   build.sh links libswiftCore with the members of librecaulk.a that lib.sh's recaulk_subset picks: the
#   ones defining each named API, and what they need from the archive (a forwarder's ___recaulk_impl_ body,
#   ___recaulk_resolve), by symbol, never the rest. On a fixture shaped like Recaulk's (fwd-N.o forwarders,
#   their bodies, the resolver, an unasked-for API), it must pick exactly the closure, list every global it
#   defines for -unexported_symbols_list, write the same bytes whatever the members' order in the input,
#   and refuse a name no member defines or a member that defines an API nobody asked for. Every global a
#   picked member defines is a named API or ___recaulk_-prefixed (Recaulk prefixes its incidental globals,
#   clang's block helpers among them, since 20261108.3), so a stray global is refused even when the retired
#   RECAULK_ALSO_HIDE is set; the one exception is an image-local shadow that Recaulk's
#   image-local-shadows.txt lists for that member, and only when the caller expects exactly the (member,
#   shadow) pairs taken. With no list, no shadow is taken; a list path naming no file is an error.
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
o fwd-blk 'int api_blk(void) { return 5; }
void __copy_helper_block_8_32b(void) {} void __mpls_best_fchdir(void) {}'
o fwd-sig 'int api_sig(void) { return 6; }
int os_signpost_enabled(void) { return 1; }'
( cd "$T" && ar rcs in.a fwd-1.o body-one.o fwd-resolve.o fwd-2.o greedy.o fwd-blk.o fwd-sig.o && ar rcs rev.a greedy.o fwd-2.o fwd-resolve.o body-one.o fwd-1.o ) \
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
echo "-- an incidental global without the ___recaulk_ prefix is refused, whatever RECAULK_ALSO_HIDE says"
if ( unset RECAULK_ALSO_HIDE; recaulk_subset "$T/in.a" "$T/b.a" "$T/b.unx" _api_blk ) 2> "$T/err"; then fail "accepted fwd-blk.o's block helper"; fi
grep -q '___copy_helper_block_8_32b' "$T/err" || fail "did not name ___copy_helper_block_8_32b: $(cat "$T/err")"
if ( RECAULK_ALSO_HIDE='^___(copy|destroy)_helper_block_|^___mpls_'; export RECAULK_ALSO_HIDE
     recaulk_subset "$T/in.a" "$T/b.a" "$T/b.unx" _api_blk ) 2> "$T/err"; then fail "RECAULK_ALSO_HIDE still lets a block helper through"; fi
grep -q '___mpls_best_fchdir' "$T/err" || fail "did not name ___mpls_best_fchdir: $(cat "$T/err")"
echo "-- Recaulk's prefixed block helpers are accepted and hidden"
o fwd-pblk 'int api_pblk(void) { return 7; }
void __recaulk_copy_helper_block_8_32b(void) {} void __recaulk_mpls_best_fchdir(void) {}'
( cd "$T" && ar rcs p.a fwd-pblk.o ) || fail "cannot build p.a"
recaulk_subset "$T/p.a" "$T/pb.a" "$T/pb.unx" _api_pblk || fail "refused fwd-pblk.o's prefixed helpers"
[ "$(tr '\n' ' ' < "$T/pb.unx")" = "___recaulk_copy_helper_block_8_32b ___recaulk_mpls_best_fchdir _api_pblk " ] \
  || fail "unexported list: $(tr '\n' ' ' < "$T/pb.unx")"
echo "-- an unasked name OS X 10.9's libSystem defines binds there, never to the member that shadows it"
# Recaulk 20261118.1's os_system_version member calls close, and its socket_close member defines close and
# dup2: the subset leaves socket_close out when RECAULK_SYSTEM_EXPORTS (10.9's libSystem's exports) names close.
o fwd-ver 'extern void *__recaulk_resolve(const char *); extern int close(int);
int api_ver(void) { __recaulk_resolve("v"); return close(-1); }'
o shadow-close 'int close(int fd) { return fd; } int dup2(int a, int b) { return a + b; }'
( cd "$T" && ar rcs c.a fwd-ver.o fwd-resolve.o shadow-close.o ) || fail "cannot build c.a"
printf '%s\n' _close _dup2 _open > "$T/sys.txt"
if ( unset RECAULK_SYSTEM_EXPORTS; recaulk_subset "$T/c.a" "$T/c0.a" "$T/c0.unx" _api_ver ) 2> "$T/err"; then
  fail "without RECAULK_SYSTEM_EXPORTS, took shadow-close.o's unasked close and dup2"
fi
grep -q 'shadow-close.o also defines _dup2' "$T/err" || fail "did not name shadow-close.o's _dup2: $(cat "$T/err")"
RECAULK_SYSTEM_EXPORTS="$T/sys.txt" recaulk_subset "$T/c.a" "$T/c1.a" "$T/c1.unx" _api_ver || fail "refused _api_ver with close in 10.9's libSystem"
[ "$(members "$T/c1.a")" = "fwd-resolve.o fwd-ver.o " ] || fail "picked: $(members "$T/c1.a")"
! grep -qx _close "$T/c1.unx" || fail "the unexported list hides close, which binds to libSystem"
echo "-- a name asked for comes from Recaulk even when 10.9's libSystem defines it, and its member is still held to the rule"
RECAULK_SYSTEM_EXPORTS="$T/sys.txt" recaulk_subset "$T/c.a" "$T/c2.a" "$T/c2.unx" _close _dup2 || fail "refused the asked-for _close _dup2"
[ "$(members "$T/c2.a")" = "shadow-close.o " ] || fail "picked: $(members "$T/c2.a")"
if RECAULK_SYSTEM_EXPORTS="$T/sys.txt" recaulk_subset "$T/c.a" "$T/c3.a" "$T/c3.unx" _close 2> "$T/err"; then
  fail "took shadow-close.o for _close with its unasked _dup2"
fi
grep -q 'shadow-close.o also defines _dup2' "$T/err" || fail "did not name the unasked _dup2: $(cat "$T/err")"
if RECAULK_SYSTEM_EXPORTS="$T/none.txt" recaulk_subset "$T/c.a" "$T/c4.a" "$T/c4.unx" _api_ver 2> "$T/err"; then
  fail "accepted a RECAULK_SYSTEM_EXPORTS that names no file"
fi
unset RECAULK_SYSTEM_EXPORTS   # platform: POSIX sh may keep an assignment made before a function call
echo "-- an image-local shadow Recaulk lists is taken, hidden, and only where build.sh expects it"
# spec: Recaulk's share/recaulk/image-local-shadows.txt -- 20261120.3's dispatch_inactive member defines
#       dispatch_activate's body beside hidden, weak copies of dispatch_queue_create and dispatch_resume.
o shadow-q 'int __recaulk_impl_api_q(void) { return 8; } int __recaulk_q_create(void) { return 9; }
__attribute__((weak, visibility("hidden"))) int q_create(void) { return __recaulk_q_create(); }'
o fwd-q 'extern int __recaulk_impl_api_q(void); int api_q(void) { return __recaulk_impl_api_q(); }'
( cd "$T" && ar rcs q.a fwd-q.o shadow-q.o fwd-1.o body-one.o fwd-resolve.o ) || fail "cannot build q.a"
printf '%s\n' '# Fixes to functions 10.9 has: <member> <symbol> <reason>.' '' \
  'shadow-q.o _q_create creates a queue as 10.9 does not' 'body-one.o _open opens as 10.9 does not' > "$T/shadows.txt"
( RECAULK_IMAGE_LOCAL_SHADOWS="$T/shadows.txt" RECAULK_EXPECTED_SHADOWS=shadow-q.o:_q_create; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
  recaulk_subset "$T/q.a" "$T/q1.a" "$T/q1.unx" _api_q ) || fail "refused the listed shadow _q_create"
[ "$(members "$T/q1.a")" = "fwd-q.o shadow-q.o " ] || fail "picked: $(members "$T/q1.a")"
grep -qx _q_create "$T/q1.unx" || fail "the unexported list does not hide the shadow _q_create"
echo "-- a ___recaulk_ global needs no listing, with the list in force"
( RECAULK_IMAGE_LOCAL_SHADOWS="$T/shadows.txt"; export RECAULK_IMAGE_LOCAL_SHADOWS
  recaulk_subset "$T/q.a" "$T/q2.a" "$T/q2.unx" _api_one ) || fail "refused _api_one's ___recaulk_ globals with the list in force"
echo "-- refused: an unlisted shadow, and a listed symbol in another member"
printf '%s\n' 'other.o _q_create creates a queue' > "$T/elsewhere.txt"
: > "$T/empty.txt"
for _l in empty elsewhere; do
  if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/$_l.txt" RECAULK_EXPECTED_SHADOWS=shadow-q.o:_q_create; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
       recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "$_l.txt: accepted the unlisted shadow _q_create"; fi
  grep -q 'shadow-q.o also defines _q_create, which is not asked for' "$T/err" || fail "$_l.txt: did not name shadow-q.o's _q_create: $(cat "$T/err")"
done
echo "-- no list: no shadow is taken; a list path that names no file is an error"
if ( unset RECAULK_IMAGE_LOCAL_SHADOWS; RECAULK_EXPECTED_SHADOWS=shadow-q.o:_q_create; export RECAULK_EXPECTED_SHADOWS
     recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "without a list, accepted the shadow _q_create"; fi
grep -q 'shadow-q.o also defines _q_create, which is not asked for' "$T/err" || fail "without a list, did not name _q_create: $(cat "$T/err")"
if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/none.txt" RECAULK_EXPECTED_SHADOWS=shadow-q.o:_q_create; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
     recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "accepted a RECAULK_IMAGE_LOCAL_SHADOWS that names no file"; fi
grep -q 'RECAULK_IMAGE_LOCAL_SHADOWS names no file' "$T/err" || fail "did not name the missing list: $(cat "$T/err")"
echo "-- refused: the shadows taken differ from those build.sh expects, either way"
if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/shadows.txt"; unset RECAULK_EXPECTED_SHADOWS; export RECAULK_IMAGE_LOCAL_SHADOWS
     recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "took the shadow _q_create, which nobody expected"; fi
grep -q 'carries the shadow shadow-q.o:_q_create, which is not expected' "$T/err" || fail "did not name the unexpected _q_create: $(cat "$T/err")"
if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/shadows.txt" RECAULK_EXPECTED_SHADOWS='shadow-q.o:_q_create body-one.o:_open'; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
     recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "accepted an expected shadow _open the subset does not carry"; fi
grep -q 'expected the shadow body-one.o:_open, which no member taken carries' "$T/err" || fail "did not name the missing _open: $(cat "$T/err")"
echo "-- refused: the expected shadow named under another member"
if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/shadows.txt" RECAULK_EXPECTED_SHADOWS=other.o:_q_create; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
     recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "accepted _q_create expected from other.o"; fi
grep -q 'carries the shadow shadow-q.o:_q_create, which is not expected' "$T/err" || fail "did not name shadow-q.o:_q_create: $(cat "$T/err")"
echo "-- refused: a list line without a reason, trailing whitespace or not"
for _b in 'shadow-q.o _q_create' 'shadow-q.o _q_create ' 'shadow-q.o _q_create	'; do
  printf '%s\n' 'shadow-q.o _q_create creates a queue' "$_b" > "$T/bad.txt"
  if ( RECAULK_IMAGE_LOCAL_SHADOWS="$T/bad.txt" RECAULK_EXPECTED_SHADOWS=shadow-q.o:_q_create; export RECAULK_IMAGE_LOCAL_SHADOWS RECAULK_EXPECTED_SHADOWS
       recaulk_subset "$T/q.a" "$T/x.a" "$T/x.unx" _api_q ) 2> "$T/err"; then fail "accepted the list line '$_b', which has no reason"; fi
  grep -q 'not <member> <symbol> <reason>' "$T/err" || fail "did not name the malformed line '$_b': $(cat "$T/err")"
done
echo "PASS"
