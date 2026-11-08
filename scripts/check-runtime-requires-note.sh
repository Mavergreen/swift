#!/bin/sh
# platform: host-agnostic
#   usage: check-runtime-requires-note.sh <version> [<repo-root>]
#          Fails unless release-notes/swift-runtime/<version>/requires/swift-runtime exists and says <version> on
#          its line 1. package-toolchain.sh makes the 10.9 toolchain pkg require swift-runtime of its own version,
#          which a pkg can only enforce on a 10.9 Mac where both are installed; the cross toolchain's users install
#          the runtime on their 10.9 Mac by hand, and this note is the one place the release tells them to.
#          release.yml runs it in the version job, once the version is known and the run publishes, before any
#          build, so a release without the note stops there.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$1" ] || { echo "usage: check-runtime-requires-note.sh <version> [<repo-root>]" >&2; exit 2; }
VER="$1"; ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$ROOT/release-notes/swift-runtime/$VER/requires/swift-runtime"
[ -f "$F" ] || { echo "check-runtime-requires-note: no $F -- the toolchains require swift-runtime $VER, and the cross toolchain's users need telling (README in release-notes/)" >&2; exit 1; }
[ "$(sed -n 1p "$F")" = "$VER" ] || { echo "check-runtime-requires-note: $F says '$(sed -n 1p "$F")', not $VER" >&2; exit 1; }
