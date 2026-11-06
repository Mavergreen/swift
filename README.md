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
