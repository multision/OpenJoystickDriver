import Foundation

let gipReadPacketLength = 64
let gipReadTimeoutMs: UInt32 = 100
struct USBPipelineRecoveryPolicy: Sendable {
  static let standard = Self(
    openRetryDelays: [1_000_000_000, 2_000_000_000, 4_000_000_000],
    reconnectBaseDelayNanoseconds: 250_000_000,
    reconnectMaximumDelayNanoseconds: 4_000_000_000,
    accessContentionDelayNanoseconds: 30_000_000_000
  )

  let openRetryDelays: [UInt64]
  let reconnectBaseDelayNanoseconds: UInt64
  let reconnectMaximumDelayNanoseconds: UInt64
  let accessContentionDelayNanoseconds: UInt64

  func reconnectDelayNanoseconds(after attempt: Int) -> UInt64 {
    let exponent = min(max(0, attempt), 4)
    return min(reconnectMaximumDelayNanoseconds, reconnectBaseDelayNanoseconds << exponent)
  }
}
/// Target input loop cadence in nanoseconds.
///
/// Defensive pacing prevents a transport that completes timeouts immediately from
/// creating a hot loop that can trigger launchd "inefficient" kills.
let usbIdleLoopCadenceNs: UInt64 = UInt64(gipReadTimeoutMs) * 1_000_000
let usbIOErrorReconnectThreshold = 10
let usbIOErrorBackoffBaseNs: UInt64 = 250_000_000  // 250ms
let usbIOErrorBackoffMaxNs: UInt64 = 2_000_000_000  // 2s
let usbIOErrorLogIntervalNs: UInt64 = 5_000_000_000  // 5s
private let defaultIdleMonitorIntervalNanoseconds: UInt64 = 1_000_000_000

/// Manages full lifecycle of single connected controller.
/// Each controller gets its own DevicePipeline actor - one
/// failure never affects others.
actor DevicePipeline {
  enum Transport {
    /// Vendor-specific interface owned by the selected Apple USB transport backend.
    case usb(device: USBTransportDevice)
    /// Class 0x03 via IOKit
    case hid(locationID: UInt32)
  }

  let identifier: DeviceIdentifier
  let transport: Transport
  let parser: any InputParser
  let dispatcher: any OutputDispatcher
  let usbTransportProvider: (any USBTransportProvider)?
  let transportProfile: DeviceTransportProfile
  let usbRecoveryPolicy: USBPipelineRecoveryPolicy
  let idleMonitorIntervalNanoseconds: UInt64
  var isActive = false
  var usbHandle: (any USBTransportSession)?
  var currentInputState: DeviceInputState
  var outputState: DeviceInputState
  let maxPacketLogEntries = 200
  private var currentBatteryTelemetry: ControllerBatteryTelemetry?
  private let packetLog: PacketLogBuffer
  var idleMonitorTask: Task<Void, Never>?
  private var runTask: Task<Void, Never>?
  var externalOutputAllowed: Bool
  var waitingForExternalNeutral = false
  var consecutiveUSBIOErrors: Int = 0
  var lastUSBIOErrorLogNs: UInt64 = 0
  var inputConnectionActive: Bool
  var sessionState: ControllerSessionState = .active
  var lastLiveInputReportNanoseconds: UInt64?
  var inputHealthMonitoringStartedNanoseconds: UInt64?
  var lastObservedInputReportNanoseconds: UInt64?
  var awaitingNeutralAfterLivenessLoss = false
  var inputHealthRecoveryCount = 0
  var startupOutputStatus: String?

  init(
    identifier: DeviceIdentifier,
    transport: Transport,
    parser: sending any InputParser,
    dispatcher: any OutputDispatcher,
    usbTransportProvider: (any USBTransportProvider)? = nil,
    transportProfile: DeviceTransportProfile = .gipDefault,
    usbRecoveryPolicy: USBPipelineRecoveryPolicy = .standard,
    externalOutputAllowed: Bool = true,
    idleTimeoutNanoseconds _: UInt64 = 30_000_000_000,
    idleMonitorIntervalNanoseconds: UInt64 = defaultIdleMonitorIntervalNanoseconds
  ) {
    self.identifier = identifier
    self.transport = transport
    self.parser = parser
    self.dispatcher = dispatcher
    self.usbTransportProvider = usbTransportProvider
    self.transportProfile = transportProfile
    self.usbRecoveryPolicy = usbRecoveryPolicy
    self.idleMonitorIntervalNanoseconds = idleMonitorIntervalNanoseconds
    self.externalOutputAllowed = externalOutputAllowed
    let inputLifecycle = self.parser as? any ControllerInputConnectionLifecycle
    self.inputConnectionActive = !(inputLifecycle?.requiresInputConnectionBeforeOutput ?? false)
    let initialState = DeviceInputState(
      vendorID: identifier.vendorID,
      productID: identifier.productID
    )
    self.currentInputState = initialState
    self.outputState = initialState
    self.packetLog = PacketLogBuffer(maxEntries: maxPacketLogEntries)
  }

  /// Start pipeline: open device, handshake, begin input loop.
  func start() {
    guard !isActive else { return }
    isActive = true
    if parser is any ControllerInputReportLivenessProvider {
      inputHealthMonitoringStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
    }
    startIdleMonitor()

    switch transport {
    case .usb(let device): runTask = Task { await self.startUSBPipeline(device: device) }
    case .hid:
      // HID pipeline: data fed via feedHIDData(); no separate startup loop needed
      print("[DevicePipeline] HID pipeline ready" + " for \(identifier)")
    }
  }

  /// Stop pipeline and clean up resources.
  func stop() async {
    isActive = false
    let task = runTask
    runTask = nil
    task?.cancel()
    // An adapter may be inside a non-cooperative platform open call before a session exists. The
    // inactive guard closes any handle returned later; only an established session is awaited here.
    let shouldAwaitRunTask = usbHandle != nil
    (parser as? any HIDStartupRecoveryProvider)?.expireHIDStartupRequests()
    let idleTask = idleMonitorTask
    idleMonitorTask = nil
    idleTask?.cancel()
    if case .usb = transport { await reportUSBInputOwnership(.unknown) }
    let handle = usbHandle
    usbHandle = nil
    await neutralizeOutput()
    if let listener = dispatcher as? any ControllerLifecycleListener {
      await listener.controllerDidStop(identifier)
    }
    await handle?.close()
    (parser as? any InputParserSessionLifecycle)?.resetProtocolState()
    if shouldAwaitRunTask { await task?.value }
    await idleTask?.value
    print("[DevicePipeline] Stopped: \(identifier)")
  }

  /// Feed HID input report data (called by DeviceManager for class 0x03 devices).
  @discardableResult
  func feedHIDData(_ data: Data) async -> [PhysicalHIDOutputReport] {
    guard isActive else { return [] }
    appendToPacketLog(bytes: Array(data), direction: "rx")
    do {
      let receivedAt = DispatchTime.now().uptimeNanoseconds
      let events = try parser.parse(data: data, receivedAtNanoseconds: receivedAt)
      snapshotBatteryTelemetry()
      let featureReports = await handleInputConnectionStateChangeIfNeeded()
      guard inputConnectionActive else { return featureReports }
      await handleParsedEvents(events, now: receivedAt)
      return featureReports
    } catch {
      print("[DevicePipeline] Parse error" + " for \(identifier): \(error)")
      return []
    }
  }

  func consumeHIDFeatureReport(
    _ data: Data,
    request: PhysicalHIDFeatureReadRequest,
    transport: String?
  ) -> Bool {
    guard isActive, let consumer = parser as? any HIDFeatureReportConsumer else { return false }
    return consumer.consumeHIDFeatureReport(data, request: request, transport: transport)
  }

  func hidStartupOutputPlan(transport: String?) -> ([PhysicalHIDOutputReport], UInt64) {
    guard isActive, let provider = parser as? any HIDStartupOutputReportProvider else {
      return ([], 0)
    }
    return (
      provider.hidStartupReports(transport: transport),
      provider.hidStartupReportIntervalNanoseconds(transport: transport)
    )
  }

  func pendingHIDStartupReports() -> [PhysicalHIDOutputReport] {
    guard isActive else { return [] }
    return (parser as? any HIDStartupRecoveryProvider)?.pendingHIDStartupReports() ?? []
  }

  func hidStartupOutputPrecedesFeatureReads() -> Bool {
    (parser as? any HIDStartupOutputReportProvider)?.hidStartupOutputPrecedesFeatureReads == true
  }

  func requiresSuccessfulHIDStartupOutput(transport: String?) -> Bool {
    (parser as? any HIDStartupOutputReportProvider)?.requiresSuccessfulHIDStartupOutput(
      transport: transport
    ) ?? false
  }

  func hidStartupFeatureReadPlan(
    transport: String?
  ) -> (requests: [PhysicalHIDFeatureReadRequest], validatesReplies: Bool) {
    guard let provider = parser as? any HIDStartupFeatureReadRequestProvider else {
      return ([], false)
    }
    return (
      provider.hidStartupFeatureReadRequests(transport: transport),
      parser is any HIDFeatureReportConsumer
    )
  }

  func hidStartupFeatureReports(transport: String?) -> [PhysicalHIDOutputReport] {
    (parser as? any HIDStartupFeatureReportProvider)?.hidStartupFeatureReports(transport: transport)
      ?? []
  }

  func hidInputConnectionStatusRequestReport() -> PhysicalHIDOutputReport? {
    (parser as? any HIDInputConnectionStatusRequester)?.inputConnectionStatusRequestReport()
  }

  func supportsHIDStartupRecovery() -> Bool { parser is any HIDStartupRecoveryProvider }

  func acceptsHIDFeatureReportReplies() -> Bool { parser is any HIDFeatureReportConsumer }

  func expireHIDStartupRequests() {
    (parser as? any HIDStartupRecoveryProvider)?.expireHIDStartupRequests()
  }

  /// Feed one descriptor-decoded value to the Generic HID fallback.
  func feedHIDElementValue(_ value: HIDElementValue) async {
    guard isActive, inputConnectionActive, let elementParser = parser as? any HIDElementValueParser
    else { return }
    let events = elementParser.parse(elementValue: value)
    await handleParsedEvents(events, now: DispatchTime.now().uptimeNanoseconds)
  }

  func requiresInputConnectionBeforeOutput() -> Bool {
    (parser as? any ControllerInputConnectionLifecycle)?.requiresInputConnectionBeforeOutput
      ?? false
  }

  func hidShutdownFeatureReports() -> [PhysicalHIDOutputReport] {
    if requiresInputConnectionBeforeOutput(), !inputConnectionActive { return [] }
    return (parser as? any HIDShutdownFeatureReportProvider)?.hidShutdownFeatureReports() ?? []
  }

  func physicalInputCapabilities() -> PhysicalControllerInputCapabilities {
    parser.physicalInputCapabilities
  }

  func physicalOutputCapabilities() -> PhysicalControllerOutputCapabilities {
    ControllerProfileCapabilities.physicalOutputCapabilities(for: parser)
  }

  func supportsPhysicalRumble() -> Bool { physicalOutputCapabilities().supportsRumble }

  // MARK: - Input state and packet log

  func inputState() -> DeviceInputState { currentInputState }
  func controllerSessionState() -> ControllerSessionState { sessionState }
  func batteryTelemetry() -> ControllerBatteryTelemetry? { currentBatteryTelemetry }
  func startupCommandStatus() -> String? { startupOutputStatus }
  func getPacketLog() -> [PacketLogEntry] { packetLog.entries() }

  func inputHealth() -> ControllerInputHealth {
    let now = DispatchTime.now().uptimeNanoseconds
    let reference = lastLiveInputReportNanoseconds ?? inputHealthMonitoringStartedNanoseconds
    let age = reference.map { now &- $0 }
    let observationAge = lastObservedInputReportNanoseconds.map { now &- $0 }
    let state: ControllerInputHealthState
    if awaitingNeutralAfterLivenessLoss {
      state = .waitingForNeutral
    } else if let liveness = parser as? any ControllerInputReportLivenessProvider, let age,
      age >= liveness.inputReportLivenessTimeoutNanoseconds
    {
      state = .stale
    } else {
      state = .healthy
    }
    let failureReason: ControllerInputHealthFailureReason?
    if state == .healthy {
      failureReason = nil
    } else if let liveness = parser as? any ControllerInputReportLivenessProvider,
      let observationAge, observationAge < liveness.inputReportLivenessTimeoutNanoseconds
    {
      failureReason = .freshnessNotAdvancing
    } else {
      failureReason = .missingReports
    }
    let reportFormat = (parser as? any ControllerInputReportFormatProvider)?.latestInputReportFormat
    return ControllerInputHealth(
      state: state,
      reportFormat: reportFormat,
      lastReportAgeNanoseconds: age,
      failureReason: failureReason,
      recoveryCount: inputHealthRecoveryCount
    )
  }

  func setExternalOutputAllowed(_ allowed: Bool) async {
    let changed = externalOutputAllowed != allowed
    guard changed else { return }
    externalOutputAllowed = allowed

    if !allowed {
      waitingForExternalNeutral = false
      let neutralizingEvents = outputState.neutralizingEvents()
      if !neutralizingEvents.isEmpty {
        await dispatcher.dispatch(events: neutralizingEvents, from: identifier)
        updateOutputState(from: neutralizingEvents)
      }
      print("[DevicePipeline] Output gated by foreground consumer: \(identifier)")
      return
    }

    let shouldWaitForNeutral = !currentInputState.isEffectivelyNeutral
    waitingForExternalNeutral = shouldWaitForNeutral

    if shouldWaitForNeutral {
      print(
        "[DevicePipeline] Foreground gate lifted; suppressing hidden "
          + "non-neutral state: \(identifier)"
      )
    } else {
      print("[DevicePipeline] Output ungated by foreground consumer: \(identifier)")
    }
  }

  func suspendControllerSession() async -> Bool {
    guard isActive, sessionState == .active else { return false }
    sessionState = .suspended
    lastLiveInputReportNanoseconds = nil
    inputHealthMonitoringStartedNanoseconds = nil
    awaitingNeutralAfterLivenessLoss = false
    waitingForExternalNeutral = false
    await neutralizeOutput()
    resetObservedInputState()
    if let listener = dispatcher as? any ControllerLifecycleListener {
      await listener.controllerDidStop(identifier)
    }
    return true
  }

  func resumeControllerSession() async -> Bool {
    guard isActive, sessionState == .suspended else { return false }
    resetObservedInputState()
    outputState = currentInputState
    lastLiveInputReportNanoseconds = nil
    inputHealthMonitoringStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
    awaitingNeutralAfterLivenessLoss = false
    sessionState = .active
    await dispatcher.dispatch(events: [], from: identifier)
    return true
  }

  func restartUSBStartupOutputForResume() async -> Bool {
    guard case .usb = transport, let handle = usbHandle else { return true }
    return await performUSBHandshake(handle: handle)
  }

  func updateObservedInputState(from events: [ControllerEvent]) {
    currentInputState.apply(events: events)
  }

  func snapshotBatteryTelemetry() {
    guard let provider = parser as? any ControllerBatteryTelemetryProvider else { return }
    currentBatteryTelemetry = provider.batteryTelemetry
  }

  func resetObservedInputState() {
    currentInputState = DeviceInputState(
      vendorID: identifier.vendorID,
      productID: identifier.productID
    )
  }

  func updateOutputState(from events: [ControllerEvent]) { outputState.apply(events: events) }

  func neutralizeOutput() async {
    let neutralizingEvents = outputState.neutralizingEvents()
    guard !neutralizingEvents.isEmpty else { return }
    await dispatcher.dispatch(events: neutralizingEvents, from: identifier)
    updateOutputState(from: neutralizingEvents)
  }

  func retireOutputAfterLivenessLoss() async {
    guard !awaitingNeutralAfterLivenessLoss else { return }
    await neutralizeOutput()
    awaitingNeutralAfterLivenessLoss = true
    if let listener = dispatcher as? any ControllerLifecycleListener {
      await listener.controllerDidStop(identifier)
    }
  }

  func handleInputConnectionStateChangeIfNeeded() async -> [PhysicalHIDOutputReport] {
    guard let lifecycle = parser as? any ControllerInputConnectionLifecycle,
      let state = lifecycle.consumeInputConnectionStateChange()
    else { return [] }

    if let output = parser as? any USBInputConnectionOutputProvider, let handle = usbHandle {
      for packet in output.usbInputConnectionOutputPackets(for: state) {
        do {
          _ = try await handle.writeInterruptPacket(
            endpoint: transportProfile.outputEndpoint,
            data: packet,
            timeout: 2_000
          )
          appendToPacketLog(bytes: packet, direction: "tx")
        } catch {
          print("[DevicePipeline] USB lifecycle output failed for \(identifier): \(error)")
        }
      }
    }

    switch state {
    case .connected:
      guard !inputConnectionActive else { return [] }
      inputConnectionActive = true
      await dispatcher.dispatch(events: [], from: identifier)
      print("[DevicePipeline] Input controller connected: \(identifier)")
      return (parser as? any HIDStartupFeatureReportProvider)?.hidStartupFeatureReports() ?? []
    case .disconnected:
      resetObservedInputState()
      await neutralizeOutput()
      if inputConnectionActive, let listener = dispatcher as? any ControllerLifecycleListener {
        await listener.controllerDidStop(identifier)
      }
      inputConnectionActive = false
      waitingForExternalNeutral = false
      print("[DevicePipeline] Input controller disconnected: \(identifier)")
      return (parser as? any HIDShutdownFeatureReportProvider)?.hidShutdownFeatureReports() ?? []
    }
  }

  func appendToPacketLog(bytes: [UInt8], direction: String) {
    packetLog.append(bytes: bytes, direction: direction)
  }

  // MARK: - Rumble

  func sendRumble(left: UInt8, right: UInt8, lt: UInt8, rt: UInt8) async -> Bool {
    guard let handle = usbHandle, let rumbleOutput = parser as? PhysicalRumbleOutput else {
      return false
    }
    do {
      let packet = rumbleOutput.physicalRumblePacket(left: left, right: right, lt: lt, rt: rt)
      _ = try await handle.writeInterruptPacket(
        endpoint: packet.endpoint,
        data: packet.bytes,
        timeout: packet.timeoutMilliseconds
      )
      return true
    } catch {
      if let error = error as? USBTransportError, error.isDisconnected {
        await invalidateUSBHandle(handle)
      }
      print("[DevicePipeline] Rumble send failed for \(identifier): \(error)")
      return false
    }
  }

  func invalidateUSBHandle(_ handle: any USBTransportSession) async {
    guard let current = usbHandle, ObjectIdentifier(current) == ObjectIdentifier(handle) else {
      return
    }
    usbHandle = nil
    await handle.close()
    (parser as? any InputParserSessionLifecycle)?.resetProtocolState()
  }

}
