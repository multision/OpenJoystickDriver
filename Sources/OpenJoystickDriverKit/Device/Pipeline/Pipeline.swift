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
  var currentBatteryTelemetry: ControllerBatteryTelemetry?
  let packetLog: PacketLogBuffer
  var idleMonitorTask: Task<Void, Never>?
  var runTask: Task<Void, Never>?
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
}
