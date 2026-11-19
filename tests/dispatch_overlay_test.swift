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
// DispatchWorkItem, async(flags:), async(group:flags:), sync(flags:), asyncAfter(flags:)).
// What the overlay leaves out on 10.9 (dispatchPrecondition, DispatchWorkItem.wait/notify,
// DispatchQueue.qos, autoreleaseFrequency:, .initiallyInactive, the user-data-replace source, the
// target: initializer) is not tried, and no source is cast to its per-type protocol, which 10.9 lacks.
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
func mainQueue() {
  let s = DispatchSemaphore(value: 0)
  let onMain = Box(false)
  DispatchQueue.main.async { onMain.value = pthread_main_np() != 0; s.signal() }
  check(waits(s), "a block async to DispatchQueue.main ran")
  check(onMain.value, "DispatchQueue.main's block ran on the main thread")
  check(DispatchQueue.main.sync { pthread_main_np() != 0 }, "DispatchQueue.main.sync ran on the main thread")
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
  for _ in 0..<10 { g.enter(); q.async { ms(5); n.update { $0 += 1 }; g.leave() } }
  let notified = DispatchSemaphore(value: 0)
  let atNotify = Box(-1)
  g.notify(queue: q) { atNotify.value = n.value; notified.signal() }
  check(waits(notified), "a group's notify ran")
  check(atNotify.value == 10, "notify ran after all 10 members (saw \(atNotify.value))")
  check(g.wait(timeout: .now() + .seconds(1)) == .success, "wait on a finished group succeeds")
  g.enter()
  check(g.wait(timeout: .now() + .milliseconds(50)) == .timedOut, "wait on a group never left times out")
  g.leave()
  let g2 = DispatchGroup()
  g2.enter(); q.asyncAfter(deadline: .now() + .milliseconds(30)) { g2.leave() }
  check(g2.wait(timeout: .now() + .seconds(5)) == .success, "wait returns once the last member leaves")
}

// --- a semaphore
func semaphores() {
  let s = DispatchSemaphore(value: 0)
  check(s.wait(timeout: .now() + .milliseconds(50)) == .timedOut, "an empty semaphore's wait times out")
  DispatchQueue.global().async { ms(10); _ = s.signal() }
  check(waits(s), "a signal from another queue wakes the wait")
  let two = DispatchSemaphore(value: 2)
  check(two.wait(timeout: .now()) == .success && two.wait(timeout: .now()) == .success, "a semaphore of 2 takes two waits")
  check(two.wait(timeout: .now() + .milliseconds(20)) == .timedOut, "and no third")
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
  for d in [300, 100, 200] {
    q.asyncAfter(deadline: start + .milliseconds(d), qos: .default, flags: []) { }
    g.enter()
    q.asyncAfter(deadline: start + .milliseconds(d)) {
      order.update { $0.append(d) }
      if d == 100 { firedAt.value = DispatchTime.now().uptimeNanoseconds }
      g.leave()
    }
  }
  check(g.wait(timeout: .now() + .seconds(5)) == .success, "the asyncAfter blocks ran")
  check(order.value == [100, 200, 300], "asyncAfter ran in deadline order: \(order.value)")
  check(firedAt.value >= start.uptimeNanoseconds + 95_000_000, "asyncAfter(100 ms) did not fire early")
  let s = DispatchSemaphore(value: 0)
  q.asyncAfter(wallDeadline: .now() + .milliseconds(20)) { s.signal() }
  check(waits(s), "asyncAfter(wallDeadline:) ran")
  let w = DispatchWorkItem { s.signal() }
  q.asyncAfter(deadline: .now() + .milliseconds(20), execute: w)
  check(waits(s), "asyncAfter(deadline:execute: DispatchWorkItem) ran")
}

// --- sources: a timer, a user-data-add
func sources() {
  let q = DispatchQueue(label: "dispatch-overlay-test.source")
  let timer = DispatchSource.makeTimerSource(queue: q)
  let fired = Box(0)
  let three = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
  timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(20))
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
  ms(100)
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
  func reader() {
    state.update { if $0.barrier { $0.violations += 1 }; $0.active += 1; $0.maxActive = max($0.maxActive, $0.active) }
    ms(15)
    state.update { if $0.barrier { $0.violations += 1 }; $0.active -= 1 }
  }
  func writer() {
    state.update { if $0.active != 0 || $0.barrier { $0.violations += 1 }; $0.barrier = true }
    ms(30)
    state.update { if $0.active != 0 { $0.violations += 1 }; $0.barrier = false; $0.barriers += 1 }
  }
}
func barrierCase(_ name: String, _ submit: (DispatchQueue, RW, DispatchSemaphore) -> Void) {
  let q = DispatchQueue(label: "dispatch-overlay-test.rw", attributes: .concurrent)
  let rw = RW(), writerDone = DispatchSemaphore(value: 0)
  let readers = DispatchGroup()
  for _ in 0..<8 { q.async(group: readers) { rw.reader() } }
  submit(q, rw, writerDone)
  for _ in 0..<8 { q.async(group: readers) { rw.reader() } }
  check(readers.wait(timeout: .now() + .seconds(10)) == .success, "\(name): the 16 readers finished")
  check(waits(writerDone, 10000), "\(name): the barrier writer finished")
  let st = rw.state.value
  check(st.barriers == 1, "\(name): the writer ran once (\(st.barriers))")
  check(st.violations == 0, "\(name): the writer ran alone, \(st.violations) overlaps with readers")
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
  barrierCase("asyncAfter(flags: .barrier)") { q, rw, done in
    q.asyncAfter(deadline: .now() + .milliseconds(25), flags: .barrier) { rw.writer(); done.signal() }
  }
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
  workItems(); barriers(); data()
  DispatchQueue.main.async {
    if failures.value > 0 { print("dispatch_overlay_test FAILED (\(failures.value))"); exit(1) }
    print("dispatch_overlay_test OK")
    exit(0)
  }
}
// A backstop only: each wait above is bounded already.
DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(45)) { print("FAIL: dispatch_overlay_test did not finish in 45 s"); exit(1) }
dispatchMain()
