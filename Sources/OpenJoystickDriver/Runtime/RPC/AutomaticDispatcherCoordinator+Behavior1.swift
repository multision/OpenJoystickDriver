import Foundation
import OpenJoystickDriverKit

extension AutomaticDispatcherCoordinator {
  typealias Eligibility = @Sendable (DeviceIdentifier, AutomaticCompatibilityTarget) async -> Bool
  typealias Factory =
    @Sendable (AutomaticCompatibilityTarget) throws -> any CompatibilityUserSpaceOutputDispatching
  typealias IdentityProvider =
    @Sendable (ApplicationServiceDeviceDescription, CompatibilityConsumerFamily) ->
    AutomaticCompatibilityTarget

  struct Request: Sendable {
    let controller: DeviceIdentifier
    let token: UUID
    let sessionGeneration: UInt64
    let publicationGeneration: UInt64
    let foreground: UInt64
    let consumer: CompatibilityConsumerFamily
    let target: AutomaticCompatibilityTarget
  }

  struct Pending {
    let request: Request
    let task: Task<Void, Error>
  }

  struct Entry {
    /// Physical-session state survives temporary publication suppression.
    var sessionGeneration: UInt64 = 0
    var physicalSessionActive = true
    /// Invalidates only virtual publication work for the current physical session.
    var publicationGeneration: UInt64 = 0
    var target: AutomaticCompatibilityTarget?
    var context: PublicationContext?
    var installed: AutomaticBackendSlot?
    var installedToken: UUID?
    var retiring: AutomaticBackendSlot?
    var pending: Pending?
    var tasks: [UUID: Pending] = [:]
    var lastAttemptedSend: UInt64?
    var lastCompletedSend: UInt64?
    var lastFailure: String?
    var recoveryState = "idle"
    var recoveryToken: UUID?
  }

  struct PublicationContext: Sendable {
    let consumer: CompatibilityConsumerFamily
    let target: AutomaticCompatibilityTarget
    let isEligible: Eligibility
    let factory: Factory
  }

  func activateOne(
    identifier: DeviceIdentifier,
    descriptions: [ApplicationServiceDeviceDescription],
    consumer: CompatibilityConsumerFamily,
    isEligible: @escaping Eligibility,
    identityProvider: @escaping IdentityProvider,
    factory: @escaping Factory
  ) async throws {
    guard !closed else { throw CancellationError() }
    guard
      let description = descriptions.first(where: {
        $0.runtimeIdentifier == identifier.runtimeIdentifier
      })
    else { return }
    if entries[identifier]?.physicalSessionActive == false {
      entries[identifier]?.physicalSessionActive = true
      entries[identifier]?.sessionGeneration &+= 1
      entries[identifier]?.publicationGeneration &+= 1
    }
    let lease = try await acquire(
      identifier,
      consumer: consumer,
      target: identityProvider(description, consumer),
      isEligible: isEligible,
      factory: factory
    )
    await lease?.release()
  }

  func activate(
    identifiers: [DeviceIdentifier],
    descriptions: [ApplicationServiceDeviceDescription],
    consumer: CompatibilityConsumerFamily,
    isEligible: @escaping Eligibility,
    identityProvider: @escaping IdentityProvider,
    factory: @escaping Factory
  ) async throws {
    guard !closed, entries.isEmpty else {
      throw UserSpaceOutputDispatcher.CreationError.createFailed
    }
    var seen = Set<DeviceIdentifier>()
    do {
      for identifier in identifiers where seen.insert(identifier).inserted {
        try await activateOne(
          identifier: identifier,
          descriptions: descriptions,
          consumer: consumer,
          isEligible: isEligible,
          identityProvider: identityProvider,
          factory: factory
        )
      }
    } catch {
      await close()
      throw error
    }
  }

  /// Acquires only an existing backend so cleanup cannot create a replacement controller.
  func leaseForNeutralization(_ controller: DeviceIdentifier) async -> AutomaticBackendLease? {
    if closed {
      await close()
      return nil
    }
    if let lease = entries[controller]?.installed?.acquire() { return lease }
    _ = await entries[controller]?.retiring?.retireAndWait()
    return nil
  }

  func leaseForDispatch(
    controller: DeviceIdentifier,
    consumer: CompatibilityConsumerFamily,
    identity target: AutomaticCompatibilityTarget,
    isEligible: @escaping Eligibility,
    factory: @escaping Factory
  ) async -> AutomaticBackendLease? {
    try? await acquire(
      controller,
      consumer: consumer,
      target: target,
      isEligible: isEligible,
      factory: factory
    )
  }

  func acquire(
    _ controller: DeviceIdentifier,
    consumer requestedConsumer: CompatibilityConsumerFamily,
    target: AutomaticCompatibilityTarget,
    isEligible: @escaping Eligibility,
    factory: @escaping Factory
  ) async throws -> AutomaticBackendLease? {
    guard !closed, consumer == .unknown || consumer == requestedConsumer else { return nil }
    if consumer != requestedConsumer { setConsumer(requestedConsumer) }
    if entries[controller] == nil { entries[controller] = Entry() }
    guard !suppressed, let initial = entries[controller], initial.physicalSessionActive else {
      return nil
    }
    let sessionGeneration = initial.sessionGeneration
    let publicationGeneration = initial.publicationGeneration
    let currentForeground = foreground
    guard await isEligible(controller, target) else { return nil }
    guard !closed, foreground == currentForeground, let current = entries[controller],
      current.physicalSessionActive, current.sessionGeneration == sessionGeneration,
      current.publicationGeneration == publicationGeneration, !suppressed
    else { throw CancellationError() }
    if current.target == target, let lease = current.installed?.acquire() { return lease }

    let pending: Pending
    if let existing = current.pending, existing.request.target == target {
      pending = existing
    } else {
      current.pending?.task.cancel()
      let request = Request(
        controller: controller,
        token: UUID(),
        sessionGeneration: sessionGeneration,
        publicationGeneration: publicationGeneration,
        foreground: foreground,
        consumer: requestedConsumer,
        target: target
      )
      let predecessors = current.tasks.values.map(\.task)
      // Factories may synchronously block in native creation. Keep them off the coordinator.
      let task = Task.detached { [self] in
        try Task.checkCancellation()
        let candidate = AutomaticBackendSlot(try factory(target))
        do {
          for predecessor in predecessors { _ = await predecessor.result }
          try await install(candidate, request: request, factory: factory)
        } catch {
          _ = await candidate.retireAndWait()
          throw error
        }
      }
      pending = Pending(request: request, task: task)
      entries[controller]?.context = PublicationContext(
        consumer: requestedConsumer,
        target: target,
        isEligible: isEligible,
        factory: factory
      )
      entries[controller]?.pending = pending
      entries[controller]?.tasks[request.token] = pending
    }
    defer {
      entries[controller]?.tasks[pending.request.token] = nil
      if entries[controller]?.pending?.request.token == pending.request.token {
        entries[controller]?.pending = nil
      }
    }
    try await pending.task.value
    guard !closed, foreground == currentForeground, let installed = entries[controller],
      installed.physicalSessionActive, installed.sessionGeneration == sessionGeneration,
      installed.publicationGeneration == publicationGeneration, installed.target == target,
      installed.installedToken == pending.request.token
    else { throw CancellationError() }
    return installed.installed?.acquire()
  }

  private func validate(_ request: Request) throws {
    try Task.checkCancellation()
    guard !closed, !suppressed, foreground == request.foreground, consumer == request.consumer,
      let entry = entries[request.controller], entry.physicalSessionActive,
      entry.sessionGeneration == request.sessionGeneration,
      entry.publicationGeneration == request.publicationGeneration,
      entry.pending?.request.token == request.token
    else { throw CancellationError() }
  }

  private func install(
    _ candidate: AutomaticBackendSlot,
    request: Request,
    factory: @escaping Factory
  ) async throws {
    try validate(request)
    let previousTarget = entries[request.controller]?.target
    let old = entries[request.controller]?.installed ?? entries[request.controller]?.retiring
    entries[request.controller]?.retiring = old
    entries[request.controller]?.installed = nil
    entries[request.controller]?.installedToken = nil
    entries[request.controller]?.target = nil
    if let old {
      guard await old.retireAndWait() else {
        _ = await candidate.retireAndWait()
        throw CancellationError()
      }
      try validate(request)
      entries[request.controller]?.retiring = nil
    }
    do {
      try await activateAndSynchronize(candidate, request: request)
      entries[request.controller]?.installed = candidate
      entries[request.controller]?.installedToken = request.token
      entries[request.controller]?.target = request.target
    } catch {
      _ = await candidate.retireAndWait()
      if let previousTarget {
        await restore(target: previousTarget, request: request, factory: factory)
      }
      throw error
    }
  }

  private func activateAndSynchronize(
    _ candidate: AutomaticBackendSlot,
    request: Request
  ) async throws {
    try await candidate.backend.activate(for: [request.controller])
    try validate(request)
    repeat {
      let revision = suppressionRevision
      await candidate.backend.setOutputSuppressed(suppressed)
      if let control = candidate.backend as? any RemappingGamepadOutputControlling {
        await control.setRemappingOutputSuppressed(remappingSuppressed)
      }
      try validate(request)
      if revision == suppressionRevision { break }
    } while true
  }

  private func restore(
    target: AutomaticCompatibilityTarget,
    request: Request,
    factory: @escaping Factory
  ) async {
    guard (try? validate(request)) != nil, let backend = try? factory(target) else { return }
    let rollback = AutomaticBackendSlot(backend)
    do {
      try await activateAndSynchronize(rollback, request: request)
      entries[request.controller]?.installed = rollback
      entries[request.controller]?.installedToken = nil
      entries[request.controller]?.target = target
    } catch { _ = await rollback.retireAndWait() }
  }

  private func setConsumer(_ value: CompatibilityConsumerFamily) {
    guard !closed, consumer != value else { return }
    consumer = value
    foreground &+= 1
    for identifier in entries.keys {
      entries[identifier]?.tasks.values.forEach { $0.task.cancel() }
      entries[identifier]?.pending = nil
    }
  }

  func replaceForConsumer(
    _ value: CompatibilityConsumerFamily,
    revision: UInt64,
    descriptions: [ApplicationServiceDeviceDescription],
    isEligible: @escaping Eligibility,
    identityProvider: @escaping IdentityProvider,
    factory: @escaping Factory
  ) async {
    guard !closed, revision > consumerRevision else { return }
    consumerRevision = revision
    setConsumer(value)
    let controllers = entries.compactMap { $0.value.physicalSessionActive ? $0.key : nil }
    for controller in controllers {
      guard !closed, consumerRevision == revision,
        let description = descriptions.first(where: {
          $0.runtimeIdentifier == controller.runtimeIdentifier
        })
      else { return }
      do {
        let lease = try await acquire(
          controller,
          consumer: value,
          target: identityProvider(description, value),
          isEligible: isEligible,
          factory: factory
        )
        await lease?.release()
      } catch { guard !Task.isCancelled, consumerRevision == revision else { return } }
    }
  }
}
