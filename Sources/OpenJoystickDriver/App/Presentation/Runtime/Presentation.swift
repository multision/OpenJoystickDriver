import Foundation
import OpenJoystickDriverKit

enum RuntimeLoadState: Sendable, Equatable {
  case loading
  case available
  case unavailable(String)
  case error(String)
}

enum RuntimePermissionState: String, Sendable, Equatable {
  case granted
  case denied
  case unknown
  case unavailable
}

struct RuntimePermissionSummary: Sendable, Equatable {
  let inputMonitoring: RuntimePermissionState
  let accessibility: RuntimePermissionState

  init(inputMonitoring: RuntimePermissionState, accessibility: RuntimePermissionState) {
    self.inputMonitoring = inputMonitoring
    self.accessibility = accessibility
  }

  init(status: ApplicationServiceStatusPayload) {
    self.init(
      inputMonitoring: Self.state(for: status.inputMonitoring),
      accessibility: Self.state(for: status.accessibility)
    )
  }

  init(snapshot: PermissionManager.Snapshot) {
    self.init(
      inputMonitoring: Self.state(for: snapshot.inputMonitoring),
      accessibility: Self.state(for: snapshot.accessibility)
    )
  }

  var isReady: Bool { inputMonitoring == .granted && accessibility == .granted }

  var inputMonitoringLabel: String { RuntimePresentation.permissionLabel(inputMonitoring) }

  var accessibilityLabel: String { RuntimePresentation.permissionLabel(accessibility) }

  static func state(for value: String) -> RuntimePermissionState {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "granted": return .granted
    case "denied": return .denied
    case "unknown": return .unknown
    default: return .unavailable
    }
  }

  static func state(for value: PermissionManager.AccessState) -> RuntimePermissionState {
    switch value {
    case .granted: return .granted
    case .denied: return .denied
    case .unknown: return .unknown
    }
  }
}

enum RuntimeOutputState: String, Sendable, Equatable {
  case ready
  case unavailable
  case error
  case unknown
}

enum RuntimeReadiness: String, Sendable, Equatable {
  case ready
  case needsAttention
  case noController
}

struct RuntimeStatusPresentation: Sendable, Equatable {
  let permissions: RuntimePermissionSummary
  let devices: [ApplicationServiceDeviceDescription]
  let compatibilityIdentity: CompatibilityIdentity?
  let compatibilityLabel: String
  let outputState: RuntimeOutputState
  let outputDetail: String?
  let postEventAccess: RemappingPostEventAccessState?
  let requiresPostEventAccess: Bool?
  let readiness: RuntimeReadiness

  init(
    payload: ApplicationServiceStatusPayload,
    postEventAccess: RemappingPostEventAccessState? = nil,
    requiresPostEventAccess: Bool? = nil
  ) {
    let permissions = RuntimePermissionSummary(status: payload)
    let identity = payload.compatibilityIdentity.flatMap(CompatibilityIdentity.init(rawValue:))
    let outputState: RuntimeOutputState
    if payload.userSpaceVirtualDeviceStatus?.lowercased().hasPrefix("error:") == true {
      outputState = .error
    } else if payload.userSpaceVirtualDeviceEnabled == nil {
      outputState = .unknown
    } else if payload.userSpaceVirtualDeviceEnabled == false {
      outputState = .unavailable
    } else {
      outputState = .ready
    }

    self.permissions = permissions
    self.devices = payload.connectedDevices
    self.compatibilityIdentity = identity
    self.compatibilityLabel =
      identity.map(RuntimePresentation.compatibilityLabel)
      ?? OJDLocalized.string("common.unavailable", fallback: "Unavailable")
    self.outputState = outputState
    self.outputDetail = RuntimePresentation.outputDetail(
      enabled: payload.userSpaceVirtualDeviceEnabled,
      status: payload.userSpaceVirtualDeviceStatus
    )
    self.postEventAccess = postEventAccess
    self.requiresPostEventAccess = requiresPostEventAccess
    self.readiness = Self.readiness(
      permissions: permissions,
      outputState: outputState,
      postEventAccess: postEventAccess,
      requiresPostEventAccess: requiresPostEventAccess,
      devices: payload.connectedDevices
    )
  }

  init(
    permissions: RuntimePermissionSummary,
    devices: [ApplicationServiceDeviceDescription],
    compatibilityIdentity: CompatibilityIdentity?,
    compatibilityLabel: String,
    outputState: RuntimeOutputState,
    outputDetail: String?,
    postEventAccess: RemappingPostEventAccessState?,
    requiresPostEventAccess: Bool?,
    readiness: RuntimeReadiness
  ) {
    self.permissions = permissions
    self.devices = devices
    self.compatibilityIdentity = compatibilityIdentity
    self.compatibilityLabel = compatibilityLabel
    self.outputState = outputState
    self.outputDetail = outputDetail
    self.postEventAccess = postEventAccess
    self.requiresPostEventAccess = requiresPostEventAccess
    self.readiness = readiness
  }
}

extension RemappingProfile {
  var hasOutputMappings: Bool {
    if gyroOutput.mode != .disabled || gyroOutput.virtualMotion || !stickMappings.isEmpty
      || !touchMappings.isEmpty || motionTuning.steering != nil
      || layers.contains(where: { $0.motionTuning?.steering != nil })
    {
      return true
    }
    if !bindings.isEmpty || !chords.isEmpty || !sequences.isEmpty { return true }
    return layers.contains { layer in
      !layer.bindings.isEmpty || !layer.chords.isEmpty || !layer.sequences.isEmpty
    }
  }
}

enum RuntimeStatusState: Sendable, Equatable {
  case loading
  case available(RuntimeStatusPresentation)
  case unavailable(String)
  case error(String)
}

enum RuntimeRemappingState: Sendable, Equatable {
  case loading
  case available(ApplicationServiceRemappingSnapshotPayload)
  case unavailable(String)
  case error(String)
}

enum RuntimeActiveProfileState: Sendable, Equatable {
  case loading
  case noProfile
  case profile(String)
  case unavailable(String)
  case error(String)
}

enum RuntimePermissionLoadState: Sendable, Equatable {
  case loading
  case unavailable
  case requesting
  case available(RuntimePermissionSummary)
  case error(String)
}

enum RuntimePostEventAccessLoadState: Sendable, Equatable {
  case loading
  case requesting
  case available(RemappingPostEventAccessState)
  case unavailable(String)
  case error(String)
}

enum RuntimeCompatibilityState: Sendable, Equatable {
  case loading
  case available(CompatibilityIdentity)
  case unavailable(String)
  case error(String)
}

enum RuntimeMutationState: Sendable {
  case idle
  case saving
  case succeeded(profileID: UUID)
  case completed(RuntimeMutationOperation)
  case conflict(profileID: UUID?)
  case error(String)
}

struct RuntimeMutationRequest: Equatable, Sendable {
  let operation: RuntimeMutationOperation
  let id: UUID

  init(operation: RuntimeMutationOperation, id: UUID = UUID()) {
    self.operation = operation
    self.id = id
  }
}

enum RuntimeMutationResult: Equatable, Sendable {
  case succeeded(id: UUID, operation: RuntimeMutationOperation)
  case conflict(id: UUID, operation: RuntimeMutationOperation)
  case failed(id: UUID, operation: RuntimeMutationOperation, message: String)
  case rejected(id: UUID, operation: RuntimeMutationOperation, message: String)

  var id: UUID {
    switch self {
    case .succeeded(let id, _), .conflict(let id, _), .failed(let id, _, _),
      .rejected(let id, _, _):
      return id
    }
  }

  var operation: RuntimeMutationOperation {
    switch self {
    case .succeeded(_, let operation), .conflict(_, let operation), .failed(_, let operation, _),
      .rejected(_, let operation, _):
      return operation
    }
  }

  var request: RuntimeMutationRequest { RuntimeMutationRequest(operation: operation, id: id) }
}

enum RuntimeMutationOperation: Sendable, Equatable {
  case create(profileID: UUID)
  case update(profileID: UUID)
  case importProfile(profileID: UUID)
  case delete(profileID: UUID)
  case activate(profileID: UUID)
  case deactivate(profileID: UUID?)

  var profileID: UUID? {
    switch self {
    case .create(let profileID), .update(let profileID), .importProfile(let profileID),
      .delete(let profileID), .activate(let profileID):
      return profileID
    case .deactivate(let profileID): return profileID
    }
  }
}

enum RuntimeInputCaptureState: Sendable {
  case idle
  case listening(RuntimeDeviceSelector)
  case received(RuntimeDeviceSelector, DeviceInputState)
  case detected(RuntimeDeviceSelector, DeviceInputState, RemappingSource)
  case unavailable(RuntimeDeviceSelector, String)
  case error(RuntimeDeviceSelector, String)
}
