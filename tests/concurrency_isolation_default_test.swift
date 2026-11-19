// selftest: needs this repo's compiler (compiler patches 0003 and 0005)
// swiftc: -parse-as-library
// concurrency_isolation_default_test.swift — a `#isolation` default argument is the caller's isolation.
//
// `isolation: isolated (any Actor)? = #isolation` is evaluated at each call, in the caller's context, as
// upstream's #isolation macro is. This toolchain's compiler is built without swift-syntax, so its parser
// makes `#isolation` an isolation expression, not a macro expansion, and without compiler patch 0005 the
// default was evaluated once, in the callee's nonisolated default-argument generator: every caller got
// nil, and the function ran on the generic executor. The stdlib's own `#isolation` defaults
// (withTaskGroup and its kin) are this case too, when the stdlib is built by such a compiler: the call
// left the main actor before running the body, so another main-actor job ran in between. Covered: a
// user function's `#isolation` default from the main actor, from an actor's method and from nonisolated
// code (nil), each by value and by where the callee runs; withTaskGroup from the main actor, whose body
// runs there and before any other main-actor job enqueued ahead of the call. Needs this repo's compiler
// as concurrency_test does. STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("concurrency_isolation_default_test: \(what)", line: line) }
}

// The isolation the caller passed, by default.
func callerIsolation(isolation: isolated (any Actor)? = #isolation) async -> (any Actor)? {
  isolation
}

// Runs on the caller's actor, so it may assert that it is on `expected`.
func runsOn(_ expected: any Actor, isolation: isolated (any Actor)? = #isolation) async {
  expected.preconditionIsolated("a #isolation default does not run on the caller's actor")
}

actor Box {
  func isolationIsSelf() async -> Bool {
    let iso = await callerIsolation()
    await runsOn(self)
    return iso === self
  }
}

nonisolated func fromNonisolated() async -> Bool {
  await callerIsolation() == nil
}

@MainActor var log: [String] = []

@MainActor func taskGroupOnMain() async -> Int {
  // Enqueued on the main actor before the call: it may only run once the body suspends.
  Task { @MainActor in log.append("other main-actor job") }
  let sum = await withTaskGroup(of: Int.self) { group in
    MainActor.preconditionIsolated("withTaskGroup's body runs off the main actor")
    MainActor.assertIsolated("withTaskGroup's body runs off the main actor")
    log.append("withTaskGroup body")
    for n in 1...3 { group.addTask { n } }
    var sum = 0
    while let n = await group.next() {   // next(isolation:), another stdlib #isolation default
      MainActor.preconditionIsolated("TaskGroup.next() returns off the main actor")
      sum += n
    }
    return sum
  }
  await Task.yield()
  return sum
}

@main struct Main {
  @MainActor static func main() async {
    let fromMain = await callerIsolation()
    expect(fromMain === MainActor.shared, "#isolation from the main actor is \(String(describing: fromMain))")
    await runsOn(MainActor.shared)

    expect(await Box().isolationIsSelf(), "#isolation from an actor's method is not that actor")

    expect(await fromNonisolated(), "#isolation from a nonisolated function is not nil")
    let detached = await Task.detached { await callerIsolation() }.value
    expect(detached == nil, "#isolation from a detached task is \(String(describing: detached))")

    expect(await taskGroupOnMain() == 6, "withTaskGroup's sum")
    while log.count < 2 { await Task.yield() }
    expect(log == ["withTaskGroup body", "other main-actor job"],
           "withTaskGroup from the main actor let another main-actor job run first: \(log)")
    print("concurrency_isolation_default_test: OK")
  }
}
