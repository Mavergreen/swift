# Build ingredients

Everything baked into what this repo publishes, and how a change to it reaches a release. An
*ingredient* is an input to the product; the *own upstream* is the thing this repo ports: Swift.

This one repo builds every Swift artifact for Mavericks from one pin — the runtime `.pkg` today, the
native and cross toolchain `.pkg`s as they land. `Mavergreen/swift-toolchain`, which used to publish
the LLVM build support this repo consumed, was merged in and archived (2026-09).

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Swift release (own upstream) | `SWIFT_VERSION` + `SWIFT_SHA` in `pins.env` | ✅ `github-tags` on `swiftlang/swift`, grouped with llvm-project; minor/major held for a human (below) | auto-cuts `<upstream>-mavericks.1` on the push to main |
| swiftlang/llvm-project commit | `LLVM_SWIFT_RELEASE` + `LLVM_SHA` in `pins.env` | ✅ `github-tags` on `swiftlang/llvm-project`, in the same "Swift release" PR | moves only WITH the Swift pin: `build-llvm.sh` fails unless `LLVM_SWIFT_RELEASE` equals `SWIFT_VERSION` and `LLVM_SHA` is llvm-project's `swift-<SWIFT_VERSION>-RELEASE` |
| swiftlang/swift-cmark commit | `CMARK_SWIFT_RELEASE` + `CMARK_SHA` in `pins.env` | ✅ `github-tags` on `swiftlang/swift-cmark`, in the same "Swift release" PR | moves only WITH the Swift pin: `build-toolchain.sh` runs `check_release_pin` on it |
| mavericks-clang-22 cross toolchain (compiles the 10.9-hosted toolchain) | `CLANG22_VERSION` in `pins.env` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | auto-repackages `-mavericks.(N+1)` |
| LLVM and compiler source patches (`patches/llvm/`, `patches/compiler/`) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| swift.org toolchain `.pkg` (the host compiler that builds the stdlib) | `TOOLCHAIN_URL`, derived from `SWIFT_VERSION` | ✅ moves with the Swift pin | verified by **signer identity**, not a hash (below) |
| Runtime source patches (`patches/runtime/`) | this repo | n/a | auto-repackages `-mavericks.(N+1)`: they change what ships |
| Sparkle framework, MacOSX10.9 SDK | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a moving tag; nothing auto-repackages |

## How a bump reaches a release

- **`SWIFT_VERSION` moved** → a new upstream. `version.sh` reports `RELEASE=yes` because that upstream
  has no tag yet, so the push to main auto-cuts `-mavericks.1`.
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
each is scoped to the artifact it concerns: the first two to the stdlib dylibs (the runtime pkg's,
and the same bytes in the toolchain pkg), the rest to the swift.org mirror attached to
`-mavericks.1` releases.

- sdk-pin:*/swift-runtime/lib/swift/*.dylib: the Swift runtime cannot be built against the 10.9 SDK, which has no libc++ headers at all (only libstdc++ 4.2.1) while Swift 6.4 requires C++17, and which lacks declarations of post-10.9 APIs the runtime calls behind availability checks. Its build uses a modern SDK: today the CI runner's Xcode SDK, unpinned; the swift T2 decision (2026-09-25) replaces that with one pinned modern SDK used by CI and on 10.9. minos stays 10.9, and the real-10.9 gate is its acceptance. Revisit if the gate gains per-product pins.
- sdk-pin:*/swift-toolchain/lib/swift/macosx/*.dylib: the toolchain's stdlib dylibs are the runtime's own bytes, staged from the one stdlib build (scripts/stage-toolchain.sh), so the runtime's reason above applies verbatim. The compiler, lld and clang beside them record the pinned 10.9 SDK and take no exemption.
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
