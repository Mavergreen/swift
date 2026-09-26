// requires: overlays
// objc_interop_test.swift — objc-interop class realization on 10.9's objc4-532: an NSObject subclass,
// messaged through the ObjectiveC overlay. Split from thorough_test.swift so a compiler without the
// overlays (this repo's own 10.9 toolchain, until the runtime roadmap ships them) still builds the rest;
// make-selftest.sh with the swift.org compiler, whose SDK has the overlays, builds both.
import ObjectiveC

var acc: UInt64 = 0
func mix(_ v: UInt64) { acc = (acc &* 1099511628211) ^ v }
func mix(_ n: Int)    { mix(UInt64(truncatingIfNeeded: n)) }
func mix(_ s: String) { mix(UInt64(truncatingIfNeeded: s.hashValue) ^ UInt64(s.count)) }
func mix(_ b: Bool)   { mix(UInt64(b ? 0x9E37 : 0x1)) }

class MyObj: NSObject { func tag() -> Int { 0xBEEF } }
let o = MyObj()
mix(o.tag())
mix(String(describing: type(of: o)))
mix(o.hash)                       // NSObject.hash — real objc method dispatch
mix(o.isEqual(o))

print("objc_interop_test OK  checksum=0x\(String(acc, radix: 16))")
exit(0)
