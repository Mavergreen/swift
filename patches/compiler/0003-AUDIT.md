# Compiler patch 0003: every feature of the runtime table, classified

Patch `0003-runtime-versions-macos-10.9.patch` makes the compiler's runtime table depend on the target,
at one place, `lib/AST/Availability.cpp` (spec: the 2026-11-06 amendment, item 1, and the maintainer's
target-dependent choice of 2026-11-07):

- **A macOS deployment target below 10.14.4.** Its clients record `@rpath/libswiftCore.dylib` (Core's
  `$ld$previous`) and on a Mavergreen OS X 10.9 load the Swift runtime the swift-runtime pkg ships (6.4).
  `ASTContext::getSwiftAvailability` gives every released Swift version (upstream's
  `RuntimeVersions.def`, short of `FUTURE`) as available from 10.9.
- **10.14.4 and later.** Clients load the OS's `/usr/lib/swift`, and upstream's table holds exactly: the
  patch changes nothing there.
- **What the OS's libobjc provides** keeps upstream's table on every target: the features
  `ASTContext::isOSRuntimeFeature` names take `getOSSwiftAvailability` (upstream's table, unchanged) in
  `ASTContext.h`'s `FEATURE` getters, and so do the closed direct callers below. Below 10.14.4 that is
  what a 10.9 target saw of them before the patch: closed.

The rule: **a gate opens when what it guards ships in our pkgs, and stays closed when what it guards is
the OS's.** `RuntimeVersions.def` and `FeatureAvailability.def` are upstream's, untouched.

`tests/compiler-patch-audit-test.sh` holds the patch to this list: one row per `FEATURE(` of the pinned
`.def`; the closed rows exactly `isOSRuntimeFeature`'s; each closed direct caller asking
`getOSSwiftAvailability`; the split itself; and each closed row's symbol absent from the pinned 10.9
SDK's libobjc and libSystem (`lib.sh`'s `sdk109_stubs`).

- **open** (below 10.14.4): what the feature needs ships in our pkgs: `libswiftCore` (swift-runtime,
  today) or `libswift_Concurrency` (swift-runtime, A1's Release 2). The symbol is the runtime entry point
  the emitted code calls, or the runtime support the gate stands for. From 10.14.4: upstream's.
- **closed (below 10.14.4; upstream's from 10.14.4)**: what it needs is the OS's libobjc; the symbol is
  the libobjc one, which 10.9 lacks.
- **unreleased**: upstream's own `FUTURE`, which no released runtime has, on every target.

Readers are `grep -rn get<Feature>Availability lib/ include/` in the pinned tree (`SWIFT_SHA`), plus each
`is<Feature>FeatureAvailable` (IRGenModule.cpp:2197) caller and each `RuntimeFunctions.def` entry the
feature's `RuntimeAvailability` guards: below 10.14.4 an open feature's entry points become strong
references, a closed one's stay weak or unused.

## Features (40, in the `.def`'s order)

| Feature | Runtime | Class | Needs | Readers |
|---|---|---|---|---|
| `ObjCMetadataUpdateCallback` | (5, 0) | closed (below 10.14.4; upstream's from 10.14.4) | `_objc_realizeClassFromSwift` (libobjc, 10.14.4): libobjc calls a Swift class's metadata update callback on realization | GenType.cpp:1568 (no legacy layouts if open: the legacy-layout path and Recaulk's `objc_readClassPair` realization need it closed), GenClass.cpp:2988 (`ClassMetadataStrategy::Update`) |
| `ObjCGetClassHook` | (5, 0) | closed (below 10.14.4; upstream's from 10.14.4) | `objc_setHook_getClass` (libobjc, 10.14.4) | TypeCheckProtocol.cpp:6723 (`@_staticInitializeObjCMetadata` inferred when closed) |
| `OpaqueType` | (5, 1) | open | `swift_getOpaqueTypeMetadata` (Core) | IRGenModule.cpp:814 (`swift_getOpaqueTypeMetadata`, `swift_getOpaqueTypeConformance`), TypeCheckGeneric.cpp:95 |
| `ObjCClassStubs` | (5, 1) | closed (below 10.14.4; upstream's from 10.14.4) | `objc_loadClassref` (libobjc, 10.15) | none through the getter; Sema's own gate, TypeCheckDeclObjC.cpp:550 `getObjCClassStubAvailability`, hard-codes 10.15 and is untouched |
| `BackDeployedConcurrency` | (5, 1) | open | `swift_task_create` (libswift_Concurrency) | TypeCheckAttr.cpp:3374 (`@main` async), TypeCheckAvailability.cpp:977 (`checkConcurrencyAvailability`: "concurrency is only available in macOS 10.15.0") |
| `TypesInAbstractMetadataState` | (5, 2) | open | `swift_getTypeByMangledNameInContextInMetadataState` (Core) | IRGenModule.cpp:824, MetadataRequest.cpp:3170 |
| `PrespecializedGenericMetadata` | (5, 4) | open | `swift_getCanonicalPrespecializedGenericMetadata` (Core) | IRGenModule.cpp:872, :2223 (`shouldPrespecializeGenericMetadata`, also off unless `-prespecialize-generic-metadata`) |
| `CompareTypeContextDescriptors` | (5, 4) | open | `swift_compareTypeContextDescriptors` (Core) | IRGenModule.cpp:842 |
| `CompareProtocolConformanceDescriptors` | (5, 4) | open | `swift_compareProtocolConformanceDescriptors` (Core) | IRGenModule.cpp:852 |
| `IntermodulePrespecializedGenericMetadata` | (5, 4) | open | `swift_getCanonicalSpecializedMetadata` (Core) | IRGenModule.cpp:862 |
| `Concurrency` | (5, 5) | open | `swift_task_create` (libswift_Concurrency); `SwiftNativeNSObject` (Core) | IRGenModule.cpp:880 (Concurrency's entry points strong, not weak, below 10.14.4), :1509 (no ObjC actor superclass swizzle), :2415 `isConcurrencyAvailable` (GenClass.cpp:2912 `SwiftNativeNSObject` as an ObjC actor's superclass, Core exports `_OBJC_CLASS_$_SwiftNativeNSObject`; MetadataRequest.cpp:1837 `swift_getFunctionTypeMetadataGlobalActor`, Core; IRGenModule.cpp:2386), Decl.cpp:1500 (linkage), Linking.cpp:1621 |
| `MultiPayloadEnumTagSinglePayload` | (5, 6) | open | `swift_getMultiPayloadEnumTagSinglePayload` (Core) | ASTContext.h:1044, IRGenModule.cpp:938 |
| `ObjCIsUniquelyReferenced` | (5, 6) | closed (below 10.14.4; upstream's from 10.14.4) | `objc_isUniquelyReferenced` (libobjc, 12.3): Core's `swift_isUniquelyReferenced` asks libobjc about an ObjC object, and 10.9's cannot answer | IRGenModule.cpp:948, GenHeap.cpp:1448 (closed: the `...NonObjC` entry points, as before) |
| `ParameterizedExistential` | (5, 7) | open | `swift_getExtendedExistentialTypeMetadata` (Core) | IRGenModule.cpp:983, TypeCheckAvailability.cpp:1937 |
| `VariadicGenericType` | (5, 9) | open | `swift_allocateMetadataPack` (Core): metadata of a generic type with a pack | TypeCheckDeclPrimary.cpp:626 ("parameter packs in generic types are only available in macOS 14.0.0") |
| `SignedConformsToProtocol` | (5, 9) | open | `swift_conformsToProtocol2` (Core) | IRGenModule.cpp:957, GenDistributed.cpp:596 |
| `ConcurrencyDiscardingTaskGroup` | (5, 9) | open | `swift_taskGroup_initializeWithFlags` (libswift_Concurrency) | IRGenModule.cpp:905 |
| `ConcurrencyDistributedActorWithCustomExecutor` | (5, 9) | open | `swift_nonDefaultDistributedActor_initialize` (libswift_Concurrency) | TypeCheckConcurrency.cpp:236 (Distributed itself ships in no pkg, so no client reaches it) |
| `SignedDescriptor` | (5, 9) | open | `swift_getTypeByMangledNameInContext2` (Core) | IRGenModule.cpp:966, MetadataRequest.cpp:3321, GenArchetype.cpp:531, :574 |
| `ObjCSymbolicReferences` | (6, 0) | open | `swift_getTypeByMangledNameInContext2` (Core): its 6.0 demangler reads an ObjC protocol through the protocol reference that libobjc fixes up at load (`__objc_protorefs`, ObjC 2.0, every OS X since 10.5) | IRGenModule.cpp:2227 `canUseObjCSymbolicReferences` (MetadataRequest.cpp:378, IRGenMangler.cpp:117) |
| `TypedThrows` | (6, 0) | open | `swift_getExtendedFunctionTypeMetadata` (Core) | IRGenModule.cpp:921, TypeCheckStmt.cpp:3449 (`next(isolation:)`), TypeCheckAvailability.cpp:1955 ("runtime support for typed throws function types is only available in macOS 15.0.0") |
| `StaticReadOnlyArrays` | (6, 0) | open | `_swiftImmortalRefCount` and `$ss20__StaticArrayStorageCN` (Core) | IRGenModule.cpp:2254 `canMakeStaticObjectReadOnly` |
| `SwiftExceptionPersonality` | (6, 0) | open | `_swift_exceptionPersonality` (Core) | GenCall.cpp:5726 |
| `IsolatedAny` | (6, 0) | open | `swift_getExtendedFunctionTypeMetadata` (Core) | TypeCheckAvailability.cpp:1946 |
| `NoncopyableGenerics` | (6, 0) | open | `swift_getGenericMetadata` (Core): 6.0's invertible-protocol requirements | TypeCheckAvailability.cpp:2030 |
| `InitRawStructMetadata` | (6, 0) | open | `swift_initRawStructMetadata` (Core) | GenMeta.cpp:3589, IRGenModule.cpp:999 |
| `LayoutStringValueWitnesses` | (6, 1) | open | `swift_generic_destroy` (Core) | GenValueWitness.cpp:900 (also off unless `-enable-layout-string-value-witnesses`) |
| `CreateTaskWithConsumedFunction` | (6, 1) | open | `swift_task_create` (libswift_Concurrency) | none in the pinned tree |
| `IsolatedDeinit` | (6, 1) | open | `swift_task_deinitOnExecutor` (libswift_Concurrency) | SILGenDestructor.cpp:346, IRGenModule.cpp:929, TypeCheckAttr.cpp:161 |
| `ValueGenericType` | (6, 2) | open | `swift_getFixedArrayTypeMetadata` (Core) | IRGenModule.cpp:1015, TypeCheckDeclPrimary.cpp:650 |
| `InitRawStructMetadata2` | (6, 2) | open | `swift_initRawStructMetadata2` (Core) | GenMeta.cpp:3622, IRGenModule.cpp:1007 |
| `TaskExecutor` | (6, 2) | open | `swift_task_pushTaskExecutorPreference` (libswift_Concurrency) | IRGenModule.cpp:888 (no `RuntimeFunctions.def` entry uses it) |
| `TaskPriorityEscalationHandlers` | (6, 2) | open | `swift_task_addPriorityEscalationHandler` (libswift_Concurrency) | IRGenModule.cpp:1025 |
| `TypedCoroAlloc` | (6, 2) | open | `swift_coroFrameAlloc` (Core) | IRGenModule.cpp:896 |
| `NoncopyableReflectionSafety` | (6, 4) | open | `swift_runtimeSupportsNoncopyableTypes` (Core): 6.4's Mirror guards | GenReflection.cpp:495 |
| `CustomGlobalExecutors` | FUTURE | unreleased | `swift_task_getMainExecutor` (a future runtime's) | SILGenFunction.cpp:1437 |
| `Differentiation` | FUTURE | unreleased | `swift_autoDiffCreateLinearMapContextWithType` (`_Differentiation`, in no pkg) | IRGenModule.cpp:913 |
| `ClearSensitive` | FUTURE | unreleased | `swift_clearSensitive` | IRGenModule.cpp:991, IRGenFunction.cpp:938 |
| `UpdatePureObjCClassMetadata` | FUTURE | unreleased | `swift_updatePureObjCClassMetadata` (and libobjc's `_objc_realizeClassFromSwift`) | GenMeta.cpp:5509 |
| `CoroutineAccessors` | FUTURE | unreleased | `swift_task_dealloc_through` | GenCoro.cpp:55, :596, Linking.cpp:1635, IRGenModule.cpp:1033, TypeCheckStorage.cpp:3052, Decl.cpp:3469 |

Counts: 31 open, 4 closed, 5 unreleased. The four closed are libobjc's; no feature needs libSystem.

## Callers of a Swift version directly

These read `getSwift50/51/57/58Availability()` (or `getSwiftAvailability`) themselves, not a feature, so
below 10.14.4 the split moves them too. Each is decided by the same rule; a closed one asks
`getOSSwiftAvailability` instead, upstream's table, which keeps today's 10.9 behaviour below 10.14.4
and is upstream's above it.

| Caller | Version | Class | What it guards | Patch |
|---|---|---|---|---|
| GenHeap.cpp:1356 `getFixedClassInitializationFn` | 5.1 | closed (below 10.14.4; upstream's from 10.14.4) | `objc_opt_self` (libobjc, 10.15; not in 10.9's) | `getOSSwiftAvailability(5, 1)`: below 10.15, Core's `swift_getInitializedObjCClass` as before |
| TypeCheckAttr.cpp:1882 `@objc @implementation` | 5.0 | closed (below 10.14.4; upstream's from 10.14.4) | the stable-ABI ObjC runtime (libobjc, 10.14.4) | `getOSSwiftAvailability(5, 0)`: the diagnostic as before |
| GenClass.cpp:2799 `emitObjCProtocolData` | 5.8 | closed (below 10.14.4; upstream's from 10.14.4) | the OS's linker and loader handling one ObjC protocol defined by clang and Swift both | `getOSSwiftAvailability(5, 8)`: Swift's own protocol emission as before |
| IRGenModule.cpp:832 `DynamicReplacementAvailability` | 5.1 | open | `swift_getFunctionReplacement`, `swift_getOrigOfReplaceable` (Core) | none: Core's, strong below 10.14.4 |
| GenCoro.cpp:114, :232 (task allocator offsets) | 5.7 | open | the Task layout of libswift_Concurrency, ours at 6.4: the new layout, with no OS-version check (which on 10.9 would pick the pre-5.7 layout, wrong for our library) | none |
| GenConcurrency.cpp:268 (`async let` context padding) | 5.7 | open | a pre-5.7 libswift_Concurrency bug ours does not have | none |
| SILCombinerMiscVisitors.cpp:1454 | 5.7 | open | Core's `_ContiguousArrayStorage<AnyObject>` storage for class elements | none |
| ImportDecl.cpp:2960 (C++ foreign reference types) | 5.8 | open | Core's runtime support for foreign reference types | none |
| SILBridgingImpl.h:873 `isSwift51RuntimeAvailable` (ObjectOutliner.swift:58, SimplifyStrongRetainRelease.swift:87) | 5.1 | open | Core's immortal reference counts for statically initialized objects (`swift_initStaticObject`) | none |
| TypeCheckRegex.cpp:230 | the pattern's | n/a | unreachable: the toolchains are built with `SWIFT_BUILD_REGEX_PARSER_IN_COMPILER=OFF` | none |

## Other readers of the table

- `lib/Basic/Platform.cpp` statically reflects `RuntimeVersions.def`, which the patch leaves alone, so
  `getSwiftRuntimeCompatibilityVersionForTarget` still gives 5.0 for a 10.9 target, as before. Its
  readers: the driver's and frontend's back-deployment libraries (none: `toolchain/swiftc`, `build.sh`
  and `make-selftest.sh` all pass `-runtime-compatibility-version none`, and no pkg ships those
  archives); IRGenMangler.cpp:169 and GenReflection.cpp:464, which for a 5.0 runtime keep Concurrency's
  standard substitutions, typed throws and `@isolated(any)` out of reflection mangling and reach such
  types through metadata accessors instead (safe, and what a 10.9 target did before); GenProto.cpp:1084
  (whether a resilient protocol's Sendable base can make a conformance dependent: unchanged).
- The ObjC is-swift bit is not the table's: `CompilerInvocation.cpp:1672` sets `UseDarwinPreStableABIBit`
  for a macOS target below 10.14.4 itself, so a 10.9 target keeps the legacy bit that runtime patch 0007
  checks.
- `swift_async_extendedFramePointerFlags`: LLVM's X86 backend reads the flag dynamically for any macOS
  target below 12 (`X86Subtarget::swiftAsyncContextIsDynamicallySet`), from whichever library defines
  it (libswift_Concurrency does). A 10.9 client of the patched compiler still references it weakly (the
  evidence client in the task report); its value is the library's, unchanged by this patch.

## Declarations of the runtime pkg's modules

The same split, for the library's own declarations (the maintainer's decision of 2026-11-08). Swift's
`@available(SwiftStdlib N, *)` macros expand to the OS release that first shipped runtime N (`macOS 13.0`
for 5.7, `anyAppleOS 26.0` for 6.2), and stay upstream's in the modules we ship, so a module serves every
target. `ASTContext::getPkgsRuntimeIntroduced` (Availability.cpp), called by the deserializer for every
`@available` it reads (`readAvailable_DECL_ATTR`, Deserialization.cpp, before it makes the attribute),
moves one version:

- **Which declarations.** Those of the modules the runtime pkg ships Swift code for,
  `ASTContext::isPkgsRuntimeModule`: `Swift`, `_Concurrency`, `SwiftOnoneSupport`, `_Builtin_float`. Not
  `Darwin` or `ObjectiveC`: their availability is the OS's APIs', so a newer one stays unavailable at 10.9.
  Nor any module built from source (the stdlib's own compile reads its attributes from source, unmoved) or
  imported from C.
- **Which version.** The `introduced:` of a macOS or `anyAppleOS` attribute, when it equals (canonicalized:
  10.16 is 11.0) the macOS entry of a released runtime in `RuntimeVersions.def`, 5.0 (10.14.4) through 6.4
  (27.0), read from the `.def` at the compiler's build, no number written in. It becomes `macOS 10.9`. A
  version no runtime has (macOS 9999, `SwiftStdlib 6.5`) stays.
- **Which targets.** Only a macOS target below 10.14.4 (`isMacOSTargetBeforeSwiftInTheOS`, the same single
  test as the table's). From 10.14.4 the function answers nothing and the attribute is upstream's.
- **What never moves.** `deprecated:`, `obsoleted:`, `unavailable`, `noasync`, `@backDeployed(before:)` and
  `@_originallyDefinedIn` versions. A back-deployed declaration's client keeps its fallback thunk, which on
  10.9 picks the copy emitted into the client: correct, if not our runtime's.

Effects below 10.14.4: such a declaration type-checks at 10.9 and, its linkage availability now 10.9, is
referenced strongly (our 6.4 runtime has it). Core's own `#available(SwiftStdlib N, *)` sites fold TRUE
when Core is built (`-disable-availability-checking`) and are exercised on the 10.9 gate
(`tests/thorough_test.swift`, `tests/stdlib_availability_test.swift`); an `#available` in a client, or in
inlinable stdlib code compiled into one, is a run-time OS check, and on 10.9 takes its fallback, as before.

**Span** takes no exception. `SwiftCompatibilitySpan 5.0` is macOS 10.14.4, `SwiftStdlib 5.0`'s, so the rule
opens Span with the rest, and with the 6.2 and 6.4 APIs that vend it (`Array.span`, ...). Core's
`$ld$previous` (`PreviousModuleInstallName.json`) sends the 33 Span symbols it exports (the six types'
metadata and descriptors, their `_count`/`_pointer`/`capacity` accessors) to
`@rpath/libswiftCompatibilitySpan.dylib` for a client below macOS 26. Upstream's back-deployment library of
that name (`stdlib/toolchain/CompatibilitySpan`) defines Span itself, for an OS whose Core lacks it; beside
a Core that has Span, upstream's stdlib install makes that name a link to `libswiftCore.dylib`
(`stdlib/public/core/CMakeLists.txt`), and so does the runtime pkg (`scripts/stage-runtime.sh`). 10.9's
dyld loads one Core through both names (proved on 10.9.5 in the A1 task 13 report; on the gate,
`tests/stdlib_availability_test.swift`). The toolchains carry no such link and no toolchain binary records
it. Excluding Span instead (by its `@_originallyDefinedIn(module: "Swift;CompatibilitySpan", ...)`) would
have left Span-returning 6.2 and 6.4 APIs open with Span closed, and inferred Span values still reaching
the library: not taken.

`tests/compiler-patch-audit-test.sh` holds it: the module list, the `.def` as the only source of versions,
the exact split lines, the deserializer's call before the attribute is made, and the Span link.
