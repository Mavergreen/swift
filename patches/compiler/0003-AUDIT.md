# Compiler patch 0003: every feature of the runtime table, classified

Patch `0003-runtime-versions-macos-10.9.patch` maps the macOS entry of every released Swift version in
`include/swift/AST/RuntimeVersions.def` (5.0 through 6.4) to OS X 10.9, because the Swift runtime on a
Mavergreen 10.9 is the one its pkgs ship (spec: the 2026-11-06 amendment, item 1). The rule: **a gate
opens when what it guards ships in our pkgs, and stays closed when what it guards is the OS's.** A
closed feature reads `FUTURE` in `include/swift/AST/FeatureAvailability.def`, which is what a 10.9
target saw of it before the patch.

`tests/compiler-patch-audit-test.sh` holds the patch to this list: one row per `FEATURE(` of the pinned
`.def`, each closed or unreleased one `FUTURE` after the patch, no open one, and each closed one's symbol
absent from the pinned 10.9 SDK's libobjc and libSystem (`lib.sh`'s `sdk109_stubs`).

- **open**: what the feature needs ships in our pkgs: `libswiftCore` (swift-runtime, today) or
  `libswift_Concurrency` (swift-runtime, A1's Release 2). The symbol is the runtime entry point the
  emitted code calls, or the runtime support the gate stands for.
- **closed**: what it needs is 10.9's own OS; the symbol is the libobjc (or libSystem) one, which 10.9
  lacks.
- **unreleased**: upstream's own `FUTURE`, which no released runtime has; the patch leaves it alone.

Readers are `grep -rn get<Feature>Availability lib/ include/` in the pinned tree (`SWIFT_SHA`), plus each
`is<Feature>FeatureAvailable` (IRGenModule.cpp:2197) caller and each `RuntimeFunctions.def` entry the
feature's `RuntimeAvailability` guards: an open feature's entry points become strong references, a
closed one's stay weak or unused.

## Features (40, in the `.def`'s order)

| Feature | Runtime | Class | Needs | Readers |
|---|---|---|---|---|
| `ObjCMetadataUpdateCallback` | (5, 0) | closed | `_objc_realizeClassFromSwift` (libobjc, 10.14.4): libobjc calls a Swift class's metadata update callback on realization | GenType.cpp:1568 (no legacy layouts if open: the legacy-layout path and Recaulk's `objc_readClassPair` realization need it closed), GenClass.cpp:2988 (`ClassMetadataStrategy::Update`) |
| `ObjCGetClassHook` | (5, 0) | closed | `objc_setHook_getClass` (libobjc, 10.14.4) | TypeCheckProtocol.cpp:6723 (`@_staticInitializeObjCMetadata` inferred when closed) |
| `OpaqueType` | (5, 1) | open | `swift_getOpaqueTypeMetadata` (Core) | IRGenModule.cpp:814 (`swift_getOpaqueTypeMetadata`, `swift_getOpaqueTypeConformance`), TypeCheckGeneric.cpp:95 |
| `ObjCClassStubs` | (5, 1) | closed | `objc_loadClassref` (libobjc, 10.15) | none through the getter; Sema's own gate, TypeCheckDeclObjC.cpp:550 `getObjCClassStubAvailability`, hard-codes 10.15 and is untouched |
| `BackDeployedConcurrency` | (5, 1) | open | `swift_task_create` (libswift_Concurrency) | TypeCheckAttr.cpp:3374 (`@main` async), TypeCheckAvailability.cpp:977 (`checkConcurrencyAvailability`: "concurrency is only available in macOS 10.15.0") |
| `TypesInAbstractMetadataState` | (5, 2) | open | `swift_getTypeByMangledNameInContextInMetadataState` (Core) | IRGenModule.cpp:824, MetadataRequest.cpp:3170 |
| `PrespecializedGenericMetadata` | (5, 4) | open | `swift_getCanonicalPrespecializedGenericMetadata` (Core) | IRGenModule.cpp:872, :2223 (`shouldPrespecializeGenericMetadata`, also off unless `-prespecialize-generic-metadata`) |
| `CompareTypeContextDescriptors` | (5, 4) | open | `swift_compareTypeContextDescriptors` (Core) | IRGenModule.cpp:842 |
| `CompareProtocolConformanceDescriptors` | (5, 4) | open | `swift_compareProtocolConformanceDescriptors` (Core) | IRGenModule.cpp:852 |
| `IntermodulePrespecializedGenericMetadata` | (5, 4) | open | `swift_getCanonicalSpecializedMetadata` (Core) | IRGenModule.cpp:862 |
| `Concurrency` | (5, 5) | open | `swift_task_create` (libswift_Concurrency); `SwiftNativeNSObject` (Core) | IRGenModule.cpp:880 (Concurrency's entry points strong, not weak), :1509 (no ObjC actor superclass swizzle), :2415 `isConcurrencyAvailable` (GenClass.cpp:2912 `SwiftNativeNSObject` as an ObjC actor's superclass, Core exports `_OBJC_CLASS_$_SwiftNativeNSObject`; MetadataRequest.cpp:1837 `swift_getFunctionTypeMetadataGlobalActor`, Core; IRGenModule.cpp:2386, no weak `swift_async_extendedFramePointerFlags`, which libswift_Concurrency defines), Decl.cpp:1500 (linkage), Linking.cpp:1621 |
| `MultiPayloadEnumTagSinglePayload` | (5, 6) | open | `swift_getMultiPayloadEnumTagSinglePayload` (Core) | ASTContext.h:1044, IRGenModule.cpp:938 |
| `ObjCIsUniquelyReferenced` | (5, 6) | closed | `objc_isUniquelyReferenced` (libobjc, 12.3): Core's `swift_isUniquelyReferenced` asks libobjc about an ObjC object, and 10.9's cannot answer | IRGenModule.cpp:948, GenHeap.cpp:1448 (closed: the `...NonObjC` entry points, as before) |
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
the table moves them too. Each is decided by the same rule; a closed one has its own hunk in the patch,
which on macOS asks for the OS version upstream's table gave, and so keeps today's 10.9 behaviour.

| Caller | Version | Class | What it guards | Patch |
|---|---|---|---|---|
| GenHeap.cpp:1356 `getFixedClassInitializationFn` | 5.1 | closed | `objc_opt_self` (libobjc, 10.15; not in 10.9's) | hunk: macOS 10.15, else Core's `swift_getInitializedObjCClass` as before |
| TypeCheckAttr.cpp:1882 `@objc @implementation` | 5.0 | closed | the stable-ABI ObjC runtime (libobjc, 10.14.4) | hunk: macOS 10.14.4, the diagnostic as before |
| GenClass.cpp:2799 `emitObjCProtocolData` | 5.8 | closed | the OS's linker and loader handling one ObjC protocol defined by clang and Swift both | hunk: macOS 13.3, Swift's own protocol emission as before |
| IRGenModule.cpp:832 `DynamicReplacementAvailability` | 5.1 | open | `swift_getFunctionReplacement`, `swift_getOrigOfReplaceable` (Core) | none: Core's, strong |
| GenCoro.cpp:114, :232 (task allocator offsets) | 5.7 | open | the Task layout of libswift_Concurrency, ours at 6.4: the new layout, with no OS-version check (which on 10.9 would pick the pre-5.7 layout, wrong for our library) | none |
| GenConcurrency.cpp:268 (`async let` context padding) | 5.7 | open | a pre-5.7 libswift_Concurrency bug ours does not have | none |
| SILCombinerMiscVisitors.cpp:1454 | 5.7 | open | Core's `_ContiguousArrayStorage<AnyObject>` storage for class elements | none |
| ImportDecl.cpp:2960 (C++ foreign reference types) | 5.8 | open | Core's runtime support for foreign reference types | none |
| SILBridgingImpl.h:873 `isSwift51RuntimeAvailable` (ObjectOutliner.swift:58, SimplifyStrongRetainRelease.swift:87) | 5.1 | open | Core's immortal reference counts for statically initialized objects (`swift_initStaticObject`) | none |
| TypeCheckRegex.cpp:230 | the pattern's | n/a | unreachable: the toolchains are built with `SWIFT_BUILD_REGEX_PARSER_IN_COMPILER=OFF` | none |

## Other readers of the table

- `lib/Basic/Platform.cpp` statically reflects `RuntimeVersions.def` into each platform's
  release list, which a `static_assert` required to strictly descend in platform version as well as
  Swift version. With every macOS entry at 10.9 they no longer strictly descend: the patch's hunk there
  asks for non-increasing platform versions instead. `getSwiftRuntimeCompatibilityVersionForTarget` then
  gives 6.4 for a 10.9 target (the newest version 10.9 provides), not 5.0. Its readers: the driver's and
  frontend's back-deployment libraries (none: `toolchain/swiftc`, `build.sh` and `make-selftest.sh` all
  pass `-runtime-compatibility-version none`, and no pkg ships those archives); IRGenMangler.cpp:169 and
  GenReflection.cpp:464 (mangled names Core's 6.4 demangler reads: open); GenProto.cpp:1084 (whether a
  resilient protocol's Sendable base can make a conformance dependent; both forms are Core's
  `swift_getWitnessTable`'s: open).
- The ObjC is-swift bit is not the table's: `CompilerInvocation.cpp:1672` sets `UseDarwinPreStableABIBit`
  for a macOS target below 10.14.4 itself, so a 10.9 target keeps the legacy bit that runtime patch 0007
  checks.
- `swift_async_extendedFramePointerFlags`: LLVM's X86 backend reads the flag dynamically for any macOS
  target below 12 (`X86Subtarget::swiftAsyncContextIsDynamicallySet`), from whichever library defines
  it; libswift_Concurrency does, so with `Concurrency` open the reference is strong, not weak. Its value
  is the library's, unchanged by this patch.
