// selftest: needs this repo's compiler (compiler patch 0003)
// stdlib_availability_test.swift — the standard library's newer APIs, unmodified, on 10.9.
//
// Swift's own declarations say macOS 10.15 to 27.0 (`@available(SwiftStdlib N, *)`): the OS release that
// first shipped each Swift runtime. Below 10.14.4 a client runs on the runtime pkg's 6.4 Core instead, so
// compiler patch 0003 makes those declarations available from 10.9 (INGREDIENTS.md "The compiler's runtime
// table"); upstream's compiler refuses every use below as "only available in macOS N or newer", so only
// this repo's compiler builds this test (make-selftest.sh's default mode skips it, by its first line).
// Covered, one release each: CollectionDifference (5.1), Duration (5.7), Int128 (6.0), InlineArray and
// Span (6.2). Span's symbols reach this program through @rpath/libswiftCompatibilitySpan.dylib (Core's
// $ld$previous), which the runtime pkg ships as a link to libswiftCore.dylib: that link loads here or this
// test does not start. And Core's folded `#available` sites at Codable.swift:6385 and :6449 (5.6): a
// Dictionary keyed by a CodingKeyRepresentable type encodes and decodes keyed, not as the fallback's
// unkeyed array (thorough_test.swift has the other sites).
// STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("stdlib_availability_test: \(what)", line: line) }
}

// 5.1
let diff = [1, 2, 3, 4].difference(from: [1, 3, 4, 5])
expect(diff.insertions.count == 1 && diff.removals.count == 1, "difference(from:) gave \(diff)")
expect([1, 3, 4, 5].applying(diff) == [1, 2, 3, 4], "applying(_:) did not undo difference(from:)")

// 5.7
let d = Duration.seconds(90) + .milliseconds(250)
expect(d.components.seconds == 90 && d.components.attoseconds == 250_000_000_000_000_000, "Duration gave \(d)")
expect(d / 2 == .milliseconds(45_125), "Duration division gave \(d / 2)")

// 6.0
let big = Int128(Int64.max) * 4 + 3
expect(big.description == "36893488147419103231", "Int128 gave \(big)")
expect(big % 1_000_000_007 == 36893488147419103231 % 1_000_000_007, "Int128 remainder")
expect(UInt128.max.description == "340282366920938463463374607431768211455", "UInt128.max gave \(UInt128.max)")

// 6.2
var inline: InlineArray<4, Int> = [10, 20, 30, 40]
inline[2] += 3
var inlineSum = 0
for i in inline.indices { inlineSum += inline[i] }
expect(inlineSum == 103 && inline.count == 4, "InlineArray summed to \(inlineSum)")

let values = [5, 6, 7, 8]
let span = values.span
var spanSum = 0
for i in span.indices { spanSum += span[i] }
expect(spanSum == 26 && span.count == 4, "Span summed to \(spanSum)")
expect("\(Span<Int>.self)" == "Span<Int>", "Span's metadata named \(Span<Int>.self)")
let raw = span.bytes
expect(raw.byteCount == 4 * MemoryLayout<Int>.stride, "RawSpan counted \(raw.byteCount) bytes")

// Codable.swift:6385 and :6449 (5.6), through a minimal coder that records the keys.
enum Hue: String, Codable, CodingKeyRepresentable { case red, green }
final class Keys {
  var encoded: [String: Int] = [:]
  let toDecode: [String: Int]
  init(_ d: [String: Int] = [:]) { toDecode = d }
}
struct KeyedOut<K: CodingKey>: KeyedEncodingContainerProtocol {
  let keys: Keys
  var codingPath: [any CodingKey] { [] }
  mutating func encodeNil(forKey key: K) throws { fatalError("encodeNil") }
  mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws { keys.encoded[key.stringValue] = value as? Int }
  mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: K) -> KeyedEncodingContainer<N> { fatalError("nested") }
  mutating func nestedUnkeyedContainer(forKey key: K) -> any UnkeyedEncodingContainer { fatalError("nested") }
  mutating func superEncoder() -> any Encoder { fatalError("super") }
  mutating func superEncoder(forKey key: K) -> any Encoder { fatalError("super") }
}
struct KeyedIn<K: CodingKey>: KeyedDecodingContainerProtocol {
  let keys: Keys
  var codingPath: [any CodingKey] { [] }
  var allKeys: [K] { keys.toDecode.keys.compactMap { K(stringValue: $0) } }
  func contains(_ key: K) -> Bool { keys.toDecode[key.stringValue] != nil }
  func decodeNil(forKey key: K) throws -> Bool { false }
  func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T { keys.toDecode[key.stringValue]! as! T }
  func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: K) throws -> KeyedDecodingContainer<N> { fatalError("nested") }
  func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer { fatalError("nested") }
  func superDecoder() throws -> any Decoder { fatalError("super") }
  func superDecoder(forKey key: K) throws -> any Decoder { fatalError("super") }
}
struct KeysCoder: Encoder, Decoder {
  let keys: Keys
  var codingPath: [any CodingKey] { [] }
  var userInfo: [CodingUserInfoKey: Any] { [:] }
  func container<K: CodingKey>(keyedBy type: K.Type) -> KeyedEncodingContainer<K> { KeyedEncodingContainer(KeyedOut<K>(keys: keys)) }
  func container<K: CodingKey>(keyedBy type: K.Type) throws -> KeyedDecodingContainer<K> { KeyedDecodingContainer(KeyedIn<K>(keys: keys)) }
  func unkeyedContainer() -> any UnkeyedEncodingContainer { fatalError("stdlib_availability_test: Dictionary<Hue, Int> encoded unkeyed (the pre-5.6 branch)") }
  func unkeyedContainer() throws -> any UnkeyedDecodingContainer { fatalError("stdlib_availability_test: Dictionary<Hue, Int> decoded unkeyed (the pre-5.6 branch)") }
  func singleValueContainer() -> any SingleValueEncodingContainer { fatalError("single") }
  func singleValueContainer() throws -> any SingleValueDecodingContainer { fatalError("single") }
}
let out = Keys()
do { try [Hue.red: 1, Hue.green: 2].encode(to: KeysCoder(keys: out)) } catch { expect(false, "encode threw \(error)") }
expect(out.encoded == ["red": 1, "green": 2], "Dictionary<Hue, Int> encoded \(out.encoded)")
var back: [Hue: Int] = [:]
do { back = try [Hue: Int](from: KeysCoder(keys: Keys(["green": 3, "red": 4]))) } catch { expect(false, "decode threw \(error)") }
expect(back == [.green: 3, .red: 4], "Dictionary<Hue, Int> decoded \(back)")

print("stdlib_availability_test OK")
