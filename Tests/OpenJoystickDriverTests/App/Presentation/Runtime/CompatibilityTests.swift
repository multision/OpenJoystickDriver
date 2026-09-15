import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

final class AutomaticBackendProbe: CompatibilityUserSpaceOutputDispatching,
  ControllerLifecycleListener, @unchecked Sendable
{
  struct ActivationFailure: Error, Sendable {}

  let failsActivation: Bool
  private(set) var closed = false
  private(set) var activations: [[DeviceIdentifier]] = []
  var suppressOutput = false
  var status: String { "probe" }
  var lastRumbleStatus: String { "none" }
  init(failsActivation: Bool = false) { self.failsActivation = failsActivation }
  func activate(for identifiers: [DeviceIdentifier]) throws {
    activations.append(identifiers)
    if failsActivation { throw ActivationFailure() }
  }
  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {}
  func controllerDidStop(_ identifier: DeviceIdentifier) {}
  func close() { closed = true }
}

final class AutomaticConsumerBox: @unchecked Sendable {
  var value = CompatibilityConsumerFamily.sdlHIDAPI
  var created: [AutomaticBackendProbe] = []
}

final class ConcurrentBackendProbe: CompatibilityUserSpaceOutputDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var dispatchCount = 0
  private var closeCount = 0
  var suppressOutput = false
  var status: String { "probe" }
  var lastRumbleStatus: String { "none" }
  func activate(for identifiers: [DeviceIdentifier]) throws {}
  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {
    lock.withLock { dispatchCount += 1 }
  }
  func controllerDidStop(_ identifier: DeviceIdentifier) {}
  func close() { lock.withLock { closeCount += 1 } }
  func counts() -> (Int, Int) { lock.withLock { (dispatchCount, closeCount) } }
}

final class ConcurrentFactoryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let enteredSignal = DispatchSemaphore(value: 0)
  private(set) var created = 0
  private(set) var entered = 0
  private(set) var backends: [ConcurrentBackendProbe] = []
  var gate: DispatchSemaphore?
  func make() -> ConcurrentBackendProbe {
    lock.withLock { entered += 1 }
    enteredSignal.signal()
    gate?.wait()
    return lock.withLock {
      created += 1
      let backend = ConcurrentBackendProbe()
      backends.append(backend)
      return backend
    }
  }
  func snapshot() -> (Int, Int, [ConcurrentBackendProbe]) {
    lock.withLock { (created, entered, backends) }
  }
  func waitForEntered() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        self.enteredSignal.wait()
        continuation.resume()
      }
    }
  }
}

@Suite(.serialized)
struct CompatibilityTests {}
