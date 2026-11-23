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
for d in swift-6.2 swift-5.4 swift-4.0 swift; do
  [ -d "$WORK/$d" ] || { echo "no $WORK/$d -- skipping (build.sh fetches the pinned trees)"; exit 77; }
done
[ -f "$WORK/swift-5.4/stdlib/public/Darwin/Dispatch/Queue.swift" ] || { echo "no 5.4 Dispatch overlay under $WORK/swift-5.4 -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/overlay-sources.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "-- lays out the sources"
sh "$REPO/scripts/overlay-sources.sh" "$WORK/swift-6.2" "$WORK/swift-5.4" "$WORK/swift-4.0" "$WORK/swift" "$WORK/swift/utils/gyb" "$T/out" > "$T/log" 2>&1 \
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
echo "-- CoreFoundation, CoreGraphics and Foundation: swift-5.4's, with their shims and swift-4.0's API notes"
S54="$WORK/swift-5.4/stdlib/public/Darwin"; O="$T/out"
for f in CoreFoundation/CoreFoundation.swift CoreGraphics/CoreGraphics.swift CoreGraphics/CGFloat.swift CoreGraphics/Private.swift \
         Foundation/NSValue.swift Foundation/BundleLookup.mm Foundation/DataThunks.m \
         apinotes/Foundation.apinotes apinotes/CoreGraphics.apinotes apinotes/Dispatch.apinotes; do
  [ -s "$O/$f" ] || fail "no $O/$f"
done
# Every Swift file of 5.4's Foundation but the Combine ones and the four whose classes 10.9 lacks.
for f in "$S54/Foundation"/*.swift; do
  b="${f##*/}"
  case "$b" in
    Publishers+*|Schedulers+*|CombineTypealiases.swift)
      [ ! -e "$O/Foundation/$b" ] || fail "$b was laid out (it is Combine's)" ;;
    Measurement.swift|PersonNameComponents.swift|NSOrderedCollectionDifference.swift|NSItemProvider.swift)
      [ ! -e "$O/Foundation/$b" ] || fail "$b was laid out (10.9 declares none of its class)" ;;
    *) [ -s "$O/Foundation/$b" ] || fail "no $O/Foundation/$b" ;;
  esac
done
[ "$(ls "$O/Foundation" | grep -Ec '^(Publishers\+|Schedulers\+|CombineTypealiases)')" = 0 ] || fail "a Combine file is in $O/Foundation"
grep -q 'OSX 13.0' "$O/Foundation/NSValue.swift" "$O/CoreGraphics/CGFloat.swift" && fail "NSValue.swift or CGFloat.swift is 6.4's gyb's (OSX 13.0), not 5.4's"
grep -q 'public struct CGFloat' "$O/CoreGraphics/CGFloat.swift" || fail "CGFloat.swift holds no CGFloat"
[ "$(cat "$O/CoreFoundation/shims/module.modulemap")" = 'module _SwiftCoreFoundationOverlayShims [system] {
  header "CoreFoundationOverlayShims.h"
}' ] || fail "the CoreFoundation shims' module map is not one [system] module over CoreFoundationOverlayShims.h"
[ "$(cat "$O/Foundation/shims/module.modulemap")" = 'module _SwiftFoundationOverlayShims [system] {
  header "FoundationOverlayShims.h"
}' ] || fail "the Foundation shims' module map is not one [system] module over FoundationOverlayShims.h"
for h in CoreFoundationOverlayShims.h CFCharacterSetShims.h CFHashingShims.h; do
  [ -s "$O/CoreFoundation/shims/$h" ] || fail "no $O/CoreFoundation/shims/$h"
done
for h in FoundationOverlayShims.h FoundationShimSupport.h NSCalendarShims.h NSCharacterSetShims.h NSCoderShims.h NSDataShims.h \
         NSDictionaryShims.h NSErrorShims.h NSFileManagerShims.h NSIndexPathShims.h NSIndexSetShims.h NSKeyedArchiverShims.h \
         NSLocaleShims.h NSTimeZoneShims.h NSUndoManagerShims.h; do
  [ -s "$O/Foundation/shims/$h" ] || fail "no $O/Foundation/shims/$h"
done
[ "$(ls "$O/CoreFoundation/shims" | grep -c .)" = 4 ] && [ "$(ls "$O/Foundation/shims" | grep -c .)" = 16 ] \
  || fail "a shims dir holds more than its headers and module map"

echo "-- each CoreGraphics and Foundation patch's marker"
omark() { grep -q "$3" "$O/$2" || fail "patch $1 not applied: $O/$2 lacks '$3'"; }
omark 0017 apinotes/CoreGraphics.apinotes "Mavericks: the getters CoreGraphics.swift reads"
omark 0018 apinotes/CoreGraphics.apinotes "Mavericks: 10.9 declares CGColorSpaceModel a plain C enum"
omark 0019 apinotes/Foundation.apinotes "Mavericks: 10.9's NSCalendarUnit also lists the"
omark 0020 apinotes/Foundation.apinotes "Mavericks: 10.9's headers carry no nullability, so what the"
omark 0021 apinotes/Foundation.apinotes "Mavericks: not throwing, as later SDKs' NS_SWIFT_NOTHROW has"
omark 0022 Foundation/shims/NSDataShims.h "Mavericks: the 10.9 SDK has no API_AVAILABLE"
omark 0022 Foundation/shims/NSDictionaryShims.h "Mavericks: 10.9 has getObjects:andKeys:"
omark 0023 Foundation/NSCoder.swift "Mavericks: no resolveError: NSCoderValueNotFoundError (10.11)"
omark 0024 Foundation/NSUndoManager.swift "Mavericks: no registerUndo(withTarget:handler:): it calls"
omark 0025 Foundation/CharacterSet.swift "Mavericks: each set is NSCharacterSet's (10.9), never"
omark 0026 Foundation/Codable.swift "Mavericks: no TopLevelEncoder/TopLevelDecoder conformances of"
omark 0027 Foundation/URL.swift "Mavericks: no ubiquitousSharedItemOwnerNameComponents or"
omark 0028 Foundation/DateInterval.swift "Mavericks: not ReferenceConvertible, and bridged to no class:"
omark 0029 Foundation/URLComponents.swift "Mavericks: no queryItems or percentEncodedQueryItems: they are"
omark 0030 Foundation/URLComponents.swift "Mavericks: no string: NSURLComponents' string is 10.10, which"
omark 0031 Foundation/JSONEncoder.swift "Mavericks: no iso8601: it formats with ISO8601DateFormatter"
omark 0032 Foundation/JSONEncoder.swift "Mavericks: JSONSerialization writes a top-level fragment (a"
omark 0033 Foundation/URL.swift "Mavericks: no init(fileURLWithPath:isDirectory:relativeTo:) or"
omark 0034 Foundation/NSStringAPI.swift "Mavericks: no localizedCapitalized: NSString's"
omark 0035 Foundation/Progress.swift "Mavericks: no estimatedTimeRemaining, throughput,"
omark 0036 Foundation/URLRequest.swift "Mavericks: no allowsExpensiveNetworkAccess or"
omark 0037 Foundation/URLSession.swift "Mavericks: no URLSessionWebSocketTask (10.15) or"
omark 0038 Foundation/URLCache.swift "Mavericks: no init(memoryCapacity:diskCapacity:directory:):"
omark 0039 Foundation/NSError.swift "Mavericks: no user info value provider: NSError's"
omark 0040 Foundation/IndexPath.swift "Mavericks: getIndexes(_:), every index, which count is: the"
omark 0041 Foundation/Data.swift "Mavericks: 1299 is NSFoundationVersionNumber10_11_Max, which"
omark 0043 Foundation/NSObject.swift "Mavericks: 10.9 declares NSKeyValueChange NS_OPTIONS, not"
omark 0044 apinotes/CoreGraphics.apinotes "Mavericks: 10.9 declares CGRectEdge a plain C enum"
omark 0045 Foundation/URL.swift "Mavericks: no isApplication or applicationIsScriptable"
omark 0046 Foundation/Calendar.swift "Mavericks: NSCalendarIdentifierIslamicTabular and"

echo "-- the shims Recaulk's typedefs serve are 5.4's own; the NSCalendar and NSIndexSet blocks are NoEscape"
for h in NSCalendarShims.h NSFileManagerShims.h; do
  cmp -s "$O/Foundation/shims/$h" "$WORK/swift-5.4/stdlib/public/SwiftShims/$h" || fail "$h differs from 5.4's (NSCalendarIdentifier and NSURLResourceKey are Recaulk's)"
done
for sel in "'enumerateDatesStartingAfterDate:matchingComponents:options:usingBlock:'" "'indexesInRange:options:passingTest:'"; do
  awk -v s="  - Selector: $sel" '$0==s{on=1;next} on&&/^  - Selector:|^- Name:/{exit} on&&/^      NoEscape: true$/{ok=1} END{exit !ok}' \
    "$O/apinotes/Foundation.apinotes" || fail "Foundation.apinotes: $sel's block is not NoEscape"
done
[ "$(grep -c 'NSCalendar.Identifier(rawValue: "islamic-\(tbla\|umalqura\)")' "$O/Foundation/Calendar.swift")" = 4 ] \
  || fail "Calendar.swift does not name the two 10.10 Islamic calendars by value, both ways"
for f in AffineTransform.swift Date.swift JSONEncoder.swift NSDate.swift PlistEncoder.swift; do
  # Recaulk declares -[NSObject init] nonnull, so these keep 5.4's untyped lets of an init's result.
  cmp -s "$O/Foundation/$f" "$WORK/swift-5.4/stdlib/public/Darwin/Foundation/$f" || grep -q 'Mavericks: no ' "$O/Foundation/$f" \
    || fail "$f differs from 5.4's, and no patch removes anything from it"
  grep -q 'Mavericks: typed, as 10.9' "$O/Foundation/$f" && fail "$f still types an init's result"
done

echo "-- no laid-out source names what neither the 10.9 SDK nor Recaulk declares, outside a comment"
bad="$(grep -nE 'ISO8601DateFormatter|NSDateInterval|URLQueryItem|PersonNameComponents|URLSessionWebSocketTask|URLSessionTaskTransactionMetrics|import Combine|NSMeasurement|NSItemProvider|NSOrderedCollectionDifference|_CFURLComponentsGet|NSCoderValueNotFoundError|registerUndoWithTarget|decodeTopLevel' \
  "$O"/Foundation/*.swift "$O"/Foundation/shims/*.h "$O"/CoreFoundation/shims/*.h | grep -vE '^[^:]*:[0-9]+: *//' || true)"
[ -z "$bad" ] || fail "a source still names what 10.9 lacks: $bad"

echo "-- nor calls a method or names a constant the patches remove, outside a comment"
# 10.10-and-later NSURL, NSString, NSCoder, NSKeyedUnarchiver, NSUndoManager, NSProgress, NSURLRequest, NSURLCache,
# NSError and NSURLComponents API; 10.13's getValue:size: and 10.11's NSFoundationVersionNumber10_11_Max; Combine's coders.
gone='failWithError|userInfoValueProvider|getValue\([^)]*size:|NSFoundationVersionNumber10_11_Max|checkPromisedItemIsReachable'
gone="$gone"'|promisedItemResourceValues|allowsExpensiveNetworkAccess|allowsConstrainedNetworkAccess|localizedCapitalized'
gone="$gone"'|localizedUppercase|localizedLowercase|localizedStandardContains|estimatedTimeRemaining|fileTotalCount|fileCompletedCount'
gone="$gone"'|resolvingAliasFileAt|dataRepresentation|fileURLWithPath: [^)]*relativeTo|directory: URL|queryItems|QueryItems'
gone="$gone"'|rangeOf(Fragment|Host|Password|Path|Port|Query|Scheme|User)|unarchivedObject|unarchiveTopLevelObjectWithData'
gone="$gone"'|decodeTopLevelDecodable|getIndexes\([^)]*range:|registerUndo\(withTarget|TopLevelEncoder|TopLevelDecoder'
gone="$gone"'|__NSCoderDecodeObject(ForKey)?\(|__NSKeyedUnarchiver|__NSUndoManagerRegisterWithTargetHandler'
gone="$gone"'|NSURLErrorBackgroundTaskCancelledReasonKey|NSURLErrorNetworkUnavailableReasonKey'
# URL resource keys of 10.10 to 10.13 (0045), and the 10.10 Islamic calendars named by constant (0046)
gone="$gone"'|isApplicationKey|applicationIsScriptableKey|canonicalPathKey|generationIdentifierKey|documentIdentifierKey'
gone="$gone"'|addedToDirectoryDateKey|quarantinePropertiesKey|volumeAvailableCapacityFor(Important|Opportunistic)UsageKey'
gone="$gone"'|volumeIsEncryptedKey|volumeIsRootFileSystemKey|volumeSupports(Compression|FileCloning|SwapRenaming|ExclusiveRenaming)Key'
gone="$gone"'|volumeSupports(ImmutableFiles|AccessPermissions)Key|ubiquitousItemDownloadRequestedKey|ubiquitousItemContainerDisplayNameKey'
gone="$gone"'|ubiquitousItemIsSharedKey|ubiquitousSharedItemCurrentUser(Role|Permissions)'
gone="$gone"'|\.islamic(Tabular|UmmAlQura) : \.islamic(Tabular|UmmAlQura)'
for f in "$O"/Foundation/*.swift "$O"/Foundation/shims/*.h "$O"/CoreFoundation/shims/*.h; do
  bad="$(sed -e 's|^[[:space:]]*//.*||' -e 's|[[:space:]]//.*||' "$f" | grep -nE "$gone" || true)"
  [ -z "$bad" ] || fail "${f##*/} still calls or names what its patch removes: $bad"
done

echo "PASS"
