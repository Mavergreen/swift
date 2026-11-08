// thorough_test.swift — Milestone 1 release confidence gate.
//
// Exercises real Swift *core-runtime* surface on macOS 10.9 against a from-source
// libswiftCore. STDLIB ONLY — no `import Foundation` (overlays do not exist yet).
// The point is to drive the machinery that the trivial `print` test did not:
// value/reference types, generics, existentials, error handling, ARC with
// weak/unowned, and — most importantly — CLASS REALIZATION on the legacy
// (_objc_realizeClassFromSwift-absent) path, via a pure-Swift class hierarchy.
// (The NSObject case is objc_interop_test.swift: it needs the ObjectiveC overlay.)
//
// Build:  make-selftest.sh (at -O and -Onone, rpath /usr/local/mavergreen/swift-runtime/lib/swift)
// Run:    run-selftest.sh --gate   (NO DYLD_* env vars)   → each prints a checksum, exit(0)

import Darwin   // exit(); on 10.9 without overlays this is the SDK's Clang module

// A small accumulator so the optimizer can't dead-strip the work and so the
// Mavericks operator gets one deterministic line to eyeball.
var acc: UInt64 = 0
func mix(_ v: UInt64) { acc = (acc &* 1099511628211) ^ v }
func mix(_ n: Int)    { mix(UInt64(truncatingIfNeeded: n)) }
func mix(_ s: String) { mix(UInt64(truncatingIfNeeded: s.hashValue) ^ UInt64(s.count)) }
func mix(_ b: Bool)   { mix(UInt64(b ? 0x9E37 : 0x1)) }

// ---- String / Array / Dictionary / Set ----------------------------------
func exerciseCollections() {
    var s = "swift-on-mavericks"
    s += "-\(6)_\(3)_\(3)"
    s = String(s.reversed()).uppercased()
    mix(s)

    var a = Array(0..<64)
    a.removeAll { $0 % 7 == 0 }
    a = a.map { $0 &* $0 }.filter { $0 & 1 == 0 }
    mix(UInt64(a.reduce(0, &+)))
    mix(a.count)

    var d = [String: Int]()
    for (i, w) in ["alpha","beta","gamma","delta","alpha"].enumerated() { d[w, default: 0] += i }
    mix(d.count); mix(UInt64(d.values.reduce(0, +)))

    var set: Set<Int> = []
    for x in a { set.insert(x % 17) }
    mix(set.count)
    mix(set.symmetricDifference([0,1,2,3,4]).count)
}

// ---- Closures / optionals / throw-catch ----------------------------------
enum Oops: Error { case negative, tooBig }
func checked(_ x: Int) throws -> Int {
    if x < 0 { throw Oops.negative }
    if x > 1_000 { throw Oops.tooBig }
    return x &* 2
}
func exerciseControlFlow() {
    let fns: [(Int) -> Int] = [{ $0 + 1 }, { $0 &* 3 }, { $0 - 7 }]
    var v = 5
    for f in fns { v = f(v) }
    mix(UInt64(truncatingIfNeeded: v))

    let opts: [Int?] = [1, nil, 3, nil, 5]
    mix(UInt64(opts.compactMap { $0 }.reduce(0, +)))
    mix(opts.first(where: { $0 == nil }) != nil)

    var caught = 0
    for x in [-1, 10, 5000, 42] {
        do { _ = try checked(x) } catch { caught += 1 }
    }
    mix(caught)
}

// ---- Generics / existentials / protocol witnesses ------------------------
protocol Shape { func area() -> Double; var name: String { get } }
struct Circle: Shape { let r: Double; func area() -> Double { 3.14159 * r * r }; var name: String { "circle" } }
struct Square: Shape { let s: Double; func area() -> Double { s * s }; var name: String { "square" } }
func totalArea<S: Sequence>(_ shapes: S) -> Double where S.Element == Shape {
    shapes.reduce(0) { $0 + $1.area() }
}
func exerciseGenerics() {
    let shapes: [Shape] = [Circle(r: 2), Square(s: 3), Circle(r: 1)]   // existential boxing
    mix(UInt64(totalArea(shapes) * 1000))
    for sh in shapes { mix(sh.name) }
    // generic + protocol dispatch through a witness table
    func describe<T: Shape>(_ t: T) -> Int { t.name.count }
    mix(describe(Circle(r: 9)))
}

// ---- Class realization: pure-Swift hierarchy (legacy realization path) ----
class Animal { var legs: Int { 4 }; func sound() -> String { "..." }; final func id() -> Int { legs &* 10 } }
class Dog: Animal { override func sound() -> String { "woof" } }
class Biped: Animal { override var legs: Int { 2 } }
final class Parrot: Biped { override func sound() -> String { "squawk" } }
func exerciseSwiftClasses() {
    let zoo: [Animal] = [Animal(), Dog(), Biped(), Parrot()]
    for a in zoo { mix(a.sound()); mix(a.legs); mix(a.id()) }
    // dynamic cast / type metadata
    mix(zoo.compactMap { $0 as? Biped }.count)
    mix(zoo.filter { type(of: $0) == Dog.self }.count)
}

// ---- ARC + weak / unowned -------------------------------------------------
final class Node { let v: Int; weak var next: Node?; init(_ v: Int) { self.v = v } }
final class Owner { let name: String; init(_ n: String) { name = n } }
final class Pet { unowned let owner: Owner; init(_ o: Owner) { owner = o } }
func exerciseARC() {
    var head: Node? = Node(1)
    let mid = Node(2); let tail = Node(3)
    head?.next = mid; mid.next = tail
    mix(head?.next?.v ?? -1)
    head = nil                                   // release; `weak` refs must not dangle-crash
    mix(mid.next?.v ?? -1)

    let o = Owner("kagi"); let p = Pet(o)
    mix(p.owner.name)
    weak var w: Owner? = o
    mix(w != nil)
}

// ---- OS-version availability query. `#available` is compiler-rt's, linked into
//      this binary; on 10.9 these must return the low branch. The runtime's own
//      OS-version entry point is availability_test.swift's.
func exerciseAvailability() {
    if #available(macOS 10.10, *) { mix("ge-10.10") } else { mix("lt-10.10") }
    if #available(macOS 26.0, *)  { mix("ge-26")    } else { mix("lt-26") }
}

// ---- Core's own folded `#available` sites. The stdlib is compiled with -disable-availability-checking,
//      so each `if #available(SwiftStdlib N, *)` inside libswiftCore folds TRUE when Core is built: on
//      10.9 our 6.4 Core takes upstream's current branch, never its fallback. One check per site, each
//      telling the branches apart. Codable.swift:6385 and :6449 (5.6) are stdlib_availability_test's:
//      their key type conforms to CodingKeyRepresentable, which only this repo's compiler allows for
//      10.9. ReflectionMirror.swift:176 (6.2, Mirror's display style) is reachable only from a C++
//      foreign reference type, which no stdlib-only program can declare.
func expect(_ ok: Bool, _ what: String) {
    if !ok { print("thorough_test FAIL: \(what)"); exit(1) }
}

// StringGutsRangeReplaceable.swift:396 (5.1): scalars that are neither scalar view are spliced into a
// uniquely owned native string as their lazy UTF-8 (the fallback copies them into an array first).
func exerciseScalarReplacement() {
    var s = String(repeating: "m", count: 24) + "avericks"
    let first = s.unicodeScalars.index(s.unicodeScalars.startIndex, offsetBy: 23)
    let next = s.unicodeScalars.index(after: first)
    s.unicodeScalars.replaceSubrange(first..<next, with: ["\u{E9}", "\u{1F34E}", "!"] as [Unicode.Scalar])
    expect(s == String(repeating: "m", count: 23) + "\u{E9}\u{1F34E}!avericks", "unicodeScalars.replaceSubrange gave \(s)")
    mix(s)
}

// ContiguousArrayBuffer.swift:930 (5.7): an array of a class, bridged to Objective-C, gets its storage's
// class set to _ContiguousArrayStorage<Element>, so bridging back adopts that storage. [AnyObject] storage
// cast to [Cell] is still _ContiguousArrayStorage<AnyObject> until then; the fallback leaves it so, and
// bridging back copies. No overlay: these are the entry points the Foundation overlay calls, in Core, and
// Foundation itself is loaded by dlopen, which bridging needs (as objc_refcount_bridging_test does).
final class Cell { let v: Int; init(_ v: Int) { self.v = v } }
func exerciseArrayStorageClass() {
    expect(dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_NOW) != nil, "dlopen Foundation")
    let any: [AnyObject] = [Cell(5), Cell(6)]
    let before = any._bridgeToObjectiveCImpl()
    let was = String(describing: type(of: before))
    expect(was == "_ContiguousArrayStorage<AnyObject>", "[AnyObject] bridged as \(was)")
    let cells = any as! [Cell]
    let bridged = cells._bridgeToObjectiveCImpl()
    expect(bridged === before, "[AnyObject] as! [Cell] did not keep its storage")
    let storage = String(describing: type(of: bridged))
    expect(storage == "_ContiguousArrayStorage<Cell>", "[Cell] bridged as \(storage)")
    let again = [Cell]._bridgeFromObjectiveCAdoptingNativeStorageOf(bridged)
    expect(again != nil, "[Cell] did not adopt its bridged storage")
    expect(again!.count == 2 && again![0] === cells[0] && again![1].v == 6, "[Cell] adopted the wrong elements")
    mix(storage)
}

exerciseCollections()
exerciseControlFlow()
exerciseGenerics()
exerciseSwiftClasses()
exerciseARC()
exerciseAvailability()
exerciseScalarReplacement()
exerciseArrayStorageClass()

print("thorough_test OK  checksum=0x\(String(acc, radix: 16))")
exit(0)
