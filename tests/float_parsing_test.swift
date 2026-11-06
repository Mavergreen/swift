// float_parsing_test.swift — Double, Float and Float80 from text, from a String and from a Substring.
//
// The generic `init?<S: StringProtocol>(_:)` is @inlinable: a -O client specializes its body into
// itself, a -Onone client calls libswiftCore's copy, and both delegate to the concrete
// `init?(_: Substring)` in libswiftCore. A stdlib built under -disable-availability-checking once
// delegated to the generic init itself instead, so Double parsing overflowed the stack and Float's
// looped forever (patch 0011). The texts below cover each parser path: decimal, signed zero, inf,
// nan, the largest decimal exponent, a hex subnormal, and refusals.
// STDLIB ONLY, so this repo's own 10.9 toolchain builds it. Traps on any wrong answer; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("float_parsing_test: \(what)", line: line) }
}

// Opaque to the optimizer, so no parse is folded at compile time.
@inline(never) func text(_ s: String) -> String { CommandLine.arguments.count > 99 ? "" : s }

// Each type's closures name its init at a concrete call site, as a program would.
func check<F: BinaryFloatingPoint>(
  _ name: String, _ hexSubnormal: F, _ e308: F,
  _ fromString: (String) -> F?, _ fromSubstring: (Substring) -> F?
) {
  for viaSubstring in [false, true] {
    func parse(_ s: String) -> F? {
      let t = text(s)
      return viaSubstring ? fromSubstring(t[...]) : fromString(t)
    }
    let how = "\(name) from a \(viaSubstring ? "Substring" : "String")"
    expect(parse("1.1") == (1.1 as F), "\(how): 1.1")
    let negZero = parse("-0.0")
    expect(negZero == 0 && negZero!.sign == .minus, "\(how): -0.0 is \(String(describing: negZero))")
    expect(parse("inf") == F.infinity, "\(how): inf")
    expect(parse("-inf") == -F.infinity, "\(how): -inf")
    expect(parse("nan")?.isNaN == true, "\(how): nan")
    expect(parse("1e308") == e308, "\(how): 1e308")
    expect(parse("0x1p-1074") == hexSubnormal, "\(how): 0x1p-1074")
    expect(parse("1.5") == 1.5, "\(how): 1.5")
    for bad in ["", "abc", " 1.1", "1.1x", "0x", "--1"] {
      expect(parse(bad) == nil, "\(how): \"\(bad)\" is not nil")
    }
  }
}

check("Double", Double.leastNonzeroMagnitude, 1e308, { Double($0) }, { Double($0) })
// 2^-1074 rounds to zero as a Float, and 1e308 overflows to infinity.
check("Float", Float(0), Float.infinity, { Float($0) }, { Float($0) })
#if arch(x86_64)
check("Float80", Float80(Double.leastNonzeroMagnitude), 1e308, { Float80($0) }, { Float80($0) })
#endif
print("float_parsing_test: ok")
