import Foundation

extension DeviceManager {

  func restoreAfterFailedWirelessDisconnect(
    identifier: DeviceIdentifier,
    pipeline: DevicePipeline,
    priorState: ControllerSessionState,
    failure: WirelessControllerDisconnectFailure,
    stage: WirelessControllerDisconnectStage,
    code: Int32? = nil,
    detail: String,
    restoreHIDClaim: Bool
  ) async -> WirelessControllerDisconnectResult {
    let claimResult =
      restoreHIDClaim
      ? await hidManager.reacquireInputClaim(locationID: identifier.locationID ?? 0) : .reacquired
    guard claimResult == .reacquired else {
      return WirelessControllerDisconnectResult(
        state: .suspended,
        failure: failure,
        failedStage: .restoreHIDClaim,
        systemCode: code,
        detail: "\(detail) HID recovery failed: \(Self.hidClaimFailureDescription(claimResult)).",
        recovery: "Reconnect the controller to restore input."
      )
    }
    if priorState == .active, !(await pipeline.resumeControllerSession()) {
      return WirelessControllerDisconnectResult(
        state: .suspended,
        failure: failure,
        failedStage: .restoreControllerSession,
        systemCode: code,
        detail: "\(detail) The HID claim was restored, but the controller session did not resume.",
        recovery: "Reconnect the controller to restore OpenJoystickDriver output."
      )
    }
    notifyControllerInventoryChanged()
    return WirelessControllerDisconnectResult(
      state: priorState,
      failure: failure,
      failedStage: stage,
      systemCode: code,
      detail: detail,
      recovery: "The previous controller session was restored; retry or reconnect the controller."
    )
  }

  static func hidClaimFailureDescription(_ result: PhysicalHIDClaimResult) -> String {
    switch result {
    case .released: "released"
    case .reacquired: "reacquired"
    case .unavailable: "the HID claim was unavailable"
    case .failed(.ioReturn(let code)): "IOKit code \(code)"
    case .failed(.coreHID(let detail)): "CoreHID error \(detail)"
    }
  }

  static func bluetoothAddress(from serialNumber: String?) -> String? {
    guard let serialNumber else { return nil }
    let hexadecimal = serialNumber.filter(\.isHexDigit)
    guard hexadecimal.count == 12,
      serialNumber.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" })
    else { return nil }
    return stride(from: 0, to: hexadecimal.count, by: 2).map { offset in
      let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
      let end = hexadecimal.index(start, offsetBy: 2)
      return hexadecimal[start..<end].uppercased()
    }.joined(separator: ":")
  }

  func notifyControllerInventoryChanged() {
    NotificationCenter.default.post(name: .ojdControllerInventoryDidChange, object: nil)
  }

  /// Stop all detection and pipelines.
  public func stop() async {
    for task in hidPeriodicOutputTasks.values { task.cancel() }
    hidPeriodicOutputTasks = [:]
    for task in rumbleStopTasks.values { task.cancel() }
    rumbleStopTasks = [:]
    rumbleStopTokens.removeAll()
    for task in detectionTasks { task.cancel() }
    detectionTasks = []
    hidDetectionTask?.cancel()
    hidDetectionTask = nil
    for task in hidInitializationTasks.values { task.cancel() }
    hidInitializationTasks = [:]
    permissionWatchTask?.cancel()
    permissionWatchTask = nil
    for (identifier, pipeline) in pipelines {
      await neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)
      if let locationID = identifier.locationID {
        await sendHIDShutdownFeatureReportsIfNeeded(pipeline: pipeline, locationID: locationID)
      }
      await pipeline.stop()
    }
    pipelines = [:]
    hidOutputQueues = [:]
    physicalOutputOwnership.removeAll()
    lastPhysicalHIDOutputNanoseconds = [:]
    await permissionManager.stopPolling()
    print("[DeviceManager] Stopped")
  }

  /// Enables or suppresses application-facing compatibility output for every active pipeline.
  public func setExternalOutputAllowed(_ allowed: Bool) async {
    guard externalOutputAllowed != allowed else { return }
    externalOutputAllowed = allowed
    for pipeline in pipelines.values { await pipeline.setExternalOutputAllowed(allowed) }
  }
}
