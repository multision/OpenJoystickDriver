import Foundation

func controllerDisplayName(productName: String?, vendorID: UInt16, productID: UInt16) -> String {
  if let productName {
    let value = productName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty { return value }
  }
  return String(format: "Controller %04x:%04x", vendorID, productID)
}

let usbDetectionPollNanoseconds: UInt64 = 500_000_000
let devicePermissionWatchNanoseconds: UInt64 = 1_000_000_000
let deviceDiscoveryNanosecondsPerMillisecond: UInt64 = 1_000_000
let maxRumbleDurationMs = 5_000
let usbVendorSpecificClass: UInt8 = 0xFF

struct RumbleStopTokenRegistry {
  private var generations: [DeviceIdentifier: UInt64] = [:]

  mutating func replace(for identifier: DeviceIdentifier) -> UInt64 {
    let generation = (generations[identifier] ?? 0) &+ 1
    generations[identifier] = generation
    return generation
  }

  func isCurrent(_ generation: UInt64, for identifier: DeviceIdentifier) -> Bool {
    generations[identifier] == generation
  }

  mutating func remove(_ identifier: DeviceIdentifier) {
    generations.removeValue(forKey: identifier)
  }

  mutating func removeAll() { generations.removeAll() }
}

actor PhysicalHIDOutputSerialQueue {
  private var tail: Task<Bool, Never>?
  private var generation: UInt64 = 0

  func perform(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
    let previous = tail
    generation &+= 1
    let currentGeneration = generation
    let task = Task {
      if let previous { _ = await previous.value }
      guard !Task.isCancelled else { return false }
      return await operation()
    }
    tail = task
    let result = await task.value
    if generation == currentGeneration { tail = nil }
    return result
  }
}

/// Manages device detection and pipeline lifecycle for all
/// connected controllers.
/// Uses dual detection: an Apple USB transport provider for raw interfaces and
/// the OS-generation HID wrapper for HID-class controllers.
public actor DeviceManager {
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

  let parserRegistry: ParserRegistry
  let dispatcher: any OutputDispatcher
  let permissionManager: PermissionManager
  let hidManager: HIDManager
  let usbTransportProvider: (any USBTransportProvider)?
  let wirelessControllerDisconnector: (any WirelessControllerDisconnecting)?
  var pipelines: [DeviceIdentifier: DevicePipeline] = [:]
  var deviceInfos: [DeviceIdentifier: DeviceInfo] = [:]
  var detectionTasks: [Task<Void, Never>] = []
  var hidDetectionTask: Task<Void, Never>?
  var hidPeriodicOutputTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
  var hidOutputQueues: [DeviceIdentifier: PhysicalHIDOutputSerialQueue] = [:]
  var permissionWatchTask: Task<Void, Never>?
  var externalOutputAllowed = true
  var lastPhysicalHIDOutputNanoseconds: [DeviceIdentifier: UInt64] = [:]
  var rumbleStopTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
  var rumbleStopTokens = RumbleStopTokenRegistry()
  var physicalOutputOwnership = PhysicalOutputOwnership()

  /// Creates a manager that sends all output to `dispatcher`.
  ///
  /// - Parameters:
  ///   - dispatcher: Output dispatcher for sending HID reports.
  ///   - virtualProfile: Virtual device profile for self-exclusion filtering.
  ///   - usbTransportProvider: Native raw-USB transport provider, or nil to disable raw USB
  ///     discovery.
  public init(
    dispatcher: any OutputDispatcher,
    virtualProfile: VirtualDeviceProfile = .default,
    usbTransportProvider: (any USBTransportProvider)? = nil,
    wirelessControllerDisconnector: (any WirelessControllerDisconnecting)? = nil
  ) {
    self.dispatcher = dispatcher
    self.usbTransportProvider = usbTransportProvider
    self.wirelessControllerDisconnector = wirelessControllerDisconnector
    let registry = ParserRegistry()
    self.parserRegistry = registry
    self.permissionManager = PermissionManager()
    self.hidManager = HIDManager(
      virtualProfile: virtualProfile,
      additionalProfileIdentifiers: registry.hidProfileIdentifiers()
    )
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
    if await pipeline.controllerSessionState() == .active {
      guard await pipeline.suspendControllerSession() else {
        return WirelessControllerDisconnectResult(state: .active, failure: .notFound)
      }
    }

    switch await wirelessControllerDisconnector.disconnect(
      address: address,
      timeoutNanoseconds: timeoutNanoseconds
    ) {
    case .disconnected: return WirelessControllerDisconnectResult(state: .suspended)
    case .failed:
      return WirelessControllerDisconnectResult(state: .suspended, failure: .disconnectFailed)
    case .timedOut: return WirelessControllerDisconnectResult(state: .suspended, failure: .timedOut)
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
