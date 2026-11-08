# Build ingredients

Everything baked into what this repo publishes, and how a change to it reaches a release. An
*ingredient* is an input to the product; the *own upstream* is the thing this repo ports: Swift.

This one repo builds every Swift artifact for Mavericks from one pin: the runtime `.pkg`, the native
toolchain `.pkg` (it runs on OS X 10.9) and the cross toolchain `.pkg` (it runs on an Apple-silicon
Mac). `Mavergreen/swift-toolchain`, which used to publish the LLVM build support this repo consumed,
was merged in (2026-09) and deleted (2026-10). Its 6.4.0 installer mirror is now attached to this repo's
`6.4.0-mavericks.1` release.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Swift release (own upstream) | `SWIFT_VERSION` + `SWIFT_SHA` + `SWIFT_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/swift`, grouped with llvm-project; patch, minor and major alike merge on green, the real-10.9 gate included (below); the tarball's SHA-256 is written on the PR's branch by the pins bot (below) | auto-cuts `<upstream>-mavericks.1` on the push to main |
| swiftlang/llvm-project commit | `LLVM_SWIFT_RELEASE` + `LLVM_SHA` + `LLVM_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/llvm-project`, in the same "Swift release" PR; the SHA-256 as for Swift | moves only WITH the Swift pin: `build-llvm.sh` fails unless `LLVM_SWIFT_RELEASE` equals `SWIFT_VERSION` and `LLVM_SHA` is llvm-project's `swift-<SWIFT_VERSION>-RELEASE` |
| swiftlang/swift-cmark commit | `CMARK_SWIFT_RELEASE` + `CMARK_SHA` + `CMARK_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/swift-cmark`, in the same "Swift release" PR; the SHA-256 as for Swift | moves only WITH the Swift pin: `build-toolchain.sh` runs `check_release_pin` on it |
| mavericks-clang-22 cross toolchain (compiles the 10.9-hosted toolchain and compiler-rt's builtins, and its `llvm-libtool-darwin`, `llvm-ar`, `llvm-ranlib` and `llvm-lipo` make their archives; on OS X 10.9, `self-host.sh` uses the native package of the same release) | `CLANG22_VERSION` in `pins.env` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | auto-repackages `-mavericks.(N+1)` |
| libcxx22, the family's shared libc++ (the stdlib's C++ compiles against the pinned clang22's libc++ headers and links libcxx22's `libc++.1.dylib`; the runtime and native toolchain pkgs require it at install) | `CLANG22_VERSION` in `pins.env`: one clang-22 release publishes clang22, clang22-cross and libcxx22 under one version | ✅ with the clang22 pin (`github-releases` on `Mavergreen/clang-22`) | auto-repackages `-mavericks.(N+1)`, and the pkgs then require that libcxx22 or later |
| Recaulk, the family's back-fills of post-10.9 OS APIs (libswiftCore links Recaulk's definitions of the APIs `build.sh`'s `RECAULK_RUNTIME_SYMBOLS` names, and only those, statically, and libswiftDarwin and libswift_Concurrency their own subsets: below) | `RECAULK_VERSION` in `pins.env` | ✅ `github-releases` on `Mavergreen/recaulk`, `YYYYMMDD.N` versioning | auto-repackages `-mavericks.(N+1)`; nothing is required at install, since the link is static |
| LLVM and compiler source patches (`patches/llvm/`, `patches/compiler/`: compiler `0003` maps the compiler's runtime table, and the stdlib's own declarations, to OS X 10.9 for targets below 10.14.4, below) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| swift.org toolchain `.pkg` (CI's one seed: it compiles the cross toolchain's Swift half, and a first stdlib that only makes that toolchain runnable; everything the release ships is compiled by this repo's own compilers, below) | `TOOLCHAIN_URL`, derived from `SWIFT_VERSION` | ✅ moves with the Swift pin | verified by **signer identity**, not a hash (below) |
| Runtime source patches (`patches/runtime/`) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| swift-6.2 Darwin overlay source (`stdlib/public/Platform`) | `SWIFT62_SHA` + `SWIFT62_TARBALL_SHA256` in `pins.env`, fetched by `fetch_source` into `swift-6.2` | ❌ untrackable: frozen, since upstream removed the files in 6.3 and Mavergreen owns them; no `renovate:` marker, and no updater (Renovate, the pins bot, `pin-source-tarballs.sh`) names the pin | n/a: moves only by a deliberate edit |
| swift-5.4 ObjectiveC overlay source (`stdlib/public/Darwin/ObjectiveC`) | `SWIFT54_SHA` + `SWIFT54_TARBALL_SHA256` in `pins.env`, fetched by `fetch_source` into `swift-5.4` | ❌ untrackable: frozen, since upstream removed the files in 5.5 and Mavergreen owns them; as for swift-6.2 | n/a: moves only by a deliberate edit |
| Overlay source patches (`patches/overlays/`, applied with `-p0` from the swift-5.4 tree: `0001` makes `NSObject.hash` a method call, as the 10.9 SDK declares it) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| Sparkle framework, MacOSX10.9 SDK (the toolchains link against its original stub files, fetched with shipyard's pin by `lib.sh`'s `sdk109_stubs`, on every host: below) | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a moving tag; nothing auto-repackages |
| MacOSX11.3.sdk, the pinned modern SDK the runtime builds against (CI and OS X 10.9 alike), and the cross toolchain's arm64 binaries too | `Mavergreen/shipyard@v1` (`sdk-pins.sh`'s arm64 pin, fetched by `fetch_sdk.sh --arch arm64`) | ✅ github-actions manager tracks the tag | `@v1` is a moving tag; nothing auto-repackages |
| Apple clang, the `macos-26` runner's Command Line Tools (compiles the cross toolchain's LLVM, clang, lld and the C++ half of `swift-frontend`) | the runner image, not pinned | ❌ untrackable: no datasource for a hosted runner's Command Line Tools. The pinned MacOSX11.3.sdk bounds what those binaries record (minOS 11.0, SDK 11.3, checked by the compat guard), and `scripts/audit-imports.py` checks every Swift, C++ and ObjC runtime import of `swift-frontend` against it (it audits only a binary that links libswiftCore, so not `clang` or `ld64.lld`, whose libc++ imports nothing checks) | a runner-image change reaches the next release; those checks run on every build |

## One C++ runtime: libcxx22, on the OS's own libc++abi

The runtime is C++ as well as Swift, and the family keeps one shared libc++ in every process, its own,
never the OS's (`/usr/lib/libc++.1.dylib`, which predates clang22's headers and belongs to Apple's code).
So the stdlib's C++ compiles against the pinned clang22's own libc++ headers (`-nostdinc++ -isystem`, the
directory prefix-mapped, since cross and native find it in different places) and `-nostdlib++` links
libcxx22's `libc++.1.dylib` by path: `-L` would be searched inside the SDK first, `-isysroot`'s doing, and
find the SDK's libc++, which on 10.9 is the OS's. Runtime patch 0009 drops `Metadata.cpp`'s `-lc++`
autolink, which exists for a statically linked libswiftCore (never built here) and would load the OS's
libc++ beside libcxx22's. libcxx22 re-exports the OS's `/usr/lib/libc++abi.dylib`, so a process has one
C++ exception runtime: two copies crash when one catches what the other threw, which is why the pin must be
22.1.8-mavericks.5 or later, the first libcxx22 built that way (`tests/pins-test.sh` refuses older).
`build.sh` refuses a runtime dylib that does not link libcxx22's libc++, links the OS's beside it, or
defines a C++ ABI symbol of its own. libobjc on 10.9 itself links the OS's libc++, so a Swift process
loads both libc++ dylibs; they coexist under different install names, and share the one libc++abi.

The runtime pkg and the native toolchain pkg (whose stdlib dylibs are the runtime's bytes, loaded on 10.9)
require libcxx22 at the pin or later (`--requires "libcxx22>=$CLANG22_VERSION"`: shipyard's generated
preinstall refuses a missing or older one before installing anything); the cross toolchain only links against its copies, on a modern Mac, and requires nothing. The
install name `/usr/local/mavergreen/libcxx22/lib/libc++.1.dylib` lasts until the family's flag day, when
libcxx22 becomes the unlined `libcxx` under `/opt` and this runtime, moving there too, relinks.

## Recaulk: the OS APIs 10.9 lacks, one owner

Where the runtime calls an API OS X 10.9 lacks, and the family's Recaulk back-fills it, libswiftCore links
Recaulk's definition instead of carrying a patch of its own: `os_system_version_get_current_version`
(macOS 10.12), which runtime patch 0002 used to guard with a CoreFoundation plist read, and
`objc_readClassPair` (10.11), for which patch 0003 used to realize runtime-instantiated classes itself.
Each definition is a forwarder: where the OS has the function, it calls the OS's; on 10.9, Recaulk's
body. Recaulk's realization does what 0003's did and more: it carries the superclass's custom
retain/release and allocWithZone flags, without which objc_retain counts in libobjc's side table while
Swift counts in the object, and attaches the class's own methods, without which a bridged Dictionary
or Set answers nothing (`tests/objc_refcount_bridging_test.swift`; both failed on 0003's path). Not
`_objc_realizeClassFromSwift`: upstream keeps its legacy, fragile-layout path when that is absent, which
is what a 10.9 deployment target's class metadata is built for; revisit if a 10.9 consumer reports
"does not have a fragile layout" or needs resilient ObjC class stubs. A known gap, 0003's too: on 10.9 a
runtime-realized class is not linked into its superclass's subclass list, so a method swizzled, replaced or
added by a category on an ancestor after the class has cached that selector is not flushed from its cache;
don't rely on swizzling or KVO in such ancestries on 10.9 until a Recaulk release links its realized classes into
libobjc's class tables. Patch 0005 asks libobjc itself,
not the weak import, whether it has `objc_readClassPair`, since Recaulk's realization slides no ivars
either. For the OS version, upstream's own failure value stays (0.0.0, never a guessed 10.9.0):
`#available` does not go through it, compiler-rt's `__isPlatformVersionAtLeast` in each binary does, and
only `_swift_stdlib_operatingSystemVersion`, an ABI entry point kept for old binaries, calls it
(`tests/availability_test.swift` holds both to 10.9.5 on 10.9.5).

`build.sh` links a subset of `librecaulk.a`, never the whole archive, which would bind six of
libswiftCore's weak imports where it means one: the runtime reads a weak import's presence as "the OS has
this", so `os_signpost_enabled` would turn its tracing on and then call the `os_log_create` and
`os_signpost_id_generate` no 10.9 has, and `objc_readClassPair` and `_objc_realizeClassFromSwift` would
flip the realization paths upstream and patch 0005 choose by. `lib.sh`'s `recaulk_subset` picks, by symbol,
the members that define each name in `RECAULK_RUNTIME_SYMBOLS` and what they need from the archive, and
refuses a member that defines any other API; the link hides every global they define
(`-unexported_symbols_list`), so libswiftCore exports what it did before. Step 7 refuses a runtime that
still imports a Recaulk-supplied API, does not define it, exports it or any `___recaulk_` name, or no
longer weak-imports the APIs whose presence the runtime reads from the OS. The archive's SHA-256 is one of
the stdlib build's stamped inputs, so a Recaulk bump starts that build afresh. Recaulk's notice is in
`NOTICE`.

libswiftDarwin takes a subset of the same archive the same way, for `openat` (macOS 10.10): the overlay
calls it, so on 10.9 it would be a strong import that fails to load. `build.sh` links `recaulk_subset`'s
pick into libswiftDarwin and hides every global it defines, so the dylib exports what the overlay sources
define and nothing of Recaulk's. Its members are Recaulk's forwarder and resolver and two files of
macports-legacy-support, `atcalls.c` (under the APSL 2.0) and `pthread_chdir.c` (MIT). Every global they
define is `openat` or `___recaulk_`-prefixed: since 20261108.3 Recaulk also prefixes the incidental globals
it once left bare (clang's block helpers in its dispatch member, legacy-support's `best_fchdir`), so
`recaulk_subset` has no list of exceptions and a stray global is a request to Recaulk. Step 7 checks
libswiftDarwin as it does libswiftCore: `openat` defined in it, exported by nothing, and no longer an import.

`atcalls.c` is Apple's code under the APSL 2.0, whose section 2.3 asks for the "source is available"
notice "in the code itself as well as in related documentation". Since 20261108.3 Recaulk compiles that
notice into each Apple-derived member, as a string the linker may not dead-strip, and lists it in
`share/recaulk/notices.tsv` (the same file as the release's `recaulk-notices.tsv`, verified with the pkg by
the release's `SHA256SUMS`). Step 7 holds every dylib that links a Recaulk subset to it (`lib.sh`'s
`recaulk_notices`): each member the subset links that the tsv lists under the APSL must still have its
notice in the dylib's strings after our link, and in `NOTICE`, whitespace aside. Today that is
libswiftDarwin's `mp-atcalls.o`; libswiftCore links only Recaulk's own ISC code. A bump that pulls in
another APSL member fails the build until `NOTICE` carries its notice too. The tsv lists only APSL
members, so a linked MacPorts `mp-*` member with no row fails too, unless `build.sh`'s
`RECAULK_NOTICES_REVIEWED` names it: someone read its source's licence and `NOTICE` carries it
(`tests/notice-test.sh` holds `NOTICE` to each name). Today that is `mp-pthread_chdir.o`, under
legacy-support's MIT LICENSE, and libswift_Concurrency's `mp-time.o` (below), under its own ISC-style grant. An Apple-derived member Recaulk forgot to list cannot pass silently.

libswift_Concurrency takes a third subset, `RECAULK_CONCURRENCY_SYMBOLS`: `voucher_copy` and `voucher_adopt`,
which it imports strongly, so without them it does not load on 10.9; `qos_class_self`, `clock_gettime`,
`clock_getres` and `dispatch_activate`, weak but called with no check (every task, every clock read and
`Task.sleep`, a sleep with tolerance); and `os_release`, once a voucher is non-NULL. Runtime patch 0013
gives Concurrency's link a hook, `MAVERGREEN_CONCURRENCY_LINK_FLAGS`, so this subset and its unexported
list reach that dylib alone. The members include legacy-support's `src/time.c` (`clock_gettime`,
`clock_getres`), whose own notice is in `NOTICE`; it has no notices-list row (it is not APSL), so
`RECAULK_NOTICES_REVIEWED` names `mp-time.o` and step 7's notice check runs over libswift_Concurrency too.
Every global the subset defines is a named API or `___recaulk_`-prefixed, the dispatch member's block
helpers among them. Not yet in it: `dispatch_assert_queue$V2`, weak and called
with no check from `MainActor.assumeIsolated` and `preconditionIsolated` off the main queue's own job,
which Recaulk does not define yet; it is requested, joins the list when Recaulk ships it, and until then
the allowlist below names that call for what it is, an unguarded one. Step 7 checks libswift_Concurrency
as it does libswiftCore, and holds its tracing's weak imports (`os_signpost_*`, `_os_log_create`) to the OS's.

Step 7 also holds every dylib it ships, and the test-support libraries, to what OS X 10.9 has
(`scripts/imports-on-10.9.sh`): each symbol imported from `/usr/lib` or a framework must be exported by
that library's stub in the 10.9 SDK, or be weak and listed in `scripts/resources/weak-absent-on-10.9.txt`
beside the guard that reads it first. A strong import that 10.9 lacks otherwise links against the 11.3 SDK
without complaint and fails in dyld on a real 10.9 box.

## The compiler's runtime table: 10.9's Swift runtime is the pkgs'

Upstream's compiler maps each Swift runtime version to the OS release that first shipped it
(`RuntimeVersions.def`), and refuses, for an older target, anything that needs a newer runtime: `async`
and actors (5.1 to 5.5), parameter packs in generic types (5.9), typed-throws function types (6.0). A
client built for a macOS below 10.14.4 records `@rpath/libswiftCore.dylib` (Core's `$ld$previous`), and
on a Mavergreen 10.9 the runtime it loads is the swift-runtime pkg's, 6.4, not the OS's. Compiler patch
`0003` (`patches/compiler/0003-runtime-versions-macos-10.9.patch`, both toolchains) makes the table depend
on the target, in one place (`lib/AST/Availability.cpp`), by one rule: **a gate opens when what it guards
ships in our pkgs, and stays closed when what it guards is the OS's.** Below 10.14.4, every released
Swift version is available from 10.9. From 10.14.4, where clients load the OS's `/usr/lib/swift`,
upstream's table holds exactly, so a binary built for 10.15 imports nothing that 10.15's runtime lacks.
What the OS's libobjc provides keeps upstream's table on every target, and so stays closed for 10.9:
`ObjCMetadataUpdateCallback` (which also keeps the legacy-layout path that runtime patch 0007 and
Recaulk's `objc_readClassPair` realization depend on), `ObjCGetClassHook`, `ObjCClassStubs`,
`ObjCIsUniquelyReferenced`, and three callers that read a Swift version directly for an OS need
(`objc_opt_self`, `@objc @implementation`, ObjC protocol emission). The two `.def` files stay upstream's.
The same rule covers the library's own declarations. Swift's `@available(SwiftStdlib N, *)` macros stay
upstream's, so `Task.sleep(for:)` still reads macOS 13.0 and `InlineArray` 26.0 in the modules we ship, for
every target; so do the declarations marked `StdlibDeploymentTarget N` (`Duration`, the clocks), which
`build.sh` builds with `SWIFT_STDLIB_ENABLE_STRICT_AVAILABILITY` (without it the stdlib's CMake writes the
deployment target, 10.9, into them, and a client built for 10.15 could use `Duration`, which 10.15's own
runtime lacks). Below 10.14.4 only, the compiler reads a declaration of a module the runtime pkg ships
Swift code for (`Swift`, `_Concurrency`, `SwiftOnoneSupport`, `_Builtin_float`) as available from 10.9
when its macOS version is a released runtime's (`RuntimeVersions.def`, 5.0 through 6.4): the deserializer
moves that one `introduced:` version as it reads the attribute. `Darwin` and `ObjectiveC` stay as written,
since their availability is the OS's APIs'; deprecations, obsoletions and unavailability never move.
`Span` is opened with the rest: Core's `$ld$previous` sends its symbols to
`@rpath/libswiftCompatibilitySpan.dylib` for any client below macOS 26, and the runtime pkg ships that name
as a link to `libswiftCore.dylib`, as upstream's own stdlib install does beside a Core that has Span. So a
program built for 10.9 that uses Span needs a runtime pkg that has the link, as one using any other new API
needs a runtime that has it, and an app that bundles our runtime must bundle the link with it.
`_Concurrency` is imported implicitly, as Apple's swiftc does: the toolchains ship `_Concurrency.swiftmodule`
and `_Builtin_float.swiftmodule` and `libswift_Concurrency.dylib`, the runtime pkg that dylib alone. `_Builtin_float`
is a module only. Its dylib is a stub whose every export (but its force-load symbol) libswiftDarwin
defines, so no pkg ships it and no program links it; step 7 checks that, so a Darwin that lost a symbol fails
the build, not a client. A program built by these toolchains links `@rpath/libswift_Concurrency.dylib`,
so a toolchain pkg requires the runtime pkg of its own release or later, not the earlier runtime that had
Darwin and ObjectiveC alone. `-disable-implicit-string-processing-module-import` stays: `_StringProcessing` ships nowhere.
Every feature's class, with the symbol it needs and the compiler code that reads it, and the declaration
rule, are in `patches/compiler/0003-AUDIT.md`, and `tests/compiler-patch-audit-test.sh` holds the patch to
them. The proof programs are `tests/typed_throws_test.swift`, `tests/parameter_packs_test.swift` and
`tests/stdlib_availability_test.swift` (Core's newer APIs, Span among them, unmodified): only this repo's
compiler builds them, so `make-selftest.sh`'s swift.org-compiler mode skips them by their first line.

## Two seeds, one result

CI seeds from the swift.org compiler alone: it compiles the cross toolchain's Swift half (`build-cross`),
and the cross toolchain then compiles the standard library every package ships and the 10.9 toolchain's
Swift half (`build`). CI never builds with an earlier Mavergreen release. On OS X 10.9, `self-host.sh`
rebuilds the 10.9 toolchain with the previous release, and the result must be the release's bytes
(`self-host.sh --compare`; DEVELOPING.md). These settings, none of them an ingredient Renovate moves, keep
the two hosts' builds the same bytes:

- **Archives:** clang22's `llvm-libtool-darwin`, `llvm-ar` and `llvm-ranlib` in `build-toolchain.sh`, its
  `llvm-libtool-darwin` and `llvm-lipo` in `build-builtins.sh`, and its `llvm-ar` and `llvm-ranlib` for the
  standard library's archive in `build.sh`, never the host's Apple tools.
- **Sources:** GitHub's tarballs of the pinned commits, verified by `pins.env`'s SHA-256s and extracted
  afresh on every build, patched with the OS's `patch` (OS X 10.9's GNU patch 2.5.8 and a modern Mac's BSD
  patch 2.0 write the same bytes, and the same as `git apply` did).
- **Version stamps:** LLVM's, clang's and lld's are forced to `LLVM_SHA` and
  `https://github.com/swiftlang/llvm-project.git` (`LLVM_FORCE_VC_REVISION` and
  `LLVM_FORCE_VC_REPOSITORY`), the strings git read from a checkout; Swift's own (`SWIFT_APPEND_VC_REV`) is
  off: it reaches no shipped byte.
- **The 10.9 SDK's stubs:** `lib.sh`'s `sdk109_stubs` fetches shipyard's pinned tarball with shipyard's
  own `sdk-pins.sh` and `mavericks_fetch.sh`, and leaves its `MH_DYLIB_STUB` files as they are.
  `fetch_sdk.sh` converts them to `.tbd` where `tapi` exists, which is every modern Mac and never 10.9,
  and lld orders a `.tbd`'s exports differently from a stub's.
- **clang's linker:** `HOST_LINK_VERSION=241.9` (10.9's ld64) and `CLANG_DEFAULT_LINKER=lld`, in
  `build-toolchain.sh`, for both toolchains.
- **Paths:** the build root is mapped to `/mavergreen-build` in every compile.

## Why the sources are tarballs, and their SHA-256s a script's

The builds run on OS X 10.9 with nothing from Xcode's Command Line Tools, and 10.9's only git is one of
their stubs. So they fetch each pinned commit as GitHub's tarball of it (shipyard's
`fetch_pinned_source.sh`), verified by a SHA-256 in `pins.env`, and check the tags with `curl` against the
repository's ref advertisement (`<repo>/info/refs`, what `git ls-remote` reads). Renovate moves a commit
but cannot compute a hash, so a bot writes them on the Swift bump's own branch
(`.github/workflows/pins-bot.yml`, on pushes to `renovate/**`). Its first job, with read access only,
runs `scripts/pin-source-tarballs.sh`: it fetches each tarball and, with git, the commit itself, and
computes the SHA-256 only for a tarball that holds exactly the commit's tree; upstream's bytes never sit
beside a token that can write. Its second job, which reads no upstream byte, writes those three values
into `pins.env` (`scripts/pins-bot.sh`), commits them as `mavergreen-pins-bot[bot]` and pushes with a
token of the Mavergreen pins-bot GitHub App (`contents: write` on this repository alone; org variable
`PINS_BOT_CLIENT_ID`, org secret `PINS_BOT_PRIVATE_KEY`). A push made with `GITHUB_TOKEN` would start no
workflow, and a run it dispatched would not count for the PR; the App's push starts `release.yml` like any
push, that run's `build` is the check `main` requires, on the new head, and a Swift patch bump automerges
on green as the family rule says (minor and major still wait for a human, below). `build` fails, never
skips, when `build-cross` fails (GitHub counts a skipped required check as passed), so a bump cannot merge
on the stale pins before the bot has pushed. The token rule is the bot's two jobs': the `release.yml` run
builds upstream with the permissions every `release.yml` run has (`contents: write` workflow-wide, its
checkouts keeping the token), as the push that opened the branch already did. `gitIgnoredAuthors` in
`.github/renovate.json` keeps the bot's commit from marking the branch as edited by someone else. Until
the bot has run, CI fails at the first fetch, naming the pin; if the bot fails, `sh
scripts/pin-source-tarballs.sh` on the branch does by hand what it does, and `--check` writes nothing. GitHub's
generated archives have been byte-stable (10.9's curl and a modern Mac's fetched the same SHA-256s); if
GitHub ever regenerates them, the fetch fails rather than build other bytes.

## How a bump reaches a release

- **`SWIFT_VERSION` moved** → a new upstream. `version.sh` reports `RELEASE=yes` because that upstream
  has no tag yet, so the push to main auto-cuts `-mavericks.1`.
- **a Swift bump's tarball SHA-256s** move with it, in the same push: still a new upstream.
- **any other pin in `pins.env`, or anything under `patches/`, moved** → an ingredient bump.
  `repackage-on-ingredient-bump.yml` dispatches `release.yml` with `local_release=true`, which cuts
  `-mavericks.(N+1)`.

The caller declares `own-upstream-paths: pins.env:SWIFT_VERSION` — a *key*, not a path, because both
kinds of pin live in one file. Without it a Swift bump would publish twice.

## Every Swift bump merges on green, the real-10.9 gate included

The runtime patches are cut against specific stdlib and runtime internals, so a bump that merely builds
proves nothing about 10.9. A minor or major bump used to wait for a human for that reason, until CI could
run the real-10.9 gate. It does: `vm-test`, a required check, installs each run's pkgs on Mac OS X 10.9
(`Mavergreen/mavericks-vm`) and gates them there, so a bump whose patches apply and whose gate passes
merges like any other, as the family's default has it.

The gate is sized, so that upstream's tests can grow. `run-selftest.sh --gate` runs our own binaries
500x plus 10x under Guard Malloc (24 with Release 2's concurrency_test; concurrency_isolation_test is skipped
until Recaulk has `dispatch_assert_queue$V2`) and upstream's, each included test at -O and -Onone and once per
variant (`SELFTEST_UPSTREAM_RUNS`, default 20, plus 1 under Guard Malloc), after a `--loads` run. Release 2's
lists include 6 Darwin, 2 ObjectiveC and 19 Concurrency tests (most of those built twice: lit runs them again in
Swift 5 mode with NonisolatedNonsendingByDefault), 43 builds, 86 upstream binaries.

Measured on the real box (ultimate-hat, 12 cores, shared: load 3 to 5.5): 1116 s for all 110 binaries, about
157 s for ours and 958 s for upstream's. That run timed out one guarded run at the then-uniform 60 s, so
upstream's runs now have their own limit, `SELFTEST_UPSTREAM_TIMEOUT`, 180 s. Every binary's slowest single run on
the box: clock's Guard Malloc runs take 40 to 45 s (its unguarded runs 1.3 to 1.8 s), and
cancellation_handler_concurrent's -Onone Guard Malloc run takes 65 s (100,000 tasks; 16 s at -O). Everything else
is under 5 s, ours included. So 180 s is three to four times the box's worst. A hang still fails, three minutes
later.

The VM estimate has to tell sleeping from computing, because a VM is no faster at sleeping. Two suites are
sleep-bound: basic_future (4 binaries x 21 runs x 4.4 s, about 370 s) and clock's unguarded runs (4 x 20 x 1.55 s,
about 125 s), so about 495 s. The rest is CPU-bound: about 465 s of upstream's and 157 s of ours. At Release 1's
VM-to-box CPU ratio of 0.42 (run 40272925587), that rest takes about 260 s. The VM gate is then about 495 + 260
= 755 s, 13 min, and at the box's own pace 19 min. Compiling in the VM is the larger cost: 110 binaries at a
pessimistic 15 s each is 28 min. Install, compiles, gate and smoke total about an hour at the worst, so
`vm-test`'s `timeout-minutes` stays 120, under GitHub's 360. 20 runs stay: 20 plus 1 under Guard Malloc is a
short, deterministic-test budget, and halving it would save about 7 min on the box.

The 120 minutes must be re-sized when the next excluded groups come in. Those are the 67 FileCheck tests (once
output is checked), the 14 that set an environment variable, the 7 that need the Dispatch overlay, and
concurrency_isolation_test (once Recaulk has `dispatch_assert_queue$V2`). Together that is about 90 tests and,
most having two variants, up to about 330 binaries at -O and -Onone: some 80 min of compiles at 15 s each before
their gate time, which would by itself pass today's budget.

Owed: upstream tests the gate excludes because 10.9 or this release lacks something, each owed
until its blocker goes (the reasons are in `tests/upstream/*.list`):
- `test/stdlib/PrintFloat16.swift`: its regex literal needs `_StringProcessing`, which this release does not ship.
- `validation-test/stdlib/ObjectiveC.swift`: `override var hash` overrides nothing, as the 10.9 SDK declares
  -hash as a method, not a property.
- `validation-test/stdlib/ObjectiveC_without_Foundation.swift`: the 10.9 SDK has no nullability, so
  `NSObject()` is `NSObject!` and `var anNSObject` is not `CVarArg`.
- `test/stdlib/FloatingPoint.swift.gyb`: 10.9's libm, where `fma` returns the wrong sign (`Double.addingProduct`
  at -Onone) and `truncl(-0)` returns +0 (`Float80.round`).
- POSIX.swift and mmap.swift hand the test a temp directory (`%t`), which the gate does not supply.
- `tests/concurrency_isolation_test.swift` (MainActor.assumeIsolated, preconditionIsolated): needs
  `dispatch_assert_queue$V2`, which 10.9's libdispatch lacks; requested from Recaulk, skipped until it ships.
- The Concurrency tests that use `DispatchQueue` or `DispatchTime` (7): the Dispatch Swift overlay, which this release
  does not ship.
- The Concurrency tests whose RUN: line sets an environment variable with `env` (14, the isolation-mode
  overrides and `SWIFT_DEBUG_VALIDATE_UNCHECKED_CONTINUATIONS` among them): the gate sets no variable.
- `test/Concurrency/Runtime/actor_dynamic_subclass.swift`: the 10.9 SDK has no nullability, so it does not compile
  (line 32).

## Why LLVM is pinned by release tag, and checked against the Swift pin

LLVM build support cut for one Swift release and used for another builds fine and is wrong. It used
to be a branch pin (`swift/release/<minor>`) tracked by `git-refs`, which can only follow the branch
it names; from 6.4 swiftlang cuts a branch per release, so a Swift patch bump would have automerged
against the previous release's LLVM. llvm-project tags every Swift release with the same
`swift-X.Y.Z-RELEASE` name swiftlang/swift uses, so LLVM is pinned by that tag. Its release is its own
literal, `LLVM_SWIFT_RELEASE`, only because Renovate needs a value of its own to move `LLVM_SHA` by;
`build-llvm.sh` refuses to start unless the two are equal and `LLVM_SHA` is the commit the tag names.

## Why the swift.org toolchain is verified by signature, not a pinned hash

A hash can only vouch for bytes someone has already seen, so every version bump needed a human to
paste a new one. The signing identity is stable across releases, so `TOOLCHAIN_SIGNER` verifies a
version that does not exist yet. Upstream publishes no GPG signature for the macOS `.pkg`; it is an
Apple-signed installer, so `pkgutil` is the check that exists.

## Automatic publishing does not mean automatic acceptance

A macOS 26 runner is structurally blind to the 10.9-only behaviour this runtime exists to fix, so an
auto-cut release can reach a 10.9 user through Sparkle before anyone has run it on real hardware. The
trade accepted: shipping promptly and fixing real-hardware breakage forward in `-mavericks.(N+1)`.
CI green is still not acceptance: real-10.9 validation (`run-selftest.sh --gate`) is the bar for
believing a release is good; it is not the bar for publishing one.

## Conformance deviations

`check-artifact-conformance.sh` holds a release's artifacts to the family's schemes, and the compat
guard (`scripts/guard.sh`) reads the `sdk-pin` entries too. These departures are deliberate, and
each is scoped to the artifact it concerns: the first ten to the stdlib dylibs (libswiftCore,
libswiftSwiftOnoneSupport and libswift_Concurrency: the runtime pkg's, with the libswiftCompatibilitySpan.dylib link to
Core, and the same bytes in both toolchain pkgs), the next to the cross toolchain pkg's install floor, the
next to vm-test's upgrade from the newest release, and the last ones to the swift.org mirror attached to
`-mavericks.1` releases.

- sdk-pin:*/swift-runtime/lib/swift/libswiftCore.dylib: the Swift runtime cannot be built against the 10.9 SDK, which has no libc++ headers at all (only libstdc++ 4.2.1) while Swift 6.4 requires C++17, and which lacks declarations of post-10.9 APIs the runtime calls behind availability checks. Its build uses a modern SDK, pinned: MacOSX11.3.sdk, shipyard's arm64 pin (`fetch_sdk.sh --arch arm64`), the same in CI and on 10.9, so a runtime built on 10.9 is byte-identical to CI's. These two record sdk 11.3 (the Darwin and ObjectiveC overlays beside them compile against the 10.9 SDK, record sdk 10.9, and take no exemption); their libc++ is libcxx22's, not the SDK's ("One C++ runtime", above). minos stays 10.9, and the real-10.9 gate is its acceptance. Revisit if the gate gains per-product pins.
- sdk-pin:*/swift-runtime/lib/swift/libswiftSwiftOnoneSupport.dylib: the same stdlib build and the same reason as libswiftCore.dylib's, above.
- sdk-pin:*/swift-runtime/lib/swift/libswift_Concurrency.dylib: the same stdlib build and the same reason as libswiftCore.dylib's, above: Concurrency's runtime is C++17 as Core's is, and records sdk 11.3 and minos 10.9 (runtime patch 0012 lowers the 10.15 its build forced).
- sdk-pin:*/swift-runtime/lib/swift/libswiftCompatibilitySpan.dylib: a link to libswiftCore.dylib in the same directory (scripts/stage-runtime.sh; "The compiler's runtime table", above), so it is libswiftCore's bytes, and the compat guard, given the runtime's lib/swift/*.dylib, follows it and reads Core's sdk 11.3: libswiftCore.dylib's reason, above, verbatim. The toolchains ship no such link (a program's link reaches the name through Core's $ld$previous, not a file).
- sdk-pin:*/swift-toolchain/lib/swift/macosx/libswiftCore.dylib: the toolchain's stdlib dylibs are the runtime's own bytes, staged from the one stdlib build (scripts/stage-toolchain.sh), so the runtime's reason above applies verbatim. The compiler, lld and clang beside them record the pinned 10.9 SDK and take no exemption.
- sdk-pin:*/swift-toolchain/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib: the same stdlib build and the same reason as libswiftCore.dylib's, above.
- sdk-pin:*/swift-toolchain/lib/swift/macosx/libswift_Concurrency.dylib: the runtime's own bytes too, from the same stdlib build, and the same reason as libswiftCore.dylib's, above; the toolchain ships it so a program's link finds it, as it ships Core's.
- sdk-pin:*/swift-toolchain-cross/lib/swift/macosx/libswiftCore.dylib: the cross toolchain's stdlib dylibs are the runtime's own bytes too: CI's build-cross job builds the one stdlib, with that cross toolchain, and stages it into all three pkgs, and collect refuses a release whose two toolchains' stdlib and builtins trees differ in a byte, so the runtime's reason above applies verbatim. The compiler, lld and clang beside them are arm64 and record the family's arm64 pin (minOS 11.0, SDK 11.3) and take no exemption.
- sdk-pin:*/swift-toolchain-cross/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib: the same stdlib build and the same reason as libswiftCore.dylib's, above.
- sdk-pin:*/swift-toolchain-cross/lib/swift/macosx/libswift_Concurrency.dylib: the runtime's own bytes too, staged from the one stdlib build into all three pkgs and compared byte for byte by collect, as libswiftCore.dylib's are; the same reason as its, above.
- floor:swift-toolchain-cross-*.pkg: the cross toolchain runs on an Apple-silicon Mac with macOS 11 or later and only targets 10.9, so its archive's install floor is 11.0 (arm64), not 10.9.5; clang22-cross and rust-cross declare the same.
- unpinned:.github/workflows/release.yml: vm-test installs the newest published release's runtime and native toolchain pkgs (`gh release view`, then SHA256SUMS-verified), and this run's over them, because that is the upgrade a user makes: from whatever they have, which is the latest release. A pin would test an upgrade from a version nobody upgrades from once the next one ships. Reconsider if the family keeps more than one supported line at once, when each line's latest is the one to upgrade from. Longboat, which only the native smoke's mavericks-clang-22 pkg needs, comes the same way (`gh release view`, then SHA256SUMS-verified), because clang22's pkg sends a user to Longboat's latest release.
- version:upstream-swift-*.pkg: mirrored verbatim from swift.org, so its version is upstream's own
  (`6.4.20260913101` for 6.4.0). Rewriting it would break the correspondence with download.swift.org
  that the mirror exists to keep checkable.
- floor:upstream-swift-*.pkg: upstream ships a 10.11 floor. We do not restamp a mirrored package.
- identifier:upstream-swift-*.pkg: `org.swift.*` is upstream's identifier; claiming
  `dev.mavergreen.*` for bytes we did not build would be a lie.
- install-path:Library/Developer/Toolchains/swift-*.xctoolchain/*: upstream's pkg, verbatim, installs where Xcode finds toolchains.
- manifest:upstream-swift-*.pkg: mirrored verbatim from swift.org; it is a build input
  build.sh expands, never installed by the family, so there is no product tree for a manifest to describe.
- bundle-id:org.swift.*: upstream's own bundles, verbatim in upstream's pkg (sourcekitd, sourcekitdInProc, PlaygroundLogger).
- bundle-id:com.apple.dt.*: PlaygroundSupport and XCPlayground frameworks, verbatim in upstream's pkg under Apple's ids.
- bundle-id:com.apple.LLDB.framework: LLDB.framework, verbatim in upstream's pkg under Apple's id.
- bundle-id:swift-build.*: SwiftPM's SwiftBuild_*.bundle resource bundles, verbatim in upstream's pkg (6.4 renamed their ids from `SwiftBuild.*`).
- bundle-id:swiftpm.*: SwiftPM's own SwiftPM_*.bundle resource bundles (SBOMModel), verbatim in upstream's pkg.
- bundle-id:swift-crypto.*: SwiftPM's swift-crypto_*.bundle resource bundles, verbatim in upstream's pkg.
- sdk-pin:Library/Developer/Toolchains/swift-*.xctoolchain/*: swift.org's own installer, mirrored verbatim and never recompiled or re-signed by us, so its binaries record whatever SDK and floor swift.org built them against (the same scope as the install-path and bundle-id deviations above)
