import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

actor CompatibilityTransitionGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

actor CompatibilityFeedbackProbe {
  private var commands: [VirtualRumbleCommand] = []

  func append(_ command: VirtualRumbleCommand) { commands.append(command) }
  func count() -> Int { commands.count }
  func values() -> [VirtualRumbleCommand] { commands }
}

final class CompatibilityTransitionProbe: CompatibilityUserSpaceOutputDispatching,
  CompatibilityUserSpaceOutputControllerActivating, @unchecked Sendable
{
  struct ActivationFailure: Error, Sendable {}

  let identity: CompatibilityIdentity
  let activationGate: CompatibilityTransitionGate?
  let closeGate: CompatibilityTransitionGate?
  let failsActivation: Bool
  private let lock = NSLock()
  private var closeCount = 0
  private var activations: [[DeviceIdentifier]] = []

  init(
    identity: CompatibilityIdentity,
    activationGate: CompatibilityTransitionGate? = nil,
    closeGate: CompatibilityTransitionGate? = nil,
    failsActivation: Bool = false
  ) {
    self.identity = identity
    self.activationGate = activationGate
    self.closeGate = closeGate
    self.failsActivation = failsActivation
  }

  var closeCountValue: Int { lock.withLock { closeCount } }
  var activationValues: [[DeviceIdentifier]] { lock.withLock { activations } }
  var suppressOutput = false
  var status: String { "probe" }
  var lastRumbleStatus: String { "none" }

  func activate(for identifiers: [DeviceIdentifier]) async throws {
    lock.withLock { activations.append(identifiers) }
    await activationGate?.wait()
    if failsActivation { throw ActivationFailure() }
  }

  func activate(controller identifier: DeviceIdentifier) async throws {
    try await activate(for: [identifier])
  }

  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {}
  func setOutputSuppressed(_ suppressed: Bool) { suppressOutput = suppressed }
  func close() async {
    await closeGate?.wait()
    lock.withLock { closeCount += 1 }
  }
}

final class CompatibilityTransitionFactory: @unchecked Sendable {
  struct BuildFailure: Error, Sendable {}

  private let lock = NSLock()
  private var probes: [CompatibilityTransitionProbe] = []
  var buildFailures: Set<CompatibilityIdentity> = []
  var activationFailures: Set<CompatibilityIdentity> = []
  var firstActivationGate: CompatibilityTransitionGate?
  var closeGates: [CompatibilityIdentity: CompatibilityTransitionGate] = [:]

  func make(_ identity: CompatibilityIdentity) throws -> any CompatibilityUserSpaceOutputDispatching
  {
    if buildFailures.contains(identity) { throw BuildFailure() }
    return lock.withLock { () -> CompatibilityTransitionProbe in
      let probe = CompatibilityTransitionProbe(
        identity: identity,
        activationGate: probes.isEmpty ? firstActivationGate : nil,
        closeGate: closeGates[identity],
        failsActivation: activationFailures.contains(identity)
      )
      probes.append(probe)
      return probe
    }
  }

  func values() -> [CompatibilityTransitionProbe] { lock.withLock { probes } }

  func waitForCount(_ count: Int) async {
    while lock.withLock({ probes.count }) < count { await Task.yield() }
  }
}

final class IdentifierSnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [[DeviceIdentifier]]

  init(_ snapshots: [[DeviceIdentifier]]) { self.snapshots = snapshots }

  func next() -> [DeviceIdentifier] {
    lock.withLock {
      guard snapshots.count > 1 else { return snapshots.first ?? [] }
      return snapshots.removeFirst()
    }
  }
}

@Suite(.serialized)
struct CompatibilityTransitionTests {}
