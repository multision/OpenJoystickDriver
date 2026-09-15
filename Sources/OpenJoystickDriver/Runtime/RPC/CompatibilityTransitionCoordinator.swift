import Foundation
import OpenJoystickDriverKit

enum CompatibilityTransitionError: Error, Sendable {
  case stageTimedOut
  case feedbackTimedOut
  case candidateCloseTimedOut
  case activationTimedOut
  case rollbackStageTimedOut
  case rollbackTimedOut
  case zeroDeviceIntervalTimedOut
  case serverStopped
}

func withCompatibilityTimeout<Value: Sendable>(
  _ timeout: UInt64,
  clock: CompatibilityTransitionClock,
  error: CompatibilityTransitionError,
  operation: @escaping @Sendable () async throws -> Value,
  onLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
) async throws -> Value {
  guard timeout > 0 else { throw error }

  let stream = AsyncThrowingStream<Value, Error> { continuation in
    let operationTask = Task.detached {
      do {
        let result = try await operation()
        switch continuation.yield(result) {
        case .enqueued: continuation.finish()
        case .dropped, .terminated:
          await onLateSuccess(result)
          continuation.finish()
        @unknown default: continuation.finish()
        }
      } catch { continuation.finish(throwing: error) }
    }
    let timerTask = Task.detached {
      do {
        try await clock.sleep(timeout)
        continuation.finish(throwing: error)
      } catch {
        // Cancellation only stops the timer.
      }
    }
    continuation.onTermination = { _ in
      operationTask.cancel()
      timerTask.cancel()
    }
  }
  var iterator = stream.makeAsyncIterator()
  guard let result = try await iterator.next() else { throw CancellationError() }
  return result
}

final class CompatibilityTransitionCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  var isStopped: Bool { lock.withLock { stopped } }
  func stop() { lock.withLock { stopped = true } }
}

actor CompatibilityTransitionCoordinator {
  private var tail: Task<Bool, Never>?
  private let cancellation = CompatibilityTransitionCancellation()
  private var submittedCount = 0

  func enqueue(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
    guard !cancellation.isStopped else { return false }
    submittedCount += 1
    let previous = tail
    let cancellation = self.cancellation
    let next = Task {
      _ = await previous?.value
      guard !Task.isCancelled, !cancellation.isStopped else { return false }
      return await operation()
    }
    tail = next
    return await next.value
  }

  func stop() {
    cancellation.stop()
    tail?.cancel()
    tail = nil
  }

  func submissionCount() -> Int { submittedCount }
}

final class CompatibilityFeedbackGate: @unchecked Sendable {
  typealias SendFeedback = @Sendable (DeviceIdentifier, VirtualRumbleCommand) async -> Void

  private let sendFeedback: SendFeedback
  let lock = NSLock()
  private var accepting = true
  private var generation: UInt64 = 0
  private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

  init(deviceManager: DeviceManager) {
    sendFeedback = { identifier, command in
      _ = await deviceManager.sendRumble(
        for: identifier,
        left: command.left,
        right: command.right,
        lt: command.leftTrigger,
        rt: command.rightTrigger,
        durationMs: command.durationMs
      )
    }
  }

  init(sendFeedback: @escaping SendFeedback) { self.sendFeedback = sendFeedback }

  func submit(identifier: DeviceIdentifier, command: VirtualRumbleCommand) {
    let token = UUID()
    let currentGeneration = lock.withLock { () -> UInt64? in
      guard accepting else { return nil }
      return generation
    }
    guard let currentGeneration else { return }
    let task = Task { [weak self] in
      guard let self, self.isCurrent(currentGeneration) else {
        self?.finish(token)
        return
      }
      await self.sendFeedback(identifier, command)
      self.finish(token)
    }
    let shouldCancel = lock.withLock { () -> Bool in
      cancellationHandlers[token] = { task.cancel() }
      return !accepting || generation != currentGeneration
    }
    if shouldCancel { task.cancel() }
  }

  func quiesceAndNeutralize(
    _ identifiers: [DeviceIdentifier],
    timeout: UInt64 = CompatibilityTransitionTimeouts.standard.feedbackNanoseconds,
    clock: CompatibilityTransitionClock = .system,
    resumeWhenComplete: Bool = false
  ) async -> Bool {
    let (wasAccepting, cancellations) = lock.withLock {
      let wasAccepting = accepting
      accepting = false
      generation &+= 1
      let cancellations = Array(cancellationHandlers.values)
      cancellationHandlers.removeAll()
      return (wasAccepting, cancellations)
    }
    cancellations.forEach { $0() }

    // A canceled HID/USB write is not required to cooperate with Swift task cancellation. Once
    // admission advances to a new generation, quarantine those writes instead of waiting for
    // their completion. Queue one neutral write per controller behind any late operation and
    // bound only how long this transition waits for the neutralization attempt.
    do {
      try await withCompatibilityTimeout(timeout, clock: clock, error: .feedbackTimedOut) {
        await withTaskGroup(of: Void.self) { group in
          for identifier in identifiers {
            group.addTask {
              await self.sendFeedback(
                identifier,
                VirtualRumbleCommand(
                  left: 0,
                  right: 0,
                  leftTrigger: 0,
                  rightTrigger: 0,
                  durationMs: 0
                )
              )
            }
          }
          await group.waitForAll()
        }
      }
    } catch {
      // The queued neutral writes remain owned by their transport workers. Their late completion
      // cannot re-open feedback admission or mutate the compatibility publication.
    }
    if resumeWhenComplete && wasAccepting { resume() }
    return true
  }

  func resume() {
    lock.withLock {
      generation &+= 1
      accepting = true
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.withLock { accepting && self.generation == generation }
  }

  private func finish(_ token: UUID) {
    _ = lock.withLock { cancellationHandlers.removeValue(forKey: token) }
  }
}

struct CompatibilityTransitionSnapshot: Sendable {
  let requestedIdentity: CompatibilityIdentity
  let persistedIdentity: CompatibilityIdentity
  let liveIdentity: CompatibilityIdentity?
  let enabled: Bool
  let dispatcher: (any CompatibilityUserSpaceOutputDispatching)?
  let closeSlot: CompatibilityBackendCloseSlot?
}

struct CompatibilityRetrySnapshot: Codable, Equatable, Sendable {
  let requestedIdentity: CompatibilityIdentity
  let priorProfileIdentity: CompatibilityIdentity
  let phase: CompatibilityTransitionPhase
  let detail: String?

  init(
    requestedIdentity: CompatibilityIdentity,
    priorProfileIdentity: CompatibilityIdentity,
    phase: CompatibilityTransitionPhase,
    detail: String? = nil
  ) {
    self.requestedIdentity = requestedIdentity
    self.priorProfileIdentity = priorProfileIdentity
    self.phase = phase
    self.detail = detail
  }
}

enum CompatibilityTransitionPhase: String, Codable, Equatable, Sendable {
  case stage
  case feedbackQuiescence
  case candidateClose
  case activation
  case rollbackStage
  case rollbackActivation
  case zeroDeviceInterval
}

final class CompatibilityBackendCloseSlot: @unchecked Sendable {
  let backend: any CompatibilityUserSpaceOutputDispatching
  let lock = NSLock()
  private var closeTask: Task<Void, Never>?

  init(_ backend: any CompatibilityUserSpaceOutputDispatching) { self.backend = backend }

  func close(
    timeout: UInt64,
    clock: CompatibilityTransitionClock,
    error: CompatibilityTransitionError = .candidateCloseTimedOut
  ) async -> Bool {
    let task = lock.withLock { () -> Task<Void, Never> in
      if let closeTask { return closeTask }
      let backend = self.backend
      let task = Task.detached { await backend.close() }
      closeTask = task
      return task
    }
    do {
      try await withCompatibilityTimeout(timeout, clock: clock, error: error) { await task.value }
      return true
    } catch { return false }
  }
}

extension ApplicationServiceServer {}
