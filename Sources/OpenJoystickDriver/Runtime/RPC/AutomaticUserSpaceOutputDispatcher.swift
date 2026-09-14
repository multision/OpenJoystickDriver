import Foundation
import OpenJoystickDriverKit

final class AutomaticUserSpaceOutputDispatcher: CompatibilityUserSpaceOutputDispatching,
  CompatibilityUserSpaceOutputControllerActivating, ControllerLifecycleListener,
  RemappingGamepadSink, RemappingGamepadOutputControlling, @unchecked Sendable
{
  private let deviceManager: DeviceManager
  private let ownershipProvider:
    @Sendable (DeviceIdentifier) async -> ControllerOwnershipObservation
  private let descriptionsProvider: @Sendable () async -> [ApplicationServiceDeviceDescription]
  private let consumerProvider: @Sendable () -> CompatibilityConsumerFamily
  private let identityProvider:
    @Sendable (ApplicationServiceDeviceDescription, CompatibilityConsumerFamily) ->
      AutomaticCompatibilityTarget
  private let builder:
    @Sendable (AutomaticCompatibilityTarget) throws -> any CompatibilityUserSpaceOutputDispatching
  private let coordinator = AutomaticDispatcherCoordinator()
  private let stateLock = NSLock()
  private var suppressedOutput = false
  private var remappingSuppressedOutput = false
  private var consumer: CompatibilityConsumerFamily
  private var consumerRevision: UInt64 = 0
  private var diagnosticTargets: [DeviceIdentifier: AutomaticCompatibilityTarget] = [:]
  private var publicationDiagnostics: [String] = []
  private var observationTask: Task<Void, Never>?
  init(
    deviceManager: DeviceManager,
    ownershipProvider: (@Sendable (DeviceIdentifier) async -> ControllerOwnershipObservation)? =
      nil,
    consumerProvider: @escaping @Sendable () -> CompatibilityConsumerFamily,
    builder:
      @escaping @Sendable (AutomaticCompatibilityTarget) throws ->
      any CompatibilityUserSpaceOutputDispatching,
    observeConsumerChanges: Bool = true,
    descriptionsProvider: (@Sendable () async -> [ApplicationServiceDeviceDescription])? = nil,
    identityProvider:
      @escaping @Sendable (ApplicationServiceDeviceDescription, CompatibilityConsumerFamily) ->
      AutomaticCompatibilityTarget = { description, consumer in
        AutomaticCompatibilityResolver.target(for: description, consumer: consumer)
      }
  ) {
    self.deviceManager = deviceManager
    self.ownershipProvider =
      ownershipProvider ?? { identifier in await deviceManager.ownershipObservation(for: identifier)
      }
    self.descriptionsProvider =
      descriptionsProvider ?? { await deviceManager.connectedDeviceDescriptions() }
    self.consumerProvider = consumerProvider
    self.consumer = consumerProvider()
    self.identityProvider = identityProvider
    self.builder = builder
    if observeConsumerChanges {
      observationTask = Task { [weak self] in
        guard let self else { return }
        await withTaskGroup(of: Void.self) { group in
          for await consumer in CompatibilityConsumerRouting.changes() {
            let revision = self.register(consumer: consumer)
            group.addTask { await self.refresh(consumer: consumer, revision: revision) }
          }
          group.cancelAll()
        }
      }
    }
  }
  var suppressOutput: Bool {
    get { stateLock.withLock { suppressedOutput } }
    set { stateLock.withLock { suppressedOutput = newValue } }
  }
  func activate(controller identifier: DeviceIdentifier) async throws {
    try await coordinator.activateOne(
      identifier: identifier,
      descriptions: await descriptionsProvider(),
      consumer: currentConsumer(),
      isEligible: { [weak self] identifier, target in
        await self?.isEligible(identifier, target: target) ?? false
      },
      identityProvider: identityProvider,
      factory: builder
    )
    await synchronizeDiagnostics()
  }

  func activate(for identifiers: [DeviceIdentifier]) async throws {
    try await coordinator.activate(
      identifiers: identifiers,
      descriptions: await descriptionsProvider(),
      consumer: currentConsumer(),
      isEligible: { [weak self] identifier, target in
        await self?.isEligible(identifier, target: target) ?? false
      },
      identityProvider: identityProvider,
      factory: builder
    )
    await synchronizeDiagnostics()
  }

  func setOutputSuppressed(_ suppressed: Bool) async {
    suppressOutput = suppressed
    await coordinator.synchronizeSuppression { self.suppressOutput }
  }
  func setRemappingOutputSuppressed(_ suppressed: Bool) async {
    stateLock.withLock { remappingSuppressedOutput = suppressed }
    await coordinator.synchronizeRemappingSuppression {
      self.stateLock.withLock { self.remappingSuppressedOutput }
    }
  }
  var status: String {
    stateLock.withLock {
      let targets = Set(diagnosticTargets.values.map(Self.diagnosticTarget)).sorted()
      let suffix = targets.isEmpty ? "" : ", targets: \(targets.joined(separator: "; "))"
      let diagnostics =
        publicationDiagnostics.isEmpty
        ? "" : ", publication: \(publicationDiagnostics.joined(separator: "; "))"
      return "automatic, consumer: \(consumer.rawValue)\(suffix)\(diagnostics)"
    }
  }
  var lastRumbleStatus: String { "none" }
  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) async {
    try? await deliver(events: events, state: nil, from: identifier)
    await synchronizeDiagnostics()
  }

  func send(_ state: RemappingGamepadState, for identifier: DeviceIdentifier) async throws {
    guard state == .neutral else {
      try await activate(controller: identifier)
      try await deliver(events: [], state: state, from: identifier)
      return
    }
    guard let lease = await coordinator.leaseForNeutralization(identifier) else { return }
    do {
      await coordinator.recordPublicationAttempt(for: identifier)
      guard let sink = lease.backend as? any RemappingGamepadSink else {
        throw RemappingEventEngineError.sinkUnavailable
      }
      try await sink.send(state, for: identifier)
      await coordinator.recordPublicationCompletion(for: identifier)
    } catch {
      await lease.release()
      await coordinator.recoverPublication(for: identifier, failure: error)
      await synchronizeDiagnostics()
      throw error
    }
    await lease.release()
    await synchronizeDiagnostics()
  }

  func send(_ motion: RemappingVirtualMotionState?, for identifier: DeviceIdentifier) async throws {
    if let motion {
      try await activate(controller: identifier)
      try await deliver(motion: motion, from: identifier)
      return
    }
    guard let lease = await coordinator.leaseForNeutralization(identifier) else { return }
    do {
      await coordinator.recordPublicationAttempt(for: identifier)
      guard let sink = lease.backend as? any RemappingGamepadSink else {
        throw RemappingEventEngineError.sinkUnavailable
      }
      try await sink.send(nil, for: identifier)
      await coordinator.recordPublicationCompletion(for: identifier)
    } catch {
      await lease.release()
      await coordinator.recoverPublication(for: identifier, failure: error)
      await synchronizeDiagnostics()
      throw error
    }
    await lease.release()
    await synchronizeDiagnostics()
  }

  private func deliver(
    motion: RemappingVirtualMotionState,
    from identifier: DeviceIdentifier
  ) async throws {
    await coordinator.synchronizeSuppression { self.suppressOutput }
    let description = await descriptionsProvider().first {
      $0.runtimeIdentifier == identifier.runtimeIdentifier
    }
    let consumer = currentConsumer()
    let target = description.map { identityProvider($0, consumer) } ?? .genericHID
    guard
      let lease = await coordinator.leaseForDispatch(
        controller: identifier,
        consumer: consumer,
        identity: target,
        isEligible: { [weak self] identifier, target in
          await self?.isEligible(identifier, target: target) ?? false
        },
        factory: builder
      )
    else { throw RemappingEventEngineError.sinkUnavailable }
    do {
      await coordinator.recordPublicationAttempt(for: identifier)
      guard let sink = lease.backend as? any RemappingGamepadSink else {
        throw RemappingEventEngineError.sinkUnavailable
      }
      try await sink.send(motion, for: identifier)
      await coordinator.recordPublicationCompletion(for: identifier)
    } catch {
      await lease.release()
      await coordinator.recoverPublication(for: identifier, failure: error)
      await synchronizeDiagnostics()
      throw error
    }
    await lease.release()
    await synchronizeDiagnostics()
  }

  private func deliver(
    events: [ControllerEvent],
    state: RemappingGamepadState?,
    from identifier: DeviceIdentifier
  ) async throws {
    await coordinator.synchronizeSuppression { self.suppressOutput }
    let description = await descriptionsProvider().first {
      $0.runtimeIdentifier == identifier.runtimeIdentifier
    }
    let consumer = currentConsumer()
    let target = description.map { identityProvider($0, consumer) } ?? .genericHID
    guard
      let lease = await coordinator.leaseForDispatch(
        controller: identifier,
        consumer: consumer,
        identity: target,
        isEligible: { [weak self] identifier, target in
          await self?.isEligible(identifier, target: target) ?? false
        },
        factory: builder
      )
    else { throw RemappingEventEngineError.sinkUnavailable }
    do {
      await coordinator.recordPublicationAttempt(for: identifier)
      if let state {
        guard let sink = lease.backend as? any RemappingGamepadSink else {
          throw RemappingEventEngineError.sinkUnavailable
        }
        try await sink.send(state, for: identifier)
      } else {
        try await lease.backend.dispatchReportingFailure(events: events, from: identifier)
      }
      await coordinator.recordPublicationCompletion(for: identifier)
    } catch {
      await lease.release()
      await coordinator.recoverPublication(for: identifier, failure: error)
      await synchronizeDiagnostics()
      throw error
    }
    await lease.release()
    await synchronizeDiagnostics()
  }
  func controllerDidStop(_ identifier: DeviceIdentifier) async {
    await coordinator.stop(identifier)
    await synchronizeDiagnostics()
  }
  func refreshForCurrentConsumer() async {
    let consumer = consumerProvider()
    let revision = register(consumer: consumer)
    await refresh(consumer: consumer, revision: revision)
  }

  private func refresh(consumer: CompatibilityConsumerFamily, revision: UInt64) async {
    let descriptions = await descriptionsProvider()
    await coordinator.replaceForConsumer(
      consumer,
      revision: revision,
      descriptions: descriptions,
      isEligible: { [weak self] identifier, target in
        await self?.isEligible(identifier, target: target) ?? false
      },
      identityProvider: identityProvider,
      factory: builder
    )
    await synchronizeDiagnostics()
  }

  private func register(consumer: CompatibilityConsumerFamily) -> UInt64 {
    stateLock.withLock {
      self.consumer = consumer
      consumerRevision &+= 1
      return consumerRevision
    }
  }

  private func currentConsumer() -> CompatibilityConsumerFamily { stateLock.withLock { consumer } }

  private func synchronizeDiagnostics() async {
    let targets = await coordinator.installedTargets()
    let publication = await coordinator.publicationDiagnostics()
    stateLock.withLock {
      diagnosticTargets = targets
      publicationDiagnostics = publication
    }
  }

  private static func diagnosticTarget(_ target: AutomaticCompatibilityTarget) -> String {
    let profile: VirtualDeviceProfile
    let variant: String
    switch target.reportVariant {
    case .canonical:
      profile = CompatibilityOutputProfileCatalog.profile(for: target.identity).deviceProfile
      variant = "canonical"
    case .geckoXboxOneS:
      profile = .firefoxXboxOneS
      variant = "gecko-xbox-one-s"
    }
    return "\(variant) \(String(format: "%04X:%04X", profile.vendorID, profile.productID))"
  }

  private func isEligible(
    _ identifier: DeviceIdentifier,
    target: AutomaticCompatibilityTarget
  ) async -> Bool {
    let identity = target.identity
    guard identity != .automatic else { return false }
    guard
      let description = await descriptionsProvider().first(where: {
        $0.runtimeIdentifier == identifier.runtimeIdentifier
      })
    else { return false }
    let ownership = await ownershipProvider(identifier)
    let profileAvailable = CompatibilityProfileAvailabilityPolicy.decision(
      for: description,
      identity: identity
    ).isAvailable
    return ControllerExposureDecision.decide(
      ownership: ownership,
      intent: .automatic(resolvedIdentity: identity),
      profileAvailable: profileAvailable
    ).eligibility == .eligible
  }
  func close() async {
    let task = stateLock.withLock { observationTask }
    task?.cancel()
    await coordinator.close()
    if let task { await task.value }
  }
}
