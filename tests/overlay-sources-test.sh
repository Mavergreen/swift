#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch
# usage: sh tests/overlay-sources-test.sh
#   scripts/overlay-sources.sh lays out the Dispatch overlay's sources from the pinned trees build.sh fetches
#   ($SWIFT_WORK, default $MAVERICKS_BUILD_ROOT/swift/work: swift-6.2, swift-5.4, swift): swift-5.4's
#   Darwin/Dispatch, patched for 10.9 by patches/overlays 0003 onward -- each patch's marker present, the
#   QoS-to-priority mapping under an #available(macOS 10.10, *) else-branch, and nothing the 10.9 SDK and
#   Recaulk declare nowhere (autorelease frequency, initiallyInactive, block wait/notify, DATA_REPLACE,
#   dispatchPrecondition, DispatchQueue.qos) left in a source -- and its shims, DispatchOverlayShims.h under
#   its own module map. Skips, saying so, when the trees are absent.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
WORK="${SWIFT_WORK:-${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/swift/work}"
for d in swift-6.2 swift-5.4 swift; do
  [ -d "$WORK/$d" ] || { echo "no $WORK/$d -- skipping (build.sh fetches the pinned trees)"; exit 77; }
done
[ -f "$WORK/swift-5.4/stdlib/public/Darwin/Dispatch/Queue.swift" ] || { echo "no 5.4 Dispatch overlay under $WORK/swift-5.4 -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/overlay-sources.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "-- lays out the sources"
sh "$REPO/scripts/overlay-sources.sh" "$WORK/swift-6.2" "$WORK/swift-5.4" "$WORK/swift" "$WORK/swift/utils/gyb" "$T/out" > "$T/log" 2>&1 \
  || { cat "$T/log" >&2; fail "overlay-sources.sh failed"; }
D="$T/out/Dispatch"
for f in Block.swift Data.swift Dispatch.swift IO.swift Private.swift Queue.swift Source.swift Time.swift Dispatch.mm; do
  [ -s "$D/$f" ] || fail "no $D/$f"
done
[ "$(ls "$D" | grep -c .)" = 10 ] || fail "$D holds $(ls "$D" | tr '\n' ' '), not the nine sources and shims/"
[ ! -e "$D/Schedulers+DispatchQueue.swift" ] || fail "Schedulers+DispatchQueue.swift was laid out (it imports Combine)"
[ ! -e "$T/out/.patch" ] || fail "the scratch patch tree was left in the output"

echo "-- the shims: 5.4's DispatchOverlayShims.h under its own module map"
cmp -s "$D/shims/DispatchOverlayShims.h" "$WORK/swift-5.4/stdlib/public/SwiftShims/DispatchOverlayShims.h" \
  && fail "the shims are upstream's bytes, unpatched"
[ "$(cat "$D/shims/module.modulemap")" = 'module _SwiftDispatchOverlayShims {
  header "DispatchOverlayShims.h"
}' ] || fail "the shims' module map is not one module _SwiftDispatchOverlayShims over DispatchOverlayShims.h"
grep -q 'Mavericks: no _swift_dispatch_block_wait' "$D/shims/DispatchOverlayShims.h" || fail "shims: patch 0007 (block wait/notify) not applied"
grep -q 'Mavericks: no DATA_REPLACE' "$D/shims/DispatchOverlayShims.h" || fail "shims: patch 0010 (DATA_REPLACE) not applied"
[ "$(grep -v 'Mavericks' "$D/shims/DispatchOverlayShims.h" | grep -Ec 'dispatch_block_wait|dispatch_block_notify|DATA_REPLACE')" = 0 ] \
  || fail "the shims still call what no header declares"

echo "-- each patch's marker"
mark() { grep -q "$3" "$D/$2" || fail "patch $1 not applied: $D/$2 lacks '$3'"; }
mark 0003 Queue.swift "Mavericks: 10.9's dispatch_get_global_queue"
mark 0004 Queue.swift "Mavericks: no AutoreleaseFrequency"
mark 0005 Queue.swift "Mavericks: no initially-inactive attribute"
mark 0006 Queue.swift "Mavericks: no dispatch_queue_create_with_target"
mark 0007 Block.swift "Mavericks: no wait or notify"
mark 0008 Dispatch.swift "Mavericks: no DispatchPredicate"
mark 0009 Queue.swift "Mavericks: no qos"
mark 0010 Source.swift "Mavericks: no makeUserDataReplaceSource"
mark 0011 Data.swift "Mavericks: the 10.9 headers carry no nullability"
mark 0011 IO.swift "Mavericks: the 10.9 headers carry no nullability"
mark 0012 Block.swift "Mavericks: Recaulk defines and declares dispatch_block_create"
mark 0012 Queue.swift "Mavericks: Recaulk defines and declares dispatch_block_create"
mark 0012 Source.swift "Mavericks: Recaulk defines and declares dispatch_activate"
mark 0013 Queue.swift "Mavericks: 10.9's dispatch_block_create drops DISPATCH_BLOCK_BARRIER"
mark 0013 Block.swift "Mavericks: 10.9's dispatch_block_create drops its flags"
mark 0013 Dispatch.swift "Mavericks: a barrier-flagged block is submitted as a barrier below 10.10"

echo "-- below macOS 10.10, every path that submits a barrier-flagged block routes it through a barrier function"
# sync(execute:) and the three async forms (execute:, group:execute:, group:qos:flags:), asyncAfter (4), notify (2)
n="$(grep -c '_blockFlagsAreHonored && .*flags.contains(.barrier)' "$D/Queue.swift" "$D/Dispatch.swift" | awk -F: '{s+=$2} END{print s}')"
[ "$n" -ge 10 ] || fail "only $n barrier-routing checks in Queue.swift and Dispatch.swift, not the 10 submission paths"
grep -q '_swift_dispatch_barrier_async(self, { block(); g.leave() })' "$D/Queue.swift" || fail "a grouped barrier does not leave its group after the block"
grep -q '_syncBarrier(block: { workItem.perform() })' "$D/Queue.swift" || fail "sync(execute: DispatchWorkItem) has no barrier route"

echo "-- DispatchQueue.global(qos:) passes the QoS through only on 10.10, else maps it to a 10.9 priority"
awk '/public class func global\(qos:/{on=1} on{print} on&&/^\t}$/{exit}' "$D/Queue.swift" > "$T/global"
[ -s "$T/global" ] || fail "no DispatchQueue.global(qos:) in Queue.swift"
grep -q '^		if #available(macOS 10.10, iOS 8.0, \*) {$' "$T/global" || fail "global(qos:) has no #available(macOS 10.10, *) branch"
awk '/#available\(macOS 10.10/{on=1} on&&/qos.rawValue.rawValue/{ok=1} /^\t\t}$/{if(on)exit} END{exit !ok}' "$T/global" \
  || fail "global(qos:) does not pass the QoS through inside its 10.10 branch"
# After that branch: the else path, in the 10.9 SDK's priorities (queue.h: HIGH 2, DEFAULT 0, LOW -2, BACKGROUND INT16_MIN)
awk 'found{print} /^\t\t}$/{found=1}' "$T/global" > "$T/else"
for pair in 'userInteractive, .userInitiated:2' 'default, .unspecified:0' 'utility:-2' 'background:Int(Int16.min)'; do
  cases="${pair%:*}"; prio="${pair##*:}"
  grep -Fq "case .$cases: return __dispatch_get_global_queue($prio, 0)" "$T/else" || fail "global(qos:) does not map .$cases to priority $prio after its 10.10 branch"
done
grep -q 'DISPATCH_QUEUE_PRIORITY_HIGH' "$T/else" && grep -q 'DISPATCH_QUEUE_PRIORITY_BACKGROUND' "$T/else" || fail "the priority mapping does not name the 10.9 constants"

echo "-- nothing declared nowhere is left"
for w in autoreleaseFrequency initiallyInactive __dispatch_autorelease_frequency_t; do
  if grep -l "$w" "$D"/*.swift > "$T/hit"; then fail "$w is named in $(cat "$T/hit")"; fi
done
bad="$(grep -nE '__dispatch_assert_queue|__dispatch_queue_get_qos_class|_dispatch_block_wait|_dispatch_block_notify|DATA_REPLACE|dispatch_queue_create_with_target|DispatchPredicate|dispatchPrecondition' "$D"/*.swift \
  | grep -v 'Mavericks' | grep -v 'Private.swift:.*dispatch_queue_create_with_target' || true)"
[ -z "$bad" ] || fail "a source still names what no header declares: $bad"

echo "-- unchanged by the patches: Time.swift and Dispatch.mm are 5.4's bytes"
for f in Time.swift Dispatch.mm; do
  cmp -s "$D/$f" "$WORK/swift-5.4/stdlib/public/Darwin/Dispatch/$f" || fail "$f differs from the pinned 5.4 tree's"
done
echo "PASS"
