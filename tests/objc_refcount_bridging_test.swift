// objc_refcount_bridging_test.swift — what libobjc does with a class the RUNTIME realized, on 10.9.
//
// A generic class is realized by objc_readClassPair: libobjc's where it has one, Recaulk's (linked into
// libswiftCore) on 10.9. That realization must carry the superclass's custom retain/release flag, or
// objc_retain counts in libobjc's side table while Swift counts in the object, and the object is freed
// at Swift's last release whatever objc holds; and it must attach the class's methods, or a bridged
// Dictionary or Set answers nothing (-[NSDictionary count]: method only defined for abstract class); and
// it must carry the C++ destructor flag, or libobjc never calls .cxx_destruct, Swift's ivar destroyer, and
// a generic NSObject subclass's stored properties are never released.
// No overlays: the entry points are looked up with dlsym, and Foundation is loaded by dlopen, which
// bridging needs (swift_stdlib_connectNSBaseClasses reparents the native NS*Base classes under it).
// Exits non-zero on any wrong answer; a crash is a wrong answer too.

import Darwin
import ObjectiveC   // NSObject

typealias Raw = UnsafeRawPointer
func sym<T>(_ name: String, _: T.Type) -> T {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {   // RTLD_DEFAULT
    print("FAIL: dlsym \(name)"); exit(1)
  }
  return unsafeBitCast(p, to: T.self)
}
var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok { print("FAIL: \(what)"); failures += 1 }
}
func obj(_ o: AnyObject) -> Raw { Raw(Unmanaged.passUnretained(o).toOpaque()) }

guard dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_NOW) != nil else {
  print("FAIL: dlopen Foundation"); exit(1)
}
let objc_retain = sym("objc_retain", (@convention(c) (Raw) -> Raw).self)
let objc_release = sym("objc_release", (@convention(c) (Raw) -> Void).self)
let objc_autorelease = sym("objc_autorelease", (@convention(c) (Raw) -> Raw).self)
let poolPush = sym("objc_autoreleasePoolPush", (@convention(c) () -> Raw?).self)
let poolPop = sym("objc_autoreleasePoolPop", (@convention(c) (Raw?) -> Void).self)
let CFDictionaryGetCount = sym("CFDictionaryGetCount", (@convention(c) (Raw) -> Int).self)
let CFSetGetCount = sym("CFSetGetCount", (@convention(c) (Raw) -> Int).self)

// ---- objc retain/release on Swift objects: one count, Swift's ----
var deinits = 0
class Plain { deinit { deinits += 1 } }
class Gen<T> { var t: T; init(_ t: T) { self.t = t }; deinit { deinits += 1 } }
func balance(_ label: String, _ make: () -> AnyObject) {
  deinits = 0
  let rounds = 10_000
  let p: Raw = { let o = make(); let p = obj(o); for _ in 0..<rounds { _ = objc_retain(p) }; return p }()
  check(deinits == 0, "\(label): deinit ran at Swift's last release, with \(rounds) objc retains outstanding")
  guard deinits == 0 else { return }   // freed: anything further reads freed memory
  for _ in 0..<(rounds - 1) { objc_release(p) }
  for _ in 0..<100 { let pool = poolPush(); _ = objc_retain(p); _ = objc_autorelease(p); poolPop(pool) }
  check(deinits == 0, "\(label): deinit ran with one objc retain outstanding")
  objc_release(p)
  check(deinits == 1, "\(label): \(deinits) deinits after the last objc release, not 1")
}
balance("Plain") { Plain() }
balance("Gen<Int>") { Gen(1) }
balance("Gen<String>") { Gen("s") }

// ---- an NSObject subclass's stored properties are destroyed with it (.cxx_destruct) ----
var inners = 0
final class Inner { deinit { inners += 1 } }
class StaticHolder: NSObject { var i = Inner() }
class GenericHolder<T>: NSObject { var i = Inner(); var t: T; init(_ t: T) { self.t = t } }
do { let made: StaticHolder? = StaticHolder(); _ = made }   // optional without the overlay
check(inners == 1, "StaticHolder: \(inners) stored-property deinits, not 1")
inners = 0
do { _ = GenericHolder(1); _ = GenericHolder("s"); _ = GenericHolder([2.5]) }
check(inners == 3, "GenericHolder<T>: \(inners) stored-property deinits, not 3 (no .cxx_destruct?)")

// ---- Dictionary and Set bridged to CF: their classes' methods answer ----
// The bridged object is a temporary that obj() doesn't retain: keep it alive across the CF call, or
// the call reads freed memory (which Guard Malloc unmaps).
func cf(_ bridged: AnyObject, _ get: (Raw) -> Int) -> Int { withExtendedLifetime(bridged) { get(obj(bridged)) } }
let d: [Int: String] = [1: "a", 2: "b", 3: "c"]
check(cf(d._bridgeToObjectiveCImpl(), CFDictionaryGetCount) == 3, "bridged [Int: String]'s CFDictionaryGetCount")
let s: Set<Int> = [1, 2, 3, 4]
check(cf(s._bridgeToObjectiveCImpl(), CFSetGetCount) == 4, "bridged Set<Int>'s CFSetGetCount")
let e: [String: [Int]] = [:]
check(cf(e._bridgeToObjectiveCImpl(), CFDictionaryGetCount) == 0, "bridged empty [String: [Int]]'s CFDictionaryGetCount")

if failures > 0 { print("objc_refcount_bridging_test FAILED (\(failures))"); exit(1) }
print("objc_refcount_bridging_test OK")
exit(0)
