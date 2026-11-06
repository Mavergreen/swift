#!/bin/sh
# platform: host-agnostic
# usage: sh tests/notice-test.sh
#   NOTICE ships in every pkg (stage-runtime.sh, stage-toolchain.sh) and must name what those pkgs hold:
#   every patch in patches/runtime and patches/overlays by its number, the Darwin and ObjectiveC overlays'
#   sources, and each of Recaulk's members build.sh links statically. Two of those (libswiftDarwin's
#   openat) are MacPorts legacy-support's sources, which keep their own licences: atcalls.c's APSL 2.0
#   asks for its notices, its licence text and where its source is; pthread_chdir.c's for its notice.
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
grep -q "src/pthread_chdir.c" "$N" || fail "NOTICE does not name MacPorts' pthread_chdir.c"
grep -q "Copyright (c) 2025 Frederick H. G. Wright II <fw@fwright.net>" "$N" || fail "NOTICE lacks pthread_chdir.c's copyright"

echo "-- each Recaulk symbol build.sh links is named"
for s in $(sed -En 's/^RECAULK_(RUNTIME|DARWIN)_SYMBOLS="([^"]*)"$/\2/p' "$REPO/build.sh"); do
  grep -q "${s#_}" "$N" || fail "NOTICE does not name Recaulk's ${s#_}, which build.sh links"
done
[ -n "$(sed -n 's/^RECAULK_DARWIN_SYMBOLS="\([^"]*\)"$/\1/p' "$REPO/build.sh")" ] || fail "read no RECAULK_DARWIN_SYMBOLS from build.sh"
echo "PASS"
