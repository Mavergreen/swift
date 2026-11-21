// dispatch_overlay_test.swift — the Dispatch overlay (libswiftDispatch) on 10.9.
// selftest: also -swift-version 6
//
// `import Dispatch` here is libswiftDispatch.dylib's module over 10.9's own libdispatch (through Recaulk,
// which supplies what 10.9 lacks), not the bare C one. Each part is exercised for real: DispatchQueue.main
// (served by dispatchMain, the program ending in an exit from the main queue), global() and every QoS
// (10.9's dispatch_get_global_queue takes a legacy priority, not a QoS class, so each class must map to
// one or its block never runs), serial and concurrent queues (the concurrent one proved by two blocks that
// each wait for the other), a group with wait and notify, a semaphore, asyncAfter and DispatchTime
// ordering, a timer source firing three times and then cancelled, a user-data-add source, DispatchWorkItem
// (performed; cancelled before it is submitted and while it waits in a queue: it never runs, isCancelled
// reads true), and DispatchData (append, count, the bytes read back).
// Barriers: below 10.10 Recaulk's dispatch_block_create ignores its flags, so the overlay submits
// barrier-flagged work with dispatch_barrier_async/sync; on a concurrent queue with readers on both
// sides, a barrier writer must run alone, however it is submitted (async(execute:) of a .barrier
// DispatchWorkItem, async(flags:), async(group:flags:), sync(flags:), asyncAfter(flags:), and a work item's
// notify(flags:)).
// What macOS 10.10 and 10.12 added past DispatchWorkItem, which Recaulk gives 10.9: dispatchPrecondition
// (only its passing forms: a failing one traps, and this test runs in one process), on a queue and on a
// queue targeting it; DispatchWorkItem's wait (returning once the work ran, and timing out while it cannot)
// and notify (running after the work item); an initially inactive queue, running nothing until activate(),
// a resume() before activate() that does not trap, and a source started with activate(); each
// autoreleaseFrequency:, and target: at creation (a concurrent queue on a serial target runs one block at a
// time, and sees the target's specific). What the overlay leaves out on 10.9 (DispatchQueue.qos, which
// Recaulk cannot read back, and the user-data-replace source) is not tried. No source is cast to a per-type
// protocol: with this overlay, every source conforms to them all.
// Every wait has a timeout, so a broken path fails rather than hangs. It compiles with no warning in
// Swift 6 mode too (the marker above). Exits non-zero on any failure.

import Darwin
import Dispatch

final class Lock: @unchecked Sendable {
  private var m = pthread_mutex_t()
  init() { pthread_mutex_init(&m, nil) }
  deinit { pthread_mutex_destroy(&m) }
  func with<T>(_ body: () -> T) -> T { pthread_mutex_lock(&m); defer { pthread_mutex_unlock(&m) }; return body() }
}
final class Box<T: Sendable>: @unchecked Sendable {
  private let lock = Lock()
  private var v: T
  init(_ v: T) { self.v = v }
  var value: T { get { lock.with { v } } set { lock.with { v = newValue } } }
  func update(_ f: (inout T) -> Void) { lock.with { f(&v) } }
}

let failures = Box(0)
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures.update { $0 += 1 } } }
func waits(_ s: DispatchSemaphore, _ ms: Int = 5000) -> Bool { s.wait(timeout: .now() + .milliseconds(ms)) == .success }
func ms(_ n: Int) { usleep(UInt32(n * 1000)) }

// --- the main queue
// platform: dispatchMain() ends the main thread (pthread_exit) and libdispatch's own threads drain the main
//           queue after it, so a block there is told by the queue's specific value, not pthread_main_np().
let mainKey = DispatchSpecificKey<Int>()
func mainQueue() {
  DispatchQueue.main.setSpecific(key: mainKey, value: 7)
  let s = DispatchSemaphore(value: 0)
  let onMain = Box(false)
  DispatchQueue.main.async { onMain.value = DispatchQueue.getSpecific(key: mainKey) == 7; s.signal() }
  guard waits(s) else { check(false, "a block async to DispatchQueue.main ran (the main queue is not running)"); return }
  check(onMain.value, "DispatchQueue.main's block ran on the main queue")
  check(DispatchQueue.main.sync { DispatchQueue.getSpecific(key: mainKey) == 7 }, "DispatchQueue.main.sync ran on the main queue")
  check(DispatchQueue.getSpecific(key: mainKey) == nil, "the suite's own queue is not the main queue")
}

// --- global() and each QoS
func globalQueues() {
  let s = DispatchSemaphore(value: 0)
  DispatchQueue.global().async { s.signal() }
  check(waits(s), "DispatchQueue.global() ran a block")
  let classes: [(DispatchQoS.QoSClass, String)] = [
    (.userInteractive, "userInteractive"), (.userInitiated, "userInitiated"), (.default, "default"),
    (.utility, "utility"), (.background, "background"), (.unspecified, "unspecified")]
  for (c, name) in classes {
    DispatchQueue.global(qos: c).async { s.signal() }
    check(waits(s), "DispatchQueue.global(qos: .\(name)) ran a block")
    check(DispatchQoS.QoSClass(rawValue: c.rawValue) == c, "QoSClass .\(name) round-trips its rawValue")
  }
  let q = DispatchQueue(label: "dispatch-overlay-test.qos", qos: .utility)
  q.async { s.signal() }
  check(waits(s), "DispatchQueue(label:qos:) ran a block")
  check(q.label == "dispatch-overlay-test.qos", "the queue's label reads back: \(q.label)")
}

// --- serial and concurrent queues
func serialAndConcurrent() {
  let serial = DispatchQueue(label: "dispatch-overlay-test.serial")
  let seen = Box([Int]())
  let g = DispatchGroup()
  for i in 0..<100 { serial.async(group: g) { seen.update { $0.append(i) } } }
  check(g.wait(timeout: .now() + .seconds(5)) == .success, "a serial queue ran its 100 blocks")
  check(seen.value == Array(0..<100), "a serial queue ran its blocks in order")
  check(serial.sync { 42 } == 42, "sync returns its block's value")

  // Two blocks, each signalling then waiting for the other: only a concurrent queue gets past both.
  let conc = DispatchQueue(label: "dispatch-overlay-test.concurrent", attributes: .concurrent)
  let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  let metA = Box(false), metB = Box(false)
  conc.async { a.signal(); metA.value = waits(b, 3000); done.signal() }
  conc.async { b.signal(); metB.value = waits(a, 3000); done.signal() }
  check(waits(done) && waits(done), "both blocks of a concurrent queue finished")
  check(metA.value && metB.value, "a concurrent queue ran two blocks at once")

  let hits = Box(0)
  DispatchQueue.concurrentPerform(iterations: 8) { _ in hits.update { $0 += 1 } }
  check(hits.value == 8, "concurrentPerform ran 8 iterations (\(hits.value))")
}

// --- a group: wait and notify
func groups() {
  let q = DispatchQueue.global()
  let g = DispatchGroup()
  let n = Box(0)
  for _ in 0..<10 { g.enter(); q.async { ms(2); n.update { $0 += 1 }; g.leave() } }
  let notified = DispatchSemaphore(value: 0)
  let atNotify = Box(-1)
  g.notify(queue: q) { atNotify.value = n.value; notified.signal() }
  check(waits(notified), "a group's notify ran")
  check(atNotify.value == 10, "notify ran after all 10 members (saw \(atNotify.value))")
  check(g.wait(timeout: .now() + .seconds(1)) == .success, "wait on a finished group succeeds")
  g.enter()
  check(g.wait(timeout: .now() + .milliseconds(10)) == .timedOut, "wait on a group never left times out")
  g.leave()
  let g2 = DispatchGroup()
  g2.enter(); q.asyncAfter(deadline: .now() + .milliseconds(5)) { g2.leave() }
  check(g2.wait(timeout: .now() + .seconds(5)) == .success, "wait returns once the last member leaves")
}

// --- a semaphore
func semaphores() {
  let s = DispatchSemaphore(value: 0)
  check(s.wait(timeout: .now() + .milliseconds(10)) == .timedOut, "an empty semaphore's wait times out")
  DispatchQueue.global().async { ms(2); _ = s.signal() }
  check(waits(s), "a signal from another queue wakes the wait")
  let two = DispatchSemaphore(value: 2)
  check(two.wait(timeout: .now()) == .success && two.wait(timeout: .now()) == .success, "a semaphore of 2 takes two waits")
  check(two.wait(timeout: .now() + .milliseconds(5)) == .timedOut, "and no third")
  // platform: libdispatch traps when a semaphore is released holding less than it was created with
  //           ("Semaphore/group object deallocated while in use"), so the two are given back first.
  two.signal(); two.signal()
}

// --- asyncAfter and DispatchTime ordering
func timing() {
  let t0 = DispatchTime.now()
  check(t0 < t0 + .milliseconds(1), "DispatchTime + interval is later")
  check(t0 + .seconds(1) > t0 + .milliseconds(999), "DispatchTime orders by the interval added")
  check(t0 + .nanoseconds(1_000_000) > t0 && t0 + .microseconds(1) > t0, "intervals of other units compare")
  check(DispatchTime(uptimeNanoseconds: 5) < DispatchTime(uptimeNanoseconds: 6), "DispatchTime(uptimeNanoseconds:) orders")
  check(DispatchTime.now() >= t0, "DispatchTime.now() does not go back")

  let q = DispatchQueue(label: "dispatch-overlay-test.after")
  let order = Box([Int]())
  let g = DispatchGroup()
  let start = DispatchTime.now()
  let firedAt = Box(UInt64(0))
  // Submitted out of order; they fire in order of their deadlines.
  for d in [30, 10, 20] {
    q.asyncAfter(deadline: start + .milliseconds(d), qos: .default, flags: []) { }
    g.enter()
    q.asyncAfter(deadline: start + .milliseconds(d)) {
      order.update { $0.append(d) }
      if d == 10 { firedAt.value = DispatchTime.now().uptimeNanoseconds }
      g.leave()
    }
  }
  check(g.wait(timeout: .now() + .seconds(5)) == .success, "the asyncAfter blocks ran")
  check(order.value == [10, 20, 30], "asyncAfter ran in deadline order: \(order.value)")
  check(firedAt.value >= start.uptimeNanoseconds + 9_500_000, "asyncAfter(10 ms) did not fire early")
  let s = DispatchSemaphore(value: 0)
  q.asyncAfter(wallDeadline: .now() + .milliseconds(5)) { s.signal() }
  check(waits(s), "asyncAfter(wallDeadline:) ran")
  let w = DispatchWorkItem { s.signal() }
  q.asyncAfter(deadline: .now() + .milliseconds(5), execute: w)
  check(waits(s), "asyncAfter(deadline:execute: DispatchWorkItem) ran")
}

// --- sources: a timer, a user-data-add
func sources() {
  let q = DispatchQueue(label: "dispatch-overlay-test.source")
  let timer = DispatchSource.makeTimerSource(queue: q)
  let fired = Box(0)
  let three = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
  timer.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(5))
  timer.setEventHandler {
    var n = 0
    fired.update { $0 += 1; n = $0 }
    if n == 3 { three.signal() }
  }
  timer.setCancelHandler { cancelled.signal() }
  timer.resume()
  check(waits(three), "the timer source fired three times (\(fired.value))")
  timer.cancel()
  check(waits(cancelled), "the timer's cancel handler ran")
  let atCancel = fired.value
  ms(25)
  check(fired.value == atCancel, "the timer did not fire after its cancel handler ran (\(atCancel) -> \(fired.value))")
  check(timer.isCancelled, "the cancelled timer reports isCancelled")

  let add = DispatchSource.makeUserDataAddSource(queue: q)
  let total = Box(UInt(0))
  let enough = DispatchSemaphore(value: 0)
  add.setEventHandler {
    let n = add.data
    total.update { $0 += n; if $0 >= 6 { enough.signal() } }
  }
  add.resume()
  add.add(data: 1); add.add(data: 2); add.add(data: 3)
  check(waits(enough), "the user-data-add source's handler saw its data (\(total.value))")
  add.cancel()
}

// --- DispatchWorkItem
func workItems() {
  let q = DispatchQueue(label: "dispatch-overlay-test.item")
  let s = DispatchSemaphore(value: 0)
  let ran = Box(0)

  let item = DispatchWorkItem { ran.update { $0 += 1 } }
  check(!item.isCancelled, "a new item is not cancelled")
  item.perform()
  check(ran.value == 1, "perform() ran the item")
  q.async(execute: item)
  q.async { s.signal() }
  check(waits(s) && ran.value == 2, "async(execute:) ran the item (ran \(ran.value))")

  let early = DispatchWorkItem { ran.update { $0 += 100 } }
  early.cancel()
  check(early.isCancelled, "isCancelled reads true after cancel()")
  q.async(execute: early)
  q.async { s.signal() }
  check(waits(s), "the queue went on past a cancelled item")
  check(ran.value == 2, "an item cancelled before async never ran (ran \(ran.value))")

  // Cancelled while it waits behind another block.
  let gate = DispatchSemaphore(value: 0)
  let waiting = DispatchWorkItem { ran.update { $0 += 1000 } }
  q.async { _ = waits(gate) }
  q.async(execute: waiting)
  waiting.cancel()
  gate.signal()
  q.async { s.signal() }
  check(waits(s), "the queue went on past an item cancelled while waiting")
  check(ran.value == 2 && waiting.isCancelled, "an item cancelled while waiting never ran (ran \(ran.value))")

  let flagged = DispatchWorkItem(qos: .utility, flags: [.detached, .inheritQoS]) { ran.update { $0 += 1 } }
  q.async(execute: flagged)
  q.async { s.signal() }
  check(waits(s) && ran.value == 3, "an item with qos and flags ran (ran \(ran.value))")
}

// --- barriers: a barrier writer runs alone among a concurrent queue's readers
final class RW: Sendable {
  struct State: Sendable { var active = 0, maxActive = 0, barrier = false, violations = 0, barriers = 0 }
  let state = Box(State())
  let readerMs: Int
  init(readerMs: Int = 5) { self.readerMs = readerMs }
  // A meeting reader, while in flight, signals its own semaphore and waits for the other's (3 s).
  func reader(meeting: (mine: DispatchSemaphore, other: DispatchSemaphore, met: Box<Bool>)? = nil) {
    state.update { if $0.barrier { $0.violations += 1 }; $0.active += 1; $0.maxActive = max($0.maxActive, $0.active) }
    if let m = meeting { m.mine.signal(); m.met.value = waits(m.other, 3000) }
    ms(readerMs)
    state.update { if $0.barrier { $0.violations += 1 }; $0.active -= 1 }
  }
  func writer() {
    state.update { if $0.active != 0 || $0.barrier { $0.violations += 1 }; $0.barrier = true }
    ms(10)
    state.update { if $0.active != 0 { $0.violations += 1 }; $0.barrier = false; $0.barriers += 1 }
  }
}
func barrierCase(_ name: String, readerMs: Int = 5, _ submit: (DispatchQueue, RW, DispatchSemaphore) -> Void) {
  let q = DispatchQueue(label: "dispatch-overlay-test.rw", attributes: .concurrent)
  let rw = RW(readerMs: readerMs), writerDone = DispatchSemaphore(value: 0)
  let readers = DispatchGroup()
  // The first two readers meet, as the concurrent-queue case's blocks do: each, in flight, signals and then waits
  // for the other, so on a concurrent queue both are in flight at once however slowly its threads start, and
  // readers run one at a time (submitted as barriers, say) never meet.
  let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0), metA = Box(false), metB = Box(false)
  q.async(group: readers) { rw.reader(meeting: (mine: a, other: b, met: metA)) }
  q.async(group: readers) { rw.reader(meeting: (mine: b, other: a, met: metB)) }
  for _ in 0..<6 { q.async(group: readers) { rw.reader() } }
  submit(q, rw, writerDone)
  for _ in 0..<8 { q.async(group: readers) { rw.reader() } }
  check(readers.wait(timeout: .now() + .seconds(10)) == .success, "\(name): the 16 readers finished")
  check(waits(writerDone, 10000), "\(name): the barrier writer finished")
  let st = rw.state.value
  check(st.barriers == 1, "\(name): the writer ran once (\(st.barriers))")
  check(st.violations == 0, "\(name): the writer ran alone, \(st.violations) overlaps with readers")
  check(metA.value && metB.value, "\(name): the first two readers met, in flight at once")
  check(st.maxActive >= 2, "\(name): readers ran concurrently (at most \(st.maxActive) at once)")
}
func barriers() {
  barrierCase("async(execute: .barrier item)") { q, rw, done in
    q.async(execute: DispatchWorkItem(flags: .barrier) { rw.writer(); done.signal() })
  }
  barrierCase("async(flags: .barrier)") { q, rw, done in
    q.async(flags: .barrier) { rw.writer(); done.signal() }
  }
  barrierCase("async(group:flags: .barrier)") { q, rw, done in
    let g = DispatchGroup()
    q.async(group: g, flags: .barrier) { rw.writer() }
    let left = DispatchSemaphore(value: 0)
    g.notify(queue: DispatchQueue.global()) { left.signal() }
    check(waits(left, 10000), "async(group:flags: .barrier): the group's notify ran after the writer")
    check(rw.state.value.barriers == 1, "async(group:flags: .barrier): the group left only after the writer ran")
    done.signal()
  }
  barrierCase("sync(flags: .barrier)") { q, rw, done in
    q.sync(flags: .barrier) { rw.writer() }
    done.signal()
  }
  // The readers last 20 ms, so they are still running when the 8 ms deadline passes: a barrier that is not
  // routed as one starts then, with readers active, and the writer's own check (active == 0 at its start) fails.
  barrierCase("asyncAfter(flags: .barrier)", readerMs: 20) { q, rw, done in
    q.asyncAfter(deadline: .now() + .milliseconds(8), flags: .barrier) { rw.writer(); done.signal() }
  }
  // The item runs elsewhere; its notification, flagged barrier, is submitted to the readers' queue as one.
  barrierCase("notify(flags: .barrier)", readerMs: 20) { q, rw, done in
    let item = DispatchWorkItem { ms(8) }
    item.notify(flags: .barrier, queue: q) { rw.writer(); done.signal() }
    DispatchQueue.global().async(execute: item)
  }
}

// --- dispatchPrecondition: the passing forms (a failing one traps)
func preconditions() {
  let q = DispatchQueue(label: "dispatch-overlay-test.precondition")
  let other = DispatchQueue(label: "dispatch-overlay-test.precondition-other")
  let child = DispatchQueue(label: "dispatch-overlay-test.precondition-child", target: q)
  let passed = Box(0)
  dispatchPrecondition(condition: .notOnQueue(q))
  q.sync {
    dispatchPrecondition(condition: .onQueue(q))
    dispatchPrecondition(condition: .onQueueAsBarrier(q))
    dispatchPrecondition(condition: .notOnQueue(other))
    passed.update { $0 += 1 }
  }
  let s = DispatchSemaphore(value: 0)
  q.async {
    dispatchPrecondition(condition: .onQueue(q))
    passed.update { $0 += 1 }
    s.signal()
  }
  check(waits(s), "an async block's dispatchPrecondition(.onQueue) returned")
  child.async {
    dispatchPrecondition(condition: .onQueue(child))
    dispatchPrecondition(condition: .onQueue(q))
    dispatchPrecondition(condition: .notOnQueue(other))
    passed.update { $0 += 1 }
    s.signal()
  }
  check(waits(s), "dispatchPrecondition(.onQueue) of a queue's target returned")
  other.sync { dispatchPrecondition(condition: .notOnQueue(q)); passed.update { $0 += 1 } }
  check(passed.value == 4, "every passing dispatchPrecondition returned (\(passed.value) of 4 blocks)")
}

// --- DispatchWorkItem: wait and notify
func waitAndNotify() {
  let q = DispatchQueue(label: "dispatch-overlay-test.wait", attributes: .concurrent)
  let gate = DispatchSemaphore(value: 0), ranGated = DispatchSemaphore(value: 0)
  let order = Box([String]())

  // wait(timeout:) times out while the item cannot run; the item is not waited on again.
  let gated = DispatchWorkItem { _ = waits(gate); order.update { $0.append("gated") }; ranGated.signal() }
  q.async(execute: gated)
  check(gated.wait(timeout: .now() + .milliseconds(20)) == .timedOut, "wait(timeout:) timed out on a work item that cannot run")
  gate.signal()
  check(waits(ranGated), "the gated work item ran once let go")

  // wait() returns once the work has run.
  let ran = Box(false)
  let slow = DispatchWorkItem { ms(20); ran.value = true }
  q.async(execute: slow)
  slow.wait()
  check(ran.value, "wait() returned after the work item ran")
  let walled = DispatchWorkItem { ms(5); ran.value = false }
  q.async(execute: walled)
  check(walled.wait(wallTimeout: .now() + .seconds(5)) == .success && !ran.value, "wait(wallTimeout:) returned after the work item ran")

  // notify runs after the work item, both forms.
  let notified = DispatchSemaphore(value: 0)
  let gate2 = DispatchSemaphore(value: 0)
  let item = DispatchWorkItem { _ = waits(gate2); order.update { $0.append("item") } }
  item.notify(queue: q) { order.update { $0.append("notify") }; notified.signal() }
  item.notify(queue: q, execute: DispatchWorkItem { order.update { $0.append("notify-item") }; notified.signal() })
  q.async(execute: item)
  ms(20)
  check(!order.value.contains("notify") && !order.value.contains("notify-item"), "notify did not run before its work item")
  gate2.signal()
  check(waits(notified) && waits(notified), "both of a work item's notify blocks ran")
  let o = order.value
  if let i = o.firstIndex(of: "item"), let n = o.firstIndex(of: "notify"), let m = o.firstIndex(of: "notify-item") {
    check(i < n && i < m, "notify ran after its work item: \(o)")
  } else {
    check(false, "the work item and its notify blocks all ran: \(o)")
  }
}

// --- initially inactive queues and activate()
func inactiveQueues() {
  let s = DispatchSemaphore(value: 0)
  let ran = Box(0)
  let q = DispatchQueue(label: "dispatch-overlay-test.inactive", attributes: .initiallyInactive)
  q.async { ran.update { $0 += 1 }; s.signal() }
  check(!waits(s, 50) && ran.value == 0, "an initially inactive queue ran nothing before activate()")
  q.activate()
  check(waits(s) && ran.value == 1, "activate() started the inactive queue (ran \(ran.value))")
  q.activate()
  q.async { ran.update { $0 += 1 }; s.signal() }
  check(waits(s) && ran.value == 2, "a second activate() left the active queue running")

  let c = DispatchQueue(label: "dispatch-overlay-test.inactive-concurrent", qos: .utility,
                        attributes: [.concurrent, .initiallyInactive])
  let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  let metA = Box(false), metB = Box(false)
  c.async { a.signal(); metA.value = waits(b, 3000); done.signal() }
  c.async { b.signal(); metB.value = waits(a, 3000); done.signal() }
  check(!waits(done, 50), "an initially inactive concurrent queue ran nothing before activate()")
  c.activate()
  check(waits(done) && waits(done) && metA.value && metB.value, "the activated queue is concurrent: its two blocks met")

  // A resume() first counts as the activation, so activate() after it does not over-resume and trap.
  let r = DispatchQueue(label: "dispatch-overlay-test.resumed", attributes: .initiallyInactive)
  r.async { s.signal() }
  r.resume()
  check(waits(s), "resume() started an initially inactive queue")
  r.activate()
  r.async { s.signal() }
  check(waits(s), "activate() after resume() did not trap, and the queue still runs")

  // A source, started with activate() rather than resume().
  let src = DispatchSource.makeUserDataAddSource(queue: DispatchQueue(label: "dispatch-overlay-test.activate-source"))
  let got = Box(UInt(0))
  src.setEventHandler { got.update { $0 += src.data }; s.signal() }
  src.activate()
  src.add(data: 5)
  check(waits(s) && got.value == 5, "a source started with activate() delivered its data (\(got.value))")
  src.cancel()
}

// --- autoreleaseFrequency:
func autoreleaseFrequencies() {
  let s = DispatchSemaphore(value: 0)
  let cases: [(DispatchQueue.AutoreleaseFrequency, String)] = [(.inherit, "inherit"), (.workItem, "workItem"), (.never, "never")]
  for (f, name) in cases {
    let q = DispatchQueue(label: "dispatch-overlay-test.autorelease-\(name)", autoreleaseFrequency: f)
    let n = Box(0)
    for _ in 0..<3 { q.async { n.update { $0 += 1 } } }
    q.async { s.signal() }
    check(waits(s) && n.value == 3, "a queue with autoreleaseFrequency: .\(name) ran its blocks (\(n.value) of 3)")
  }
  let c = DispatchQueue(label: "dispatch-overlay-test.autorelease-concurrent", attributes: .concurrent,
                        autoreleaseFrequency: .workItem)
  c.async { s.signal() }
  check(waits(s), "a concurrent queue with autoreleaseFrequency: .workItem ran a block")
}

// --- target: at creation
func targets() {
  let key = DispatchSpecificKey<Int>()
  let serial = DispatchQueue(label: "dispatch-overlay-test.target")
  serial.setSpecific(key: key, value: 9)
  let conc = DispatchQueue(label: "dispatch-overlay-test.targeted", attributes: .concurrent, target: serial)
  let s = DispatchSemaphore(value: 0)
  let sawTarget = Box(false)
  conc.async { sawTarget.value = DispatchQueue.getSpecific(key: key) == 9; s.signal() }
  check(waits(s) && sawTarget.value, "a queue created with target: sees its target's specific value")

  // On a serial target, a concurrent queue's two blocks run one at a time: each, waiting 200 ms for the other,
  // never meets it, and no two are ever in flight.
  let active = Box(0), maxActive = Box(0)
  let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  let metA = Box(true), metB = Box(true)
  @Sendable func body(_ mine: DispatchSemaphore, _ other: DispatchSemaphore, _ met: Box<Bool>) {
    active.update { $0 += 1; let n = $0; maxActive.update { $0 = max($0, n) } }
    mine.signal(); met.value = waits(other, 200)
    active.update { $0 -= 1 }
    done.signal()
  }
  conc.async { body(a, b, metA) }
  conc.async { body(b, a, metB) }
  check(waits(done) && waits(done), "both blocks of the targeted concurrent queue finished")
  check(maxActive.value == 1, "a concurrent queue on a serial target ran its blocks one at a time (\(maxActive.value) at once)")
  check(!(metA.value && metB.value), "the targeted queue's two blocks never ran at once")

  let inactive = DispatchQueue(label: "dispatch-overlay-test.targeted-inactive", attributes: .initiallyInactive, target: serial)
  inactive.async { sawTarget.value = DispatchQueue.getSpecific(key: key) == 9; s.signal() }
  check(!waits(s, 50), "an inactive queue created with target: ran nothing before activate()")
  sawTarget.value = false
  inactive.activate()
  check(waits(s) && sawTarget.value, "the activated queue ran on its target")
}

// --- DispatchData
func data() {
  let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
  check(DispatchData.empty.count == 0, "DispatchData.empty has no bytes")
  var d = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
  check(d.count == 8, "DispatchData(bytes:) has \(d.count) bytes")
  let more: [UInt8] = [9, 10, 11]
  more.withUnsafeBytes { d.append($0) }
  check(d.count == 11, "append grew it to \(d.count)")
  d.append(DispatchData(bytes: bytes.withUnsafeBytes { UnsafeRawBufferPointer(rebasing: $0[0..<2]) }))
  check(d.count == 13, "appending a DispatchData grew it to \(d.count)")
  check(Array(d) == bytes + more + [1, 2], "the bytes read back by iteration: \(Array(d))")
  check(d[0] == 1 && d[8] == 9 && d[12] == 2, "subscript reads bytes")
  check(Array(d.subdata(in: 2..<6)) == [3, 4, 5, 6], "subdata(in:) is the slice")
  var out = [UInt8](repeating: 0, count: 13)
  let copied = out.withUnsafeMutableBufferPointer { d.copyBytes(to: $0) }
  check(copied == 13 && out == Array(d), "copyBytes(to:) copies them all (\(copied))")
  let (region, offset) = d.region(location: 9)
  check(offset <= 9 && offset + region.count > 9, "region(location:) holds the location (offset \(offset), count \(region.count))")
}

// --- run them off the main queue, which dispatchMain() serves; the last step exits from the main queue
let suite = DispatchQueue(label: "dispatch-overlay-test.suite")
suite.async {
  mainQueue(); globalQueues(); serialAndConcurrent(); groups(); semaphores(); timing(); sources()
  workItems(); barriers(); preconditions(); waitAndNotify(); inactiveQueues(); autoreleaseFrequencies(); targets()
  data()
  DispatchQueue.main.async {
    if failures.value > 0 { print("dispatch_overlay_test FAILED (\(failures.value))"); exit(1) }
    print("dispatch_overlay_test OK")
    exit(0)
  }
}
// A backstop only (each wait above is bounded already), on a thread of its own: not the main queue, which
// a broken dispatchMain would leave unserved, nor a dispatch queue, which would be what is broken.
// nonisolated: in Swift 6 mode a closure written in top-level code is the main actor's, and its entry
// checks that it runs there, which a thread of its own never does.
nonisolated func watchdogBody(_: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  sleep(45); print("FAIL: dispatch_overlay_test did not finish in 45 s"); exit(1)
}
var watchdog: pthread_t? = nil
pthread_create(&watchdog, nil, watchdogBody, nil)
dispatchMain()
