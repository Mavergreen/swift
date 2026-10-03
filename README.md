# Swift for Mavericks

Swift runtime and toolchain for Mac OS X 10.9 Mavericks.

## Runtime

Included: strings, collections, closures, generics, protocols, classes, ARC, and `if #available`.

Not yet included: Foundation, AppKit, Darwin, Objective-C, Macros, Concurrency.

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
