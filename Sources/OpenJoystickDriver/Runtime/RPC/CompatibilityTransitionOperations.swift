import Foundation
import OpenJoystickDriverKit

extension ApplicationServiceServer {
  internal func stageCompatibilityDispatcher(
    identity: CompatibilityIdentity,
    timeout: UInt64
  ) async throws -> UserSpaceDispatcherBuild {
    try await withCompatibilityTimeout(
      timeout,
      clock: compatibilityTransitionClock,
      error: .stageTimedOut
    ) {
      try self.buildUserSpaceDispatcher(identity: identity)
    } onLateSuccess: { candidate in
      _ = await self.closeCompatibilityBackend(candidate.dispatcher, slot: candidate.closeSlot)
    }
  }

  internal func activateCompatibilityDispatcher(
    _ candidate: any CompatibilityUserSpaceOutputDispatching,
    for identifiers: [DeviceIdentifier],
    timeout: UInt64
  ) async throws -> Bool {
    guard !identifiers.isEmpty else {
      let zeroControllerTimeout = min(
        timeout,
        compatibilityTransitionTimeouts.zeroControllerActivationNanoseconds
      )
      try await withCompatibilityTimeout(
        zeroControllerTimeout,
        clock: compatibilityTransitionClock,
        error: .activationTimedOut
      ) { try await candidate.activate(for: []) }
      return true
    }
    if let scoped = candidate as? any CompatibilityUserSpaceOutputControllerActivating {
      let started = compatibilityTransitionClock.now()
      for identifier in identifiers {
        let elapsed = elapsedNanoseconds(since: started)
        let remaining = timeout > elapsed ? timeout - elapsed : 0
        let controllerTimeout = min(
          remaining,
          compatibilityTransitionTimeouts.perControllerNanoseconds
        )
        try await withCompatibilityTimeout(
          controllerTimeout,
          clock: compatibilityTransitionClock,
          error: .activationTimedOut
        ) { try await scoped.activate(controller: identifier) }
      }
      return true
    }
    try await withCompatibilityTimeout(
      timeout,
      clock: compatibilityTransitionClock,
      error: .activationTimedOut
    ) { try await candidate.activate(for: identifiers) }
    return true
  }

  internal func rollbackCompatibilityDispatcher(
    identity: CompatibilityIdentity,
    identifiers: [DeviceIdentifier],
    prior: CompatibilityTransitionSnapshot,
    requestedIdentityAfterFailure: CompatibilityIdentity,
    zeroDeviceStarted: UInt64?
  ) async -> Bool {
    var candidate: UserSpaceDispatcherBuild?
    do {
      let staged = try await stageCompatibilityDispatcher(
        identity: identity,
        timeout: min(
          compatibilityTransitionTimeouts.rollbackStageNanoseconds,
          zeroDeviceStarted.map {
            remainingNanoseconds(
              since: $0,
              within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds
            )
          } ?? UInt64.max
        )
      )
      candidate = staged
      let timeout = min(
        compatibilityTransitionTimeouts.rollbackActivationNanoseconds(for: identifiers.count),
        zeroDeviceStarted.map {
          remainingNanoseconds(
            since: $0,
            within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds
          )
        } ?? UInt64.max
      )
      guard timeout > 0 else { throw CompatibilityTransitionError.zeroDeviceIntervalTimedOut }
      let activated = try await activateCompatibilityDispatcher(
        staged.dispatcher,
        for: identifiers,
        timeout: timeout
      )
      let reconciled = await connectedIdentifiers()
      guard activated, reconciled == identifiers, !isCompatibilityServerStopped() else {
        throw CompatibilityTransitionError.rollbackTimedOut
      }
      guard
        commitCompatibilityDispatcher(
          staged,
          identity: identity,
          identifiers: reconciled,
          persistedIdentity: prior.persistedIdentity,
          requestedIdentity: prior.requestedIdentity
        )
      else { throw CompatibilityTransitionError.serverStopped }
      return true
    } catch {
      guard
        await closeCompatibilityBackendWithinZeroDeviceBudget(
          candidate?.dispatcher,
          slot: candidate?.closeSlot,
          zeroDeviceStarted: zeroDeviceStarted
        )
      else {
        installUnavailableCompatibilityState(
          phase: .zeroDeviceInterval,
          requestedIdentity: requestedIdentityAfterFailure,
          prior: prior
        )
        return false
      }
      return false
    }
  }

  internal func activateGenericFallback(
    identifiers: [DeviceIdentifier],
    prior: CompatibilityTransitionSnapshot,
    requestedIdentityAfterFailure: CompatibilityIdentity,
    zeroDeviceStarted: UInt64?
  ) async -> Bool {
    let priorIdentity = prior.liveIdentity ?? prior.requestedIdentity
    guard prior.dispatcher == nil || priorIdentity != .genericHID, !isCompatibilityServerStopped()
    else { return false }
    var candidate: UserSpaceDispatcherBuild?
    do {
      let remaining =
        zeroDeviceStarted.map {
          remainingNanoseconds(
            since: $0,
            within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds
          )
        } ?? UInt64.max
      guard remaining > 0 else { throw CompatibilityTransitionError.zeroDeviceIntervalTimedOut }
      let staged = try await stageCompatibilityDispatcher(
        identity: .genericHID,
        timeout: min(compatibilityTransitionTimeouts.rollbackStageNanoseconds, remaining)
      )
      candidate = staged
      let timeout = min(
        compatibilityTransitionTimeouts.rollbackActivationNanoseconds(for: identifiers.count),
        zeroDeviceStarted.map {
          remainingNanoseconds(
            since: $0,
            within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds
          )
        } ?? UInt64.max
      )
      guard timeout > 0 else { throw CompatibilityTransitionError.zeroDeviceIntervalTimedOut }
      _ = try await activateCompatibilityDispatcher(
        staged.dispatcher,
        for: identifiers,
        timeout: timeout
      )
      guard await connectedIdentifiers() == identifiers, !isCompatibilityServerStopped() else {
        throw CompatibilityTransitionError.rollbackTimedOut
      }
      guard
        commitCompatibilityDispatcher(
          staged,
          identity: .genericHID,
          identifiers: identifiers,
          persistedIdentity: prior.persistedIdentity,
          requestedIdentity: prior.requestedIdentity
        )
      else { throw CompatibilityTransitionError.serverStopped }
      recordCompatibilityTransitionFailure(
        phase: .rollbackActivation,
        requestedIdentity: requestedIdentityAfterFailure,
        priorProfileIdentity: priorIdentity,
        retainedStatus: "using generic-hid fallback"
      )
      return true
    } catch {
      _ = await closeCompatibilityBackendWithinZeroDeviceBudget(
        candidate?.dispatcher,
        slot: candidate?.closeSlot,
        zeroDeviceStarted: zeroDeviceStarted
      )
      return false
    }
  }

  internal func commitCompatibilityDispatcher(
    _ build: UserSpaceDispatcherBuild,
    identity: CompatibilityIdentity,
    identifiers: [DeviceIdentifier],
    persistedIdentity: CompatibilityIdentity? = nil,
    requestedIdentity: CompatibilityIdentity? = nil,
    removePersistedIdentity: Bool = false
  ) -> Bool {
    userSpaceLock.withLock {
      guard !compatibilityServerStopped else { return false }
      dispatcher.setBackend(build.dispatcher)
      userSpaceDispatcher = build.dispatcher
      userSpaceCloseSlot = build.closeSlot
      userSpaceEnabled = true
      userSpaceStatus = build.dispatcher.status
      compatibilityLiveIdentity = identity
      compatibilityIdentity = requestedIdentity ?? identity
      let persisted = persistedIdentity ?? identity
      persistedCompatibilityIdentity = persisted
      compatibilityRetrySnapshot = nil
      Self.persistCompatibilityRetrySnapshot(nil)
      if removePersistedIdentity {
        UserDefaults.standard.removeObject(forKey: Self.compatibilityIdentityDefaultsKey)
      } else {
        UserDefaults.standard.set(persisted.rawValue, forKey: Self.compatibilityIdentityDefaultsKey)
      }
      return true
    }
  }

  internal func installUnavailableCompatibilityState(
    phase: CompatibilityTransitionPhase,
    requestedIdentity: CompatibilityIdentity,
    prior: CompatibilityTransitionSnapshot
  ) {
    userSpaceLock.withLock {
      dispatcher.setBackend(nil)
      userSpaceDispatcher = nil
      userSpaceCloseSlot = nil
      userSpaceEnabled = false
      compatibilityLiveIdentity = nil
      compatibilityIdentity = prior.requestedIdentity
      persistedCompatibilityIdentity = prior.persistedIdentity
      let retrySnapshot = CompatibilityRetrySnapshot(
        requestedIdentity: requestedIdentity,
        priorProfileIdentity: prior.liveIdentity ?? prior.requestedIdentity,
        phase: phase
      )
      compatibilityRetrySnapshot = retrySnapshot
      Self.persistCompatibilityRetrySnapshot(retrySnapshot)
      userSpaceStatus = "error: compatibility \(phase.rawValue) failed; output unavailable"
    }
  }

  internal func recordCompatibilityTransitionFailure(
    phase: CompatibilityTransitionPhase,
    requestedIdentity: CompatibilityIdentity,
    priorProfileIdentity: CompatibilityIdentity,
    retainedStatus: String? = nil
  ) {
    userSpaceLock.withLock {
      let retrySnapshot = CompatibilityRetrySnapshot(
        requestedIdentity: requestedIdentity,
        priorProfileIdentity: priorProfileIdentity,
        phase: phase
      )
      compatibilityRetrySnapshot = retrySnapshot
      let status = retainedStatus ?? "retained \(priorProfileIdentity.rawValue)"
      userSpaceStatus = "error: compatibility \(phase.rawValue) failed; \(status)"
    }
  }

  internal func elapsedNanoseconds(since start: UInt64) -> UInt64 {
    let now = compatibilityTransitionClock.now()
    return now >= start ? now - start : 0
  }

  internal func remainingNanoseconds(since start: UInt64, within limit: UInt64) -> UInt64 {
    let elapsed = elapsedNanoseconds(since: start)
    return elapsed >= limit ? 0 : limit - elapsed
  }

  internal func closeCompatibilityBackendWithinZeroDeviceBudget(
    _ backend: (any CompatibilityUserSpaceOutputDispatching)?,
    slot: CompatibilityBackendCloseSlot?,
    zeroDeviceStarted: UInt64?
  ) async -> Bool {
    guard backend != nil else { return true }
    let remaining = zeroDeviceStarted.map {
      remainingNanoseconds(since: $0, within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds)
    }
    let timeout = min(
      compatibilityTransitionTimeouts.candidateCloseNanoseconds,
      remaining ?? UInt64.max
    )
    return await closeCompatibilityBackend(
      backend,
      slot: slot,
      timeout: timeout,
      error: zeroDeviceStarted == nil ? .candidateCloseTimedOut : .zeroDeviceIntervalTimedOut
    )
  }

  internal func connectedIdentifiers() async -> [DeviceIdentifier] {
    var seen = Set<DeviceIdentifier>()
    return (await connectedIdentifierProvider()).filter { seen.insert($0).inserted }
  }

  internal func requestedIdentity() -> CompatibilityIdentity {
    userSpaceLock.withLock { compatibilityIdentity }
  }
}
