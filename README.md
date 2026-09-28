# swift

**Swift for OS X 10.9 "Mavericks"** (Intel x86_64), built from source. Every release ships the
**Swift runtime**, a **Swift toolchain that runs on 10.9**, and a **cross toolchain that runs on an
Apple-silicon Mac** and builds the same programs for 10.9.

Modern Swift (6.x) assumes an Objective-C runtime and Swift ABI machinery that first shipped in
macOS 10.14.4. This repo builds `libswiftCore` from unmodified
[swiftlang/swift](https://github.com/swiftlang/swift) sources with a **10.9 deployment target**,
plus a small set of source patches that make Swift's class-realization path work on 10.9's
objc4-532 runtime. The result is **memory-safe on real hardware**: the validation test runs
**510/510 consecutive** clean on macOS 10.9.5, verified under Guard Malloc and MallocScribble.

## What works

A memory-safe Swift **core runtime**: strings, arrays, dictionaries, sets, closures, generics,
existentials/protocol witnesses, ARC (incl. `weak`/`unowned`), class hierarchies, `NSObject`
subclasses, runtime-instantiated generic classes (the storage behind `Dictionary`/`Set`/`String`),
and `if #available`. Enough for **command-line / computational Swift**.

## Scope / bounds — read before using

- **Programs for Intel x86_64, OS X 10.9 only.** The cross toolchain runs on an Apple-silicon Mac;
  what it builds runs on 10.9.
- **Core runtime only.** Ships `libswiftCore` (+ `libswiftSwiftOnoneSupport` for `-Onone`). The
  Foundation / AppKit *overlays* — needed for most apps, and for GUI — are later roadmap increments.
- **Framework ceiling untouched.** Swift running does not bring back APIs absent from 10.9 (modern
  WKWebView, CryptoKit, Network.framework, …). Those are separate work.
- **Compile on the 10.9 Mac** with the toolchain package, or on an Apple-silicon Mac with the cross
  toolchain package (both below); on an Intel Mac with a modern macOS, with the swift.org toolchain
  (Install). None has macros, Swift Concurrency or the Darwin/ObjectiveC overlays yet.
- Running on an OS with no security updates is your own risk.

## Install

```sh
sudo installer -pkg swift-runtime-<version>.pkg -target /
```
Installs the runtime into `/usr/local/mavergreen/swift-runtime/lib/swift/` and its license into
`/usr/local/mavergreen/swift-runtime/share/doc/`. A program finds the runtime through an rpath
naming that directory.

**Building a program for 10.9 on an Intel Mac with a modern macOS.** (On an Apple-silicon Mac, use the
cross toolchain package, below.) Use the swift.org toolchain of the Swift release this runtime is
built from, with the SDK `xcrun` finds.
`swiftc` adds an rpath of `/usr/lib/swift`; replace it with the runtime's:
```sh
<swift.org toolchain>/usr/bin/swiftc -sdk "$(xcrun --show-sdk-path)" \
  -target x86_64-apple-macosx10.9 -O -no-stdlib-rpath \
  -Xlinker -rpath -Xlinker /usr/local/mavergreen/swift-runtime/lib/swift hello.swift -o hello
```
The binary's only rpath is the runtime's directory, so it runs on the 10.9 Mac, not on the one that
built it: copy `hello` to the 10.9 Mac and run `./hello` there.

**A prebuilt Swift binary** that expects the runtime in `/usr/lib/swift` needs one
[Drydock](https://github.com/Mavergreen/drydock) statement, usually beside others it already needs to
run on 10.9:
```
rpath replace /usr/lib/swift /usr/local/mavergreen/swift-runtime/lib/swift
```

## The toolchain: `swiftc` on 10.9

```sh
sudo installer -pkg swift-runtime-<version>.pkg -target /
sudo installer -pkg swift-toolchain-<version>.pkg -target /
```
Installs `swiftc`, the standard library, `ld64.lld` and a matching `clang` into
`/usr/local/mavergreen/swift-toolchain/`, and puts `swiftc` on the `PATH` of new Terminal windows
(through `/usr/local/mavergreen/bin`). Then, on the 10.9 Mac itself:
```sh
swiftc hello.swift -o hello && ./hello
```
`swiftc` supplies the 10.9 target, the SDK (fetched into `~/Library/Caches/mavericks-sdk` on first
use; `$SDKROOT` overrides it), its own linker and the runtime's rpath. Your arguments come after
those, so yours win. Programs it builds need only the runtime package. Not yet: macros, Swift
Concurrency, the Darwin and ObjectiveC overlays (`import Darwin` works, through the SDK's C module).

## The cross toolchain: `swiftc` on an Apple-silicon Mac

```sh
sudo installer -pkg swift-toolchain-cross-<version>.pkg -target /
```
Installs the same compiler, standard library, `ld64.lld` and `clang`, built to run on an Apple-silicon
Mac with macOS 11 or later, into `/usr/local/mavergreen/swift-toolchain-cross/`. New Terminal windows
find `swiftc-cross` on their `PATH`, and `swiftc` as well (see below). It builds for OS X 10.9 by
default, with the 10.9 toolchain's defaults, so the same Swift source compiled by either is the same
program, byte for byte (C too, when both link against the same SDK bytes: the 10.9 SDK fetched on a
modern Mac is converted to `.tbd` stubs, which can reorder a C program's imports):
```sh
swiftc hello.swift -o hello    # an x86_64 program for OS X 10.9
```
Copy `hello` to a 10.9 Mac with the runtime package from the same release, and run it there; it does
not run on the Mac that built it. The first compile fetches the 10.9 SDK into
`~/Library/Caches/mavericks-sdk`. Its `clang` builds for 10.9 too, with no flags; to link, name the SDK
and the toolchain's linker:
```sh
SDK="$(sh /usr/local/mavergreen/swift-toolchain-cross/libexec/mavergreen-swift/fetch_sdk.sh)"
/usr/local/mavergreen/swift-toolchain-cross/bin/clang -isysroot "$SDK" -fuse-ld=lld hello.c -o hello
```
The two toolchain packages share the name `swiftc`: the one installed first owns it. The 10.9
toolchain's compiler does not run on a modern macOS, so if that package was installed on this Mac
first, `swiftc-cross` still works, and `mavergreen select swift swift-toolchain-cross` gives `swiftc`
to the cross toolchain. An Intel Mac with a modern macOS has neither yet: the cross package is for
Apple silicon, and the 10.9 one's compiler does not run there (use the swift.org route under Install).

## Developing on OS X 10.9

The runtime builds on a 10.9 Mac from this checkout, with the toolchain package, and the result is
byte-identical to the runtime CI builds from the same commit: `build-llvm.sh` and `build.sh` run one
recipe on both, picking their inputs by host (shipyard's `mavericks_mode.sh`). So the runtime is
developed there: edit, build, gate.

Once, install:
- Command Line Tools for Xcode 6.2, the last for 10.9: the build runs `otool`, `strings`, `xcrun` and
  10.9's own `git`, which without them are stubs that offer to install them;
- the toolchain package of the newest release of the Swift version in `pins.env` (`SWIFT_VERSION`
  6.4.0: the newest `6.4.0-mavericks.N`; from `.7` on, it carries the builtins archive the build
  links). `build.sh` prints the release it builds with, and refuses one of another Swift version. The
  same release's runtime package runs the programs its `swiftc` builds; the gate below needs none;
- mavericks-clang-22's native package (it compiles LLVM's TableGen and lld);
- the shipyard package (`shipyard-cmake`).

pkgsrc supplies `python3` (gyb, line-directive, LLVM's CMake), `ninja`, and a `git` newer than 10.9's
own — needed only while `~/.gitconfig` uses options 10.9's git 1.9.5 rejects. CMake picks gyb's python,
and `build.sh` names it; 3.13 on 10.9, 3.14 in CI and 3.9 on a modern Mac have built the same runtime.
Then, in a Terminal window (a login shell, so `/usr/local/mavergreen/bin` is on `PATH`), from the
checkout:
```sh
export MAVERICKS_BUILD_ROOT="$HOME/mm-build"   # local disk: not /tmp (a reboot wipes it), not the checkout; no spaces
./build-llvm.sh     # LLVM build support and lld, with clang-22: about 28 min the first time
./build.sh          # the runtime, with the installed toolchain: about 5 min
S="$MAVERICKS_BUILD_ROOT/swift"; R="$S/payload/runtime/usr/local/mavergreen/swift-runtime"
SWIFTC=/usr/local/mavergreen/bin/swiftc SWIFT_RUNTIME_PREFIX="$R" DIST="$S/dist" sh make-selftest.sh
( cd "$S/dist" && tar -xzf swift-runtime-selftest.tar.gz && SWIFT_RUNTIME_PREFIX="$R" sh swift-runtime-selftest/run-selftest.sh --gate )
```
From nothing to a gated runtime takes about 35 minutes on a 6-core Mac Pro: `build-llvm.sh` is the
long one-time step, now also building lld; each later runtime build is about 5 minutes. The first runs
also fetch the two SDKs and clone llvm-project and swift. `build.sh` resets its swift checkout to the
pin and applies `patches/runtime/` every run, so a change to the runtime is a patch there. A new patch
also needs its number in `build.sh`'s `RUNTIME_PATCHES` and a marker grep after the list (`build.sh`
refuses a patch file the list lacks). After one, rerun `./build.sh` and the last three commands. A
reused build root keeps CMake's cached probe results across a rebuild. `build.sh` starts
`$MAVERICKS_BUILD_ROOT/swift/work/stdlib-build` afresh by itself when the host compiler, its clang or
the builtins archive changed (a toolchain update, say); after changing any other compiler or linker
setting, remove that directory first, so `build.sh` reconfigures from scratch. The
self-test binaries load the runtime just built, not the installed one (`DYLD_PRINT_LIBRARIES=1` shows
it). `--gate` runs each 500 times, then 10 more under Guard Malloc.

## How it's built

On a modern macOS, in order: `./build-llvm.sh` (swiftlang's LLVM build support: TableGen and the
CMake package, and the `ld64.lld` that links the runtime), `./mirror-toolchain.sh` (the pinned
swift.org compiler, verified by its signer), `./build-builtins.sh` (compiler-rt's builtins for 10.9,
with mavericks-clang-22's cross compiler), `./build.sh` (the standard library only, against the pinned
MacOSX11.3.sdk, with `patches/runtime/` applied, then its own self pre-flight), `./package.sh`; then,
for the toolchain, `./build-toolchain.sh` (LLVM, clang and
lld for an x86_64/10.9 host with mavericks-clang-22's cross compiler, cmark, and `swift-frontend`, with
`patches/llvm/` and `patches/compiler/`), `sh scripts/stage-toolchain.sh "$SWIFT_BUILD/payload/toolchain"`,
`./package-toolchain.sh`; and for the cross toolchain, `./build-toolchain.sh --host arm64` (the same
LLVM, clang, lld and `swift-frontend` for an arm64 / macOS 11 host, with Apple's clang and the pinned
MacOSX11.3.sdk, and nothing cross-compiled), `STAGE_HOST=arm64 sh scripts/stage-toolchain.sh
"$SWIFT_BUILD/payload/toolchain-cross"`, `STAGE_HOST=arm64 ./package-toolchain.sh`. CI runs the compat
guard (`scripts/guard.sh`) after each build, builds the two toolchains in parallel jobs, and refuses a
release whose two toolchains' standard library or builtins archive differ by a byte.
Every source, tool and compiler input is pinned in `pins.env`, and both SDKs in shipyard (see
`INGREDIENTS.md`). CI does the same on a `macos-26` runner and attaches the `.pkg`s to a GitHub
Release (see `.github/workflows/release.yml`). The same `build-llvm.sh` and `build.sh` also run on
OS X 10.9 (below), and build the same bytes.

### The fix stack (all confirmed on real 10.9.5)

1. **Threading** — `SWIFT_THREADING_PACKAGE="OSX:pthreads"` removes `os_unfair_lock` (10.12).
2. **`-fno-sized-deallocation`** — 10.9's libc++ lacks the C++14 sized `operator delete`.
3. **`os_system_version` guard** — guarded + CoreFoundation `SystemVersion.plist` fallback, so
   `if #available` works on 10.9.
4. **`objc_readClassPair` guard + minimal in-place realization** — 10.9's objc lacks the 10.11 SPI;
   the runtime realizes runtime-instantiated generic classes itself, in objc4-532's layout.
5. **Realization-aware `getROData`** — follow `rw->ro` when `RW_REALIZED` (objc-532 realizes
   eagerly at image load, so the class's `Data` word is the `rw`, not the `ro`).
6. **objc-super instance-size fix** — size subclasses from `class_getInstanceSize(super)` on 10.9,
   where objc-532 drops the Swift is-swift bit and the normal path under-sizes them.

All gated to the pre-`objc_readClassPair` (10.9/10.10) runtime; the modern-OS code path is
byte-unchanged.

One more patch serves equivalence rather than 10.9: `0008` drops `ObjectIdentifier`'s LLDB type
summary, whose `@DebugDescription` macro the 10.9-hosted toolchain cannot expand, and keeps a `String`
fast path that the same missing macro support would compile out. So a runtime built on 10.9 is the
one CI builds.

## Validation

The gate is on **real 10.9.5** (a modern host is structurally blind to these bugs):
`./make-selftest.sh` builds `tests/*.swift` at `-O` and `-Onone` into a bundle, and on the 10.9 box
`./run-selftest.sh --gate` requires 500 consecutive clean exits per binary, then 10 more under Guard
Malloc + MallocScribble + MallocGuardEdges, with no DYLD variables otherwise.

## Licensing

Swift is **Apache License 2.0 with the Runtime Library Exception** (see `LICENSE`). `swift`
builds that source and redistributes the resulting binary under those terms — the runtime `.pkg`
contains only binaries built here from source (no Apple prebuilt runtime, SDK, or framework).
Separately, each new upstream's first release (`-mavericks.1`) also attaches the official swift.org
toolchain installer, mirrored byte-for-byte and unmodified (`upstream-swift-*-RELEASE-osx.pkg`),
which contains upstream's prebuilt binaries under their own licenses. See `NOTICE` for attribution
and the list of local patches. This repo's own glue (scripts, packaging) is under the same license.

## Provenance

Each release's notes list the pinned build ingredients and the local patches, generated from
`pins.env` and `patches/` by shipyard's release-notes generator. `INGREDIENTS.md` explains each pin.
No Apple bytes are committed here.
