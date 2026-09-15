import Combine
import Foundation
import OpenJoystickDriverKit

protocol RuntimeStatusGateway: Sendable {
  func status() async throws -> ApplicationServiceStatusPayload
  func virtualDeviceDiagnostics() async throws -> ApplicationServiceVirtualDeviceDiagnosticsPayload
  func requestPermissions() async throws -> PermissionManager.Snapshot
  func requestPermission(
    _ requirement: PermissionManager.Requirement
  ) async throws -> PermissionManager.Snapshot
  func deviceInputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState?
}

protocol ControllerDiagnosticsGateway: Sendable {
  func deviceInputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState?
  func packetLog(for selector: RuntimeDeviceSelector) async throws -> [PacketLogEntry]
}

protocol RemappingGateway: Sendable {
  func remappingSnapshot() async throws -> ApplicationServiceRemappingSnapshotPayload
  func remappingProfile(id: UUID) async throws -> RemappingProfile
  func createRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func updateRemappingProfile(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func importRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func deleteRemappingProfile(id: UUID) async throws -> ApplicationServiceRemappingSnapshotPayload
  func deleteDamagedRemappingProfile(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func resetRemappingProfileLibrary(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func activateRemappingProfile(id: UUID) async throws -> ApplicationServiceRemappingSnapshotPayload
  func deactivateRemappingProfile(
    vendorID: UInt16,
    productID: UInt16
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func deactivateRemappingProfile(
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func remappingPostEventAccess() async throws -> RemappingPostEventAccessState
  func requestRemappingPostEventAccess() async throws -> RemappingPostEventAccessState
  func pairRemappingJoyCons(
    left: String,
    right: String,
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
  func unpairRemappingJoyCons(
    sessionID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload
}

protocol CompatibilityGateway: Sendable {
  func compatibilityIdentity() async throws -> CompatibilityIdentity
  func setCompatibilityIdentity(_ identity: CompatibilityIdentity) async throws -> Bool
  func setCompatibilityIdentityDetailed(
    _ identity: CompatibilityIdentity
  ) async throws -> CompatibilityIdentityTransitionResult
  func suspendController(_ selector: RuntimeDeviceSelector) async throws -> ControllerSuspendResult
  func resumeController(_ selector: RuntimeDeviceSelector) async throws -> ControllerResumeResult
  func disconnectWirelessController(
    _ selector: RuntimeDeviceSelector
  ) async throws -> WirelessControllerDisconnectResult
}

extension CompatibilityGateway {
  func setCompatibilityIdentityDetailed(
    _ identity: CompatibilityIdentity
  ) async throws -> CompatibilityIdentityTransitionResult {
    let succeeded = try await setCompatibilityIdentity(identity)
    let live = succeeded ? identity : try? await compatibilityIdentity()
    return CompatibilityIdentityTransitionResult(
      requestedIdentity: identity,
      liveIdentity: live,
      retainedIdentity: succeeded ? nil : live,
      failure: succeeded
        ? nil : CompatibilityIdentityTransitionFailure(phase: .activation, cause: .unavailable)
    )
  }

  func suspendController(_ selector: RuntimeDeviceSelector) async throws -> ControllerSuspendResult
  {
    _ = try? await compatibilityIdentity()
    return ControllerSuspendResult(state: .active, failure: .notFound)
  }

  func resumeController(_ selector: RuntimeDeviceSelector) async throws -> ControllerResumeResult {
    _ = try? await compatibilityIdentity()
    return ControllerResumeResult(state: .suspended, failure: .notFound)
  }

  func disconnectWirelessController(
    _ selector: RuntimeDeviceSelector
  ) async throws -> WirelessControllerDisconnectResult {
    _ = try? await compatibilityIdentity()
    return WirelessControllerDisconnectResult(state: .active, failure: .notFound)
  }
}

protocol ApplicationServiceGateway: RuntimeStatusGateway, ControllerDiagnosticsGateway,
  RemappingGateway, CompatibilityGateway
{}

enum ApplicationServiceGatewayError: Error, LocalizedError, Sendable, Equatable {
  case invalidCompatibilityIdentity(String)
  case compatibilityIdentityChangeRejected(CompatibilityIdentity)
  case profileRecoveryUnavailable
  case controllerSessionChangeRejected

  var errorDescription: String? {
    switch self {
    case .invalidCompatibilityIdentity:
      return OJDLocalized.string(
        "error.selectedOutputUnavailable",
        fallback: "The selected controller output is unavailable."
      )
    case .compatibilityIdentityChangeRejected:
      return OJDLocalized.string(
        "error.selectedOutputEnableFailed",
        fallback: "The selected controller output could not be enabled."
      )
    case .profileRecoveryUnavailable:
      return OJDLocalized.string("profiles.unavailable", fallback: "Profiles unavailable")
    case .controllerSessionChangeRejected:
      return OJDLocalized.string(
        "error.controllerSessionChangeRejected",
        fallback: "The controller session could not be changed."
      )
    }
  }
}

actor ApplicationServiceClientGateway: ApplicationServiceGateway {
  let client: ApplicationServiceClient
  var connectionTask: Task<Void, Never>?

  init(client: ApplicationServiceClient = ApplicationServiceClient()) { self.client = client }
}

extension RemappingGateway {
  func deleteDamagedRemappingProfile(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await Task.yield()
    throw ApplicationServiceGatewayError.profileRecoveryUnavailable
  }

  func resetRemappingProfileLibrary(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await Task.yield()
    throw ApplicationServiceGatewayError.profileRecoveryUnavailable
  }
}

extension ApplicationServiceClientGateway: InputTestDeviceGateway {
  func inputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState? {
    try await deviceInputState(for: selector)
  }

  func sendRumble(
    for selector: RuntimeDeviceSelector,
    left: UInt8,
    right: UInt8,
    leftTrigger: UInt8,
    rightTrigger: UInt8,
    durationMilliseconds: Int
  ) async throws -> Bool {
    await ensureConnection()
    return try await client.sendPhysicalRumble(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier,
      left: left,
      right: right,
      lt: leftTrigger,
      rt: rightTrigger,
      durationMs: durationMilliseconds
    )
  }

  func setPlayerIndicator(
    for selector: RuntimeDeviceSelector,
    indicator: PhysicalPlayerIndicator
  ) async throws -> Bool {
    await ensureConnection()
    return try await client.setPhysicalPlayerIndicator(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier,
      indicator: indicator
    )
  }

  func previewColor(
    for selector: RuntimeDeviceSelector,
    token: UUID,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async throws -> Bool {
    await ensureConnection()
    return try await client.previewPhysicalColor(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier,
      token: token,
      red: red,
      green: green,
      blue: blue
    )
  }

  func releaseColorPreview(for selector: RuntimeDeviceSelector, token: UUID) async throws -> Bool {
    await ensureConnection()
    return try await client.releasePhysicalColorPreview(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier,
      token: token
    )
  }

  func setBrightness(for selector: RuntimeDeviceSelector, brightness: UInt8) async throws -> Bool {
    await ensureConnection()
    return try await client.setPhysicalBrightness(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier,
      brightness: brightness
    )
  }

  func motionCalibration(
    for selector: RuntimeDeviceSelector,
    command: RemappingMotionCalibrationCommand?
  ) async throws -> RemappingMotionCalibrationStatus {
    guard let runtimeIdentifier = selector.runtimeIdentifier else {
      throw RemappingMotionCalibrationError.controllerUnavailable
    }
    await ensureConnection()
    return try await client.remappingMotionCalibration(
      runtimeIdentifier: runtimeIdentifier,
      command: command
    )
  }
}

struct RuntimeDeviceSelector: Codable, Equatable, Hashable, Sendable {
  let vendorID: UInt16
  let productID: UInt16
  let runtimeIdentifier: String?

  init(vendorID: UInt16, productID: UInt16, runtimeIdentifier: String? = nil) {
    self.vendorID = vendorID
    self.productID = productID
    self.runtimeIdentifier = runtimeIdentifier
  }

  init(device: ApplicationServiceDeviceDescription) {
    self.init(
      vendorID: device.vendorID,
      productID: device.productID,
      runtimeIdentifier: device.runtimeIdentifier
    )
  }

  var displayIdentifier: String {
    runtimeIdentifier ?? String(format: "%04X:%04X", vendorID, productID)
  }
}
