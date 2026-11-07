// selftest: needs this repo's compiler (compiler patch 0003)
// typed_throws_test.swift — a typed-throws function type, as a value, on 10.9.
//
// Its metadata comes from libswiftCore's swift_getExtendedFunctionTypeMetadata (Swift 6.0's runtime).
// Upstream's compiler refuses the type for a 10.9 target ("runtime support for typed throws function
// types is only available in macOS 15.0.0"), because it takes 10.9's Swift runtime to be the OS's;
// compiler patch 0003 knows it is the runtime pkg's, so only this repo's compiler builds this test
// (make-selftest.sh's default mode skips it, by its first line). Covered: a `() throws(E) -> Int`
// stored, put in an Any and cast back with as?, called, and its error caught typed; the same type
// formed at run time by a generic function, so its metadata is instantiated, not emitted statically.
// STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("typed_throws_test: \(what)", line: line) }
}

enum ParseError: Error, Equatable { case empty, notADigit(Character) }

func digit(_ s: String) throws(ParseError) -> Int {
  guard let c = s.first else { throw .empty }
  guard let v = c.wholeNumberValue else { throw .notADigit(c) }
  return v
}

// Stored as its own type, and called: the value and the typed error both come back.
let parseSeven: () throws(ParseError) -> Int = { try digit("7") }
let parseX: () throws(ParseError) -> Int = { try digit("x") }
do throws(ParseError) {
  expect(try parseSeven() == 7, "a stored typed-throws closure returned the wrong value")
  _ = try parseX()
  expect(false, "a typed-throws closure that throws returned")
} catch {
  expect(error == .notADigit("x"), "the typed error caught was \(error), not .notADigit(\"x\")")
}

// Into an Any and back: the cast reads the function type's metadata, error type and all.
@inline(never) func erase(_ v: Any) -> Any { v }
let boxed = erase(parseSeven)
guard let back = boxed as? () throws(ParseError) -> Int else {
  fatalError("typed_throws_test: as? did not recover a () throws(ParseError) -> Int from Any")
}
expect((try? back()) == 7, "the closure recovered from Any returned the wrong value")
expect((boxed as? () -> Int) == nil, "as? recovered a throwing closure as a non-throwing one")
let name = String(describing: type(of: boxed))
expect(name == "() throws(ParseError) -> Int", "the type's name is \(name)")

// Generic over the error type: the metadata of `() throws(Failure) -> Int` is made at run time.
@inline(never) func eraseThrowing<Failure: Error>(_ body: @escaping () throws(Failure) -> Int) -> Any { body }
@inline(never) func call<Failure: Error>(_ body: () throws(Failure) -> Int) throws(Failure) -> Int { try body() }
let made = eraseThrowing(parseX)
guard let madeBack = made as? () throws(ParseError) -> Int else {
  fatalError("typed_throws_test: as? did not recover the generically formed closure")
}
do throws(ParseError) {
  _ = try call(madeBack)
  expect(false, "the generically formed closure did not throw")
} catch {
  expect(error == .notADigit("x"), "the generic path's typed error was \(error)")
}
expect(String(describing: type(of: made)) == "() throws(ParseError) -> Int",
       "the generically formed type is \(String(describing: type(of: made)))")

print("typed_throws_test: OK")
