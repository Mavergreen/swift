// selftest: skip: needs dispatch_assert_queue$V2, which 10.9's libdispatch lacks and Recaulk does not provide yet
// swiftc: -parse-as-library
// concurrency_isolation_test.swift — the run-time isolation checks, on 10.9.
//
// MainActor.assumeIsolated and an actor's preconditionIsolated ask the executor whether the caller runs on
// it; for the main actor's and a default actor's dispatch-backed executors libswift_Concurrency answers
// with dispatch_assert_queue$V2 (ExecutorBridge.cpp), which 10.9's libdispatch lacks. Until Recaulk
// provides it, make-selftest.sh skips this test by its first line (its usage says so); the marker goes
// when Recaulk ships the symbol. Needs this repo's compiler as concurrency_test does. Covered:
// MainActor.assumeIsolated and preconditionIsolated from the main actor's own job, an actor's
// preconditionIsolated and assumeIsolated from its own job, and assertIsolated on both.
// STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("concurrency_isolation_test: \(what)", line: line) }
}

@MainActor var mainCount = 0

// Synchronous and nonisolated, as assumeIsolated's callers are: they can only assert where they run.
func bumpOnMain() -> Int {
  MainActor.assumeIsolated { mainCount += 1; return mainCount }
}
func readAssuming(_ box: Box) -> Int {
  box.assumeIsolated { box in box.value }
}

actor Box {
  var value = 0
  func checked() -> Int {
    preconditionIsolated("Box.checked runs off its actor")
    assertIsolated("Box.checked runs off its actor")
    value += 1
    return readAssuming(self)
  }
}

@main struct Main {
  @MainActor static func main() async {
    MainActor.preconditionIsolated("main runs off the main actor")
    MainActor.assertIsolated("main runs off the main actor")
    expect(bumpOnMain() == 1, "MainActor.assumeIsolated's body did not run")
    let fromJob = await Task { @MainActor () -> Int in bumpOnMain() }.value
    expect(fromJob == 2, "a main-actor job's assumeIsolated body did not run")
    let box = Box()
    expect(await box.checked() == 1, "an actor's isolation checks")
    expect(await box.checked() == 2, "an actor's isolation checks, again")
    print("concurrency_isolation_test: OK")
  }
}
