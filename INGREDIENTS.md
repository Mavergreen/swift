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
| Swift release (own upstream) | `SWIFT_VERSION` + `SWIFT_SHA` + `SWIFT_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/swift`, grouped with llvm-project; minor/major held for a human (below); the tarball's SHA-256 is written on the PR's branch by the pins bot (below) | auto-cuts `<upstream>-mavericks.1` on the push to main |
| swiftlang/llvm-project commit | `LLVM_SWIFT_RELEASE` + `LLVM_SHA` + `LLVM_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/llvm-project`, in the same "Swift release" PR; the SHA-256 as for Swift | moves only WITH the Swift pin: `build-llvm.sh` fails unless `LLVM_SWIFT_RELEASE` equals `SWIFT_VERSION` and `LLVM_SHA` is llvm-project's `swift-<SWIFT_VERSION>-RELEASE` |
| swiftlang/swift-cmark commit | `CMARK_SWIFT_RELEASE` + `CMARK_SHA` + `CMARK_TARBALL_SHA256` in `pins.env` | ✅ `github-tags` on `swiftlang/swift-cmark`, in the same "Swift release" PR; the SHA-256 as for Swift | moves only WITH the Swift pin: `build-toolchain.sh` runs `check_release_pin` on it |
| mavericks-clang-22 cross toolchain (compiles the 10.9-hosted toolchain and compiler-rt's builtins, and its `llvm-libtool-darwin`, `llvm-ar`, `llvm-ranlib` and `llvm-lipo` make their archives; on OS X 10.9, `self-host.sh` uses the native package of the same release) | `CLANG22_VERSION` in `pins.env` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | auto-repackages `-mavericks.(N+1)` |
| libcxx22, the family's shared libc++ (the stdlib's C++ compiles against the pinned clang22's libc++ headers and links libcxx22's `libc++.1.dylib`; the runtime and native toolchain pkgs require it at install) | `CLANG22_VERSION` in `pins.env`: one clang-22 release publishes clang22, clang22-cross and libcxx22 under one version | ✅ with the clang22 pin (`github-releases` on `Mavergreen/clang-22`) | auto-repackages `-mavericks.(N+1)`, and the pkgs then require that libcxx22 or later |
| Recaulk, the family's back-fills of post-10.9 OS APIs (libswiftCore links Recaulk's definitions of the APIs `build.sh`'s `RECAULK_RUNTIME_SYMBOLS` names, and only those, statically: below) | `RECAULK_VERSION` in `pins.env` | ✅ `github-releases` on `Mavergreen/recaulk`, `YYYYMMDD.N` versioning | auto-repackages `-mavericks.(N+1)`; nothing is required at install, since the link is static |
| LLVM and compiler source patches (`patches/llvm/`, `patches/compiler/`) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| swift.org toolchain `.pkg` (CI's one seed: it compiles the cross toolchain's Swift half, and a first stdlib that only makes that toolchain runnable; everything the release ships is compiled by this repo's own compilers, below) | `TOOLCHAIN_URL`, derived from `SWIFT_VERSION` | ✅ moves with the Swift pin | verified by **signer identity**, not a hash (below) |
| Runtime source patches (`patches/runtime/`) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
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
Recaulk's definition instead of carrying a patch of its own: today `os_system_version_get_current_version`
(macOS 10.12), which runtime patch 0002 used to guard with a CoreFoundation plist read. Recaulk's
definition is a forwarder: where the OS has the function, it calls the OS's; on 10.9, Recaulk's body,
which reads SystemVersion.plist. Upstream's own failure value stays (0.0.0, never a guessed 10.9.0):
`#available` does not go through it, compiler-rt's `__isPlatformVersionAtLeast` in each binary does, and
only `_swift_stdlib_operatingSystemVersion`, an ABI entry point kept for old binaries, calls it
(`tests/availability_test.swift` holds both to 10.9.5 on 10.9.5).

`build.sh` links a subset of `librecaulk.a`, never the whole archive, which would bind six of
libswiftCore's weak imports where it means one: the runtime reads a weak import's presence as "the OS has
this", so `os_signpost_enabled` would turn its tracing on and then call the `os_log_create` and
`os_signpost_id_generate` no 10.9 has, and `objc_readClassPair` and `_objc_realizeClassFromSwift` would
flip the realization paths patches 0003 and 0005 choose by. `lib.sh`'s `recaulk_subset` picks, by symbol,
the members that define each name in `RECAULK_RUNTIME_SYMBOLS` and what they need from the archive, and
refuses a member that defines any other API; the link hides every global they define
(`-unexported_symbols_list`), so libswiftCore exports what it did before. Step 7 refuses a runtime that
still imports a Recaulk-supplied API, does not define it, exports it or any `___recaulk_` name, or no
longer weak-imports the APIs whose presence the runtime reads from the OS. The archive's SHA-256 is one of
the stdlib build's stamped inputs, so a Recaulk bump starts that build afresh. Recaulk's notice is in
`NOTICE`.

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

## Why a minor or major Swift bump waits for a human

The runtime patches are cut against specific stdlib and runtime internals, so a bump that happens to
build proves nothing about the 10.9 behaviour a macOS 26 runner cannot see. The exit condition is CI
that runs the real-10.9 gate (the umbrella's track E, once `Mavergreen/vm-guest` can boot a 10.9 image
in GitHub Actions); then a bump whose patches apply and whose gate passes automerges.

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
each is scoped to the artifact it concerns: the first three to the stdlib dylibs (the runtime pkg's,
and the same bytes in both toolchain pkgs), the next to the cross toolchain pkg's install floor, the
next ones to the swift.org mirror attached to `-mavericks.1` releases, and the two `rosetta` entries,
last, to CI's native-toolchain smoke.

- sdk-pin:*/swift-runtime/lib/swift/*.dylib: the Swift runtime cannot be built against the 10.9 SDK, which has no libc++ headers at all (only libstdc++ 4.2.1) while Swift 6.4 requires C++17, and which lacks declarations of post-10.9 APIs the runtime calls behind availability checks. Its build uses a modern SDK, pinned: MacOSX11.3.sdk, shipyard's arm64 pin (`fetch_sdk.sh --arch arm64`), the same in CI and on 10.9, so a runtime built on 10.9 is byte-identical to CI's. It records sdk 11.3; its libc++ is libcxx22's, not the SDK's ("One C++ runtime", above). minos stays 10.9, and the real-10.9 gate is its acceptance. Revisit if the gate gains per-product pins.
- sdk-pin:*/swift-toolchain/lib/swift/macosx/*.dylib: the toolchain's stdlib dylibs are the runtime's own bytes, staged from the one stdlib build (scripts/stage-toolchain.sh), so the runtime's reason above applies verbatim. The compiler, lld and clang beside them record the pinned 10.9 SDK and take no exemption.
- sdk-pin:*/swift-toolchain-cross/lib/swift/macosx/*.dylib: the cross toolchain's stdlib dylibs are the runtime's own bytes too: CI's build-cross job builds the one stdlib, with that cross toolchain, and stages it into all three pkgs, and collect refuses a release whose two toolchains' stdlib and builtins trees differ in a byte, so the runtime's reason above applies verbatim. The compiler, lld and clang beside them are arm64 and record the family's arm64 pin (minOS 11.0, SDK 11.3) and take no exemption.
- floor:swift-toolchain-cross-*.pkg: the cross toolchain runs on an Apple-silicon Mac with macOS 11 or later and only targets 10.9, so its archive's install floor is 11.0 (arm64), not 10.9.5; clang22-cross and rust-cross declare the same.
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
- rosetta:tests/toolchain-smoke-test.sh: runs the STAGED toolchain's shipped x86_64 swift-frontend and ld64.lld, behind its bin/swiftc, to compile and link a hello world and the gate corpus (make-selftest.sh's SWIFTC= mode), and checks what they record: minOS 10.9, SDK 10.9, and the runtime's rpath alone. Only compiling and linking run translated; nothing built is run. It runs a copy of the staged prefix whose swift-frontend takes the OS's Swift runtime (`/usr/lib/swift`) instead of the bundled 10.9 one: a modern macOS loads its own Swift runtime into every process through CoreFoundation, Security and CoreServices, and two Swift runtimes in one frontend crash it (CI run 36297440367); what it compiles and links against is unchanged, and the compiler running on its bundled runtime stays the 10.9 gate's to prove. It SKIPs (77) when nothing is staged or when this host cannot run x86_64 code (`arch -x86_64 /usr/bin/true`). It cannot be native yet: the product is x86_64, and the release runner (and a maintainer's Apple Silicon Mac) is arm64, with no Intel runner to use instead; native 10.9 users run the toolchain natively. Reconsider when CI can run the real 10.9 gate (the umbrella's track E, `Mavergreen/vm-guest`), which builds the corpus on 10.9 itself; at the latest before macOS 28 removes Rosetta.
- rosetta:.github/workflows/release.yml: the build job primes Rosetta ("Ensure this runner can run x86_64 (Rosetta)") and runs tests/toolchain-smoke-test.sh, which executes the shipped x86_64 swift-frontend and ld64.lld translated, compiling and linking only; the step fails when the smoke SKIPs, so a runner that lost Rosetta is loud rather than a green build that never ran the compiler it ships. It cannot be native yet: the release runner is arm64 and the product is x86_64. Reconsider when CI can run the real 10.9 gate (the umbrella's track E, `Mavergreen/vm-guest`); at the latest before macOS 28 removes Rosetta.
