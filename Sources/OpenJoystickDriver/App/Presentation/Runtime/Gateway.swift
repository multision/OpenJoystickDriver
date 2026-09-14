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
}

protocol ApplicationServiceGateway: RuntimeStatusGateway, ControllerDiagnosticsGateway,
  RemappingGateway, CompatibilityGateway
{}

enum ApplicationServiceGatewayError: Error, LocalizedError, Sendable, Equatable {
  case invalidCompatibilityIdentity(String)
  case compatibilityIdentityChangeRejected(CompatibilityIdentity)

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
    }
  }
}

actor ApplicationServiceClientGateway: ApplicationServiceGateway {
  private let client: ApplicationServiceClient
  private var connectionTask: Task<Void, Never>?

  init(client: ApplicationServiceClient = ApplicationServiceClient()) { self.client = client }

  func status() async throws -> ApplicationServiceStatusPayload {
    await ensureConnection()
    return try await client.getStatus()
  }

  func virtualDeviceDiagnostics() async throws -> ApplicationServiceVirtualDeviceDiagnosticsPayload
  {
    await ensureConnection()
    return try await client.getVirtualDeviceDiagnostics()
  }

  func requestPermissions() async throws -> PermissionManager.Snapshot {
    await ensureConnection()
    return try await client.requestRequiredAccess()
  }

  func requestPermission(
    _ requirement: PermissionManager.Requirement
  ) async throws -> PermissionManager.Snapshot {
    await ensureConnection()
    return try await client.requestAccess(requirement)
  }

  func deviceInputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState? {
    await ensureConnection()
    return try await client.deviceInputState(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier
    )
  }

  func packetLog(for selector: RuntimeDeviceSelector) async throws -> [PacketLogEntry] {
    await ensureConnection()
    return try await client.packetLog(
      vendorID: selector.vendorID,
      productID: selector.productID,
      runtimeIdentifier: selector.runtimeIdentifier
    )
  }

  func remappingSnapshot() async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.getRemappingSnapshot()
  }

  func remappingProfile(id: UUID) async throws -> RemappingProfile {
    await ensureConnection()
    return try await client.getRemappingProfile(id: id)
  }

  func createRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.createRemappingProfile(profile)
  }

  func updateRemappingProfile(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.updateRemappingProfile(profile, expectedCurrent: expectedCurrent)
  }

  func importRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.importRemappingProfile(profile)
  }

  func deleteRemappingProfile(id: UUID) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.deleteRemappingProfile(id: id)
  }

  func activateRemappingProfile(id: UUID) async throws -> ApplicationServiceRemappingSnapshotPayload
  {
    await ensureConnection()
    return try await client.activateRemappingProfile(id: id)
  }

  func deactivateRemappingProfile(
    vendorID: UInt16,
    productID: UInt16
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.deactivateRemappingProfile(vendorID: vendorID, productID: productID)
  }

  func deactivateRemappingProfile(
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.deactivateRemappingProfile(profileID: profileID)
  }

  func remappingPostEventAccess() async throws -> RemappingPostEventAccessState {
    await ensureConnection()
    return try await client.getRemappingPostEventAccess()
  }

  func requestRemappingPostEventAccess() async throws -> RemappingPostEventAccessState {
    await ensureConnection()
    return try await client.requestRemappingPostEventAccess()
  }

  func pairRemappingJoyCons(
    left: String,
    right: String,
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.pairRemappingJoyCons(
      leftRuntimeIdentifier: left,
      rightRuntimeIdentifier: right,
      profileID: profileID
    )
  }

  func unpairRemappingJoyCons(
    sessionID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    await ensureConnection()
    return try await client.unpairRemappingJoyCons(sessionID: sessionID)
  }

  func compatibilityIdentity() async throws -> CompatibilityIdentity {
    await ensureConnection()
    let rawValue = try await client.getCompatibilityIdentity()
    guard let identity = CompatibilityIdentity(rawValue: rawValue) else {
      throw ApplicationServiceGatewayError.invalidCompatibilityIdentity(rawValue)
    }
    return identity
  }

  func setCompatibilityIdentity(_ identity: CompatibilityIdentity) async throws -> Bool {
    await ensureConnection()
    return try await client.setCompatibilityIdentity(identity.rawValue)
  }

  private func ensureConnection() async {
    guard !client.isConnected else { return }
    if let connectionTask {
      await connectionTask.value
      return
    }
    let client = self.client
    let task = Task.detached(priority: nil) { client.connect() }
    connectionTask = task
    await task.value
    connectionTask = nil
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
