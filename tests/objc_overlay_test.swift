// selftest: needs the SDK view
// objc_overlay_test.swift — the ObjectiveC overlay (swift-5.4's) on 10.9.
//
// #selector and Selector, autoreleasepool, ObjCBool and NSObject's ==, Hashable and description, from
// libswiftObjectiveC.dylib over libobjc. The bare 10.9 SDK declares NSObject's -hash a method; the SDK view
// the Foundation overlays are built with, which every client compiles against, declares it a property, as
// later SDKs do, so the override is `override var hash: Int`. Exits non-zero on any wrong answer.
import ObjectiveC

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures += 1 } }
func name(_ s: Selector) -> String { String(cString: sel_getName(s)) }

final class Thing: NSObject {
  let n: Int
  init(_ n: Int) { self.n = n }
  override func isEqual(_ object: Any?) -> Bool { (object as? Thing)?.n == n }
  override var hash: Int { n }
}

let sel = #selector(NSObject.isEqual(_:))
check(name(sel) == "isEqual:", "selector name is \(name(sel))")
check(sel == Selector("isEqual:"), "Selector equality")
check(Thing(42).responds(to: sel), "responds(to:)")
check(Thing(1) == Thing(1), "NSObject == goes through isEqual:")
check(Thing(1) != Thing(2), "NSObject != too")
check(Set([Thing(3), Thing(3), Thing(4)]).count == 2, "NSObject Hashable through -hash")
check(String(describing: sel) == "isEqual:", "Selector description")
var made = 0
for i in 0..<1000 {
  autoreleasepool {
    let o = Thing(i)
    made += o.hash == i ? 1 : 0
  }
}
check(made == 1000, "autoreleasepool ran \(made) times")
let b: ObjCBool = true
check(b.boolValue, "ObjCBool")

if failures > 0 { print("objc_overlay_test FAILED (\(failures))"); exit(1) }
print("objc_overlay_test OK")
exit(0)
