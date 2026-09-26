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

// ---- OS-version availability query (exercises the guarded os_system_version
//      fallback added for 10.9). On 10.9 these must return the low branch
//      WITHOUT crashing — the whole point of the Availability.mm guard.
func exerciseAvailability() {
    if #available(macOS 10.10, *) { mix("ge-10.10") } else { mix("lt-10.10") }
    if #available(macOS 26.0, *)  { mix("ge-26")    } else { mix("lt-26") }
}

exerciseCollections()
exerciseControlFlow()
exerciseGenerics()
exerciseSwiftClasses()
exerciseARC()
exerciseAvailability()

print("thorough_test OK  checksum=0x\(String(acc, radix: 16))")
exit(0)
