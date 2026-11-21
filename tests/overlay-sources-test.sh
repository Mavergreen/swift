#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch
# usage: sh tests/overlay-sources-test.sh
#   scripts/overlay-sources.sh lays out the Dispatch overlay's sources from the pinned trees build.sh fetches
#   ($SWIFT_WORK, default $MAVERICKS_BUILD_ROOT/swift/work: swift-6.2, swift-5.4, swift): swift-5.4's
#   Darwin/Dispatch, patched for 10.9 by patches/overlays 0003 onward -- each patch's marker present, the
#   QoS-to-priority mapping under an #available(macOS 10.10, *) else-branch, what Recaulk declares and defines
#   (autorelease frequency, initiallyInactive, the target at creation, block wait/notify, dispatchPrecondition,
#   activate()) at macOS 10.9, and neither DATA_REPLACE, declared nowhere, nor DispatchQueue.qos, which Recaulk
#   cannot read back, left in a source -- and its shims, DispatchOverlayShims.h under its own module map. Skips,
#   saying so, when the trees are absent.
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
grep -q 'Mavericks: no DATA_REPLACE' "$D/shims/DispatchOverlayShims.h" || fail "shims: patch 0010 (DATA_REPLACE) not applied"
[ "$(grep -v 'Mavericks' "$D/shims/DispatchOverlayShims.h" | grep -Ec 'DATA_REPLACE')" = 0 ] \
  || fail "the shims still name DATA_REPLACE, which no header declares"
for f in dispatch_block_wait dispatch_block_notify; do
  grep -q "return $f(block, timeout);\|$f(block, queue, notifier);" "$D/shims/DispatchOverlayShims.h" || fail "the shims do not call $f (Recaulk declares it)"
done

echo "-- each patch's marker"
mark() { grep -q "$3" "$D/$2" || fail "patch $1 not applied: $D/$2 lacks '$3'"; }
mark 0003 Queue.swift "Mavericks: 10.9's dispatch_get_global_queue"
mark 0004 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_attr_make_with_autorelease_frequency"
mark 0005 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_attr_make_initially_inactive"
mark 0006 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_create_with_target"
mark 0008 Dispatch.swift "Mavericks: Recaulk defines and declares dispatch_assert_queue"
mark 0009 Queue.swift "Mavericks: no qos"
mark 0010 Source.swift "Mavericks: no makeUserDataReplaceSource"
mark 0011 Data.swift "Mavericks: the 10.9 headers carry no nullability"
mark 0011 IO.swift "Mavericks: the 10.9 headers carry no nullability"
mark 0012 Block.swift "Mavericks: Recaulk defines and declares dispatch_block_create"
mark 0012 Queue.swift "Mavericks: Recaulk defines and declares dispatch_block_create"
mark 0012 Source.swift "Mavericks: Recaulk defines and declares dispatch_block_create"
mark 0013 Queue.swift "Mavericks: 10.9's dispatch_block_create drops DISPATCH_BLOCK_BARRIER"
mark 0013 Block.swift "Mavericks: 10.9's dispatch_block_create drops its flags"
mark 0013 Dispatch.swift "Mavericks: a barrier-flagged block is submitted as a barrier below 10.10"
mark 0013 Source.swift "Mavericks: a .barrier flag is not routed here"

echo "-- patch 0014: DispatchGroup() and DispatchSemaphore(value:) are not failable (10.9's headers carry no nullability)"
A="$T/out/apinotes/Dispatch.apinotes"; [ -f "$A" ] || fail "no $A"
for f in dispatch_group_create dispatch_semaphore_create; do
  grep -A4 "^- Name: $f\$" "$A" | grep -q '^  NullabilityOfRet: N$' || fail "patch 0014 not applied: Dispatch.apinotes' $f lacks NullabilityOfRet: N"
done
mark 0015 Dispatch.swift "Mavericks: 5.4 predates Sendable"
grep -q '^extension DispatchObject : @unchecked Sendable {}$' "$D/Dispatch.swift" || fail "patch 0015: DispatchObject is not Sendable"

grep -q '^extension DispatchQueue.AutoreleaseFrequency : @unchecked Sendable {}$' "$D/Dispatch.swift" \
  && grep -q '^extension DispatchPredicate : @unchecked Sendable {}$' "$D/Dispatch.swift" \
  || fail "patch 0015: AutoreleaseFrequency and DispatchPredicate are not Sendable, as Apple's SDK declares them"

echo "-- what macOS 10.12 added and Recaulk declares and defines is macOS 10.9"
# activate(), both of them, is the overlay's (0016 for an object's, 0012 for a source's), so a program calls
# libswiftDispatch, which links Recaulk's dispatch_activate, never the C function, which 10.9's libSystem lacks.
mark 0016 Dispatch.swift "Mavericks: activate() is the overlay's"
grep -A1 '^- Name: dispatch_activate$' "$A" | grep -q "^  SwiftName: 'DispatchObject.__activate(self:)'$" \
  || fail "patch 0016 not applied: Dispatch.apinotes still imports dispatch_activate as activate()"
for f in Dispatch.swift Source.swift; do
  grep -B1 '^	public func activate() {$' "$D/$f" | grep -q '^	@available(macOS 10.9, iOS 10.0, tvOS 10.0, watchOS 3.0, \*)$' \
    || fail "$f's activate() is not @available(macOS 10.9, ...)"
done
[ "$(grep -c 'public func activate()' "$D"/*.swift | awk -F: '{s+=$2} END{print s}')" = 2 ] || fail "an activate() other than DispatchObject's and DispatchSourceProtocol's"
grep -q '^	public func wait(timeout: DispatchTime) -> DispatchTimeoutResult {$' "$D/Block.swift" \
  && grep -q '^	public func notify(queue: DispatchQueue, execute: DispatchWorkItem) {$' "$D/Block.swift" \
  || fail "DispatchWorkItem has no wait(timeout:) or notify(queue:execute:)"
grep -q 'self.init(__label: label, attr: attr, queue: target)' "$D/Queue.swift" || fail "the target: initializer does not pass the target at creation"
for f in "$D"/*.swift; do
  if grep -n 'macOS 10.12' "$f" | grep -v '#unavailable(macOS 10.12, '; then fail "${f##*/} still names macOS 10.12 (above)"; fi
done
# On 10.10 and 10.11 the OS's QoS attributes and Recaulk's inactive one do not compose, so there an initially
# inactive queue drops its QoS (0005); 10.9 and 10.12 and later keep it. Not run-testable on the 10.9 box.
awk '/public convenience init\(/{on=1} on{print} on&&/^\t}$/{exit}' "$D/Queue.swift" > "$T/init"
grep -q 'Mavericks: on macOS 10.10 and 10.11 an initially inactive queue keeps no QoS' "$T/init" \
  && grep -q '^		if #unavailable(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0), attributes.contains(.initiallyInactive) {$' "$T/init" \
  && grep -q '^			if #available(macOS 10.10, iOS 8.0, \*) { qos = .unspecified }$' "$T/init" \
  || fail "the queue initializer does not drop the QoS of an initially inactive queue on 10.10 and 10.11"
[ "$(grep -n 'qos = .unspecified' "$T/init" | cut -d: -f1)" -lt "$(grep -n '__dispatch_queue_attr_make_with_qos_class' "$T/init" | cut -d: -f1)" ] \
  || fail "the initializer drops the QoS after it has made the attribute"
echo "-- below macOS 10.10, every path that submits a barrier-flagged block routes it through a barrier function"
# sync(execute:) and the three async forms (execute:, group:execute:, group:qos:flags:), asyncAfter (4), notify (2)
n="$(grep -c '_blockFlagsAreHonored && .*flags.contains(.barrier)' "$D/Queue.swift" "$D/Dispatch.swift" | awk -F: '{s+=$2} END{print s}')"
[ "$n" -ge 10 ] || fail "only $n barrier-routing checks in Queue.swift and Dispatch.swift, not the 10 submission paths"
# and DispatchWorkItem's two notify forms
n="$(grep -c '_blockFlagsAreHonored && .*flags.contains(.barrier)' "$D/Block.swift")"
[ "$n" = 2 ] || fail "$n barrier-routing checks in Block.swift, not DispatchWorkItem.notify's 2"
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

echo "-- neither DATA_REPLACE, declared nowhere, nor DispatchQueue.qos, which Recaulk cannot read back, is left"
bad="$(grep -nE '__dispatch_queue_get_qos_class|DATA_REPLACE|public var qos: DispatchQoS' "$D"/*.swift | grep -v 'Mavericks' || true)"
[ -z "$bad" ] || fail "a source still names what the overlay leaves out: $bad"
for w in 'public enum AutoreleaseFrequency' 'public static let initiallyInactive' 'public enum DispatchPredicate' 'public func dispatchPrecondition'; do
  grep -q "$w" "$D"/*.swift || fail "no '$w' in the sources"
done

echo "-- unchanged by the patches: Time.swift and Dispatch.mm are 5.4's bytes"
for f in Time.swift Dispatch.mm; do
  cmp -s "$D/$f" "$WORK/swift-5.4/stdlib/public/Darwin/Dispatch/$f" || fail "$f differs from the pinned 5.4 tree's"
done
echo "PASS"
