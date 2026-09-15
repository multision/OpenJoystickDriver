import Foundation

extension DeviceManager {
  enum DiscoverySource {
    case hid
    case rawUSB(route: USBTransportRoute)

    var requiresInputMonitoring: Bool {
      if case .hid = self { return true }
      return false
    }

    var applicationServiceValue: ApplicationServiceDeviceDiscoverySource {
      switch self {
      case .hid: .hid
      case .rawUSB: .rawUSB
      }
    }

    var ownershipObservation: ControllerOwnershipObservation {
      switch self {
      case .hid: .nativeHIDVisible
      case .rawUSB(.ioUSBHost): .exclusiveRawUSB
      case .rawUSB(.usbDriverKit): .driverKitOwnedUSB
      }
    }
  }

  struct DeviceInfo {
    let name: String
    let connection: String
    let serialNumber: String?
    let discoverySource: DiscoverySource
    var hidInputOwnership: HIDInputOwnership = .unknown

    var ownershipObservation: ControllerOwnershipObservation {
      if case .hid = discoverySource, hidInputOwnership == .exclusive { return .exclusiveHID }
      return discoverySource.ownershipObservation
    }
  }

  /// Start device detection and input processing.
  public func start() async {
    let state = await permissionManager.checkAccess().inputMonitoring
    switch state {
    case .unknown, .denied:
      if state == .denied {
        print("[DeviceManager] Input Monitoring denied" + " - running in detect-only mode")
        print(
          "[DeviceManager] Open System Settings" + " > Privacy > Input Monitoring"
            + " to grant access"
        )
      } else {
        print("[DeviceManager] Input Monitoring not yet granted" + " - running in detect-only mode")
        print(
          "[DeviceManager] Use the app's Request Access action" + " to show the native macOS prompt"
        )
      }
    case .granted: print("[DeviceManager] Input Monitoring granted")
    }

    if usbTransportProvider != nil {
      detectionTasks = [Task { await self.runUSBDetection() }]
    } else {
      detectionTasks = []
    }
    await ensureHIDDetectionState(for: state)
    permissionWatchTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let currentState = await self.permissionManager.checkAccess().inputMonitoring
        await self.ensureHIDDetectionState(for: currentState)
        try? await Task.sleep(nanoseconds: devicePermissionWatchNanoseconds)
      }
    }

    print("[DeviceManager] Started" + " - dual detection active")
  }

  /// Returns the latest input snapshot for a device matched by vendor and product ID.
  ///
  /// Returns nil if no pipeline is active for the device.
  public func inputState(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil
  ) async -> DeviceInputState? {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier)
    else { return nil }
    return await pipelines[key]?.inputState()
  }

  /// Returns the ownership evidence for the exact connected device identifier.
  ///
  /// Missing identifiers intentionally fail closed to unknown ownership.
  public func ownershipObservation(
    for identifier: DeviceIdentifier
  ) -> ControllerOwnershipObservation { deviceInfos[identifier]?.ownershipObservation ?? .unknown }

  /// Returns recent raw USB packets for a device matched by vendor and product ID.
  ///
  /// Returns an empty array if no pipeline is active for the device.
  public func packetLog(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil
  ) async -> [PacketLogEntry] {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier)
    else { return [] }
    return await pipelines[key]?.getPacketLog() ?? []
  }

  /// Sends a short physical-controller rumble command for a matched USB device.
  /// Used by the application service to report its live device list.
  public func connectedDeviceDescriptions() async -> [ApplicationServiceDeviceDescription] {
    var descriptions: [ApplicationServiceDeviceDescription] = []
    for id in pipelines.keys {
      let info = deviceInfos[id]
      let profile = parserRegistry.runtimeProfile(for: id)
      let ownership = info?.ownershipObservation ?? .unknown
      let pipeline = pipelines[id]
      descriptions.append(
        ApplicationServiceDeviceDescription(
          name: info?.name ?? "Controller",
          vendorID: id.vendorID,
          productID: id.productID,
          parser: profile.parserName,
          connection: info?.connection ?? "USB",
          discoverySource: info?.discoverySource.applicationServiceValue ?? .unknown,
          physicalOwnership: ownership,
          hidInputOwnership: info?.hidInputOwnership ?? .unknown,
          duplicateExposureRisk: ControllerExposureDecision.decide(
            ownership: ownership,
            intent: .outputDisabled
          ).duplicateRisk,
          serialNumber: info?.serialNumber,
          protocolVariant: profile.protocolVariant,
          quirks: profile.quirks,
          inputEndpoint: profile.transportProfile.inputEndpoint,
          outputEndpoint: profile.transportProfile.outputEndpoint,
          needsSetConfiguration: profile.transportProfile.needsSetConfiguration,
          postHandshakeSettleMs: Int(
            profile.transportProfile.postHandshakeSettleNanoseconds
              / deviceDiscoveryNanosecondsPerMillisecond
          ),
          preferredBackends: profile.preferredBackends.map(\.rawValue),
          physicalOutputCapabilities: await pipeline?.physicalOutputCapabilities() ?? .none,
          physicalInputCapabilities: await pipeline?.physicalInputCapabilities() ?? .none,
          battery: await pipeline?.batteryTelemetry(),
          sessionState: await pipeline?.controllerSessionState() ?? .active,
          startupCommandStatus: await pipeline?.startupCommandStatus(),
          inputHealth: await pipeline?.inputHealth() ?? ControllerInputHealth(state: .healthy),
          runtimeIdentifier: id.runtimeIdentifier
        )
      )
    }
    return descriptions
  }

  /// Returns live identifiers for connected controller pipelines.
  public func connectedDeviceIdentifiers() -> [DeviceIdentifier] { Array(pipelines.keys) }

  /// Returns controllers whose sessions can currently publish compatibility output.
  public func activeDeviceIdentifiers() async -> [DeviceIdentifier] {
    var identifiers: [DeviceIdentifier] = []
    for (identifier, pipeline) in pipelines where await pipeline.controllerSessionState() == .active
    { identifiers.append(identifier) }
    return identifiers
  }

  public func suspendController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?
  ) async -> ControllerSuspendResult {
    let model = DeviceIdentifier(vendorID: vendorID, productID: productID)
    guard
      let identifier = connectedIdentifier(matching: model, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[identifier]
    else { return ControllerSuspendResult(state: .active, failure: .notFound) }
    guard await pipeline.controllerSessionState() == .active else {
      return ControllerSuspendResult(state: .suspended, failure: .alreadySuspended)
    }
    await neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)
    guard await pipeline.suspendControllerSession() else {
      return ControllerSuspendResult(state: .active, failure: .notFound)
    }
    notifyControllerInventoryChanged()
    return ControllerSuspendResult(state: .suspended)
  }

  public func resumeController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?
  ) async -> ControllerResumeResult {
    let model = DeviceIdentifier(vendorID: vendorID, productID: productID)
    guard
      let identifier = connectedIdentifier(matching: model, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[identifier]
    else { return ControllerResumeResult(state: .suspended, failure: .notFound) }
    guard await pipeline.controllerSessionState() == .suspended else {
      return ControllerResumeResult(state: .active, failure: .alreadyActive)
    }
    guard await pipeline.restartUSBStartupOutputForResume() else {
      return ControllerResumeResult(state: .suspended, failure: .notFound)
    }
    if let locationID = identifier.locationID,
      await pipeline.requiresSuccessfulHIDStartupOutput(
        transport: deviceInfos[identifier]?.connection
      )
    {
      guard
        await sendHIDStartupOutputReportsIfNeeded(
          pipeline: pipeline,
          locationID: locationID,
          transport: deviceInfos[identifier]?.connection
        )
      else { return ControllerResumeResult(state: .suspended, failure: .notFound) }
    }
    guard await pipeline.resumeControllerSession() else {
      return ControllerResumeResult(state: .suspended, failure: .notFound)
    }
    notifyControllerInventoryChanged()
    return ControllerResumeResult(state: .active)
  }

  public func disconnectWirelessController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?,
    timeoutNanoseconds: UInt64 = 3_000_000_000
  ) async -> WirelessControllerDisconnectResult {
    let model = DeviceIdentifier(vendorID: vendorID, productID: productID)
    guard
      let identifier = connectedIdentifier(matching: model, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[identifier], let info = deviceInfos[identifier]
    else { return WirelessControllerDisconnectResult(state: .active, failure: .notFound) }
    guard info.connection.caseInsensitiveCompare("Bluetooth") == .orderedSame else {
      return WirelessControllerDisconnectResult(
        state: await pipeline.controllerSessionState(),
        failure: .notBluetooth
      )
    }
    guard let address = Self.bluetoothAddress(from: info.serialNumber) else {
      return WirelessControllerDisconnectResult(
        state: await pipeline.controllerSessionState(),
        failure: .missingAddress
      )
    }
    guard let wirelessControllerDisconnector else {
      return WirelessControllerDisconnectResult(
        state: await pipeline.controllerSessionState(),
        failure: .disconnectFailed
      )
    }

    await neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)
    let priorState = await pipeline.controllerSessionState()
    if await pipeline.controllerSessionState() == .active {
      guard await pipeline.suspendControllerSession() else {
        return WirelessControllerDisconnectResult(state: .active, failure: .notFound)
      }
    }

    let claimResult = await hidManager.releaseInputClaim(locationID: identifier.locationID ?? 0)
    if case .failed = claimResult {
      if priorState == .active { _ = await pipeline.resumeControllerSession() }
      notifyControllerInventoryChanged()
      return WirelessControllerDisconnectResult(
        state: await pipeline.controllerSessionState(),
        failure: .disconnectFailed,
        failedStage: .releaseHIDClaim,
        detail: Self.hidClaimFailureDescription(claimResult),
        recovery: "Reconnect the controller if input does not resume."
      )
    }
    let claimWasReleased = claimResult == .released

    switch await wirelessControllerDisconnector.disconnect(
      address: address,
      timeoutNanoseconds: timeoutNanoseconds
    ) {
    case .disconnected:
      await handleHIDDeviceDisconnected(
        vendorID: identifier.vendorID,
        productID: identifier.productID,
        locationID: identifier.locationID ?? 0
      )
      return WirelessControllerDisconnectResult(state: .suspended)
    case .failed(let code):
      return await restoreAfterFailedWirelessDisconnect(
        identifier: identifier,
        pipeline: pipeline,
        priorState: priorState,
        failure: .disconnectFailed,
        stage: .closeBluetoothConnection,
        code: code,
        detail: "IOBluetoothDevice.closeConnection failed with I/O code \(code).",
        restoreHIDClaim: claimWasReleased
      )
    case .stillConnected:
      return await restoreAfterFailedWirelessDisconnect(
        identifier: identifier,
        pipeline: pipeline,
        priorState: priorState,
        failure: .disconnectFailed,
        stage: .confirmBluetoothDisconnection,
        detail: "Bluetooth reported that the controller remained connected after closeConnection.",
        restoreHIDClaim: claimWasReleased
      )
    case .timedOut:
      return await restoreAfterFailedWirelessDisconnect(
        identifier: identifier,
        pipeline: pipeline,
        priorState: priorState,
        failure: .timedOut,
        stage: .confirmBluetoothDisconnection,
        detail: "Bluetooth disconnection was not confirmed before the timeout.",
        restoreHIDClaim: claimWasReleased
      )
    }
  }
}
