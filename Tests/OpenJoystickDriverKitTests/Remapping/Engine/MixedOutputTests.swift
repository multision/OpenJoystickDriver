import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct RemappingMixedOutputTests {}

final class MixedOutputRecorder: RemappingSystemInputSink, RemappingGamepadSink, @unchecked Sendable
{
  private let lock = NSLock()
  private var recorded: [RemappingEngineAction] = []
  private var rejectsNextGamepad = false

  var actions: [RemappingEngineAction] { lock.withLock { recorded } }

  func rejectNextGamepadSend() { lock.withLock { rejectsNextGamepad = true } }

  func send(_ action: RemappingSystemInputAction) {
    lock.withLock { recorded.append(.system(action)) }
  }

  func send(_ state: RemappingGamepadState, for identifier: DeviceIdentifier) async throws {
    let reject = lock.withLock {
      recorded.append(.gamepad(state, identifier))
      defer { rejectsNextGamepad = false }
      return rejectsNextGamepad
    }
    if reject { throw RemappingEventEngineError.sinkUnavailable }
    await Task.yield()
  }
}

actor SuspendedGamepadSink: RemappingGamepadSink {
  private(set) var states: [RemappingGamepadState] = []
  private(set) var terminationCompleted = false
  private var suspended = false
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var sendWaiter: CheckedContinuation<Void, Never>?

  func send(_ state: RemappingGamepadState, for identifier: DeviceIdentifier) async {
    states.append(state)
    guard !suspended else { return }
    suspended = true
    startedWaiter?.resume()
    startedWaiter = nil
    await withCheckedContinuation { sendWaiter = $0 }
  }

  func waitUntilSuspended() async {
    guard !suspended else { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  func resumeSend() {
    sendWaiter?.resume()
    sendWaiter = nil
  }

  func markTerminationCompleted() { terminationCompleted = true }
}
