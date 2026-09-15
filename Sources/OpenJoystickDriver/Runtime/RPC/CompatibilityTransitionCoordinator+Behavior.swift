import Foundation
import OpenJoystickDriverKit

extension ApplicationServiceServer {
  func activateCompatibilityBackendForCurrentDevices() async -> Bool {
    await compatibilityTransitionCoordinator.enqueue { [weak self] in
      guard let self else { return false }
      return await self.performCompatibilityIdentityTransition(
        to: self.requestedIdentity(),
        force: true
      )
    }
  }

  func performCompatibilityIdentityTransition(
    to identity: CompatibilityIdentity,
    force: Bool = false,
    removePersistedIdentityOnCommit: Bool = false
  ) async -> Bool {
    guard !isCompatibilityServerStopped() else { return false }
    let prior = compatibilityTransitionSnapshot()
    if !force, prior.requestedIdentity == identity, prior.liveIdentity == identity, prior.enabled,
      prior.dispatcher != nil
    {
      return true
    }

    let candidate: UserSpaceDispatcherBuild
    do {
      candidate = try await stageCompatibilityDispatcher(
        identity: identity,
        timeout: compatibilityTransitionTimeouts.stageNanoseconds
      )
    } catch {
      recordCompatibilityTransitionFailure(
        phase: .stage,
        requestedIdentity: identity,
        priorProfileIdentity: prior.liveIdentity ?? prior.requestedIdentity,
        detail: String(reflecting: error)
      )
      return false
    }

    guard !isCompatibilityServerStopped() else {
      _ = await closeCompatibilityBackend(candidate.dispatcher, slot: candidate.closeSlot)
      return false
    }
    let identifiers = await connectedIdentifiers()
    guard
      await feedbackGate.quiesceAndNeutralize(
        identifiers,
        timeout: compatibilityTransitionTimeouts.feedbackNanoseconds,
        clock: compatibilityTransitionClock
      )
    else {
      _ = await closeCompatibilityBackend(candidate.dispatcher, slot: candidate.closeSlot)
      recordCompatibilityTransitionFailure(
        phase: .feedbackQuiescence,
        requestedIdentity: identity,
        priorProfileIdentity: prior.liveIdentity ?? prior.requestedIdentity
      )
      if prior.enabled, prior.dispatcher != nil { feedbackGate.resume() }
      return false
    }
    var zeroDeviceStarted: UInt64?
    if let old = prior.dispatcher {
      userSpaceLock.withLock { dispatcher.setBackend(nil) }
      let closed = await closeCompatibilityBackend(old, slot: prior.closeSlot)
      guard closed else {
        _ = await closeCompatibilityBackend(candidate.dispatcher, slot: candidate.closeSlot)
        installUnavailableCompatibilityState(
          phase: .candidateClose,
          requestedIdentity: identity,
          prior: prior
        )
        return false
      }
      zeroDeviceStarted = compatibilityTransitionClock.now()
    }

    do {
      let zeroDeviceRemaining = zeroDeviceStarted.map {
        remainingNanoseconds(
          since: $0,
          within: compatibilityTransitionTimeouts.zeroDeviceNanoseconds
        )
      }
      guard zeroDeviceRemaining != 0 else {
        throw CompatibilityTransitionError.zeroDeviceIntervalTimedOut
      }
      let activationTimeout = min(
        compatibilityTransitionTimeouts.activationNanoseconds(for: identifiers.count),
        zeroDeviceRemaining ?? UInt64.max
      )
      let activated = try await activateCompatibilityDispatcher(
        candidate.dispatcher,
        for: identifiers,
        timeout: activationTimeout
      )
      let reconciled = await connectedIdentifiers()
      guard activated, reconciled == identifiers, !isCompatibilityServerStopped() else {
        throw CompatibilityTransitionError.serverStopped
      }
      guard
        commitCompatibilityDispatcher(
          candidate,
          identity: identity,
          identifiers: reconciled,
          removePersistedIdentity: removePersistedIdentityOnCommit
        )
      else {
        _ = await closeCompatibilityBackend(candidate.dispatcher, slot: candidate.closeSlot)
        return false
      }
      feedbackGate.resume()
      return true
    } catch {
      let transitionDetail = String(reflecting: error)
      guard
        await closeCompatibilityBackendWithinZeroDeviceBudget(
          candidate.dispatcher,
          slot: candidate.closeSlot,
          zeroDeviceStarted: zeroDeviceStarted
        )
      else {
        installUnavailableCompatibilityState(
          phase: .zeroDeviceInterval,
          requestedIdentity: identity,
          prior: prior
        )
        return false
      }
      guard !isCompatibilityServerStopped() else { return false }
      let rollbackIdentifiers = await connectedIdentifiers()
      if prior.dispatcher != nil,
        await rollbackCompatibilityDispatcher(
          identity: prior.liveIdentity ?? prior.requestedIdentity,
          identifiers: rollbackIdentifiers,
          prior: prior,
          requestedIdentityAfterFailure: identity,
          zeroDeviceStarted: zeroDeviceStarted
        )
      {
        recordCompatibilityTransitionFailure(
          phase: .activation,
          requestedIdentity: identity,
          priorProfileIdentity: prior.liveIdentity ?? prior.requestedIdentity,
          detail: transitionDetail
        )
        feedbackGate.resume()
      } else if await activateGenericFallback(
        identifiers: rollbackIdentifiers,
        prior: prior,
        requestedIdentityAfterFailure: identity,
        zeroDeviceStarted: zeroDeviceStarted
      ) {
        feedbackGate.resume()
      } else {
        installUnavailableCompatibilityState(
          phase: prior.dispatcher == nil ? .activation : .rollbackActivation,
          requestedIdentity: identity,
          prior: prior
        )
      }
      return false
    }
  }
}
