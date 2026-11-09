# Swift for Mavericks

Swift runtime and toolchain for Mac OS X 10.9 Mavericks.

## Runtime

Included: strings, collections, closures, generics, protocols, classes, ARC, `if #available`, and the
`Darwin` and `ObjectiveC` runtime libraries.

Not yet included: Foundation, AppKit, Macros, Concurrency.

The runtime package carries only the libraries, which run programs already built. To compile a program
that does `import Darwin` or `import ObjectiveC`, install a toolchain package: the modules ship there.

`import Darwin` gives the C library as Swift sees it: `errno`, `getenv`, `exit`, the math functions,
`stat`, `open` and the rest of the C headers in the 10.9 SDK, with Swift's `Int32`-and-pointer overloads
over them. `import ObjectiveC` gives `NSObject` and the Objective-C runtime (`Selector`, `AnyClass`,
`ObjCBool`, `autoreleasepool`, `NSObjectProtocol`) and lets a Swift class inherit from `NSObject`,
without Foundation. Both are Swift 6.2's and 5.4's own sources, built against the 10.9 SDK.

The 10.9 SDK differs from later ones where a Swift class overrides `NSObject`: `hash` is a method there,
so write `override func hash() -> Int`, not `override var hash: Int`. It also has no nullability, so
`NSObject()` has the type `NSObject?` (checked with the cross toolchain against the 10.9 SDK).

A program built with `-O` on 6.4.1-mavericks.8 or earlier carries a float-parsing bug (`Double("1.1")`
crashed, `Float(String)` hung) inlined into the program itself; recompile it with this release.

```sh
sudo installer -pkg swift-runtime-<version>.pkg -target /
```

## Compiling

### Directly on Mavericks

```sh
sudo installer -pkg swift-toolchain-<version>.pkg -target /
```

In a new Terminal:

```sh
swiftc hello.swift -o hello
./hello
```

### From Apple Silicon

```sh
sudo installer -pkg swift-toolchain-cross-<version>.pkg -target /
```

In a new Terminal:

```sh
swiftc hello.swift -o hello
scp hello your-mavericks-system:
```

### From post-Mavericks-pre-Silicon

Install the matching [Swift.org toolchain](https://swift.org/install/).
Use the SDK provided by Xcode Command Line Tools:

```sh
/path/to/swift/toolchain/usr/bin/swiftc -sdk "$(xcrun --show-sdk-path)" \
    -target x86_64-apple-macosx10.9 -O -no-stdlib-rpath \
    -Xlinker -rpath \
    -Xlinker /usr/local/mavergreen/swift-runtime/lib/swift \
    hello.swift -o hello
scp hello your-mavericks-system:
```

That compiler links no Recaulk (below), so such a program takes 10.9's own `fma`, `fmal` and `truncl`.

### Recaulk in every program

Both toolchain packages' `swiftc`, and their bundled `clang` and `clang++`, link [Recaulk](https://github.com/Mavergreen/recaulk) statically into
every program and library they build, as mavericks-clang-22 does: a program takes Recaulk's correct `fma`,
`fmal` and `truncl` (10.9's get some results wrong, `Double.addingProduct` and `Float80.rounded(.towardZero)`
among them), and its versions of the newer APIs it declares itself (through `@_silgen_name` or its own C declarations; `import Darwin` reaches none of them), and everything else from the OS.
Most programs take only Recaulk's own code, under its ISC licence. A program that itself calls one of the few
APIs Recaulk builds from Apple's code (`openat` and the other `*at` calls, `fdopendir`, `fstatat`,
`utimensat`, `futimens`) carries that code's APSL notice in its binary; mention that notice in your
program's documentation. The toolchain's `lib/recaulk/notices.tsv` lists those parts and their notices.
