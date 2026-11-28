#!/bin/sh
# platform: host-agnostic -- runs a built compiler: the Linux-hosted one on Linux, the cross one on an Apple-silicon Mac
# usage: SWIFT_HOST_TOOLCHAIN=<prefix> sh tests/coro-frame-order-test.sh
#   llvm patch 0007: CoroSplit lays out an optimized async function's frame in an order the IR alone
#   decides, whatever C++ library built the compiler. An async function awaiting 9, and then 20, tasks is
#   compiled at -O for x86_64-apple-macosx10.9, and its frame is read right after CoroSplit: its 32-byte
#   executor records, which tie in the frame's sort by size, must take frame fields in the order the
#   function declares them. Unpatched, the cross compiler (SDK 11.3's libc++) swapped them at 9 tasks, and
#   the Linux one (libstdc++) at 12 or more, so the two compilers built the same source differently.
#   The stdlib is <prefix>/lib/swift where it holds macosx/Swift.swiftmodule (a toolchain pkg's), else
#   build.sh's stdlib-build ($MAVERICKS_BUILD_ROOT/swift/work/stdlib-build/lib/swift), else
#   CORO_RESOURCE_DIR; the SDK is shipyard's fetch_sdk.sh's 10.9 SDK, or CORO_SDK.
#   SKIPs (77) with no such compiler or stdlib, or a compiler this host cannot run; with
#   CORO_FRAME_ORDER_REQUIRED=1 (release.yml's build job, on the same run's cross toolchain) each of those
#   fails instead. It is host-agnostic all the same: the script runs on any host, and what it needs is a
#   compiler and stdlib, not an OS, so a host without them skips it like any test whose input is absent.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() {
  [ "${CORO_FRAME_ORDER_REQUIRED:-0}" != 1 ] || fail "$* (CORO_FRAME_ORDER_REQUIRED=1)"
  echo "$* -- skipping"; exit 77
}
. "$REPO/lib.sh"     # -> $SWIFT_BUILD
P="${SWIFT_HOST_TOOLCHAIN:-}"
[ -n "$P" ] && [ -x "$P/bin/swift-frontend" ] || skip "no SWIFT_HOST_TOOLCHAIN with bin/swift-frontend"
FE="$P/bin/swift-frontend"
"$FE" -version >/dev/null 2>&1 || skip "$FE does not run on this host"
RES="${CORO_RESOURCE_DIR:-}"
if [ -z "$RES" ]; then
  for r in "$P/lib/swift" "$SWIFT_BUILD/work/stdlib-build/lib/swift"; do
    [ -d "$r/macosx/Swift.swiftmodule" ] && { RES="$r"; break; }
  done
fi
[ -n "$RES" ] && [ -d "$RES/macosx/Swift.swiftmodule" ] || skip "no macOS stdlib for $P (set CORO_RESOURCE_DIR)"
SDK="${CORO_SDK:-}"
if [ -z "$SDK" ]; then
  . "$REPO/msc.sh"   # -> $SHIPYARD (fetch_sdk.sh)
  SDK="$(sh "$SHIPYARD/fetch_sdk.sh")" || fail "could not fetch the pinned 10.9 SDK"
fi
T="$(mktemp -d "${TMPDIR:-/tmp}/coro-frame-order.XXXXXX")"
trap 'rm -rf "$T"' EXIT

for n in 9 20; do
  S="$T/coro$n.swift"
  { echo "@inline(never) public func f() async -> Int {"
    i=0; while [ "$i" -lt "$n" ]; do echo "  let t$i = Task { $i }; let v$i = await t$i.value"; i=$((i + 1)); done
    printf '  return 0'; i=0; while [ "$i" -lt "$n" ]; do printf ' &+ v%d' "$i"; i=$((i + 1)); done; printf '\n}\n'
  } > "$S"
  M="coro$n"; FN="\$s${#M}${M}1fSiyYaF"
  "$FE" -frontend -primary-file "$S" -target x86_64-apple-macosx10.9 -sdk "$SDK" -resource-dir "$RES" \
    -module-name "$M" -O -parse-as-library -emit-ir -o "$T/$M.ll" \
    -Xllvm -print-after=coro-split -Xllvm "-filter-print-funcs=$FN" 2> "$T/$M.after" \
    || fail "$n tasks: the compile failed: $(tail -5 "$T/$M.after")"
  # Each executor record's frame field, first use only, as "<declaration order> <field>", in declaration
  # order: the record's name suffix grows with the declaration (initial_serial_executor_record, ...4, ...10).
  awk -v fr="%\"$FN.Frame\", ptr %async.ctx.frameptr" '
    /IR Dump After CoroSplit/ { p++ } p != 1 { next }
    index($0, fr) && $1 ~ /^%initial_serial_executor_record[0-9]*$/ && !seen[$1]++ {
      k = $1; sub(/^%initial_serial_executor_record/, "", k); print (k == "" ? 0 : k), $NF }' "$T/$M.after" \
    | sort -n -k1,1 > "$T/$M.fields"
  c="$(wc -l < "$T/$M.fields" | tr -d ' ')"
  [ "$c" -ge 3 ] || fail "$n tasks: $c executor records in $FN's frame after CoroSplit, not 3 or more: $(head -20 "$T/$M.after")"
  awk 'NR > 1 && $2 <= f { bad = 1 } { f = $2 } END { exit bad }' "$T/$M.fields" \
    || fail "$n tasks: the executor records' frame fields are not in declaration order (llvm patch 0007?): $(tr '\n' ' ' < "$T/$M.fields")"
  echo "$n tasks: $c executor records, frame fields in declaration order: $(awk '{ printf "%s ", $2 }' "$T/$M.fields")"
done
echo "PASS"
