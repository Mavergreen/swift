// objc_interop_test.swift — objc-interop class realization on 10.9: an NSObject subclass, messaged
// through real Objective-C dispatch. Builds with or without the ObjectiveC overlay: without it
// (the bare Clang module) NSObject's init is failable and BOOL is Int8; with it (this repo's 10.9
// toolchain since libswiftObjectiveC) init is not failable and BOOL is Bool; the 10.9 SDK's -hash is a
// method, a newer one's a property. So the instance is held optional and each form is taken as it comes;
// swift.org's toolchain, with its overlay, takes the same lines unchanged. The nil guard is dead
// code with the overlay, kept so the one source means the same on both. The ObjectiveC overlay's own
// surface is objc_overlay_test.swift.
import ObjectiveC

var acc: UInt64 = 0
func mix(_ v: UInt64) { acc = (acc &* 1099511628211) ^ v }
func mix(_ n: Int)    { mix(UInt64(truncatingIfNeeded: n)) }
func mix(_ s: String) { mix(UInt64(truncatingIfNeeded: s.hashValue) ^ UInt64(s.count)) }
func mix(_ b: Bool)   { mix(UInt64(b ? 0x9E37 : 0x1)) }
func mix(_ b: Int8)   { mix(b != 0) }   // BOOL, without the overlay
// The 10.9 SDK declares -hash a method, a newer one a property: o.hash is () -> Int there, Int here.
func value(_ f: () -> Int) -> Int { f() }
func value(_ v: Int) -> Int { v }

class MyObj: NSObject { func tag() -> Int { 0xBEEF } }
let made: MyObj? = MyObj()        // optional without the overlay, promoted with it
guard let o = made else { print("objc_interop_test: MyObj() returned nil"); exit(1) }
mix(o.tag())
mix(String(describing: type(of: o)))
mix(value(o.hash))                // NSObject's -hash — real objc method dispatch
mix(o.isEqual(o))

print("objc_interop_test OK  checksum=0x\(String(acc, radix: 16))")
exit(0)
