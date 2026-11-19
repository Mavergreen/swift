// selftest: needs this repo's compiler (compiler patch 0003)
// swiftc: -parse-as-library
// selftest: also -swift-version 6
// dispatch_task_executor_test.swift — a DispatchQueue as a TaskExecutor, on 10.9.
//
// withTaskExecutorPreference is Swift 6.0's API, which upstream's compiler takes to need macOS 15; compiler
// patch 0003 opens it for a 10.9 binary (the runtime pkg's 6.4 _Concurrency has it), so only this repo's
// compiler builds this test (make-selftest.sh's default mode skips it, by its first line). The executor
// wraps a DispatchQueue of this overlay's: its enqueue hands each job to the queue, which must run it
// (queue.async, from a Task's job, through libswiftDispatch). Tasks started under the preference must run
// on that queue: its specific value reads back inside them, for a child task of a task group, an async let
// and an unstructured Task, and the executor was asked to run at least those jobs. A watchdog thread-free
// timeout (a global-queue asyncAfter) fails the run rather than let a job that never runs hang it.
// It compiles in Swift 6 mode too (the marker above). Exits non-zero on any failure.

import Dispatch

final class Box<T: Sendable>: @unchecked Sendable {
  private let q = DispatchQueue(label: "dispatch-task-executor-test.box")
  private var v: T
  init(_ v: T) { self.v = v }
  var value: T { q.sync { v } }
  func update(_ f: @Sendable (inout T) -> Void) { q.sync { f(&v) } }
}
let failures = Box(0)
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures.update { $0 += 1 } } }

let key = DispatchSpecificKey<Int>()

final class QueueExecutor: TaskExecutor, @unchecked Sendable {
  let queue: DispatchQueue
  let enqueued: Box<Int>
  init(queue: DispatchQueue, enqueued: Box<Int>) { self.queue = queue; self.enqueued = enqueued }
  func enqueue(_ job: consuming ExecutorJob) {
    let unowned = UnownedJob(job)
    enqueued.update { $0 += 1 }
    let executor = self.asUnownedTaskExecutor()
    queue.async { unowned.runSynchronously(on: executor) }
  }
}

func onTheQueue() async -> Bool { DispatchQueue.getSpecific(key: key) == 42 }

@main struct Main {
  static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(45)) {
      print("FAIL: dispatch_task_executor_test did not finish in 45 s"); exit(1)
    }
    let queue = DispatchQueue(label: "dispatch-task-executor-test.queue")
    queue.setSpecific(key: key, value: 42)
    let enqueued = Box(0)
    let executor = QueueExecutor(queue: queue, enqueued: enqueued)

    check(!(await onTheQueue()), "a task outside the preference is not on the queue")
    await withTaskExecutorPreference(executor) {
      check(await onTheQueue(), "an async function under the preference ran on the queue")
      let inGroup = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<4 { group.addTask { await onTheQueue() } }
        var all = true
        for await ok in group { all = all && ok }
        return all
      }
      check(inGroup, "a task group's children ran on the queue")
      async let viaLet = onTheQueue()
      check(await viaLet, "an async let ran on the queue")
      check(await Task { await onTheQueue() }.value, "an unstructured Task inherited the preference")
    }
    check(enqueued.value >= 1, "the executor was asked to run jobs (\(enqueued.value))")
    check(!(await onTheQueue()), "the preference ended with the closure")

    if failures.value > 0 { print("dispatch_task_executor_test FAILED (\(failures.value))"); exit(1) }
    print("dispatch_task_executor_test OK")
    exit(0)
  }
}
