// availability_test.swift — the OS version the runtime reports, by both of its paths, on 10.9.
//
// `#available` lowers to compiler-rt's __isPlatformVersionAtLeast, linked into THIS binary;
// _swift_stdlib_operatingSystemVersion is libswiftCore's own ABI entry point (Availability.mm),
// kept for old binaries that inlined it, and the one place os_system_version_get_current_version
// (absent before 10.12) is called. On the 10.9.5 floor both must say 10.9.5, from any thread.
// STDLIB ONLY, so this repo's own 10.9 toolchain builds it. Exits non-zero on any wrong answer.

import Darwin
import SwiftShims   // _swift_stdlib_operatingSystemVersion's own (C) declaration: it returns by sret

struct OSVersion: Equatable { var major: Int; var minor: Int; var patch: Int }
func runtimeOSVersion() -> OSVersion {
  let v = _swift_stdlib_operatingSystemVersion()
  return OSVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok { print("FAIL: \(what)"); failures += 1 }
}

func osRelease() -> String {
  var buf = [CChar](repeating: 0, count: 64)
  var len = buf.count
  guard sysctlbyname("kern.osrelease", &buf, &len, nil, 0) == 0 else { return "" }
  return String(cString: buf)
}

// 10.9.5 and 10.9.6 cannot be folded away at a 10.9 deployment target: one true, one false query.
struct Answers: Equatable { var os: OSVersion; var ge1095: Bool; var ge1096: Bool; var ge1010: Bool }
func answers() -> Answers {
  var a = Answers(os: runtimeOSVersion(), ge1095: false, ge1096: false, ge1010: false)
  if #available(macOS 10.9.5, *) { a.ge1095 = true }
  if #available(macOS 10.9.6, *) { a.ge1096 = true }
  if #available(macOS 10.10, *) { a.ge1010 = true }
  return a
}

// The first callers race: 32 threads ask at once, before the main thread has.
let threads = 32
var seen = [Answers?](repeating: nil, count: threads)
var tids = [pthread_t?](repeating: nil, count: threads)
seen.withUnsafeMutableBufferPointer { out in
  for i in 0..<threads {
    check(pthread_create(&tids[i], nil, { p in
      let slot: UnsafeMutableRawPointer? = p   // optional in the 10.9 SDK, not in a modern one
      slot!.assumingMemoryBound(to: Answers?.self).pointee = answers()
      return nil
    }, UnsafeMutableRawPointer(out.baseAddress! + i)) == 0, "pthread_create \(i)")
  }
  for i in 0..<threads { if let t = tids[i] { pthread_join(t, nil) } }
}
let main = answers()
for (i, s) in seen.enumerated() { check(s == main, "thread \(i) saw \(String(describing: s)), main saw \(main)") }

check(main.os != OSVersion(major: 0, minor: 0, patch: 0), "runtime OS version is 0.0.0 (the failure value)")
// Darwin 13.4.0 is OS X 10.9.5; elsewhere the exact answers do not hold.
if osRelease() == "13.4.0" {
  check(main.os == OSVersion(major: 10, minor: 9, patch: 5), "runtime OS version is \(main.os), not 10.9.5")
  check(main.ge1095, "#available(macOS 10.9.5) is false on 10.9.5")
  check(!main.ge1096, "#available(macOS 10.9.6) is true on 10.9.5")
  check(!main.ge1010, "#available(macOS 10.10) is true on 10.9.5")
} else {
  print("note: not Darwin 13.4.0 (got \(osRelease())); the exact 10.9.5 checks are skipped")
}

if failures > 0 { print("availability_test FAILED (\(failures))"); exit(1) }
print("availability_test OK  \(main.os.major).\(main.os.minor).\(main.os.patch)")
exit(0)
