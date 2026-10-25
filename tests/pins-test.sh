#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pins-test.sh
#   pins.env is sourced by every build script, on a modern Mac and on 10.9: it must need nothing
#   installed, and its derived names must agree with its pins.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(cd "$REPO" && env -i PATH=/usr/bin:/bin HOME="$HOME" /bin/sh -c 'set -eu; . ./pins.env
  printf "%s\n" "$SWIFT_VERSION" "$SWIFT_TAG" "$SWIFT_SHA" "$LLVM_SWIFT_RELEASE" "$LLVM_TAG" "$LLVM_SHA" \
    "$TOOLCHAIN_URL" "$TOOLCHAIN_ASSET" "$DEPLOYMENT" "$ARCH" "${VERSION-unset}" "${BUILDSUPPORT_ASSET-unset}" \
    "$CMARK_SWIFT_RELEASE" "$CMARK_TAG" "$CMARK_SHA" "$CLANG22_VERSION" \
    "$SWIFT_TARBALL_SHA256" "$LLVM_TARBALL_SHA256" "$CMARK_TARBALL_SHA256" "$RECAULK_VERSION"
  [ -n "$TOOLCHAIN_SIGNER" ]')" || fail "sourcing pins.env with only /usr/bin:/bin on PATH failed"
set -- $out
[ $# -eq 20 ] || fail "expected 20 values from pins.env, got $#: $out"
v="$1"
case "$v" in [0-9]*.[0-9]*.[0-9]*) ;; *) fail "SWIFT_VERSION '$v' is not X.Y.Z" ;; esac
[ "$2" = "swift-$v-RELEASE" ] || fail "SWIFT_TAG '$2' is not derived from SWIFT_VERSION"
printf '%s' "$3" | grep -Eq '^[0-9a-f]{40}$' || fail "SWIFT_SHA '$3' is not a commit"
[ "$4" = "$v" ] || fail "LLVM_SWIFT_RELEASE '$4' differs from SWIFT_VERSION '$v'"
[ "$5" = "swift-$4-RELEASE" ] || fail "LLVM_TAG '$5' is not derived from LLVM_SWIFT_RELEASE"
printf '%s' "$6" | grep -Eq '^[0-9a-f]{40}$' || fail "LLVM_SHA '$6' is not a commit"
[ "$7" = "https://download.swift.org/swift-$v-release/xcode/swift-$v-RELEASE/swift-$v-RELEASE-osx.pkg" ] \
  || fail "TOOLCHAIN_URL '$7' is not derived from SWIFT_VERSION"
[ "$8" = "upstream-swift-$v-RELEASE-osx.pkg" ] || fail "TOOLCHAIN_ASSET '$8' is not derived from SWIFT_VERSION"
[ "$9" = 10.9 ] || fail "DEPLOYMENT is '$9'"
[ "${10}" = x86_64 ] || fail "ARCH is '${10}'"
[ "${11}" = unset ] || fail "pins.env defines VERSION ('${11}'): the release version is package.sh's to resolve"
[ "${12}" = unset ] || fail "pins.env still names a build-support tarball ('${12}')"

[ "${13}" = "$v" ] || fail "CMARK_SWIFT_RELEASE '${13}' differs from SWIFT_VERSION '$v'"
[ "${14}" = "swift-${13}-RELEASE" ] || fail "CMARK_TAG '${14}' is not derived from CMARK_SWIFT_RELEASE"
printf '%s' "${15}" | grep -Eq '^[0-9a-f]{40}$' || fail "CMARK_SHA '${15}' is not a commit"
printf '%s' "${16}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-mavericks\.[0-9]+$' || fail "CLANG22_VERSION '${16}' is not a -mavericks.N release"
# spec: INGREDIENTS.md "One C++ runtime" -- the pin is libcxx22's minimum too,
#       and a libcxx22 before 22.1.8-mavericks.5 carries its own libc++abi
printf '%s\n%s\n' "$(printf '%s' "${16}" | sed 's/-mavericks\./ /; s/\./ /g')" "22 1 8 5" \
  | awk 'NR == 1 { split($0, h, " ") } NR == 2 { split($0, m, " "); for (i = 1; i <= 4; i++) { if (h[i] + 0 > m[i] + 0) exit 0; if (h[i] + 0 < m[i] + 0) exit 1 } exit 0 }' \
  || fail "CLANG22_VERSION '${16}' is older than 22.1.8-mavericks.5, the first libcxx22 on the OS's own libc++abi"
for h in "${17}" "${18}" "${19}"; do
  printf '%s' "$h" | grep -Eq '^[0-9a-f]{64}$' || fail "a *_TARBALL_SHA256 pin '$h' is not a SHA-256 (scripts/pin-source-tarballs.sh writes them)"
done

printf '%s' "${20}" | grep -Eq '^[0-9]{8}\.[0-9]+$' || fail "RECAULK_VERSION '${20}' is not a YYYYMMDD.N release"

up="$(cd "$REPO" && sh scripts/derive-upstream-version.sh)"
[ "$up" = "$v" ] || fail "derive-upstream-version.sh says '$up', pins.env says '$v'"
echo "PASS"
