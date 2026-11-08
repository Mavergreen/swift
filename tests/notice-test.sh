#!/bin/sh
# platform: host-agnostic
# usage: sh tests/notice-test.sh
#   NOTICE ships in every pkg (stage-runtime.sh, stage-toolchain.sh) and must name what those pkgs hold:
#   every patch in patches/runtime and patches/overlays by its number, swift-frontend's modification by
#   patches/compiler (Apache-2.0 section 4(b)) with each of its patches by number, the Darwin and ObjectiveC overlays'
#   sources, and each of Recaulk's members build.sh links statically. Three of those (libswiftDarwin's
#   openat, libswift_Concurrency's clock_gettime) are MacPorts legacy-support's sources, which keep their
#   own licences: atcalls.c's APSL 2.0 asks for its notices, its licence text and where its source is;
#   pthread_chdir.c's header is no grant, so NOTICE carries legacy-support's LICENSE (MIT for the
#   MacPorts community's files) as its grant; time.c's header is its own grant (ISC-style), which asks
#   for its copyright notices and itself in every copy.
#   Each MacPorts member build.sh's RECAULK_NOTICES_REVIEWED vouches for (one Recaulk's notices list has
#   no row for, since it is not APSL) must have its source named here.
#   A patch or a member added without its NOTICE entry once shipped unnamed.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
N="$REPO/NOTICE"

echo "-- every runtime and overlay patch is named by its number"
for d in runtime overlays; do
  for p in "$REPO/patches/$d"/*.patch; do
    n="$(basename "$p" | cut -c1-4)"
    grep -Eq "^ +$n  " "$N" || fail "NOTICE lists no $d patch $n ($(basename "$p"))"
  done
done
grep -q "patches/overlays" "$N" || fail "NOTICE does not say where the overlay patches are"

echo "-- the toolchains' swift-frontend: its modification statement (Apache-2.0 section 4(b)) names every compiler patch"
grep -q "swift-frontend" "$N" && grep -q "built with the patches in ./patches/compiler" "$N" \
  || fail "NOTICE does not say swift-frontend is modified, with the patches in ./patches/compiler"
# Read from that statement to the next blank line: overlay patch 0001 shares compiler patch 0001's number.
awk '/built with the patches in .\/patches\/compiler/{on=1} on&&/^$/{exit} on' "$N" > "${TMPDIR:-/tmp}/notice-compiler.$$"
for p in "$REPO"/patches/compiler/*.patch; do
  n="$(basename "$p" | cut -c1-4)"
  grep -Eq "^ +$n  " "${TMPDIR:-/tmp}/notice-compiler.$$" || { rm -f "${TMPDIR:-/tmp}/notice-compiler.$$"; fail "NOTICE's statement lists no compiler patch $n ($(basename "$p"))"; }
done
rm -f "${TMPDIR:-/tmp}/notice-compiler.$$"

echo "-- the overlays' sources: swift-6.2's Darwin, swift-5.4's ObjectiveC, Apache-2.0 with the Runtime Library Exception"
grep -q "libswiftDarwin" "$N" && grep -q "swift-6.2" "$N" || fail "NOTICE does not name libswiftDarwin's swift-6.2 source"
grep -q "libswiftObjectiveC" "$N" && grep -q "swift-5.4" "$N" || fail "NOTICE does not name libswiftObjectiveC's swift-5.4 source"

echo "-- MacPorts legacy-support's sources in libswiftDarwin, with their notices"
grep -q "src/atcalls.c" "$N" || fail "NOTICE does not name MacPorts' atcalls.c"
grep -q "Copyright (c) 2013-2015 Apple Inc. All rights reserved." "$N" || fail "NOTICE lacks atcalls.c's Apple copyright"
grep -q "Copyright (C) 2023 raf <raf@raf.org>" "$N" || fail "NOTICE lacks atcalls.c's second copyright"
grep -q "https://github.com/macports/macports-legacy-support" "$N" || fail "NOTICE does not say where atcalls.c's source is (APSL 2.0 section 2.3)"
grep -q "^APPLE PUBLIC SOURCE LICENSE$" "$N" && grep -q "^Version 2.0 - August 6, 2003$" "$N" \
  || fail "NOTICE does not carry the APSL 2.0's text"
# Recaulk's notices.tsv row for mp-atcalls.o: its notice, which libswiftDarwin also carries in its code,
# names atcalls.h too and the commit-pinned sources. build.sh's step 7 holds NOTICE to the tsv's very
# text (lib.sh's recaulk_notices); this keeps the hand-edited lines from going missing between builds.
NF="$(tr -s ' \t\n' '   ' < "$N")"
LS="https://github.com/macports/macports-legacy-support/blob/f89c155cbc2ca8714e4ada66c11b222353e8d87a/src"
for t in "Recaulk member mp-atcalls.o is object code compiled from src/atcalls.c of MacPorts legacy-support" \
         "contains Covered Code from src/atcalls.c, src/atcalls.h" "$LS/atcalls.c and $LS/atcalls.h." \
         "This chunk of header was refactored from the above Apple-supplied file, atcalls.c."; do
  case "$NF" in *"$t"*) ;; *) fail "NOTICE lacks Recaulk's atcalls notice text: $t" ;; esac
done
grep -q "src/pthread_chdir.c" "$N" || fail "NOTICE does not name MacPorts' pthread_chdir.c"
grep -q "Copyright (c) 2025 Frederick H. G. Wright II <fw@fwright.net>" "$N" || fail "NOTICE lacks pthread_chdir.c's copyright"
grep -q "Copyright (c) 2018-2025 Chris Jones, Michael Dickens" "$N" && grep -q "are under the MIT License" "$N" \
  && grep -q "The above copyright notice and this permission notice shall be included in all" "$N" \
  || fail "NOTICE lacks legacy-support's LICENSE, the grant for pthread_chdir.c"

echo "-- MacPorts legacy-support's time.c in libswift_Concurrency, with its notices and grant"
grep -q "src/time.c" "$N" || fail "NOTICE does not name MacPorts' time.c"
grep -q "libswift_Concurrency" "$N" || fail "NOTICE does not name libswift_Concurrency"
grep -q "Copyright (c) 2018 Chris Jones <jonesc@macports.org>" "$N" || fail "NOTICE lacks time.c's first copyright"
[ "$(grep -c "Copyright (c) 2025 Frederick H. G. Wright II <fw@fwright.net>" "$N")" -ge 2 ] \
  || fail "NOTICE lacks time.c's second copyright (it appears once, for pthread_chdir.c)"
[ "$(grep -c "copyright notice and this permission notice appear in all copies." "$N")" -ge 2 ] \
  || fail "NOTICE lacks time.c's own grant (its permission text appears once, for Recaulk)"

echo "-- each MacPorts member build.sh's RECAULK_NOTICES_REVIEWED vouches for has its source named in NOTICE"
# Recaulk's notices list has rows only for APSL members; step 7 accepts a linked mp-* member without one
# only when this list names it, so NOTICE must carry that member's own licence (mp-X.o is src/X.c).
REV="$(sed -n 's/^RECAULK_NOTICES_REVIEWED="\([^"]*\)"$/\1/p' "$REPO/build.sh")"
[ -n "$REV" ] || fail "read no RECAULK_NOTICES_REVIEWED from build.sh"
for m in $REV; do
  case "$m" in mp-*.o) ;; *) fail "RECAULK_NOTICES_REVIEWED names $m, not a MacPorts mp-*.o member" ;; esac
  f="${m#mp-}"; f="src/${f%.o}.c"
  grep -q "$f" "$N" || fail "NOTICE does not name $f, the source of $m, which build.sh vouches for"
done
echo "-- each Recaulk symbol build.sh links is named"
# By its API's name, as a whole word (fma is not fmax): a \$V2-style suffix, escaped in build.sh, is the
# SDK's binding, not the API's name.
for s in $(sed -En 's/^RECAULK_(RUNTIME|DARWIN|CONCURRENCY)_SYMBOLS="([^"]*)"$/\2/p' "$REPO/build.sh"); do
  a="${s#_}"; a="${a%%[\\\$]*}"
  grep -qw -- "$a" "$N" || fail "NOTICE does not name Recaulk's $a, which build.sh links"
done
[ -n "$(sed -n 's/^RECAULK_DARWIN_SYMBOLS="\([^"]*\)"$/\1/p' "$REPO/build.sh")" ] || fail "read no RECAULK_DARWIN_SYMBOLS from build.sh"
[ -n "$(sed -n 's/^RECAULK_CONCURRENCY_SYMBOLS="\([^"]*\)"$/\1/p' "$REPO/build.sh")" ] || fail "read no RECAULK_CONCURRENCY_SYMBOLS from build.sh"
echo "PASS"
