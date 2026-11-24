// selftest: also -swift-version 6
// foundation_overlay_test.swift — the Foundation, CoreFoundation and CoreGraphics overlays (Swift 5.4's) on 10.9.
//
// `import Foundation` here is libswiftFoundation.dylib's module over 10.9's own Foundation.framework, read
// through the SDK view the overlay was built with. Each part is exercised for real: bridging both ways
// (String, Array, Dictionary, an empty one too, Data and URL to their NS classes and back), a bridged mutable
// class copied, not shared, an Error to NSError and back (code, domain, the cast back), a bridged NSError's
// localizedDescription (which once recursed forever under another SDK view), Codable through JSON and property
// lists (XML and binary) and the DecodingErrors a bad document throws, a file URL with a space and a non-ASCII
// name, a Gregorian date in GMT, a file written, measured and removed with FileManager, NSString's API on
// String, CGRect's null and infinite rects by their Swift names, an observer block added for a
// Notification.Name and fired by a post of it, an NSCache of NSString keys and NSNumber values, and Bundle(for:)
// as a Bundle, not an optional one (the SDK view declares +bundleForClass: nonnull). Nothing a program writes loads libswiftCoreFoundation or libswiftCoreGraphics, so each of the three
// overlay dylibs is dlopened by its @rpath name, and must come from the directory libswiftCore came from.
// What 10.9's Foundation lacks is not tried: JSONEncoder's .sortedKeys says macOS 10.13, so on 10.9 a
// one-key object is encoded without it (an object of one key has one order). The 10.9 headers carry no
// nullability, so FileManager.default and NSMutableArray(array:) import as implicitly unwrapped, and
// attributesOfItem(atPath:) returns [AnyHashable: Any]: each is written as a 10.9 client writes it. It
// compiles with no warning in Swift 6 mode too (the marker above). Exits non-zero on any failure.

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures += 1 } }

enum E: Error { case x, y }
struct P: Codable, Equatable { var n: Int; var s: String; var d: [Double] }
let sample = P(n: 42, s: "héllo, \"world\"", d: [0.5, -1, 1e10])

// --- the three overlay dylibs, by their @rpath names, from libswiftCore's directory
func overlayDylibs() {
  func dir(ofImage suffix: String) -> String? {
    for i in 0..<_dyld_image_count() {
      guard let p = _dyld_get_image_name(i) else { continue }
      let s = String(cString: p)
      if s.hasSuffix("/" + suffix) { return (s as NSString).deletingLastPathComponent }
    }
    return nil
  }
  let core = dir(ofImage: "libswiftCore.dylib")
  check(core != nil, "overlayDylibs: libswiftCore.dylib is loaded")
  for lib in ["libswiftCoreFoundation.dylib", "libswiftCoreGraphics.dylib", "libswiftFoundation.dylib"] {
    let h = dlopen("@rpath/" + lib, RTLD_NOW)
    check(h != nil, "overlayDylibs: dlopen(@rpath/\(lib)): \(h == nil ? String(cString: dlerror()) : "")")
    let d = dir(ofImage: lib)
    check(d != nil && d == core, "overlayDylibs: \(lib) is from \(d ?? "nowhere"), not libswiftCore's \(core ?? "nowhere")")
  }
}

// --- bridging both ways
func bridgingBothWays() {
  check(("héllo" as NSString) as String == "héllo", "bridgingBothWays: String through NSString")
  check(([1, 2, 3] as NSArray).count == 3, "bridgingBothWays: [Int] as NSArray has count 3")
  check((["a": 1] as NSDictionary)["a"] as? Int == 1, "bridgingBothWays: NSDictionary's \"a\" is 1")
  // An empty one, by both of NSDictionary's in-place bridges: a cast (as?, as!: the conditional bridge), and an
  // Objective-C method's NSDictionary result (the unconditional bridge, which returns hand to Swift).
  check((NSDictionary() as? [String: Any])?.isEmpty == true, "bridgingBothWays: an empty NSDictionary as? [String: Any]")
  check((NSDictionary() as! [String: Any]).isEmpty, "bridgingBothWays: an empty NSDictionary as! [String: Any]")
  let none = NSDictionary().dictionaryWithValues(forKeys: [])
  check(none?.isEmpty == true, "bridgingBothWays: dictionaryWithValues(forKeys: []) is \(String(describing: none)), not empty")
  check((Data([1, 2, 3]) as NSData).length == 3, "bridgingBothWays: Data as NSData has length 3")
  let host = (URL(string: "https://e.x/p")! as NSURL).host
  check(host == "e.x", "bridgingBothWays: URL as NSURL has host e.x, not \(host ?? "nil")")
}

// --- a bridged mutable class is copied, not shared
func bridgingCopiesMutable() {
  let m = NSMutableString(string: "a")
  let s = m as String
  m.append("b")
  check(s == "a", "bridgingCopiesMutable: the String is \(s), not a, after its NSMutableString changed")
  let ma: NSMutableArray = NSMutableArray(array: [1])
  let a = ma as! [Any]
  ma.add(2)
  check(a.count == 1, "bridgingCopiesMutable: the [Any] has \(a.count) elements, not 1, after its NSMutableArray changed")
}

// --- Error to NSError and back
func errorRoundTrip() {
  let ns = E.y as NSError
  let domain: String = ns.domain
  check(ns.code == 1, "errorRoundTrip: E.y's code is \(ns.code), not 1")
  check(domain.hasSuffix(".E"), "errorRoundTrip: E.y's domain \(domain) does not end in .E")
  check(ns as? E == .y, "errorRoundTrip: the NSError does not cast back to E.y")
  do {
    throw NSError(domain: "d", code: 7)
  } catch {
    let back = error as NSError
    let domain: String = back.domain
    check(domain == "d" && back.code == 7, "errorRoundTrip: a thrown NSError came back as \(domain) \(back.code)")
  }
}

// --- a bridged error's localizedDescription: a String, not endless recursion
func errorDescription() {
  let d = (E.y as Error).localizedDescription
  check(!d.isEmpty, "errorDescription: E.y's localizedDescription is empty")
  let nd = (NSError(domain: "d", code: 7) as Error).localizedDescription
  check(!nd.isEmpty, "errorDescription: an NSError's localizedDescription is empty")
}

// --- Codable through JSON
func codableJSON() {
  do {
    let data = try JSONEncoder().encode(sample)
    let back = try JSONDecoder().decode(P.self, from: data)
    check(back == sample, "codableJSON: \(sample) came back as \(back)")
    let e = JSONEncoder()
    // platform: .sortedKeys is macOS 10.13's (NSJSONWritingSortedKeys); one key has one order without it.
    if #available(macOS 10.13, *) { e.outputFormatting = .sortedKeys }
    let k = String(decoding: try e.encode(["k": 1]), as: UTF8.self)
    check(k == "{\"k\":1}", "codableJSON: [\"k\": 1] encoded as \(k)")
  } catch {
    check(false, "codableJSON: \(error)")
  }
}

// --- Codable through property lists, XML and binary
func codablePlist() {
  for (f, name) in [(PropertyListSerialization.PropertyListFormat.xml, "xml"), (.binary, "binary")] {
    do {
      let e = PropertyListEncoder()
      e.outputFormat = f
      let data = try e.encode(sample)
      let back = try PropertyListDecoder().decode(P.self, from: data)
      check(back == sample, "codablePlist: \(name): \(sample) came back as \(back)")
    } catch {
      check(false, "codablePlist: \(name): \(error)")
    }
  }
}

// --- what a bad document throws
func decodingErrors() {
  do {
    _ = try JSONDecoder().decode(P.self, from: Data("{\"n\":\"x\",\"s\":\"\",\"d\":[]}".utf8))
    check(false, "decodingErrors: a String for n decoded")
  } catch DecodingError.typeMismatch(_, let c) {
    let path = c.codingPath.map { $0.stringValue }
    check(path == ["n"], "decodingErrors: the typeMismatch's codingPath is \(path), not [n]")
  } catch {
    check(false, "decodingErrors: a String for n threw \(error), not typeMismatch")
  }
  do {
    _ = try JSONDecoder().decode(P.self, from: Data("{}".utf8))
    check(false, "decodingErrors: {} decoded")
  } catch DecodingError.keyNotFound {
  } catch {
    check(false, "decodingErrors: {} threw \(error), not keyNotFound")
  }
}

// --- a file URL with a space and a non-ASCII name
func urlNonASCII() {
  let u = URL(fileURLWithPath: "/tmp/a b/é.txt")
  check(u.path == "/tmp/a b/é.txt", "urlNonASCII: the path is \(u.path)")
  check(u.absoluteString.contains("a%20b"), "urlNonASCII: \(u.absoluteString) does not hold a%20b")
}

// --- the reference date, from components in the GMT Gregorian calendar
func dateCalendar() {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "GMT")!
  let d = c.date(from: DateComponents(year: 2001, month: 1, day: 1))
  check(d == Date(timeIntervalSinceReferenceDate: 0), "dateCalendar: 2001-01-01 GMT is \(String(describing: d))")
}

// --- a file written, measured and removed
func fileManager() {
  let fm: FileManager = FileManager.default
  let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("foundation_overlay_test.\(getpid())")
  let f = dir.appendingPathComponent("data")
  do {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    try Data([1, 2, 3, 4, 5]).write(to: f)
    let size = (try fm.attributesOfItem(atPath: f.path)[FileAttributeKey.size] as? NSNumber)?.intValue
    check(size == 5, "fileManager: attributesOfItem reports size \(String(describing: size)), not 5")
    try fm.removeItem(at: dir)
    check(!fm.fileExists(atPath: dir.path), "fileManager: \(dir.path) is still there")
  } catch {
    check(false, "fileManager: \(error)")
    try? fm.removeItem(at: dir)
  }
}

// --- NSString's API on String
func stringAPI() {
  check("a,b".components(separatedBy: ",") == ["a", "b"], "stringAPI: components(separatedBy:)")
  let s = String(format: "%03d", 7)
  check(s == "007", "stringAPI: String(format: %03d, 7) is \(s)")
}

// --- CGRectNull and CGRectInfinite, by the names later SDKs give them
func cgRectConstants() {
  check(CGRect.null.isNull, "cgRectConstants: CGRect.null is not null")
  check(CGRect.infinite.isInfinite, "cgRectConstants: CGRect.infinite is not infinite")
  let r = CGRect(x: 1, y: 2, width: 3, height: 4)
  check(CGRect.null.union(r) == r, "cgRectConstants: CGRect.null.union(r) is \(CGRect.null.union(r)), not r")
}

// --- an observer block, added for a Notification.Name, fired by a post of that name (no queue: on the posting thread)
nonisolated(unsafe) var notified = 0
func notificationName() {
  let name = Notification.Name("foundation_overlay_test.x")
  let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in notified += 1 }
  NotificationCenter.default.post(name: name, object: nil)
  NotificationCenter.default.post(name: Notification.Name("foundation_overlay_test.other"), object: nil)
  check(notified == 1, "notificationName: the observer ran \(notified) times, not once")
  NotificationCenter.default.removeObserver(token)
  NotificationCenter.default.post(name: name, object: nil)
  check(notified == 1, "notificationName: the observer ran after it was removed")
}

// --- NSCache, generic over its key and value classes
func cacheGeneric() {
  let cache = NSCache<NSString, NSNumber>()
  cache.setObject(NSNumber(value: 42), forKey: "k")
  check(cache.object(forKey: "k")?.intValue == 42, "cacheGeneric: k holds \(String(describing: cache.object(forKey: "k")))")
  check(cache.object(forKey: "absent") == nil, "cacheGeneric: an absent key holds a value")
}

// --- Bundle(for:): a Bundle, so .bundlePath needs no unwrapping; a class of this program's is in the main bundle
final class BundleProbe: NSObject {}
func bundleForClass() {
  let b = Bundle(for: BundleProbe.self)
  let _: Bundle.Type = type(of: b)  // compiles only if b is a Bundle, not a Bundle? (+bundleForClass: imported as init!)
  check(b == Bundle.main, "bundleForClass: \(String(describing: b.bundlePath)), not the main bundle's \(String(describing: Bundle.main.bundlePath))")
}

overlayDylibs(); bridgingBothWays(); bridgingCopiesMutable(); errorRoundTrip(); errorDescription()
codableJSON(); codablePlist(); decodingErrors(); urlNonASCII(); dateCalendar(); fileManager(); stringAPI()
cgRectConstants(); notificationName(); cacheGeneric(); bundleForClass()
if failures > 0 { print("foundation_overlay_test FAILED (\(failures))"); exit(1) }
print("foundation_overlay_test: OK")
