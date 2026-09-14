import Combine
import Foundation
import OpenJoystickDriverKit

@MainActor
final class RuntimeViewModel: ObservableObject {
  let gateway: any ApplicationServiceGateway

  @Published
  var loadState: RuntimeLoadState = .loading
  @Published
  var statusState: RuntimeStatusState = .loading
  @Published
  var remappingState: RuntimeRemappingState = .loading
  @Published
  var permissionState: RuntimePermissionLoadState = .unavailable
  @Published
  var postEventAccessState: RuntimePostEventAccessLoadState = .loading
  @Published
  var compatibilityState: RuntimeCompatibilityState = .loading
  @Published
  var compatibilityError: String?
  @Published
  var mutationState: RuntimeMutationState = .idle
  @Published
  var inputCaptureState: RuntimeInputCaptureState = .idle
  @Published
  var supportDiagnosticsState: RuntimeSupportDiagnosticsState = .idle
  @Published
  var supportReportState: RuntimeSupportReportState = .idle
  @Published
  var supportLogsState: RuntimeSupportLogsState = .idle
  @Published
  var lastError: String?
  @Published
  var activeMutationOperation: RuntimeMutationOperation?
  @Published
  var activeMutationID: UUID?
  @Published
  var lastMutationOperation: RuntimeMutationOperation?
  @Published
  var lastMutationID: UUID?
  @Published
  private(set) var systemExtensionSetupState: SystemExtensionSetupState = .checking

  var requestedCompatibilityIdentity: CompatibilityIdentity {
    if let authoritativeCompatibilityIdentity { return authoritativeCompatibilityIdentity }
    guard case .available(let status) = statusState, let identity = status.compatibilityIdentity
    else { return .automatic }
    return identity
  }

  var refreshGeneration = 0
  var liveStatusGeneration = 0
  var permissionRefreshGeneration = 0
  var postEventAccessGeneration = 0
  var compatibilityGeneration = 0
  var authoritativePermissionSummary: RuntimePermissionSummary?
  var authoritativePostEventAccess: RemappingPostEventAccessState?
  var authoritativeCompatibilityIdentity: CompatibilityIdentity?
  var inputGeneration = 0
  var supportDiagnosticsGeneration = 0
  var supportReportGeneration = 0
  var supportLogsGeneration = 0
  var mutationInFlight = false
  var fullRefreshInFlight = false
  var scopedRefreshInFlight = false
  private let systemExtensionSetup: SystemExtensionSetupCoordinator

  init(
    gateway: any ApplicationServiceGateway,
    systemExtensionSetup: SystemExtensionSetupCoordinator = SystemExtensionSetupCoordinator()
  ) {
    self.gateway = gateway
    self.systemExtensionSetup = systemExtensionSetup
  }

  func startSystemExtensionSetup() async {
    await systemExtensionSetup.launch()
    systemExtensionSetupState = systemExtensionSetup.state
  }

  func refreshSystemExtensionSetup() async {
    await systemExtensionSetup.refresh()
    systemExtensionSetupState = systemExtensionSetup.state
  }

  func repairSystemExtension() async {
    await systemExtensionSetup.repair()
    systemExtensionSetupState = systemExtensionSetup.state
  }

  func refresh() async {
    await refreshSystemExtensionSetup()
    refreshGeneration += 1
    let generation = refreshGeneration
    fullRefreshInFlight = true
    defer { if generation == refreshGeneration { fullRefreshInFlight = false } }
    liveStatusGeneration += 1
    let statusGeneration = liveStatusGeneration
    loadState = .loading
    statusState = .loading
    remappingState = .loading
    permissionRefreshGeneration += 1
    let permissionGeneration = permissionRefreshGeneration
    postEventAccessGeneration += 1
    let postEventGeneration = postEventAccessGeneration
    compatibilityGeneration += 1
    let compatibilityOperationGeneration = compatibilityGeneration
    authoritativePermissionSummary = nil
    authoritativePostEventAccess = nil
    authoritativeCompatibilityIdentity = nil
    permissionState = .loading
    postEventAccessState = .loading
    compatibilityState = .loading
    compatibilityError = nil
    lastError = nil
    var loadedAny = false

    do {
      let payload = try await gateway.status()
      guard generation == refreshGeneration, statusGeneration == liveStatusGeneration else {
        return
      }
      let permissions: RuntimePermissionSummary
      if permissionGeneration == permissionRefreshGeneration {
        permissions = RuntimePermissionSummary(status: payload)
        authoritativePermissionSummary = permissions
      } else {
        // A newer permission request owns the visible permission state.  Until its response is
        // available, replace the payload's old value with an honest checking state.
        permissions =
          authoritativePermissionSummary
          ?? RuntimePermissionSummary(inputMonitoring: .unknown, accessibility: .unknown)
      }
      let presentation = RuntimeStatusPresentation(payload: payload).applyingPermissions(
        permissions
      ).applyingCompatibilityIdentity(authoritativeCompatibilityIdentity)
      statusState = .available(presentation)
      if permissionGeneration == permissionRefreshGeneration {
        permissionState = .available(permissions)
      }
      loadedAny = true
    } catch {
      guard generation == refreshGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      statusState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      if permissionGeneration == permissionRefreshGeneration { permissionState = .error(message) }
      lastError = message
    }

    do {
      let snapshot = try await gateway.remappingSnapshot()
      guard generation == refreshGeneration else { return }
      remappingState = .available(snapshot)
      let postEventAccess: RemappingPostEventAccessState?
      if postEventGeneration == postEventAccessGeneration {
        let currentPostEventAccess = snapshot.postEventAccess
        postEventAccess = currentPostEventAccess
        authoritativePostEventAccess = currentPostEventAccess
        postEventAccessState = .available(currentPostEventAccess)
      } else {
        // A newer access request owns the visible state.  Do not let this older snapshot roll its
        // result back while the newer request is loading or has already completed.
        postEventAccess = authoritativePostEventAccess
      }
      updateStatusRemappingSnapshot(snapshot, postEventAccess: postEventAccess)
      loadedAny = true
    } catch {
      guard generation == refreshGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      remappingState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      if postEventGeneration == postEventAccessGeneration {
        postEventAccessState =
          RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      }
      lastError = lastError ?? message
    }

    do {
      let identity = try await gateway.compatibilityIdentity()
      guard generation == refreshGeneration else { return }
      // A scoped Output action may have started while the broader refresh was in flight.  Keep
      // that newer operation authoritative instead of letting this older read roll it back.
      if compatibilityOperationGeneration == compatibilityGeneration {
        authoritativeCompatibilityIdentity = identity
        compatibilityState = .available(identity)
        compatibilityError = nil
        updateStatusCompatibilityIdentity(identity)
        loadedAny = true
      }
    } catch {
      guard generation == refreshGeneration else { return }
      if compatibilityOperationGeneration == compatibilityGeneration {
        let message = RuntimePresentation.userFacingError(error)
        compatibilityState =
          RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
        compatibilityError = message
        authoritativeCompatibilityIdentity = nil
        updateStatusCompatibilityIdentity(nil)
        lastError = lastError ?? message
      }
    }

    guard generation == refreshGeneration else { return }
    loadState =
      loadedAny
      ? .available
      : .unavailable(
        lastError
          ?? OJDLocalized.string(
            "error.notAvailable",
            fallback: "OpenJoystickDriver isn't available right now."
          )
      )
  }

  /// Refreshes connection- and profile-sensitive state without replacing the UI with loading state.
  @discardableResult
  func refreshLiveStatus() async -> Bool {
    guard !fullRefreshInFlight, !mutationInFlight, !scopedRefreshInFlight else { return false }
    let previousStatusState = statusState
    let previousRemappingState = remappingState
    let previousPermissionState = permissionState
    let previousPostEventAccessState = postEventAccessState
    let previousLoadState = loadState
    let previousLastError = lastError
    scopedRefreshInFlight = true
    defer { scopedRefreshInFlight = false }
    liveStatusGeneration += 1
    let generation = liveStatusGeneration
    await refreshStatusRetainingPresentation(generation: generation)

    do {
      let snapshot = try await gateway.remappingSnapshot()
      guard generation == liveStatusGeneration else { return false }
      let nextRemappingState = RuntimeRemappingState.available(snapshot)
      if remappingState != nextRemappingState { remappingState = nextRemappingState }
      authoritativePostEventAccess = snapshot.postEventAccess
      let nextPostEventAccessState = RuntimePostEventAccessLoadState.available(
        snapshot.postEventAccess
      )
      if postEventAccessState != nextPostEventAccessState {
        postEventAccessState = nextPostEventAccessState
      }
      updateStatusRemappingSnapshot(snapshot, postEventAccess: snapshot.postEventAccess)
    } catch {
      // Keep the last known remapping state during an unobtrusive background refresh.
    }
    return previousStatusState != statusState || previousRemappingState != remappingState
      || previousPermissionState != permissionState
      || previousPostEventAccessState != postEventAccessState || previousLoadState != loadState
      || previousLastError != lastError
  }

  /// Refreshes controller inventory and permission observations without touching unrelated panes.
  func refreshControllerInventory() async {
    guard !fullRefreshInFlight, !mutationInFlight, !scopedRefreshInFlight else { return }
    scopedRefreshInFlight = true
    defer { scopedRefreshInFlight = false }
    liveStatusGeneration += 1
    await refreshStatusRetainingPresentation(generation: liveStatusGeneration)
  }

  private func refreshStatusRetainingPresentation(generation: Int) async {
    do {
      let payload = try await gateway.status()
      guard generation == liveStatusGeneration else { return }
      let previousStatus: RuntimeStatusPresentation?
      if case .available(let status) = statusState {
        previousStatus = status
      } else {
        previousStatus = nil
      }
      let permissions: RuntimePermissionSummary
      switch permissionState {
      case .requesting:
        permissions =
          authoritativePermissionSummary
          ?? RuntimePermissionSummary(inputMonitoring: .unknown, accessibility: .unknown)
      case .loading, .available, .unavailable, .error:
        permissions = RuntimePermissionSummary(status: payload)
        authoritativePermissionSummary = permissions
      }
      let nextStatusState = RuntimeStatusState.available(
        RuntimeStatusPresentation(
          payload: payload,
          postEventAccess: authoritativePostEventAccess ?? previousStatus?.postEventAccess,
          requiresPostEventAccess: previousStatus?.requiresPostEventAccess
        ).applyingPermissions(permissions)
      )
      if statusState != nextStatusState { statusState = nextStatusState }
      if case .requesting = permissionState {
        // The explicit permission request remains authoritative until its response arrives.
      } else {
        let nextPermissionState = RuntimePermissionLoadState.available(permissions)
        if permissionState != nextPermissionState { permissionState = nextPermissionState }
      }
      if loadState != .available { loadState = .available }
      if lastError != nil { lastError = nil }
    } catch {
      guard generation == liveStatusGeneration else { return }
      if case .loading = statusState {
        let message = RuntimePresentation.userFacingError(error)
        statusState =
          RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
        lastError = message
      }
    }
  }

  func refreshPermissions() async {
    permissionRefreshGeneration += 1
    let generation = permissionRefreshGeneration
    authoritativePermissionSummary = nil
    permissionState = .loading
    updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
    do {
      let payload = try await gateway.status()
      guard generation == permissionRefreshGeneration else { return }
      let presentation = RuntimeStatusPresentation(payload: payload)
      permissionState = .available(presentation.permissions)
      authoritativePermissionSummary = presentation.permissions
      updateStatusPermissions(presentation.permissions)
    } catch {
      guard generation == permissionRefreshGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      permissionState = .error(message)
      updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
      lastError = message
    }
  }

  @discardableResult
  func requestPermissions() async -> RuntimePermissionSummary? {
    permissionRefreshGeneration += 1
    let generation = permissionRefreshGeneration
    authoritativePermissionSummary = nil
    permissionState = .requesting
    updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
    do {
      let snapshot = try await gateway.requestPermissions()
      guard generation == permissionRefreshGeneration else { return nil }
      let permissions = RuntimePermissionSummary(snapshot: snapshot)
      permissionState = .available(permissions)
      authoritativePermissionSummary = permissions
      updateStatusPermissions(permissions)
      lastError = nil
      return permissions
    } catch {
      guard generation == permissionRefreshGeneration else { return nil }
      let message = RuntimePresentation.userFacingError(error)
      permissionState = .error(message)
      updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
      lastError = message
      return nil
    }
  }

  @discardableResult
  func requestPermission(
    _ requirement: PermissionManager.Requirement
  ) async -> RuntimePermissionSummary? {
    permissionRefreshGeneration += 1
    let generation = permissionRefreshGeneration
    authoritativePermissionSummary = nil
    permissionState = .requesting
    updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
    do {
      let snapshot = try await gateway.requestPermission(requirement)
      guard generation == permissionRefreshGeneration else { return nil }
      let permissions = RuntimePermissionSummary(snapshot: snapshot)
      permissionState = .available(permissions)
      authoritativePermissionSummary = permissions
      updateStatusPermissions(permissions)
      lastError = nil
      return permissions
    } catch {
      guard generation == permissionRefreshGeneration else { return nil }
      let message = RuntimePresentation.userFacingError(error)
      permissionState = .error(message)
      updateStatusPermissions(.init(inputMonitoring: .unknown, accessibility: .unknown))
      lastError = message
      return nil
    }
  }

  @discardableResult
  func requestPostEventAccess() async -> RemappingPostEventAccessState? {
    postEventAccessGeneration += 1
    let generation = postEventAccessGeneration
    authoritativePostEventAccess = nil
    postEventAccessState = .requesting
    updateStatusPostEventAccess(nil)
    do {
      let state = try await gateway.requestRemappingPostEventAccess()
      guard generation == postEventAccessGeneration else { return nil }
      postEventAccessState = .available(state)
      authoritativePostEventAccess = state
      updateStatusPostEventAccess(state)
      lastError = nil
      return state
    } catch {
      guard generation == postEventAccessGeneration else { return nil }
      let message = RuntimePresentation.userFacingError(error)
      postEventAccessState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      authoritativePostEventAccess = nil
      updateStatusPostEventAccess(nil)
      lastError = message
      return nil
    }
  }

  func refreshPostEventAccess() async {
    postEventAccessGeneration += 1
    let generation = postEventAccessGeneration
    authoritativePostEventAccess = nil
    postEventAccessState = .loading
    updateStatusPostEventAccess(nil)
    do {
      let state = try await gateway.remappingPostEventAccess()
      guard generation == postEventAccessGeneration else { return }
      postEventAccessState = .available(state)
      authoritativePostEventAccess = state
      updateStatusPostEventAccess(state)
    } catch {
      guard generation == postEventAccessGeneration else { return }
      let message = RuntimePresentation.userFacingError(error)
      postEventAccessState =
        RuntimePresentation.isUnavailable(error) ? .unavailable(message) : .error(message)
      authoritativePostEventAccess = nil
      updateStatusPostEventAccess(nil)
      lastError = message
    }
  }

}
