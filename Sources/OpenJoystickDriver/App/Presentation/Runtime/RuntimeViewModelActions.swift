import Foundation
import OpenJoystickDriverKit

@MainActor
extension RuntimeViewModel {
  func listenForInput(for selector: RuntimeDeviceSelector) async {
    inputGeneration += 1
    let generation = inputGeneration
    inputCaptureState = .listening(selector)
    var baselineState: DeviceInputState?

    for attempt in 0..<50 {
      guard generation == inputGeneration else { return }
      do {
        if let state = try await gateway.deviceInputState(for: selector) {
          guard generation == inputGeneration else { return }
          if let baselineState,
            let detectedSource = RuntimePresentation.detectedTransition(
              from: baselineState,
              to: state
            )
          {
            inputCaptureState = .detected(selector, state, detectedSource)
            return
          }
          baselineState = state
        }
        if attempt < 49 { try await Task.sleep(nanoseconds: 100_000_000) }
      } catch is CancellationError {
        guard generation == inputGeneration else { return }
        inputCaptureState = .idle
        return
      } catch {
        guard generation == inputGeneration else { return }
        let message = RuntimePresentation.userFacingError(error)
        inputCaptureState =
          RuntimePresentation.isUnavailable(error)
          ? .unavailable(selector, message) : .error(selector, message)
        lastError = message
        return
      }
    }

    guard generation == inputGeneration else { return }
    inputCaptureState = .unavailable(
      selector,
      OJDLocalized.string(
        "error.noDetectedControl",
        fallback: "No new controller control was detected."
      )
    )
  }

  func cancelInputCapture() {
    inputGeneration += 1
    inputCaptureState = .idle
  }

  @discardableResult
  func createRemappingProfile(
    _ profile: RemappingProfile,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    if let failure = locallyValid(profile, request: request) { return failure }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: nil) {
      try await gateway.createRemappingProfile(profile)
    }
  }

  @discardableResult
  func updateRemappingProfile(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    if let failure = locallyValid(profile, request: request) { return failure }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: profile.id) {
      try await gateway.updateRemappingProfile(profile, expectedCurrent: expectedCurrent)
    }
  }

  @discardableResult
  func importRemappingProfile(
    _ profile: RemappingProfile,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    if let failure = locallyValid(profile, request: request) { return failure }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: nil) {
      try await gateway.importRemappingProfile(profile)
    }
  }

  @discardableResult
  func deleteRemappingProfile(
    id: UUID,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: id) {
      try await gateway.deleteRemappingProfile(id: id)
    }
  }

  @discardableResult
  func activateRemappingProfile(
    id: UUID,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: id) {
      try await gateway.activateRemappingProfile(id: id)
    }
  }

  @discardableResult
  func deactivateRemappingProfile(
    vendorID: UInt16,
    productID: UInt16,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: nil) {
      try await gateway.deactivateRemappingProfile(vendorID: vendorID, productID: productID)
    }
  }

  func pairRemappingJoyCons(left: String, right: String, profileID: UUID) async -> String? {
    guard !mutationInFlight else {
      return OJDLocalized.string(
        "error.operationInProgress",
        fallback: "Another profile operation is already in progress."
      )
    }
    do {
      remappingState = .available(
        try await gateway.pairRemappingJoyCons(left: left, right: right, profileID: profileID)
      )
      return nil
    } catch {
      let message = RuntimePresentation.userFacingError(error)
      lastError = message
      return message
    }
  }

  func unpairRemappingJoyCons(sessionID: UUID) async -> String? {
    guard !mutationInFlight else {
      return OJDLocalized.string(
        "error.operationInProgress",
        fallback: "Another profile operation is already in progress."
      )
    }
    do {
      remappingState = .available(try await gateway.unpairRemappingJoyCons(sessionID: sessionID))
      return nil
    } catch {
      let message = RuntimePresentation.userFacingError(error)
      lastError = message
      return message
    }
  }

  @discardableResult
  func deactivateRemappingProfile(
    profileID: UUID,
    request: RuntimeMutationRequest
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(request) }
    let gateway = self.gateway
    return await performMutation(request: request, conflictProfileID: profileID) {
      try await gateway.deactivateRemappingProfile(profileID: profileID)
    }
  }

  func loadCompatibilityIdentity() async {
    compatibilityGeneration += 1
    let generation = compatibilityGeneration
    authoritativeCompatibilityIdentity = nil
    compatibilityState = .loading
    compatibilityError = nil
    updateStatusCompatibilityIdentity(nil)
    do {
      let identity = try await gateway.compatibilityIdentity()
      guard generation == compatibilityGeneration else { return }
      authoritativeCompatibilityIdentity = identity
      compatibilityState = .available(identity)
      updateStatusCompatibilityIdentity(identity)
    } catch {
      guard generation == compatibilityGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      compatibilityState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      compatibilityError = message
      authoritativeCompatibilityIdentity = nil
      updateStatusCompatibilityIdentity(nil)
      lastError = message
    }
  }

  func setCompatibilityIdentity(_ identity: CompatibilityIdentity) async {
    compatibilityGeneration += 1
    let generation = compatibilityGeneration
    authoritativeCompatibilityIdentity = nil
    compatibilityState = .loading
    compatibilityError = nil
    updateStatusCompatibilityIdentity(nil)
    do {
      guard try await gateway.setCompatibilityIdentity(identity) else {
        throw ApplicationServiceGatewayError.compatibilityIdentityChangeRejected(identity)
      }
      guard generation == compatibilityGeneration else { return }
      authoritativeCompatibilityIdentity = identity
      compatibilityState = .available(identity)
      compatibilityError = nil
      updateStatusCompatibilityIdentity(identity)
      lastError = nil
    } catch {
      guard generation == compatibilityGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      compatibilityState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      compatibilityError = message
      authoritativeCompatibilityIdentity = nil
      updateStatusCompatibilityIdentity(nil)
      lastError = message
    }
  }

  func resetCompatibilityIdentity() async { await setCompatibilityIdentity(.automatic) }

  private func locallyValid(
    _ profile: RemappingProfile,
    request: RuntimeMutationRequest
  ) -> RuntimeMutationResult? {
    do {
      try profile.validate()
      return nil
    } catch {
      lastMutationID = request.id
      lastMutationOperation = request.operation
      let message = RuntimePresentation.userFacingError(error)
      mutationState = .error(message)
      lastError = message
      return .failed(id: request.id, operation: request.operation, message: message)
    }
  }

  private func performMutation(
    request mutationRequest: RuntimeMutationRequest,
    conflictProfileID: UUID?,
    request: @escaping @Sendable () async throws -> ApplicationServiceRemappingSnapshotPayload
  ) async -> RuntimeMutationResult {
    guard !mutationInFlight else { return rejectMutation(mutationRequest) }
    await waitForScopedRefreshCompletion()
    await waitForExclusiveOperationCompletion()
    guard !mutationInFlight else { return rejectMutation(mutationRequest) }
    let operation = mutationRequest.operation
    let mutationID = mutationRequest.id
    mutationInFlight = true
    activeMutationOperation = operation
    activeMutationID = mutationID
    lastMutationOperation = nil
    lastMutationID = nil
    mutationState = .saving
    defer {
      mutationInFlight = false
      activeMutationOperation = nil
      activeMutationID = nil
      resumeExclusiveOperationWaiters()
      schedulePendingScopedRefresh()
    }
    do {
      let snapshot = try await request()
      remappingState = .available(snapshot)
      postEventAccessState = .available(snapshot.postEventAccess)
      postEventAccessGeneration += 1
      authoritativePostEventAccess = snapshot.postEventAccess
      updateStatusRemappingSnapshot(snapshot, postEventAccess: snapshot.postEventAccess)
      lastMutationOperation = operation
      lastMutationID = mutationID
      switch operation {
      case .update(let profileID): mutationState = .succeeded(profileID: profileID)
      default: mutationState = .completed(operation)
      }
      lastError = nil
      return .succeeded(id: mutationID, operation: operation)
    } catch {
      let message = RuntimePresentation.userFacingError(error)
      if let rpcError = error as? ApplicationServiceRemappingRPCError,
        rpcError.code == .profileUpdateConflict
      {
        lastMutationOperation = operation
        lastMutationID = mutationID
        mutationState = .conflict(profileID: conflictProfileID)
        lastError = message
        return .conflict(id: mutationID, operation: operation)
      }
      lastMutationOperation = operation
      lastMutationID = mutationID
      mutationState = .error(message)
      lastError = message
      return .failed(id: mutationID, operation: operation, message: message)
    }
  }

  @discardableResult
  private func rejectMutation(_ request: RuntimeMutationRequest) -> RuntimeMutationResult {
    lastMutationOperation = request.operation
    lastMutationID = request.id
    let message = OJDLocalized.string(
      "error.actionInProgress",
      fallback: "Another profile action is already in progress."
    )
    mutationState = .error(message)
    lastError = message
    return .rejected(id: request.id, operation: request.operation, message: message)
  }

  func updateStatusPermissions(_ permissions: RuntimePermissionSummary) {
    guard case .available(let status) = statusState else { return }
    let nextState = RuntimeStatusState.available(status.applyingPermissions(permissions))
    if statusState != nextState { statusState = nextState }
  }

  func updateStatusPostEventAccess(_ state: RemappingPostEventAccessState?) {
    guard case .available(let status) = statusState else { return }
    let nextState = RuntimeStatusState.available(status.applyingPostEventAccess(state))
    if statusState != nextState { statusState = nextState }
  }

  func updateStatusCompatibilityIdentity(_ identity: CompatibilityIdentity?) {
    guard case .available(let status) = statusState else { return }
    let nextState = RuntimeStatusState.available(status.applyingCompatibilityIdentity(identity))
    if statusState != nextState { statusState = nextState }
  }

  func updateStatusRemappingSnapshot(
    _ snapshot: ApplicationServiceRemappingSnapshotPayload,
    postEventAccess: RemappingPostEventAccessState?
  ) {
    guard case .available(let status) = statusState else { return }
    let nextState = RuntimeStatusState.available(
      status.applyingRemappingSnapshot(snapshot, postEventAccess: postEventAccess)
    )
    if statusState != nextState { statusState = nextState }
  }
}
