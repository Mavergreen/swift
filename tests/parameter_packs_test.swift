// selftest: needs this repo's compiler (compiler patch 0003)
// parameter_packs_test.swift — a generic type with a parameter pack, on 10.9.
//
// Its metadata is made by libswiftCore's generic metadata instantiation, with the pack allocated by
// swift_allocateMetadataPack (Swift 5.9's runtime). Upstream's compiler refuses such a type for a 10.9
// target ("parameter packs in generic types are only available in macOS 14.0.0"), because it takes
// 10.9's Swift runtime to be the OS's; compiler patch 0003 knows it is the runtime pkg's, so only this
// repo's compiler builds this test (make-selftest.sh's default mode skips it, by its first line).
// Covered: `struct Tuple<each T>`, its metadata reached through type(of:) and String(describing:) from
// a value a generic function formed (so the metadata is instantiated at run time), an as? cast back
// to the concrete type, and pack iteration. STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("parameter_packs_test: \(what)", line: line) }
}

struct Tuple<each T> {
  var items: (repeat each T)
  init(_ items: repeat each T) { self.items = (repeat each items) }
}

// Formed generically and erased, so Tuple<Int, String, Double>'s metadata is made at run time.
@inline(never) func make<each T>(_ v: repeat each T) -> Any { Tuple(repeat each v) }

// Pack iteration: one element at a time, in order.
@inline(never) func describeEach<each T>(_ v: repeat each T) -> [String] {
  var parts: [String] = []
  for x in repeat each v { parts.append(String(describing: x)) }
  return parts
}
@inline(never) func count<each T>(_ v: repeat each T) -> Int {
  var n = 0
  for _ in repeat each v { n += 1 }
  return n
}

let made = make(1, "two", 3.5)
let name = String(describing: type(of: made))
expect(name == "Tuple<Pack{Int, String, Double}>", "the type's name is \(name)")
expect(String(describing: made) == "Tuple<Pack{Int, String, Double}>(items: (1, \"two\", 3.5))",
       "the value reads \(String(describing: made))")
guard let back = made as? Tuple<Int, String, Double> else {
  fatalError("parameter_packs_test: as? did not recover a Tuple<Int, String, Double> from Any")
}
expect(back.items.0 == 1 && back.items.1 == "two" && back.items.2 == 3.5, "the recovered items are \(back.items)")
expect((made as? Tuple<Int, String>) == nil, "as? recovered a three-element Tuple as a two-element one")

// Two instantiations with different packs are different types; the same pack is the same type.
let other = make(true)
expect(String(describing: type(of: other)) == "Tuple<Pack{Bool}>", "the one-element type is \(type(of: other))")
expect(ObjectIdentifier(type(of: made)) == ObjectIdentifier(Tuple<Int, String, Double>.self),
       "the generically made metadata is not the statically named type's")
expect(ObjectIdentifier(type(of: made)) != ObjectIdentifier(type(of: other)), "two packs gave one type")
expect(String(describing: type(of: make())) == "Tuple<Pack{}>", "the empty pack's type is \(type(of: make()))")

expect(describeEach(1, "two", 3.5) == ["1", "two", "3.5"], "pack iteration gave \(describeEach(1, "two", 3.5))")
expect(count() == 0 && count(1) == 1 && count(1, 2, 3, 4) == 4, "pack iteration counted wrong")

print("parameter_packs_test: OK")
