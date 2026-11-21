#!/bin/sh
# platform: host-agnostic -- python3 (gyb), patch, cp
#   usage: overlay-sources.sh <tree-6.2> <tree-5.4> <swift-tree> <gyb> <out>
#          Lays out the Darwin and ObjectiveC overlays' sources, replacing whatever <out> held, from the
#          pinned trees build.sh fetches (pins.env's SWIFT62_SHA and SWIFT54_SHA; spec: "The overlays"):
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
#   Env: PYTHON (gyb's python, default python3: build.sh names the one CMake found).
set -eu
[ $# -eq 5 ] || { echo "usage: overlay-sources.sh <tree-6.2> <tree-5.4> <swift-tree> <gyb> <out>" >&2; exit 2; }
T62="$1"; T54="$2"; TSW="$3"; GYB="$4"; OUT="$5"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib.sh"   # -> patch_source, runtime_patches_unlisted
PLAT="$T62/stdlib/public/Platform"
OBJC="$T54/stdlib/public/Darwin/ObjectiveC/ObjectiveC.swift"
SHIM="$T54/stdlib/public/SwiftShims/ObjectiveCOverlayShims.h"
DSRC="$T54/stdlib/public/Darwin/Dispatch"
DSHIM="$T54/stdlib/public/SwiftShims/DispatchOverlayShims.h"
DFILES="Block.swift Data.swift Dispatch.swift IO.swift Private.swift Queue.swift Source.swift Time.swift Dispatch.mm"
APN="$TSW/apinotes/Dispatch.apinotes"
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
rm -rf "$OUT"; mkdir -p "$OUT/Darwin" "$OUT/ObjectiveC/shims" "$OUT/Dispatch/shims" "$OUT/apinotes" "$OUT/.patch"

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
OVERLAY_PATCHES="0001 0002 0003 0004 0005 0006 0008 0009 0010 0011 0012 0013 0014 0015 0016"
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
cp "$P/ObjectiveC.swift" "$OUT/ObjectiveC/"
for f in $DFILES; do cp "$PD/$f" "$OUT/Dispatch/"; done
cp "$PS/DispatchOverlayShims.h" "$OUT/Dispatch/shims/"
printf 'module _SwiftDispatchOverlayShims {\n  header "DispatchOverlayShims.h"\n}\n' > "$OUT/Dispatch/shims/module.modulemap"
cp "$AP" "$OUT/apinotes/"
rm -rf "$OUT/.patch"
cp "$SHIM" "$OUT/ObjectiveC/shims/"
printf 'module _SwiftObjectiveCOverlayShims {\n  header "ObjectiveCOverlayShims.h"\n}\n' > "$OUT/ObjectiveC/shims/module.modulemap"
