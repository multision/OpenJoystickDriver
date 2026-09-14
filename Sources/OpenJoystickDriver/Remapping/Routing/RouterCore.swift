import Foundation
import OpenJoystickDriverKit

actor RemappingRoutingCore {
  let library: RemappingProfileLibrary
  let engine: RemappingEventEngine
  let compatibility: any OutputDispatcher
  let foregroundApplication: any RemappingForegroundApplicationProviding
  let postEventAccess: any RemappingPostEventAccessProviding
  let operationCheckpoint: @Sendable (RemappingRoutingCheckpoint) async -> Void
  var emissionBarrier: RemappingEmissionBarrier { engine.emissionBarrier }
  var controls = RemappingRoutingControls(
    outputSuppressed: false,
    compatibilityOutputAllowed: true,
    revision: 0
  )
  var routes: [DeviceIdentifier: RemappingControllerRoute] = [:]
  var connectedIdentifiers: Set<DeviceIdentifier> = []
  var inputOwnership: [DeviceIdentifier: HIDInputOwnership] = [:]
  var joyConPairs: [UUID: RemappingJoyConPairSession] = [:]
  var joyConPairByMember: [DeviceIdentifier: UUID] = [:]
  var profileTransactionState = RemappingProfileTransactionState.inactive
  var terminationRequested = false
  internal var terminalCleanupComplete = false
  var schedulingRevision: UInt64 = 0

  init(
    library: RemappingProfileLibrary,
    engine: RemappingEventEngine,
    compatibility: any OutputDispatcher,
    foregroundApplication: any RemappingForegroundApplicationProviding,
    postEventAccess: any RemappingPostEventAccessProviding,
    operationCheckpoint: @escaping @Sendable (RemappingRoutingCheckpoint) async -> Void
  ) {
    self.library = library
    self.engine = engine
    self.compatibility = compatibility
    self.foregroundApplication = foregroundApplication
    self.postEventAccess = postEventAccess
    self.operationCheckpoint = operationCheckpoint
  }

  func apply(
    _ proposed: RemappingRoutingControls,
    requiring permit: RemappingEmissionPermit?,
    refreshEligibilityWhenUnchanged: Bool = false
  ) async throws {
    defer { schedulingRevision &+= 1 }
    _ = try requireOperationalPermit(permit)
    guard proposed.revision >= controls.revision else { return }
    let previousCompatibilitySuppressed = compatibilityIsSuppressed
    let outputSuppressionChanged = proposed.outputSuppressed != controls.outputSuppressed
    let compatibilityEligibilityChanged =
      proposed.compatibilityOutputAllowed != controls.compatibilityOutputAllowed
    controls = proposed
    await operationCheckpoint(.apply)
    _ = try requireOperationalPermit(permit)
    if case .unreconciled = profileTransactionState { return }
    let compatibilityBecameSuppressed =
      !previousCompatibilitySuppressed && compatibilityIsSuppressed
    if compatibilityBecameSuppressed && !profileTransactionState.blocksOutput {
      for identifier in sortedIdentifiers {
        guard case .compatibility = routes[identifier]?.selection else { continue }
        await notifyCompatibilityStop(identifier)
      }
    }
    guard
      outputSuppressionChanged || compatibilityEligibilityChanged || refreshEligibilityWhenUnchanged
    else { return }
    try await refreshEligibility(requiring: permit)
  }

  func dispatch(
    events: [ControllerEvent],
    from identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64,
    requiring proposedPermit: RemappingEmissionPermit?
  ) async throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    connectedIdentifiers.insert(identifier)
    guard !profileTransactionState.blocksOutput else {
      recordUnreconciledRouteIfNeeded(for: identifier)
      return
    }
    if routes[identifier] == nil {
      try await loadSelection(for: identifier, requiring: proposedPermit)
    }
    let pair = pairSession(for: identifier)
    let routingIdentifier = pair?.left ?? identifier
    try await reconcileEligibility(for: routingIdentifier, requiring: proposedPermit)
    await operationCheckpoint(.dispatch)
    guard let route = routes[routingIdentifier] else { return }
    switch route.selection {
    case .compatibility:
      guard route.eligibility == .eligible else { return }
      _ = try requireOperationalPermit(proposedPermit)
      await compatibility.dispatch(events: events, from: identifier)
    case .remapping(let profile):
      guard route.eligibility == .eligible else { return }
      let permit = try requireOperationalPermit(proposedPermit)
      do {
        try await engine.process(
          events: pairEvents(events, from: identifier),
          from: routingIdentifier,
          using: profile,
          at: uptimeNanoseconds,
          requiring: permit
        )
      } catch let error as RemappingEventEngineError {
        if error == .outputSuspended {
          if emissionBarrier.isTerminated { throw RemappingOutputRoutingError.shutDown }
          return
        }
        recordEngineFailure(error)
        throw RemappingOutputRoutingError.engine(error)
      }
    case .unavailable(let error): throw error
    }
  }

  /// Retains exact controller identity while a transaction rejects its event output.
  ///
  /// This operation never selects a route or reaches either output sink. Accepted and rolled-back
  /// transactions use the retained identity when installing their completed route set.
  func recordConnectedIdentifierWhileOutputClosed(_ identifier: DeviceIdentifier) throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    connectedIdentifiers.insert(identifier)
    recordUnreconciledRouteIfNeeded(for: identifier)
  }

  func refresh(
    _ identifier: DeviceIdentifier,
    requiring permit: RemappingEmissionPermit?
  ) async throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    connectedIdentifiers.insert(identifier)
    guard !profileTransactionState.blocksOutput else {
      recordUnreconciledRouteIfNeeded(for: identifier)
      return
    }
    try await loadSelection(for: identifier, requiring: permit)
  }

  func refreshModel(
    vendorID: UInt16,
    productID: UInt16,
    requiring permit: RemappingEmissionPermit?
  ) async throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    if case .unreconciled(_, let error) = profileTransactionState { throw error }
    let affected = sortedIdentifiers.filter { $0.vendorID == vendorID && $0.productID == productID }
    let profile: RemappingProfile?
    do {
      let frontmostBundleID = foregroundApplication.frontmostBundleIdentifier()
      profile = try await library.activeProfile(
        vendorID: vendorID,
        productID: productID,
        frontmostBundleIdentifier: frontmostBundleID
      )
    } catch let error as RemappingProfileLibraryError {
      try await markLibraryUnavailable(error, identifiers: affected, requiring: permit)
      throw RemappingOutputRoutingError.library(error)
    }
    for identifier in affected {
      _ = try requireOperationalPermit(permit)
      try await transition(
        to: independentSelection(for: profile),
        for: identifier,
        requiring: permit
      )
    }
  }

  func refreshEligibility(requiring permit: RemappingEmissionPermit?) async throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    let environment = sampleEligibilityEnvironment()
    if case .unreconciled(_, let error) = profileTransactionState {
      markRoutesUnreconciled(error, environment: environment)
      return
    }
    for identifier in sortedIdentifiers {
      try await reconcileEligibility(for: identifier, environment: environment, requiring: permit)
    }
  }

  func tick(
    at uptimeNanoseconds: UInt64,
    requiring proposedPermit: RemappingEmissionPermit?
  ) async throws {
    defer { schedulingRevision &+= 1 }
    try ensureRunning()
    guard !profileTransactionState.blocksOutput else { return }
    try await refreshEligibility(requiring: proposedPermit)
    await operationCheckpoint(.tick)
    let hasEligibleRemapping = routes.values.contains {
      if case .remapping = $0.selection { return $0.eligibility == .eligible }
      return false
    }
    guard hasEligibleRemapping else { return }
    let permit = try requireOperationalPermit(proposedPermit)
    do { try await engine.tick(at: uptimeNanoseconds, requiring: permit) } catch let error
      as RemappingEventEngineError
    {
      if error == .outputSuspended {
        if emissionBarrier.isTerminated { throw RemappingOutputRoutingError.shutDown }
        return
      }
      recordEngineFailure(error)
      throw RemappingOutputRoutingError.engine(error)
    }
  }

  func schedulingSnapshot(
    after uptimeNanoseconds: UInt64,
    continuousIntervalNanoseconds: UInt64
  ) async -> RemappingSchedulingSnapshot {
    guard !profileTransactionState.blocksOutput else {
      return RemappingSchedulingSnapshot(
        revision: schedulingRevision,
        nextTickUptimeNanoseconds: nil
      )
    }
    let nextTick = await engine.nextScheduledTick(
      after: uptimeNanoseconds,
      continuousIntervalNanoseconds: continuousIntervalNanoseconds
    )
    return RemappingSchedulingSnapshot(
      revision: schedulingRevision,
      nextTickUptimeNanoseconds: nextTick
    )
  }

  func stopController(
    _ identifier: DeviceIdentifier,
    requiring proposedPermit: RemappingEmissionPermit?
  ) async throws {
    defer { schedulingRevision &+= 1 }
    inputOwnership.removeValue(forKey: identifier)
    if try await stopPairedJoyCon(identifier, requiring: proposedPermit) { return }
    guard let route = routes[identifier] else { return }
    if profileTransactionState.blocksOutput {
      routes.removeValue(forKey: identifier)
      connectedIdentifiers.remove(identifier)
      return
    }
    switch route.selection {
    case .compatibility: await notifyCompatibilityStop(identifier)
    case .remapping(let profile):
      try await releaseAndRetire(for: identifier, profile: profile, requiring: proposedPermit)
    case .unavailable: try await releaseAllSafely(for: identifier, requiring: proposedPermit)
    }
    routes.removeValue(forKey: identifier)
    connectedIdentifiers.remove(identifier)
  }

  internal var terminalRetiredIdentifiers = Set<DeviceIdentifier>()

  func shutdown() async throws {
    defer { schedulingRevision &+= 1 }
    terminationRequested = true
    guard !terminalCleanupComplete else { return }
    var cleanupError: (any Error)?
    do { try await engine.drainAfterTermination() } catch let error as RemappingEventEngineError {
      recordEngineFailure(error)
      cleanupError = RemappingOutputRoutingError.engine(error)
    } catch { cleanupError = error }
    for identifier in sortedIdentifiers where !terminalRetiredIdentifiers.contains(identifier) {
      if let session = pairSession(for: identifier), identifier != session.left { continue }
      switch routes[identifier]?.selection {
      case .compatibility: await notifyCompatibilityStop(identifier)
      case .remapping(let profile) where profile.outputPolicy.virtualGamepad != .disabled:
        await notifyCompatibilityStop(identifier)
      default: continue
      }
      terminalRetiredIdentifiers.insert(identifier)
    }
    if let cleanupError { throw cleanupError }
    routes.removeAll()
    connectedIdentifiers.removeAll()
    inputOwnership.removeAll()
    joyConPairs.removeAll()
    joyConPairByMember.removeAll()
    terminalCleanupComplete = true
  }

}
