import Foundation
import CoreHID
import Testing

@testable import OpenJoystickDriverKit

private actor ReportSendGate {
  private var opened = false
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    enteredWaiters.forEach { $0.resume() }
    enteredWaiters.removeAll()
    if !opened { await withCheckedContinuation { waiters.append($0) } }
  }

  func waitForEntry() async {
    if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
  }

  func open() {
    opened = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

private final class OrderedReportBackend: UserSpaceOutputDispatcher.VirtualDeviceBackend,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var reports: [[UInt8]] = []
  private var activeSends = 0
  private var maxActiveSends = 0
  private var closes = 0
  let gate: ReportSendGate?

  init(gate: ReportSendGate? = nil) { self.gate = gate }

  func send(_ report: [UInt8]) async {
    lock.withLock {
      activeSends += 1
      maxActiveSends = max(maxActiveSends, activeSends)
    }
    await gate?.wait()
    lock.withLock {
      reports.append(report)
      activeSends -= 1
    }
  }

  func close() { lock.withLock { closes += 1 } }
  func snapshot() -> (reports: [[UInt8]], maxActive: Int, closes: Int) {
    lock.withLock { (reports, maxActiveSends, closes) }
  }
}

private actor CancellableSendState {
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markEntered() {
    entered = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }

  func waitForEntry() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
}

private final class CancellableReportBackend: UserSpaceOutputDispatcher.VirtualDeviceBackend,
  @unchecked Sendable
{
  let state = CancellableSendState()

  func send(_ report: [UInt8]) async throws {
    await state.markEntered()
    try await Task.sleep(nanoseconds: .max)
  }

  func close() {}
}

private actor NonCooperativeSendGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    entryWaiters.forEach { $0.resume() }
    entryWaiters.removeAll()
    if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
  }

  func waitForEntry() async {
    if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
  }

  func release() {
    released = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private final class NonCooperativeReportBackend: UserSpaceOutputDispatcher.VirtualDeviceBackend,
  @unchecked Sendable
{
  private let lock = NSLock()
  let gate = NonCooperativeSendGate()
  private var closes = 0

  func send(_ report: [UInt8]) async { await gate.wait() }
  func close() { lock.withLock { closes += 1 } }
  func closeCount() -> Int { lock.withLock { closes } }
}

private actor KeepaliveClock {
  private var ticks = 0
  private var cancelled = false
  private var sleepers: [CheckedContinuation<Void, Never>] = []
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep() async {
    ticks += 1
    let ready = observers.filter { $0.0 <= ticks }
    observers.removeAll { $0.0 <= ticks }
    ready.forEach { $0.1.resume() }
    await withTaskCancellationHandler {
      if !cancelled { await withCheckedContinuation { sleepers.append($0) } }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func waitForTick(_ count: Int) async {
    if ticks < count { await withCheckedContinuation { observers.append((count, $0)) } }
  }

  func advance() {
    let values = sleepers
    sleepers.removeAll()
    values.forEach { $0.resume() }
  }

  private func cancel() {
    cancelled = true
    advance()
  }
}

private final class KeepaliveActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  func set(_ value: Bool) { lock.withLock { active = value } }
  func get() -> Bool { lock.withLock { active } }
}

struct ReportSenderTests {
  @available(macOS 15, *)
  @Test(.timeLimit(.minutes(1)))
  func coreHIDNintendoSetReportReturnsAfterOrderedEnqueue() async throws {
    let gate = ReportSendGate()
    let backend = OrderedReportBackend(gate: gate)
    let input = UserSpaceInputReportState(format: SwitchProUSBHIDReportFormat())
    let entry = UserSpaceOutputDispatcher.Entry(backend: backend, inputReportState: input)
    let isOpen: @Sendable () -> Bool = { true }
    let handler = UserSpaceHostReportHandler(
      identifier: DeviceIdentifier(vendorID: 1, productID: 2),
      input: input,
      sender: entry.sender,
      isOpen: isOpen,
      onRumble: nil
    ) { _ in }
    let delegate = UserSpaceOutputDispatcher.CoreHIDDelegate(handler: handler)
    let first = [1, 0] + [UInt8](repeating: 0, count: 8) + [2]
    let second = [1, 0] + [UInt8](repeating: 0, count: 8) + [3, 0x30]

    try delegate.enqueueSetReport(type: .output, id: HIDReportID(rawValue: 1), data: Data(first))
    try delegate.enqueueSetReport(type: .output, id: HIDReportID(rawValue: 1), data: Data(second))
    await gate.waitForEntry()
    await gate.open()
    try await entry.sender.submit { [] }.value()

    let reports = backend.snapshot().reports
    #expect(reports.count == 2)
    #expect(reports.map { $0[14] } == [2, 3])
    await entry.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func suppressionBetweenReportsSkipsTheRemainingReportAndCanResume() async throws {
    let gate = ReportSendGate()
    let backend = OrderedReportBackend(gate: gate)
    let sender = UserSpaceReportSender()
    let activity = KeepaliveActivity()
    sender.attach(backend)
    let isActive: @Sendable () -> Bool = { activity.get() }
    let reports = sender.submit(whileActive: isActive) { [[1], [2]] }
    await gate.waitForEntry()
    activity.set(false)
    let barrier = sender.submit { [] }
    await gate.open()
    try await reports.value()
    try await barrier.value()
    #expect(backend.snapshot().reports == [[1]])
    activity.set(true)
    try await sender.submit(whileActive: isActive) { [[3]] }.value()
    #expect(backend.snapshot().reports == [[1], [3]])
    await sender.beginClose().value
  }

  @Test(.timeLimit(.minutes(1)))
  func eventsKeepalivesAndHostRepliesShareOneOrder() async throws {
    let gate = ReportSendGate()
    let backend = OrderedReportBackend(gate: gate)
    let input = UserSpaceInputReportState(format: SwitchProUSBHIDReportFormat())
    let entry = UserSpaceOutputDispatcher.Entry(backend: backend, inputReportState: input)
    let first = entry.sender.submit { [input] in [input.update { $0.buttons = 1 }] }
    await gate.waitForEntry()
    let second = entry.sender.submit { [input] in [input.update { $0.buttons = 2 }] }
    let keepalive = entry.sender.submit { [input] in [input.currentReport()] }
    let isOpen: @Sendable () -> Bool = { true }
    let handler = UserSpaceHostReportHandler(
      identifier: DeviceIdentifier(vendorID: 1, productID: 2),
      input: input,
      sender: entry.sender,
      isOpen: isOpen,
      onRumble: nil
    ) { _ in }
    let reply = try handler.setReport(
      type: .output,
      reportID: 1,
      bytes: [1, 0] + [UInt8](repeating: 0, count: 8) + [2]
    )
    await gate.open()
    try await first.value()
    try await second.value()
    try await keepalive.value()
    try await reply.value()
    let snapshot = backend.snapshot()
    #expect(snapshot.maxActive == 1)
    try #require(snapshot.reports.count == 4)
    #expect(snapshot.reports[0][3] == 4)
    #expect(snapshot.reports[1][3] == 8)
    #expect(snapshot.reports[2] == snapshot.reports[1])
    #expect(snapshot.reports[3][0] == 0x21)
    #expect(snapshot.reports[3][3] == 8)
    await entry.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func closeRejectsQueuedWorkAndClosesBackendBeforeDrainingCurrentSend() async throws {
    let gate = ReportSendGate()
    let backend = OrderedReportBackend(gate: gate)
    let sender = UserSpaceReportSender()
    sender.attach(backend)
    let first = sender.submit { [[1]] }
    await gate.waitForEntry()
    let queued = sender.submit { [[2]] }
    let close = sender.beginClose()
    let repeatedClose = sender.beginClose()
    #expect(backend.snapshot().closes == 1)
    await #expect(throws: CancellationError.self) { try await sender.submit { [[3]] }.value() }
    await gate.open()
    try await first.value()
    await #expect(throws: CancellationError.self) { try await queued.value() }
    await close.value
    await repeatedClose.value
    #expect(backend.snapshot().reports == [[1]])
    #expect(backend.snapshot().closes == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func closeCancelsAStalledCurrentSend() async {
    let backend = CancellableReportBackend()
    let sender = UserSpaceReportSender()
    sender.attach(backend)
    _ = sender.submit { [[1]] }
    await backend.state.waitForEntry()

    await sender.beginClose().value
  }

  @Test(.timeLimit(.minutes(1)))
  func closeCompletesWhenNativeSendIgnoresCancellation() async {
    let backend = NonCooperativeReportBackend()
    let sender = UserSpaceReportSender()
    sender.attach(backend)
    _ = sender.submit { [[1]] }
    await backend.gate.waitForEntry()

    await sender.beginClose().value
    #expect(backend.closeCount() == 1)
    await backend.gate.release()
  }

  @Test(.timeLimit(.minutes(1)))
  func stalledControllerPublicationDoesNotBlockAnotherController() async throws {
    let gate = ReportSendGate()
    let stalledBackend = OrderedReportBackend(gate: gate)
    let readyBackend = OrderedReportBackend()
    let stalled = UserSpaceReportSender()
    let ready = UserSpaceReportSender()
    stalled.attach(stalledBackend)
    ready.attach(readyBackend)

    let blocked = stalled.submit { [[1]] }
    await gate.waitForEntry()
    try await ready.submit { [[2]] }.value()
    #expect(readyBackend.snapshot().reports == [[2]])

    await gate.open()
    try await blocked.value()
    await stalled.beginClose().value
    await ready.beginClose().value
  }

  @Test(.timeLimit(.minutes(1)))
  func keepaliveResumesAfterSuppressionWithoutAnInputEvent() async {
    let backend = OrderedReportBackend()
    let input = UserSpaceInputReportState(format: OJDGenericGamepadFormat())
    let entry = UserSpaceOutputDispatcher.Entry(backend: backend, inputReportState: input)
    let clock = KeepaliveClock()
    let activity = KeepaliveActivity()
    entry.startInputReportKeepalive(
      isActive: { activity.get() },
      sleep: { _ in await clock.sleep() }
    )
    await clock.waitForTick(1)
    await clock.advance()
    await clock.waitForTick(2)
    #expect(backend.snapshot().reports.count == 1)
    activity.set(false)
    await clock.advance()
    await clock.waitForTick(3)
    #expect(backend.snapshot().reports.count == 1)
    activity.set(true)
    await clock.advance()
    await clock.waitForTick(4)
    #expect(backend.snapshot().reports.count == 2)
    await entry.close()
    #expect(backend.snapshot().closes == 1)
  }
}
