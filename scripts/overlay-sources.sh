#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch, cp
#   usage: overlay-sources.sh <tree-6.2> <tree-5.4> <tree-4.0> <swift-tree> <gyb> <out>
#          Lays out the overlays' sources, replacing whatever <out> held, from the pinned trees build.sh
#          fetches (pins.env's SWIFT62_SHA, SWIFT54_SHA and SWIFT40_SHA; spec: "The overlays"):
#            <out>/Darwin/: 6.2's stdlib/public/Platform files that its CMakeLists.txt compiles into
#              swiftDarwin -- Platform.swift, TiocConstants.swift, POSIXError.swift, MachError.swift, and
#              tgmath.swift and Darwin.swift, from their .gyb by <gyb> (the 6.4.1 tree's utils/gyb, as the
#              stdlib build runs it) with -D CMAKE_SDK=OSX. Not its magic-symbols-for-install-name.c: the
#              install name is @rpath already.
#            <out>/ObjectiveC/: 5.4's stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift, patched by
#              patches/overlays (OVERLAY_PATCHES below), and shims/: 5.4's ObjectiveCOverlayShims.h (6.4
#              dropped it; two inlines over objc_autoreleasePoolPush/Pop, both in 10.7) under a one-module
#              module.modulemap, _SwiftObjectiveCOverlayShims, which ObjectiveC.swift imports
#              @_implementationOnly, so no client sees it.
#            <out>/apinotes/Dispatch.apinotes: <swift-tree>'s (the SWIFT_SHA tree, $ROOT/swift: not the 5.4
#              tree) apinotes/Dispatch.apinotes, patched by patches/overlays' 0002, which makes
#              dispatch_sync and dispatch_barrier_sync's block NoEscape and dispatch_block_flags_t a
#              SwiftWrapper struct (the 10.9 SDK declares neither). The clang importer reads it, as
#              -iapinotes-modules, to import the 10.9 SDK's Dispatch for the Dispatch overlay and its clients.
#            <out>/Dispatch/: 5.4's stdlib/public/Darwin/Dispatch -- Block, Data, Dispatch, IO, Private, Queue,
#              Source and Time.swift and Dispatch.mm, not Schedulers+DispatchQueue.swift (it imports Combine) --
#              patched by patches/overlays 0003 onward for the 10.9 SDK and Recaulk's dispatch declarations
#              (each in OVERLAY_PATCHES below), and shims/: 5.4's stdlib/public/SwiftShims/DispatchOverlayShims.h,
#              patched by 0010, under a one-module module.modulemap, _SwiftDispatchOverlayShims, which
#              the overlay imports @_implementationOnly. The header is copied, not named in place: a map that
#              pointed into the 5.4 tree would load that tree's SwiftShims map and redefine SwiftShims.
#            <out>/CoreFoundation/: 5.4's stdlib/public/Darwin/CoreFoundation/CoreFoundation.swift, and shims/:
#              5.4's CoreFoundationOverlayShims.h and the two headers it includes (CFCharacterSetShims.h,
#              patched, and CFHashingShims.h) under a one-module module.modulemap, _SwiftCoreFoundationOverlayShims.
#            <out>/CoreGraphics/: 5.4's stdlib/public/Darwin/CoreGraphics -- CoreGraphics.swift, Private.swift and
#              CGFloat.swift, from its .gyb by the 5.4 tree's utils/gyb -- patched.
#            <out>/Foundation/: 5.4's stdlib/public/Darwin/Foundation -- every .swift but the Combine ones
#              (Publishers+*, Schedulers+*, CombineTypealiases.swift: no Combine before 10.15) and four whose classes
#              neither the 10.9 SDK nor Recaulk declares: Measurement.swift (NSMeasurement, NSUnit, 10.12),
#              PersonNameComponents.swift (NSPersonNameComponents, 10.11), NSOrderedCollectionDifference.swift
#              (10.15) and NSItemProvider.swift (10.10); a Recaulk declaration-only header for the class would
#              restore each. Plus NSValue.swift, from its .gyb by the 5.4 tree's utils/gyb, BundleLookup.mm and
#              DataThunks.m -- patched, and shims/: 5.4's FoundationOverlayShims.h and the 14 headers it
#              includes, patched, under a one-module module.modulemap, _SwiftFoundationOverlayShims.
#              Both shims maps are [system], as the SDK's own modules are: in a non-system module the
#              importer reads the shims' NSUInteger as UInt where the overlay, written against [system]
#              SwiftShims, expects Int.
#              CGFloat.swift and NSValue.swift come from the 5.4 tree's gyb, not <gyb>: 6.4's
#              utils/gyb_foundation_support.py writes #available(OSX 13.0) where 5.4's writes OSX 10.13.
#            <out>/apinotes/Foundation.apinotes and CoreGraphics.apinotes: <tree-4.0>'s apinotes, patched.
#              10.9's SDK predates Swift and has no API notes; swift-4.0's are the last that name the
#              Objective-C spellings 10.9 declares, and the clang importer reads them as -iapinotes-modules,
#              beside Dispatch.apinotes.
#   Env: PYTHON (gyb's python, default python3: build.sh names the one CMake found).
set -eu
[ $# -eq 6 ] || { echo "usage: overlay-sources.sh <tree-6.2> <tree-5.4> <tree-4.0> <swift-tree> <gyb> <out>" >&2; exit 2; }
T62="$1"; T54="$2"; T40="$3"; TSW="$4"; GYB="$5"; OUT="$6"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"   # -> patch_source, runtime_patches_unlisted
PLAT="$T62/stdlib/public/Platform"
OBJC="$T54/stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift"
SHIM="$T54/stdlib/public/SwiftShims/ObjectiveCOverlayShims.h"
DSRC="$T54/stdlib/public/Darwin/Dispatch"
DSHIM="$T54/stdlib/public/SwiftShims/DispatchOverlayShims.h"
DFILES="Block.swift Data.swift Dispatch.swift IO.swift Private.swift Queue.swift Source.swift Time.swift Dispatch.mm"
APN="$TSW/apinotes/Dispatch.apinotes"
DARWIN54="$T54/stdlib/public/Darwin"; SHIMS54="$T54/stdlib/public/SwiftShims"; GYB54="$T54/utils/gyb"
CFSHIMS="CoreFoundationOverlayShims.h CFCharacterSetShims.h CFHashingShims.h"
FSHIMS="FoundationOverlayShims.h FoundationShimSupport.h NSCalendarShims.h NSCharacterSetShims.h NSCoderShims.h NSDataShims.h
  NSDictionaryShims.h NSErrorShims.h NSFileManagerShims.h NSIndexPathShims.h NSIndexSetShims.h NSKeyedArchiverShims.h
  NSLocaleShims.h NSTimeZoneShims.h NSUndoManagerShims.h"
CGFILES="CoreGraphics.swift Private.swift"
FFILES=""
for f in "$DARWIN54/Foundation"/*.swift; do
  case "${f##*/}" in
    Publishers+*|Schedulers+*|CombineTypealiases.swift) ;;
    Measurement.swift|PersonNameComponents.swift|NSOrderedCollectionDifference.swift|NSItemProvider.swift) ;;
    *) FFILES="$FFILES ${f##*/}" ;;
  esac
done
FFILES="$FFILES BundleLookup.mm DataThunks.m"
for f in "$DARWIN54/CoreFoundation/CoreFoundation.swift" "$DARWIN54/CoreGraphics/CGFloat.swift.gyb" "$DARWIN54/Foundation/NSValue.swift.gyb" \
         "$DARWIN54/Foundation/BundleLookup.mm" "$DARWIN54/Foundation/DataThunks.m" "$GYB54" \
         "$T40/apinotes/Foundation.apinotes" "$T40/apinotes/CoreGraphics.apinotes"; do
  [ -f "$f" ] || { echo "overlay-sources.sh: no $f" >&2; exit 1; }
done
for f in $CFSHIMS $FSHIMS; do [ -f "$SHIMS54/$f" ] || { echo "overlay-sources.sh: no $SHIMS54/$f" >&2; exit 1; }; done
for f in $CGFILES; do [ -f "$DARWIN54/CoreGraphics/$f" ] || { echo "overlay-sources.sh: no $DARWIN54/CoreGraphics/$f" >&2; exit 1; }; done
for f in "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" \
         "$PLAT/tgmath.swift.gyb" "$PLAT/Darwin.swift.gyb" "$OBJC" "$SHIM" "$APN" "$GYB" "$DSHIM"; do
  [ -f "$f" ] || { echo "overlay-sources.sh: no $f" >&2; exit 1; }
done
for f in $DFILES; do
  [ -f "$DSRC/$f" ] || { echo "overlay-sources.sh: no $DSRC/$f" >&2; exit 1; }
done
# gyb's Python orders sets and dicts by hash; a fixed seed keeps the generated sources the same run to run.
# --line-directive '': gyb's default marks each block with a comment naming the .gyb by its absolute path,
# so the sources (never the compiled bytes) differed between build roots.
PYTHONHASHSEED=0; export PYTHONHASHSEED
rm -rf "$OUT"; mkdir -p "$OUT/Darwin" "$OUT/ObjectiveC/shims" "$OUT/Dispatch/shims" "$OUT/apinotes" "$OUT/.patch" \
  "$OUT/CoreFoundation/shims" "$OUT/CoreGraphics" "$OUT/Foundation/shims"

cp "$PLAT/Platform.swift" "$PLAT/TiocConstants.swift" "$PLAT/POSIXError.swift" "$PLAT/MachError.swift" "$OUT/Darwin/"
for g in tgmath Darwin; do
  "${PYTHON:-python3}" "$GYB" -D CMAKE_SDK=OSX --line-directive '' -o "$OUT/Darwin/$g.swift" "$PLAT/$g.swift.gyb" \
    || { echo "overlay-sources.sh: gyb failed on $PLAT/$g.swift.gyb" >&2; exit 1; }
done

# Patches are -p0 from a tree root, applied to a copy of the file at its own path (the tree stays
# upstream's bytes), in OVERLAY_PATCHES' order; a patch the list lacks fails, as build.sh's runtime ones do.
# 0001 is from the 5.4 root; 0002's file is in the SWIFT_SHA tree (<swift-tree>), not the 5.4 one, so both
# copies sit under one scratch root, $OUT/.patch, each at its own tree-relative path.
#  0001 hash is a method -- the 10.9 SDK's NSObject declares -hash a method, later SDKs a @property, so
#       `hash` becomes `hash()` three times.
#  0002 apinotes -- Dispatch.apinotes: NoEscape on parameter 1 of dispatch_sync and dispatch_barrier_sync (10.9's
#       headers lack DISPATCH_NOESCAPE, which a C redeclaration cannot add as far as Swift sees), and
#       SwiftWrapper: struct on dispatch_block_flags_t (Recaulk declares it a plain integer, not an option set).
#  0003 .. 0013 -- the Dispatch overlay, from the 5.4 root: the 10.9 SDK declares neither a QoS-class global queue nor
#       several of 5.4's functions, which Recaulk declares and defines, all but the DATA_REPLACE source. Each concerns one
#       thing (0007 is retired):
#       0003 global(qos:) maps the QoS to a 10.9 priority below macOS 10.10;
#       0004, 0005, 0006, 0008 lower to 10.9 what macOS 10.12 added and Recaulk declares and defines: the autorelease
#         frequencies, initiallyInactive, the target: initializer's dispatch_queue_create_with_target ($V2), and
#         DispatchPredicate and dispatchPrecondition (dispatch_assert_queue and _not as $V2, and _barrier); 0005 also
#         drops an initially inactive queue's QoS on macOS 10.10 and 10.11, where the OS's QoS attributes and
#         Recaulk's inactive one do not compose;
#       0009, 0010 remove DispatchQueue.qos (Recaulk's dispatch_queue_get_qos_class answers QOS_CLASS_UNSPECIFIED,
#         whatever the queue was made with) and the DATA_REPLACE source (declared by no 10.9 or Recaulk header);
#       0011 the 10.9 headers carry no nullability, so Data and IO unwrap what C never returns NULL for;
#       0012 availability is lowered to 10.9 where Recaulk defines and declares the functions (the dispatch_block
#         functions, wait and notify among them, dispatch_queue_attr_make_with_qos_class, dispatch_activate) and the
#         QoS types and the source's activate() that use them;
#       0013 Recaulk's dispatch_block_create drops its flags, so below macOS 10.10 a .barrier work item or block is
#         submitted with dispatch_barrier_async/_sync (a group's by enter and leave around it, a notification's
#         once the group or work item it waits on is done) rather than run
#         alongside the readers (a source's handler is not submitted, so its flag is a no-op on any macOS); the other
#         flags mean nothing without vouchers and QoS, and are dropped.
#  0014 apinotes -- Dispatch.apinotes again, after 0002: dispatch_group_create and dispatch_semaphore_create return
#       non-nil (10.9's headers carry no nullability, so DispatchGroup() and DispatchSemaphore(value:) would be failable
#       initializers, as no SDK's are).
#  0015 Sendable -- 5.4 predates it: DispatchObject (so queues, groups, semaphores, sources, IO), DispatchData, DispatchSpecificKey
#       (where its value is) and the time, QoS, flag, autorelease-frequency and predicate value types are @unchecked
#       Sendable, exactly where Apple's newest SDK has them and nowhere else, so a Swift 6 client can capture a queue or a
#       semaphore in a @Sendable closure.
#  0016 activate -- Dispatch.apinotes and Dispatch.swift: dispatch_activate is imported as DispatchObject.__activate(),
#       and the overlay declares activate() over it at macOS 10.9, so a program's activate() calls libswiftDispatch,
#       which links Recaulk's real dispatch_activate, as for every other function 10.9's libSystem lacks, rather than
#       import dispatch_activate itself, which only a program linked with Recaulk would load.
#  0007 is retired: Recaulk now declares and defines dispatch_block_wait and _notify.
#  0017 .. 0021 apinotes -- CoreGraphics.apinotes and Foundation.apinotes, swift-4.0's, for what the 5.4 overlays read
#       and 10.9 declares but 4.0's notes leave unnamed:
#       0017 CoreGraphics.swift's getters (numberOfComponents, model, baseColorSpace, the CGRect minX .. height), named
#            as later SDKs name them;
#       0018 CGColorSpaceModel, a plain C enum in 10.9, is an open extensible enum, so .unknown and the rest import;
#       0019 NSCalendarUnit's cases are named (.era .. .timeZone): 10.9 also lists the deprecated NS...CalendarUnit
#            spellings, which spoil the prefix the importer strips;
#       0020 nullability where the overlay relies on non-nil and 10.9's headers say nothing (NSScanner, NSString,
#            NSMutableArray, NSIndexSet, NSData, NSCalendar block parameters), and NSTimeZone's two factories return
#            NSTimeZone rather than id, so they import as initializers; the NSCalendar and NSIndexSet blocks are NoEscape,
#            as later SDKs' NS_NOESCAPE has them;
#       0021 -[NSURL checkResourceIsReachableAndReturnError:] does not throw, as NS_SWIFT_NOTHROW has it later;
#       0044 CGRectEdge, a plain C enum in 10.9, is a closed enum, as later SDKs' CF_CLOSED_ENUM has it.
#  0022 .. 0043, 0045, 0046 Foundation -- the shims and sources, for the 10.9 SDK, which predates much of what 5.4 calls. Where 5.4
#       names a later spelling of what 10.9 declares, it is renamed; where it names a class or method neither the 10.9
#       SDK nor Recaulk declares, it is removed, its comment naming the Recaulk declaration that would restore it:
#       0022 the shims' 10.9 spellings; 0023 no NSCoder top-level decoding (10.11); 0024 no undo registration with a
#       handler (10.11); 0025 URL character sets are NSCharacterSet's, not 10.12 CF SPI; 0026 no Combine coder
#       conformances; 0027 no URL person-name components (10.11); 0028 DateInterval bridges to no class (10.12);
#       0029 no URLQueryItem (10.10); 0030 no URLComponents string or ranges (10.10, 10.11); 0031 no ISO 8601 JSON
#       dates (10.12); 0032 JSON fragments: written under #available(macOS 10.15) or thrown below, read with
#       .allowFragments; 0033 no post-10.9 NSURL API; 0034 no post-10.9 NSString API; 0035 no 10.13 Progress
#       properties; 0036 no 10.15 URLRequest constraints; 0037 no 10.12 or 10.15 URLSession extensions; 0038 no
#       URLCache directory initializer (10.15); 0039 no NSError user-info provider (10.11) or 10.15 keys;
#       0040 NSValue and IndexPath use 10.9's getValue: and getIndexes:; 0041 Data names NSFoundationVersionNumber
#       10.11's value; 0042 an NSObject -init result is typed, as 10.9's imports as init!(); 0043 NSKeyValueChange
#       is 10.9's NS_OPTIONS, whose init(rawValue:) is not failable; 0045 no URL resource values whose keys are 10.10
#       to 10.13; 0046 the two Islamic calendars of 10.10 are named by their identifiers' values.
OVERLAY_PATCHES="0001 0002 0003 0004 0005 0006 0008 0009 0010 0011 0012 0013 0014 0015 0016 0017 0018 0019 0020 0021
  0022 0023 0024 0025 0026 0027 0028 0029 0030 0031 0032 0033 0034 0035 0036 0037 0038 0039 0040 0041 0042 0043
  0044 0045 0046"
PATCHES_DIR="$HERE/patches/overlays"
UNLISTED="$(runtime_patches_unlisted "$PATCHES_DIR" $OVERLAY_PATCHES)" || {
  [ -z "$UNLISTED" ] || printf '%s\n' "$UNLISTED" >&2
  echo "overlay-sources.sh: OVERLAY_PATCHES does not list every patch in $PATCHES_DIR (listed above) -- add its number, and a marker grep" >&2; exit 1; }
P="$OUT/.patch/stdlib/public/Darwin/ObjectiveC"
mkdir -p "$P" "$OUT/.patch/apinotes" && cp "$OBJC" "$P/" && cp "$APN" "$OUT/.patch/apinotes/"
PD="$OUT/.patch/stdlib/public/Darwin/Dispatch"; PS="$OUT/.patch/stdlib/public/SwiftShims"
mkdir -p "$PD" "$PS"
for f in $DFILES; do cp "$DSRC/$f" "$PD/"; done
cp "$DSHIM" "$PS/"
PCF="$OUT/.patch/stdlib/public/Darwin/CoreFoundation"; PCG="$OUT/.patch/stdlib/public/Darwin/CoreGraphics"
PF="$OUT/.patch/stdlib/public/Darwin/Foundation"
mkdir -p "$PCF" "$PCG" "$PF"
cp "$DARWIN54/CoreFoundation/CoreFoundation.swift" "$PCF/"
for f in $CGFILES; do cp "$DARWIN54/CoreGraphics/$f" "$PCG/"; done
for f in $FFILES; do cp "$DARWIN54/Foundation/$f" "$PF/"; done
for f in $CFSHIMS $FSHIMS; do cp "$SHIMS54/$f" "$PS/"; done
cp "$T40/apinotes/Foundation.apinotes" "$T40/apinotes/CoreGraphics.apinotes" "$OUT/.patch/apinotes/"
for g in CoreGraphics/CGFloat Foundation/NSValue; do
  "${PYTHON:-python3}" "$GYB54" -D CMAKE_SDK=OSX -D CMAKE_SIZEOF_VOID_P=8 --line-directive '' \
    -o "$OUT/.patch/stdlib/public/Darwin/$g.swift" "$DARWIN54/$g.swift.gyb" \
    || { echo "overlay-sources.sh: gyb failed on $DARWIN54/$g.swift.gyb" >&2; exit 1; }
done
for n in $OVERLAY_PATCHES; do
  for p in "$PATCHES_DIR/$n"-*.patch; do patch_source "$OUT/.patch" "$p" || exit 1; done
done
grep -q 'Mavericks: the 10.9 SDK declares -hash a method' "$P/ObjectiveC.swift" || { echo "overlay-sources.sh: overlay patch 0001 (hash) not applied" >&2; exit 1; }
AP="$OUT/.patch/apinotes/Dispatch.apinotes"
[ "$(grep -c '^    NoEscape: true$' "$AP")" = 2 ] && grep -q '^  SwiftWrapper: struct$' "$AP" || { echo "overlay-sources.sh: overlay patch 0002 (Dispatch.apinotes) not applied" >&2; exit 1; }
[ "$(grep -c '^  NullabilityOfRet: N$' "$AP")" = 2 ] || { echo "overlay-sources.sh: overlay patch 0014 (Dispatch.apinotes) not applied" >&2; exit 1; }
grep -q "^  SwiftName: 'DispatchObject.__activate(self:)'$" "$AP" || { echo "overlay-sources.sh: overlay patch 0016 (Dispatch.apinotes) not applied" >&2; exit 1; }
# One marker per patch, in the file it patches; a grep that finds none means a patch applied to nothing it meant.
dmark() { grep -q "$3" "$PD/$2" || { echo "overlay-sources.sh: overlay patch $1 ($4) not applied" >&2; exit 1; }; }
dmark 0003 Queue.swift "Mavericks: 10.9's dispatch_get_global_queue" "global(qos:)"
dmark 0004 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_attr_make_with_autorelease_frequency" "autorelease frequency"
dmark 0005 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_attr_make_initially_inactive" "initiallyInactive"
dmark 0006 Queue.swift "Mavericks: Recaulk defines and declares dispatch_queue_create_with_target" "target:"
dmark 0008 Dispatch.swift "Mavericks: Recaulk defines and declares dispatch_assert_queue" "dispatchPrecondition"
dmark 0009 Queue.swift "Mavericks: no qos" "DispatchQueue.qos"
dmark 0010 Source.swift "Mavericks: no makeUserDataReplaceSource" "DATA_REPLACE"
grep -q 'Mavericks: no DATA_REPLACE' "$PS/DispatchOverlayShims.h" || { echo "overlay-sources.sh: overlay patch 0010 (DATA_REPLACE) not applied to the shims" >&2; exit 1; }
dmark 0011 Data.swift "Mavericks: the 10.9 headers carry no nullability" "nullability"
dmark 0011 IO.swift "Mavericks: the 10.9 headers carry no nullability" "nullability"
dmark 0012 Block.swift "Mavericks: Recaulk defines and declares dispatch_block_create" "availability"
dmark 0012 Source.swift "Mavericks: Recaulk defines and declares dispatch_block_create" "availability"
dmark 0013 Queue.swift "Mavericks: 10.9's dispatch_block_create drops DISPATCH_BLOCK_BARRIER" "barrier routing"
dmark 0013 Block.swift "Mavericks: 10.9's dispatch_block_create drops its flags" "barrier routing"
dmark 0013 Dispatch.swift "Mavericks: a barrier-flagged block is submitted as a barrier below 10.10" "barrier routing"
dmark 0013 Source.swift "Mavericks: a .barrier flag is not routed here" "barrier routing"
dmark 0015 Dispatch.swift "Mavericks: 5.4 predates Sendable" "Sendable"
dmark 0016 Dispatch.swift "Mavericks: activate() is the overlay's" "activate"
# The same for CoreFoundation, CoreGraphics and Foundation: <file> is under the scratch root.
fmark() { grep -q "$3" "$OUT/.patch/$2" || { echo "overlay-sources.sh: overlay patch $1 ($4) not applied" >&2; exit 1; }; }
fmark 0017 apinotes/CoreGraphics.apinotes "Mavericks: the getters CoreGraphics.swift reads" "CoreGraphics getters"
fmark 0018 apinotes/CoreGraphics.apinotes "Mavericks: 10.9 declares CGColorSpaceModel a plain C enum" "CGColorSpaceModel"
fmark 0019 apinotes/Foundation.apinotes "Mavericks: 10.9's NSCalendarUnit also lists the" "foundation-apinotes-calendar-unit-names"
fmark 0020 apinotes/Foundation.apinotes "Mavericks: 10.9's headers carry no nullability, so what the" "foundation-apinotes-what-the-overlay-needs-non-nil"
fmark 0021 apinotes/Foundation.apinotes "Mavericks: not throwing, as later SDKs' NS_SWIFT_NOTHROW has" "foundation-apinotes-resource-reachability-does-not-throw"
fmark 0022 stdlib/public/SwiftShims/NSDataShims.h "Mavericks: the 10.9 SDK has no API_AVAILABLE" "foundation-shims-use-the-10.9-spellings"
fmark 0023 stdlib/public/Darwin/Foundation/NSCoder.swift "Mavericks: no resolveError: NSCoderValueNotFoundError (10.11)" "foundation-no-nscoder-top-level-decoding"
fmark 0024 stdlib/public/Darwin/Foundation/NSUndoManager.swift "Mavericks: no registerUndo(withTarget:handler:): it calls" "foundation-no-undo-registration-with-a-handler"
fmark 0025 stdlib/public/Darwin/Foundation/CharacterSet.swift "Mavericks: each set is NSCharacterSet's (10.9), never" "foundation-url-character-sets-are-nscharactersets"
fmark 0026 stdlib/public/Darwin/Foundation/Codable.swift "Mavericks: no TopLevelEncoder/TopLevelDecoder conformances of" "foundation-no-combine-coder-conformances"
fmark 0027 stdlib/public/Darwin/Foundation/URL.swift "Mavericks: no ubiquitousSharedItemOwnerNameComponents or" "foundation-url-no-person-name-components"
fmark 0028 stdlib/public/Darwin/Foundation/DateInterval.swift "Mavericks: not ReferenceConvertible, and bridged to no class:" "foundation-date-interval-is-not-bridged"
fmark 0029 stdlib/public/Darwin/Foundation/URLComponents.swift "Mavericks: no queryItems or percentEncodedQueryItems: they are" "foundation-no-url-query-items"
fmark 0030 stdlib/public/Darwin/Foundation/URLComponents.swift "Mavericks: no string: NSURLComponents' string is 10.10, which" "foundation-url-components-no-string-or-ranges"
fmark 0031 stdlib/public/Darwin/Foundation/JSONEncoder.swift "Mavericks: no iso8601: it formats with ISO8601DateFormatter" "foundation-json-no-iso8601-dates"
fmark 0032 stdlib/public/Darwin/Foundation/JSONEncoder.swift "Mavericks: JSONSerialization writes a top-level fragment (a" "foundation-json-fragments-on-10.9"
fmark 0033 stdlib/public/Darwin/Foundation/URL.swift "Mavericks: no init(fileURLWithPath:isDirectory:relativeTo:) or" "foundation-url-no-post-10.9-nsurl-api"
fmark 0034 stdlib/public/Darwin/Foundation/NSStringAPI.swift "Mavericks: no localizedCapitalized: NSString's" "foundation-string-no-post-10.9-nsstring-api"
fmark 0035 stdlib/public/Darwin/Foundation/Progress.swift "Mavericks: no estimatedTimeRemaining, throughput," "foundation-progress-no-10.13-properties"
fmark 0036 stdlib/public/Darwin/Foundation/URLRequest.swift "Mavericks: no allowsExpensiveNetworkAccess or" "foundation-url-request-no-network-access-constraints"
fmark 0037 stdlib/public/Darwin/Foundation/URLSession.swift "Mavericks: no URLSessionWebSocketTask (10.15) or" "foundation-url-session-no-10.12-or-10.15-extensions"
fmark 0038 stdlib/public/Darwin/Foundation/URLCache.swift "Mavericks: no init(memoryCapacity:diskCapacity:directory:):" "foundation-url-cache-no-directory-initializer"
fmark 0039 stdlib/public/Darwin/Foundation/NSError.swift "Mavericks: no user info value provider: NSError's" "foundation-error-no-user-info-provider-or-10.15-keys"
fmark 0040 stdlib/public/Darwin/Foundation/IndexPath.swift "Mavericks: getIndexes(_:), every index, which count is: the" "foundation-value-and-index-path-use-the-10.9-getters"
fmark 0041 stdlib/public/Darwin/Foundation/Data.swift "Mavericks: 1299 is NSFoundationVersionNumber10_11_Max, which" "foundation-data-names-the-10.11-foundation-version"
fmark 0042 stdlib/public/Darwin/Foundation/AffineTransform.swift "Mavericks: typed, as 10.9's unannotated -" "foundation-typed-results-of-nsobject-init"
fmark 0043 stdlib/public/Darwin/Foundation/NSObject.swift "Mavericks: 10.9 declares NSKeyValueChange NS_OPTIONS, not" "foundation-key-value-change-is-an-option-set"
fmark 0044 apinotes/CoreGraphics.apinotes "Mavericks: 10.9 declares CGRectEdge a plain C enum" "coregraphics-apinotes-rect-edge-is-a-closed-enum"
fmark 0045 stdlib/public/Darwin/Foundation/URL.swift "Mavericks: no isApplication or applicationIsScriptable" "foundation-url-no-post-10.9-resource-keys"
fmark 0046 stdlib/public/Darwin/Foundation/Calendar.swift "Mavericks: NSCalendarIdentifierIslamicTabular and" "foundation-calendar-names-the-10.10-islamic-calendars-by-value"
cp "$P/ObjectiveC.swift" "$OUT/ObjectiveC/"
for f in $DFILES; do cp "$PD/$f" "$OUT/Dispatch/"; done
cp "$PS/DispatchOverlayShims.h" "$OUT/Dispatch/shims/"
printf 'module _SwiftDispatchOverlayShims {\n  header "DispatchOverlayShims.h"\n}\n' > "$OUT/Dispatch/shims/module.modulemap"
cp "$AP" "$OUT/apinotes/"
cp "$PCF/CoreFoundation.swift" "$OUT/CoreFoundation/"
for f in $CGFILES CGFloat.swift; do cp "$PCG/$f" "$OUT/CoreGraphics/"; done
for f in $FFILES NSValue.swift; do cp "$PF/$f" "$OUT/Foundation/"; done
for f in $CFSHIMS; do cp "$PS/$f" "$OUT/CoreFoundation/shims/"; done
for f in $FSHIMS; do cp "$PS/$f" "$OUT/Foundation/shims/"; done
printf 'module _SwiftCoreFoundationOverlayShims [system] {\n  header "CoreFoundationOverlayShims.h"\n}\n' > "$OUT/CoreFoundation/shims/module.modulemap"
printf 'module _SwiftFoundationOverlayShims [system] {\n  header "FoundationOverlayShims.h"\n}\n' > "$OUT/Foundation/shims/module.modulemap"
cp "$OUT/.patch/apinotes/Foundation.apinotes" "$OUT/.patch/apinotes/CoreGraphics.apinotes" "$OUT/apinotes/"
rm -rf "$OUT/.patch"
cp "$SHIM" "$OUT/ObjectiveC/shims/"
printf 'module _SwiftObjectiveCOverlayShims {\n  header "ObjectiveCOverlayShims.h"\n}\n' > "$OUT/ObjectiveC/shims/module.modulemap"
