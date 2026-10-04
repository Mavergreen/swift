# Developing Swift for Mavericks

How this repo builds what it ships, and how to build it yourself: on OS X 10.9, where the runtime and
the toolchain both build natively, and on an Apple-silicon Mac. [README.md](README.md) is for people who
install the packages.

## How a release is built

One pin (`pins.env`), three packages: the runtime, the toolchain that runs on 10.9, and the cross
toolchain that runs on an Apple-silicon Mac. CI (`.github/workflows/release.yml`) builds them in two
jobs, one after the other:

1. `build-cross`: the swift.org compiler of the pinned release compiles the cross toolchain's Swift half.
   That is CI's one seed. The cross toolchain then builds the standard library and the runtime, once,
   for all three packages.
2. `build`: the same run's cross toolchain compiles the 10.9 toolchain's Swift half. Its C++ half is
   compiled by mavericks-clang-22. Its standard library and builtins are the cross package's own bytes.

CI never builds with an earlier Mavergreen release. On OS X 10.9, `self-host.sh` rebuilds the 10.9
toolchain with the previous release, the only Swift compiler that runs there. The two chains share no
seed, so a 10.9 rebuild that is the release's bytes shows that neither seed changed what it built.

Two builds of one source agree only when nothing of the machine that built them reaches the output.
Each of these pins removes one such difference:

- the same mavericks-clang-22 release on both hosts: its cross package in CI, its native package on
  10.9;
- its `llvm-libtool-darwin`, `llvm-ar`, `llvm-ranlib` and `llvm-lipo` make every archive. Apple's tools
  differ between 10.9 and a modern Mac, and an archive's symbol table orders what lld writes;
- the 10.9 SDK in its original stub form (`lib.sh`'s `sdk109_stubs`). shipyard's `fetch_sdk.sh` converts
  the stubs to `.tbd` on a modern Mac but not on 10.9, and lld orders the two forms' symbols differently;
- the pinned MacOSX11.3.sdk for the compiler's Swift half and for the standard library;
- clang's host linker version, `HOST_LINK_VERSION=241.9` (10.9's ld64), and its default linker, the
  `ld64.lld` beside it;
- the build root, mapped to `/mavergreen-build` in every compile.

## Developing on OS X 10.9

The runtime and the toolchain build on a 10.9 Mac from this checkout, and the results are byte-identical
to what CI builds from the same commit. The build scripts run the same recipe on both hosts and pick
their inputs by host (shipyard's `mavericks_mode.sh`).

Once, install:

- Command Line Tools for Xcode 6.2, the last for 10.9. The build runs `otool`, `strings`, `xcrun` and
  10.9's own `git`, which without them are stubs that offer to install them;
- the toolchain package of the newest release of the Swift version in `pins.env` (`SWIFT_VERSION`). For
  6.4.0 that is the newest `6.4.0-mavericks.N`. `build.sh` prints the release it builds with, and refuses
  one of another Swift version. The same release's runtime package runs the programs its `swiftc`
  builds; the gate below needs none;
- mavericks-clang-22's native package, the release `pins.env`'s `CLANG22_VERSION` names (it compiles LLVM,
  clang, lld and compiler-rt's builtins; `self-host.sh` refuses any other release's receipt);
- the shipyard package (`shipyard-cmake`).

pkgsrc supplies `python3` (gyb, line-directive, LLVM's CMake), `ninja`, and a `git` newer than 10.9's
own. The newer `git` is needed only while `~/.gitconfig` uses options that 10.9's git 1.9.5 rejects. CMake
picks gyb's python, and `build.sh` names it; 3.13 on 10.9, 3.14 in CI and 3.9 on a modern Mac have built
the same runtime.

Run everything in a Terminal window (a login shell, so `/usr/local/mavergreen/bin` is on `PATH`), from
the checkout, with the build root on local disk:

```sh
export MAVERICKS_BUILD_ROOT="$HOME/mm-build"   # not /tmp (a reboot wipes it), not the checkout; no spaces
```

### The runtime

```sh
./build-llvm.sh     # LLVM build support and lld, with clang-22: about 28 min the first time
./build.sh          # the runtime, with the installed toolchain: about 5 min
S="$MAVERICKS_BUILD_ROOT/swift"; R="$S/payload/runtime/usr/local/mavergreen/swift-runtime"
SWIFTC=/usr/local/mavergreen/bin/swiftc SWIFT_RUNTIME_PREFIX="$R" DIST="$S/dist" sh make-selftest.sh
( cd "$S/dist" && tar -xzf swift-runtime-selftest.tar.gz && SWIFT_RUNTIME_PREFIX="$R" sh swift-runtime-selftest/run-selftest.sh --gate )
```

From nothing to a gated runtime takes about 35 minutes on a 6-core Mac Pro. `build-llvm.sh` is the long
one-time step; each later runtime build takes about 5 minutes. The first runs also fetch the two SDKs and
clone llvm-project and swift.

`build.sh` resets its swift checkout to the pin and applies `patches/runtime/` on every run, so a change
to the runtime is a patch there. A new patch also needs its number in `build.sh`'s `RUNTIME_PATCHES` and
a marker grep after the list (`build.sh` refuses a patch file the list lacks). After adding one, rerun
`./build.sh` and the last three commands.

A reused build root keeps CMake's cached probe results across a rebuild. `build.sh` starts
`$MAVERICKS_BUILD_ROOT/swift/work/stdlib-build` afresh by itself when the host compiler, its clang, the
`clang.cfg` beside it or the builtins archive changed (a toolchain update, say). After changing any other
compiler or linker setting, remove that directory first, so `build.sh` reconfigures from scratch. The
self-test binaries load the runtime just built, not the installed one (`DYLD_PRINT_LIBRARIES=1` shows
it). `--gate` runs each 500 times, then 10 more under Guard Malloc.

### The toolchain: self-hosting

```sh
./self-host.sh
```

`self-host.sh` rebuilds this checkout's toolchain three times over, and checks that the third build is
the second one, file for file:

- **Seed:** the installed toolchain, `/usr/local/mavergreen/swift-toolchain` (the previous release), or
  the toolchain `SWIFT_HOST_TOOLCHAIN` names.
- **Once:** `build-llvm.sh`, and compiler-rt's builtins (`build-builtins.sh`).
- **Stage 1:** LLVM, clang, lld, cmark and the compiler's C++ half (`build-toolchain.sh`), which do not
  depend on the seed. The compiler's Swift half is compiled by the seed. The new compiler then builds its
  own standard library and runtime (`build.sh`), and the stage's toolchain is staged with them.
- **Stages 2 and 3:** the same build dirs. Each stage reconfigures the compiler for its new host (the
  previous stage), recompiles only the Swift half, and builds and stages again.
- **The fixed point:** stage 2's and stage 3's toolchains are the same files (the compiler, clang, lld,
  the standard library, the builtins archive, the helpers' outputs). `self-host.sh` checks only that stage 2
  equals stage 3. Seeded by the same release, stage 1 is expected to equal them too, as it did in the T4 runs, but
  nothing checks it. Stage 3 is what makes the check independent of the seed.

The stages land in `$MAVERICKS_BUILD_ROOT/swift/self-host/s<N>/` (`toolchain/`, the package's payload,
and `runtime/`). `self-host.sh` prints the gate's commands at the end: the self-test bundle built by
stage 2's `swiftc`, run against stage 2's runtime.

Budget on a 6-core Mac Pro (Xeon E5-1650 v2, 12 threads), from nothing:

| step | wall time |
|---|---|
| `build-llvm.sh` (first time) | 28 min |
| builtins | 1 min |
| stage 1: LLVM, clang and lld | 60 min |
| stage 1: the compiler (C++ half, then Swift half) | 45 min |
| each stage's standard library and runtime | 5 min |
| stages 2 and 3: the compiler's Swift half | 7 min and 6 min |
| in all | about 2 h 50 min |

It needs about 10 GB under the build root, and 1 GB more for the two SDKs (fetched once into
`~/Library/Caches/mavericks-sdk`). A later run reuses LLVM, clang, lld and the compiler's C++ half,
and takes about 40 minutes.

Since the seed must compile this checkout's compiler, a seed of an earlier Swift release (6.4 building
6.5) is untested until the next Swift bump.

### Verifying a release

To check, on your own 10.9 Mac, that the installed release is what its source builds, first install the
mavericks-clang-22 release that tag's `pins.env` names as `CLANG22_VERSION` (`self-host.sh` fails when the
installed one differs):

```sh
V="$(pkgutil --pkg-info dev.mavergreen.swift-toolchain | sed -n 's/^version: //p')"   # the installed release
git checkout "$V"                 # its tag (afterwards, `git checkout -` returns to your branch)
./self-host.sh --compare /usr/local/mavergreen/swift-toolchain
```

`SAME: /usr/local/mavergreen/swift-toolchain is what this checkout builds` means that the release's
compiler, clang, lld, standard library, builtins archive and helper outputs are the bytes this Mac built
from the release's source. The same release's runtime package carries those same `libswiftCore.dylib` and
`libswiftSwiftOnoneSupport.dylib` (the toolchain's `lib/swift/macosx` holds them too), and `cmp` shows that
this Mac built them (install that release's runtime package first):

```sh
S="$MAVERICKS_BUILD_ROOT/swift/self-host/s2/runtime/usr/local/mavergreen/swift-runtime/lib/swift"
for f in libswiftCore.dylib libswiftSwiftOnoneSupport.dylib; do cmp "$S/$f" "/usr/local/mavergreen/swift-runtime/lib/swift/$f" && echo "same: $f"; done
```

## Building on an Apple-silicon Mac

The same scripts, in CI's order (`.github/workflows/release.yml`), with `MAVERICKS_BUILD_ROOT` on local
disk:

```sh
./build-llvm.sh && ./mirror-toolchain.sh && ./build-builtins.sh
./build.sh                                   # a first stdlib, with the swift.org compiler
./build-toolchain.sh --host arm64            # the cross toolchain
S="$MAVERICKS_BUILD_ROOT/swift"; X=usr/local/mavergreen/swift-toolchain-cross
STAGE_HOST=arm64 sh scripts/stage-toolchain.sh "$S/payload/toolchain-cross-seed"
V="$(. ./pins.env && echo "$SWIFT_VERSION")-local"    # the release a toolchain no pkg installed declares
SWIFT_HOST_TOOLCHAIN="$S/payload/toolchain-cross-seed/$X" SWIFT_HOST_TOOLCHAIN_VERSION="$V" ./build.sh   # the stdlib, with the cross toolchain
STAGE_HOST=arm64 sh scripts/stage-toolchain.sh "$S/payload/toolchain-cross"
SWIFT_HOST_TOOLCHAIN="$S/payload/toolchain-cross/$X" ./build-toolchain.sh                                            # the 10.9 toolchain
sh scripts/stage-toolchain.sh --stdlib "$S/payload/toolchain-cross/$X/lib/swift" \
  --builtins "$(ls "$S/payload/toolchain-cross/$X"/lib/clang/*/lib/darwin/libclang_rt.osx.a)" "$S/payload/toolchain"
```

`build.sh` holds a host toolchain to this checkout's Swift: `SWIFT_HOST_TOOLCHAIN_VERSION` declares the
release of one no package installed. The 10.9 toolchain cannot run on a modern Mac (its compiler loads
its own 10.9 runtime beside the OS's, and crashes), so it is tested on 10.9, and CI runs only a
translated smoke of it (`tests/toolchain-smoke-test.sh`).
