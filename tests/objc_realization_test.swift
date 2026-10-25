// objc_realization_test.swift — classes the RUNTIME realizes for objc4-532 on 10.9, seen from libobjc.
//
// A generic class's metadata, and so its Objective-C class, is made at run time by
// swift_instantiateObjCClass, through objc_readClassPair: libobjc's, or on 10.9 Recaulk's (linked in);
// a generic NSObject subclass's ivars are laid out after its superclass's (patch 0005). libobjc then
// has to see a sane class: a metaclass, the inherited selectors, methods added to a superclass later,
// and an instance size that covers every field, which Guard Malloc in the gate holds it to.
// No overlays: the objc entry points are looked up with dlsym, so the same source builds with this
// repo's 10.9 toolchain (where `import ObjectiveC` is the bare Clang module) and with swift.org's.
// Exits non-zero on any wrong answer.

import Darwin
import ObjectiveC   // NSObject

typealias Raw = UnsafeRawPointer
func sym<T>(_ name: String, _: T.Type) -> T {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {   // RTLD_DEFAULT
    print("FAIL: dlsym \(name)"); exit(1)
  }
  return unsafeBitCast(p, to: T.self)
}
let object_getClass = sym("object_getClass", (@convention(c) (Raw) -> Raw?).self)
let class_isMetaClass = sym("class_isMetaClass", (@convention(c) (Raw) -> Int8).self)
let class_getSuperclass = sym("class_getSuperclass", (@convention(c) (Raw) -> Raw?).self)
let class_getInstanceSize = sym("class_getInstanceSize", (@convention(c) (Raw) -> Int).self)
let class_respondsToSelector = sym("class_respondsToSelector", (@convention(c) (Raw, Raw) -> Int8).self)
let class_addMethod = sym("class_addMethod", (@convention(c) (Raw, Raw, Raw, UnsafePointer<CChar>) -> Int8).self)
let class_getMethodImplementation = sym("class_getMethodImplementation", (@convention(c) (Raw, Raw) -> Raw?).self)
let sel_registerName = sym("sel_registerName", (@convention(c) (UnsafePointer<CChar>) -> Raw).self)
let objc_getClass = sym("objc_getClass", (@convention(c) (UnsafePointer<CChar>) -> Raw?).self)

// A Swift class's metadata is its Objective-C class; a foreign one's (NSObject's) is a wrapper, so
// NSObject itself comes from objc_getClass.
func cls(_ c: AnyClass) -> Raw { unsafeBitCast(c, to: Raw.self) }
func obj(_ o: AnyObject) -> Raw { Raw(Unmanaged.passUnretained(o).toOpaque()) }
func sel(_ s: String) -> Raw { sel_registerName(s) }

var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok { print("FAIL: \(what)"); failures += 1 }
}

// ---- Generic pure-Swift classes: each instantiation is a realized class with a metaclass ----
class Box<T> {
  var v: T
  init(_ v: T) { self.v = v }
  class func kind() -> Int { MemoryLayout<T>.size }
}
func exerciseBox<T>(_ v: T, _ label: String) {
  let b = Box(v)
  let c = cls(Box<T>.self)
  check(object_getClass(obj(b)) == c, "Box<\(label)>: an instance's class is not Box<\(label)>")
  guard let meta = object_getClass(c) else { check(false, "Box<\(label)>: no metaclass"); return }
  check(class_isMetaClass(meta) != 0, "Box<\(label)>: its class's class is not a metaclass")
  check(class_isMetaClass(c) == 0, "Box<\(label)>: the class is a metaclass")
  check(class_getSuperclass(c) != nil, "Box<\(label)>: no superclass (SwiftObject)")
  check(Box<T>.kind() == MemoryLayout<T>.size, "Box<\(label)>: class func dispatch")
  for s in ["retain", "release", "isEqual:", "class"] {
    check(class_respondsToSelector(c, sel(s)) != 0, "Box<\(label)>: does not respond to inherited -\(s)")
  }
  check(class_respondsToSelector(c, sel("mavergreenNoSuchSelector")) == 0, "Box<\(label)>: responds to anything")
  check(class_getInstanceSize(c) >= 16 + MemoryLayout<T>.size, "Box<\(label)>: instance size \(class_getInstanceSize(c))")
}

// ---- A generic NSObject subclass: fields of mixed alignment, laid out after NSObject's isa ----
class Mixed<T>: NSObject {
  var a: UInt8; var b: Double; var c: T; var d: UInt16
  init(_ c: T, _ n: Int) {
    a = UInt8(truncatingIfNeeded: n); b = Double(n) * 0.5; self.c = c; d = UInt16(truncatingIfNeeded: n &* 7)
  }
}
func exerciseMixed<T: Equatable>(_ v: T, _ label: String) {
  let c = cls(Mixed<T>.self)
  let ns = objc_getClass("NSObject")!
  check(class_getSuperclass(c) == ns, "Mixed<\(label)>: superclass is not NSObject")
  let floor = class_getInstanceSize(ns)
  let fields = 1 + MemoryLayout<Double>.size + MemoryLayout<T>.size + 2
  let size = class_getInstanceSize(c)
  check(size >= floor + fields, "Mixed<\(label)>: instance size \(size) < NSObject's \(floor) + fields \(fields)")
  check(class_respondsToSelector(c, sel("hash")) != 0, "Mixed<\(label)>: does not respond to inherited -hash")
  // Guard Malloc puts each allocation against a guard page: a size short of the last field faults here.
  var all: [Mixed<T>] = []
  for n in 0..<64 { all.append(Mixed(v, n)) }
  for (n, m) in all.enumerated() {
    m.d = UInt16(truncatingIfNeeded: n &* 7)
    check(m.a == UInt8(truncatingIfNeeded: n) && m.b == Double(n) * 0.5 && m.c == v
          && m.d == UInt16(truncatingIfNeeded: n &* 7), "Mixed<\(label)> #\(n): a field did not read back")
  }
}

// ---- A method added to a static superclass later is visible on runtime-realized subclasses ----
class Base { init() {} }
class Sub<T>: Base { var t: T; init(_ t: T) { self.t = t } }
let answer: @convention(c) (Raw, Raw) -> Int = { _, _ in 0x5EED }
func exerciseAddedMethod() {
  let before = Sub(1)                      // Sub<Int> is realized before the method exists
  let s = sel("mavergreenAnswer")
  check(class_addMethod(cls(Base.self), s, unsafeBitCast(answer, to: Raw.self), "q@:") != 0, "class_addMethod on Base")
  let after = Sub("x")                     // Sub<String> is realized after
  for (label, c) in [("Sub<Int>", cls(Sub<Int>.self)), ("Sub<String>", cls(Sub<String>.self))] {
    check(class_respondsToSelector(c, s) != 0, "\(label): does not see a method added to Base")
    if let imp = class_getMethodImplementation(c, s) {
      let f = unsafeBitCast(imp, to: (@convention(c) (Raw, Raw) -> Int).self)
      check(f(c, s) == 0x5EED, "\(label): the added method's implementation")
    } else { check(false, "\(label): no implementation for the added method") }
  }
  _ = (before.t, after.t)
}

exerciseBox(1, "Int"); exerciseBox("s", "String"); exerciseBox(2.5, "Double"); exerciseBox(Box(3), "Box<Int>")
exerciseMixed(Int8(-3), "Int8"); exerciseMixed(Int64(1) << 40, "Int64"); exerciseMixed("mixed", "String")
exerciseAddedMethod()

if failures > 0 { print("objc_realization_test FAILED (\(failures))"); exit(1) }
print("objc_realization_test OK")
exit(0)
