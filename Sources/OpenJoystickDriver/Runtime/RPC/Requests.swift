import Foundation
import OpenJoystickDriverKit

extension ApplicationServiceServer {
  /// Returns a list of connected device descriptions.
  public func listDevices(reply: @escaping ([String]) -> Void) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let devices = await dm.connectedDeviceDescriptions()
      let strings = devices.map(Self.deviceDescriptionLine)
      callback.call(strings)
    }
  }

  static func deviceDescriptionLine(_ device: ApplicationServiceDeviceDescription) -> String {
    let serialNumber = device.serialNumber ?? "none"
    let quirks = device.quirks.isEmpty ? "none" : device.quirks.joined(separator: ",")
    let backends =
      device.preferredBackends.isEmpty ? "none" : device.preferredBackends.joined(separator: ",")
    let battery = device.battery.map(Self.batteryDescription) ?? "unknown"
    return "\(device.name) (VID:\(device.vendorID)" + " PID:\(device.productID) \(device.parser)"
      + " [\(device.connection)] SN:\(serialNumber))"
      + " protocol=\(device.protocolVariant.rawValue)"
      + " endpoints=in:0x\(String(device.inputEndpoint, radix: 16))"
      + " out:0x\(String(device.outputEndpoint, radix: 16))"
      + " setConfig=\(device.needsSetConfiguration)" + " settleMs=\(device.postHandshakeSettleMs)"
      + " quirks=\(quirks)" + " backends=\(backends)" + " battery=\(battery)"
      + " session=\(device.sessionState.rawValue)"
      + " startup=\(device.startupCommandStatus ?? "not-required")"
  }

  private static func batteryDescription(_ battery: ControllerBatteryTelemetry) -> String {
    let percentage = battery.percentageDescription ?? "unknown"
    return "\(percentage),\(battery.chargingState.rawValue),cable-\(battery.cableState.rawValue)"
  }

  /// Returns the current application service status including input monitoring state and
  /// connected devices.
  public func getStatus(reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    let pm = permissionManager
    Task {
      let permissions = await pm.refreshAccessState()
      let devices = await dm.connectedDeviceDescriptions()
      let userSnapshot = userSpaceStatusSnapshot()
      let payload = ApplicationServiceStatusPayload(
        inputMonitoring: "\(permissions.inputMonitoring)",
        accessibility: "\(permissions.accessibility)",
        connectedDevices: devices,
        userSpaceVirtualDeviceEnabled: userSnapshot.enabled,
        userSpaceVirtualDeviceStatus: userSnapshot.status,
        compatibilityIdentity: userSnapshot.requestedIdentity.rawValue,
        compatibilityLiveIdentity: userSnapshot.liveIdentity?.rawValue,
        compatibilityRetry: userSnapshot.retrySnapshot.map {
          ApplicationServiceCompatibilityRetryPayload(
            requestedIdentity: $0.requestedIdentity.rawValue,
            priorProfileIdentity: $0.priorProfileIdentity.rawValue,
            phase: $0.phase.rawValue
          )
        }
      )
      do {
        let data = try JSONEncoder().encode(payload)
        callback.call(data)
      } catch {
        print("[ApplicationServiceServer] getStatus encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func requestRequiredAccess(reply: @escaping (PermissionManager.Snapshot) -> Void) {
    let callback = SendableReply(call: reply)
    let pm = permissionManager
    Task {
      let snapshot = await pm.requestRequiredAccess()
      callback.call(snapshot)
    }
  }

  public func requestAccess(
    _ requirement: PermissionManager.Requirement,
    reply: @escaping (PermissionManager.Snapshot) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let pm = permissionManager
    Task {
      let snapshot = await pm.requestAccess(requirement)
      callback.call(snapshot)
    }
  }

  /// Returns the current input state for the specified device as encoded JSON data.
  public func getDeviceInputState(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data?) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let state = await dm.inputState(for: identifier, runtimeIdentifier: runtimeIdentifier)
      callback.call(try? JSONEncoder().encode(state))
    }
  }

  /// Returns the recent packet log for the specified device as encoded JSON data.
  public func getPacketLog(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let log = await dm.packetLog(for: identifier, runtimeIdentifier: runtimeIdentifier)
      do {
        let data = try JSONEncoder().encode(log)
        callback.call(data)
      } catch {
        print("[ApplicationServiceServer] getPacketLog encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func sendPhysicalRumble(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    left: Int,
    right: Int,
    lt: Int,
    rt: Int,
    durationMs: Int,
    reply: @escaping (Bool) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let ok = await dm.sendRumble(
        for: identifier,
        runtimeIdentifier: runtimeIdentifier,
        left: UInt8(clamping: left),
        right: UInt8(clamping: right),
        lt: UInt8(clamping: lt),
        rt: UInt8(clamping: rt),
        durationMs: durationMs
      )
      callback.call(ok)
    }
  }

  public func setPhysicalPlayerIndicator(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    playerIndex: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard let indicator = PhysicalPlayerIndicator(rawValue: playerIndex) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.sendPlayerIndicator(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          indicator: indicator
        )
      )
    }
  }

  public func setPhysicalColor(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    red: Int,
    green: Int,
    blue: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard [red, green, blue].allSatisfy({ (0...255).contains($0) }) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.setPhysicalColor(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          red: UInt8(red),
          green: UInt8(green),
          blue: UInt8(blue)
        )
      )
    }
  }

  public func setPhysicalBrightness(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    brightness: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard (0...255).contains(brightness) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.setPhysicalBrightness(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          brightness: UInt8(brightness)
        )
      )
    }
  }

  /// Enables or disables virtual output suppression and reports success.
  public func setSuppressOutput(_ suppress: Bool, reply: @escaping (Bool) -> Void) {
    let callback = SendableReply(call: reply)
    Task {
      do {
        try await remappingRouter.setOutputSuppressed(suppress)
        callback.call(true)
      } catch { callback.call(false) }
    }
  }

  public func setCompatibilityIdentity(_ raw: String, reply: @escaping (Bool) -> Void) {
    guard case .accepted(let id) = CompatibilityIdentity.mutationDecision(for: raw) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    // The RPC bridge is callback-shaped, so this is the single request-scoped task.  The
    // asynchronous transaction itself owns the ordering: close, then publish, then reply.
    Task { [weak self] in
      guard let self else { return }
      callback.call(await self.setCompatibilityIdentityAsync(id))
    }
  }

  public func setCompatibilityIdentityDetailed(_ raw: String, reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    guard case .accepted(let identity) = CompatibilityIdentity.mutationDecision(for: raw) else {
      let result = CompatibilityIdentityTransitionResult(
        requestedIdentity: nil,
        liveIdentity: userSpaceStatusSnapshot().liveIdentity,
        retainedIdentity: userSpaceStatusSnapshot().liveIdentity,
        failure: CompatibilityIdentityTransitionFailure(phase: .validation, cause: .invalidIdentity)
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
      return
    }
    Task { [weak self] in
      guard let self else { return }
      let succeeded = await self.setCompatibilityIdentityAsync(identity)
      let snapshot = self.userSpaceStatusSnapshot()
      let result = CompatibilityIdentityTransitionResult(
        requestedIdentity: identity,
        liveIdentity: snapshot.liveIdentity,
        retainedIdentity: succeeded ? nil : snapshot.liveIdentity,
        failure: succeeded ? nil : self.compatibilityTransitionFailure(from: snapshot)
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  public func suspendController(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      let result = await deviceManager.suspendController(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID),
        runtimeIdentifier: runtimeIdentifier
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  public func resumeController(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      let result = await deviceManager.resumeController(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID),
        runtimeIdentifier: runtimeIdentifier
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  public func disconnectWirelessController(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      let result = await deviceManager.disconnectWirelessController(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID),
        runtimeIdentifier: runtimeIdentifier
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  private func compatibilityTransitionFailure(
    from snapshot: UserSpaceStatusSnapshot
  ) -> CompatibilityIdentityTransitionFailure {
    let phase =
      snapshot.retrySnapshot.map { retry in
        CompatibilityIdentityTransitionPhase(rawValue: retry.phase.rawValue) ?? .activation
      } ?? .activation
    let cause: CompatibilityIdentityTransitionCause
    if isCompatibilityServerStopped() {
      cause = .serverStopped
    } else {
      switch phase {
      case .feedbackQuiescence, .candidateClose, .zeroDeviceInterval: cause = .timedOut
      case .validation, .stage, .activation, .rollbackStage, .rollbackActivation:
        cause = .unavailable
      }
    }
    return CompatibilityIdentityTransitionFailure(phase: phase, cause: cause)
  }

  public func getCompatibilityIdentity(reply: @escaping (String) -> Void) {
    reply(userSpaceStatusSnapshot().requestedIdentity.rawValue)
  }

  public func getVirtualDeviceDiagnostics(reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    Task {
      let userSnapshot = userSpaceStatusSnapshot()
      let devices = await VirtualDeviceDiagnostics.enumerateHIDGamepads()
      let payload = ApplicationServiceVirtualDeviceDiagnosticsPayload(
        userSpaceVirtualDeviceEnabled: userSnapshot.enabled,
        userSpaceVirtualDeviceStatus: userSnapshot.status,
        hidGamepads: devices
      )
      do { callback.call(try JSONEncoder().encode(payload)) } catch {
        print("[ApplicationServiceServer] getVirtualDeviceDiagnostics encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func runVirtualDeviceSelfTest(seconds: Int, reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    let secs = max(1, min(30, seconds))
    Task {
      let payload = await runVirtualDeviceSelfTestInternal(seconds: secs)
      do { callback.call(try JSONEncoder().encode(payload)) } catch {
        print("[ApplicationServiceServer] runVirtualDeviceSelfTest encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func resetSettings(reply: @escaping (Bool) -> Void) {
    let callback = SendableReply(call: reply)
    Task { [weak self] in
      guard let self else { return }
      callback.call(await self.resetSettingsAsync())
    }
  }

  private func setCompatibilityIdentityAsync(_ id: CompatibilityIdentity) async -> Bool {
    await compatibilityTransitionCoordinator.enqueue { [weak self] in
      guard let self else { return false }
      return await self.performCompatibilityIdentityTransition(to: id)
    }
  }

  private func resetSettingsAsync() async -> Bool {
    await compatibilityTransitionCoordinator.enqueue { [weak self] in
      guard let self else { return false }
      return await self.performResetSettingsAsync()
    }
  }

  private func performResetSettingsAsync() async -> Bool {
    await performCompatibilityIdentityTransition(
      to: .automatic,
      force: true,
      removePersistedIdentityOnCommit: true
    )
  }

  func getRemappingSnapshot(
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.snapshot()) }
  }

  func deleteDamagedRemappingProfile(
    _ arguments: ApplicationServiceRemappingProfileIssueArguments,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.deleteDamagedProfile(issueID: arguments.issueID)) }
  }

  func resetRemappingProfileLibrary(
    _ arguments: ApplicationServiceRemappingProfileIssueArguments,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.resetDamagedLibrary(issueID: arguments.issueID)) }
  }

  func remappingMotionCalibration(
    _ arguments: ApplicationServiceMotionCalibrationArguments,
    reply: @escaping (RemappingRequestResult<RemappingMotionCalibrationStatus>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.motionCalibration(arguments)) }
  }

  func pairRemappingJoyCons(
    _ arguments: ApplicationServiceJoyConPairArguments,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.pairJoyCons(arguments)) }
  }

  func unpairRemappingJoyCons(
    _ arguments: ApplicationServiceJoyConUnpairArguments,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.unpairJoyCons(arguments)) }
  }

  func getRemappingProfile(
    id: UUID,
    reply: @escaping (RemappingRequestResult<RemappingProfile>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.profile(id: id)) }
  }

  func createRemappingProfile(
    _ profile: RemappingProfile,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.create(profile)) }
  }

  func updateRemappingProfile(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      callback.call(await remappingRequests.update(profile, expectedCurrent: expectedCurrent))
    }
  }

  func importRemappingProfile(
    _ profile: RemappingProfile,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.importProfile(profile)) }
  }

  func deleteRemappingProfile(
    id: UUID,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.delete(id: id)) }
  }

  func activateRemappingProfile(
    id: UUID,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.activate(id: id)) }
  }

  func deactivateRemappingProfile(
    vendorID: UInt16,
    productID: UInt16,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      callback.call(await remappingRequests.deactivate(vendorID: vendorID, productID: productID))
    }
  }

  func deactivateRemappingProfile(
    id: UUID,
    reply: @escaping (RemappingRequestResult<ApplicationServiceRemappingSnapshotPayload>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.deactivate(profileID: id)) }
  }

  func getRemappingPostEventAccess(
    reply: @escaping (RemappingRequestResult<RemappingPostEventAccessState>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.currentPostEventAccess()) }
  }

  func requestRemappingPostEventAccess(
    reply: @escaping (RemappingRequestResult<RemappingPostEventAccessState>) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task { callback.call(await remappingRequests.requestPostEventAccess()) }
  }
}
