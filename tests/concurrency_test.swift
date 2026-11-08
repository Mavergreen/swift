// selftest: needs this repo's compiler (compiler patch 0003)
// swiftc: -parse-as-library
// concurrency_test.swift — Swift Concurrency on 10.9's libdispatch, through libswift_Concurrency.
//
// Upstream's compiler takes Concurrency to need macOS 10.15 (its back-deployment floor); compiler patch
// 0003 knows a 10.9 binary runs on the runtime pkg's 6.4 _Concurrency, so only this repo's compiler builds
// this test, with no availability flag (make-selftest.sh's default mode skips it, by its first line).
// -parse-as-library, from its second line, is for @main in a one-file program. Covered: the spike's
// per-feature steps (an async main, an unstructured Task's value, an actor, a 100-child task group, a
// detached .background task, cancellation, Task.sleep(nanoseconds:) and sleep(for:), both clocks, yield,
// a detached default-priority task); every TaskPriority (patch 0014: 10.9's dispatch_get_global_queue
// answers NULL for a QoS class, so each must map to a legacy priority or its job never runs);
// Task.sleep(for:tolerance:) (a dispatch source with leeway, activated with Recaulk's dispatch_activate)
// and sleep(until:) on each clock (patch 0016: 10.9's libdispatch never fires a continuous deadline, so it
// is taken as uptime); a sleeping task cancelled (CancellationError) and withTaskCancellationHandler's
// handler; and Core's folded `#available(SwiftStdlib 6.4)` sites in Concurrency, TaskCancellation.swift:252
// and Task.swift:877, told apart from their fallbacks by a cancellation shield: under it, Task.isCancelled
// (the 6.4 path honours the shield) is false, and UnsafeCurrentTask.isCancelled (the 6.4 path ignores it)
// is true; the fallbacks, _taskIsCancelled, would answer the other way. Also a TaskLocal, a checked
// continuation, an AsyncStream and a discarding task group. MainActor.assumeIsolated and preconditionIsolated
// are concurrency_isolation_test's. STDLIB ONLY. Traps on any wrong value; exits 0.

func expect(_ ok: Bool, _ what: String, line: UInt = #line) {
  if !ok { fatalError("concurrency_test: \(what)", line: line) }
}

actor Counter {
  private var value = 0
  func add(_ n: Int = 1) { value += n }
  func get() -> Int { value }
}

func square(_ n: Int) async -> Int {
  await Task.yield()
  return n * n
}

// (TaskLocal's own form: the @TaskLocal macro needs a compiler plugin this toolchain does not have.)
enum Context { static let name = TaskLocal(wrappedValue: "none") }

@main struct Main {
  static func main() async {
    // The spike's steps (conc_steps.swift), each a check instead of a print.
    let unstructured = Task { await square(3) }
    expect(await unstructured.value == 9, "an unstructured Task's value")
    let counter = Counter()
    let sum = await withTaskGroup(of: Int.self) { group in
      for i in 1...100 { group.addTask { let s = await square(i); await counter.add(); return s } }
      var total = 0
      for await v in group { total += v }
      return total
    }
    expect(sum == 338350, "the task group's sum was \(sum)")
    expect(await counter.get() == 100, "the actor counted \(await counter.get())")
    expect(await Task.detached(priority: .background) { await square(12) }.value == 144, "a detached .background task")
    expect(await Task.detached { await square(5) }.value == 25, "a detached default-priority task")
    await Task.yield()

    // Every priority's job runs (patch 0014).
    let priorities: [TaskPriority] = [.high, .userInitiated, .medium, .low, .utility, .background]
    for p in priorities {
      expect(await Task.detached(priority: p) { await square(4) }.value == 16, "a detached task at \(p)")
      expect(await Task(priority: p) { await square(2) }.value == 4, "a Task at \(p)")
    }

    // Sleeps: each returns, and not early, on its clock (patch 0016; dispatch_activate).
    let continuous = ContinuousClock(), suspending = SuspendingClock()
    var c0 = continuous.now, s0 = suspending.now
    do { try await Task.sleep(nanoseconds: 2_000_000) } catch { expect(false, "sleep(nanoseconds:) threw \(error)") }
    expect(continuous.now - c0 >= .milliseconds(2), "sleep(nanoseconds:) returned after \(continuous.now - c0)")
    c0 = continuous.now
    do { try await Task.sleep(for: .milliseconds(3)) } catch { expect(false, "sleep(for:) threw \(error)") }
    expect(continuous.now - c0 >= .milliseconds(3), "sleep(for:) returned after \(continuous.now - c0)")
    c0 = continuous.now
    do { try await Task.sleep(for: .milliseconds(3), tolerance: .milliseconds(2)) } catch {
      expect(false, "sleep(for:tolerance:) threw \(error)")
    }
    expect(continuous.now - c0 >= .milliseconds(3), "sleep(for:tolerance:) returned after \(continuous.now - c0)")
    c0 = continuous.now
    do { try await Task.sleep(until: c0 + .milliseconds(3), clock: continuous) } catch {
      expect(false, "sleep(until:) on the continuous clock threw \(error)")
    }
    expect(continuous.now >= c0 + .milliseconds(3), "sleep(until:) on the continuous clock returned early")
    s0 = suspending.now
    do { try await Task.sleep(until: s0 + .milliseconds(3), clock: suspending) } catch {
      expect(false, "sleep(until:) on the suspending clock threw \(error)")
    }
    expect(suspending.now >= s0 + .milliseconds(3), "sleep(until:) on the suspending clock returned early")
    let elapsed = continuous.measure { for _ in 0..<1000 { _ = continuous.now } }
    expect(elapsed >= .zero && elapsed < .seconds(5), "ContinuousClock.measure gave \(elapsed)")

    // Cancellation: a spinning task sees it; a sleeping one throws CancellationError; a handler runs.
    let spinner = Task { () -> Bool in
      while !Task.isCancelled { await Task.yield() }
      return true
    }
    spinner.cancel()
    expect(await spinner.value, "a cancelled task never saw Task.isCancelled")
    let sleeper = Task { () -> Bool in
      do { try await Task.sleep(for: .seconds(30)); return false } catch is CancellationError { return true } catch { return false }
    }
    sleeper.cancel()
    expect(await sleeper.value, "a cancelled sleep did not throw CancellationError")
    // The handler resumes a continuation, so this waits for onCancel itself, however slowly it runs (a
    // single-core VM under Guard Malloc); if it never ran, the runner's timeout fails the test.
    var withHandler: Task<Bool, Never>? = nil
    await withCheckedContinuation { (handled: CheckedContinuation<Void, Never>) in
      let t = Task { () -> Bool in
        await withTaskCancellationHandler {
          while !Task.isCancelled { await Task.yield() }
          return true
        } onCancel: {
          handled.resume()
        }
      }
      withHandler = t
      t.cancel()
    }
    expect(await withHandler!.value, "the task under a cancellation handler never saw Task.isCancelled")
    expect((try? Task.checkCancellation()) != nil, "the main task reads as cancelled")

    // Core's folded #available(SwiftStdlib 6.4) sites: TaskCancellation.swift:252 and Task.swift:877.
    let shielded = Task { () -> [Bool] in
      while !Task.isCancelled { await Task.yield() }
      let inside = withTaskCancellationShield {
        [Task.isCancelled, withUnsafeCurrentTask { $0?.isCancelled ?? false }, Task.hasActiveCancellationShield]
      }
      return inside + [Task.isCancelled, Task.hasActiveCancellationShield]
    }
    shielded.cancel()
    let seen = await shielded.value
    expect(seen[0] == false, "under a shield, Task.isCancelled was true (TaskCancellation.swift:252 took its fallback)")
    expect(seen[1] == true, "under a shield, UnsafeCurrentTask.isCancelled was false (Task.swift:877 took its fallback)")
    expect(seen[2] == true, "under a shield, Task.hasActiveCancellationShield was false")
    expect(seen[3] == true && seen[4] == false, "after the shield: isCancelled \(seen[3]), shield \(seen[4])")

    // A TaskLocal, inherited by a child; a checked continuation; an AsyncStream; a discarding group.
    let inherited = await Context.name.withValue("outer") {
      await Task { Context.name.get() }.value
    }
    expect(inherited == "outer", "a Task inherited TaskLocal \(inherited)")
    expect(Context.name.get() == "none", "the TaskLocal leaked: \(Context.name.get())")
    let resumed: Int = await withCheckedContinuation { k in
      Task.detached { k.resume(returning: 42) }
    }
    expect(resumed == 42, "a checked continuation resumed with \(resumed)")
    let stream = AsyncStream<Int> { k in
      Task.detached { for i in 1...10 { k.yield(i) }; k.finish() }
    }
    var streamed = 0
    for await v in stream { streamed += v }
    expect(streamed == 55, "an AsyncStream summed to \(streamed)")
    let discarded = Counter()
    await withDiscardingTaskGroup { group in
      for _ in 1...50 { group.addTask { await discarded.add() } }
    }
    expect(await discarded.get() == 50, "a discarding task group ran \(await discarded.get()) children")

    print("concurrency_test: OK")
  }
}
