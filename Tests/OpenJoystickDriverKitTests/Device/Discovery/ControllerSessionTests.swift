import Foundation
import IOKit
import Testing

@testable import OpenJoystickDriverKit

private final class ControllerSessionOutputProbe: OutputDispatcher, ControllerLifecycleListener,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedSuppression = false
  private var batches: [[ControllerEvent]] = []
  private var stopped: [DeviceIdentifier] = []

  var suppressOutput: Bool {
    get { lock.withLock { storedSuppression } }
    set { lock.withLock { storedSuppression = newValue } }
  }

  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {
    lock.withLock { batches.append(events) }
  }

  func controllerDidStop(_ identifier: DeviceIdentifier) {
    lock.withLock { stopped.append(identifier) }
  }

  func snapshot() -> (batches: [[ControllerEvent]], stopped: [DeviceIdentifier]) {
    lock.withLock { (batches, stopped) }
  }
}

private final class WirelessDisconnectProbe: WirelessControllerDisconnecting, @unchecked Sendable {
  private let lock = NSLock()
  private let outcome: WirelessControllerDisconnectOutcome
  private var addresses: [String] = []

  init(outcome: WirelessControllerDisconnectOutcome) { self.outcome = outcome }

  func disconnect(
    address: String,
    timeoutNanoseconds _: UInt64
  ) async -> WirelessControllerDisconnectOutcome {
    await Task.yield()
    lock.withLock { addresses.append(address) }
    return outcome
  }

  var calls: [String] { lock.withLock { addresses } }
}

private final class AbsoluteObservationParser: InputParser, ControllerInputReportObserver,
  ControllerInputReportLivenessProvider
{
  let inputReportLivenessTimeoutNanoseconds: UInt64 = 1_000_000_000
  private(set) var latestInputReportObservation: ControllerInputReportObservation?

  func parse(data: Data) throws -> [ControllerEvent] {
    let controls: [ControllerEvent] =
      data.first == 1 ? [.rightStickChanged(x: 1, y: 0)] : [.rightStickChanged(x: 0, y: 0)]
    latestInputReportObservation = ControllerInputReportObservation(
      controls: controls,
      isFresh: true
    )
    return data.first == 1 ? controls : []
  }
}

struct ControllerSessionTests {
  @Test
  func absoluteObservationReconcilesAMissedRightStickDelta() async {
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: DeviceIdentifier(vendorID: 1, productID: 2),
      transport: .hid(locationID: 6),
      parser: AbsoluteObservationParser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(Data([1]))
    await pipeline.feedHIDData(Data([2]))

    #expect(
      output.snapshot().batches.flatMap { $0 } == [
        .rightStickChanged(x: 1, y: 0), .rightStickChanged(x: 0, y: 0),
      ]
    )
    await pipeline.stop()
  }

  @Test(arguments: [
    (WirelessControllerDisconnectOutcome.disconnected, nil as WirelessControllerDisconnectFailure?),
    (
      WirelessControllerDisconnectOutcome.failed(kIOReturnError),
      WirelessControllerDisconnectFailure.disconnectFailed
    ), (WirelessControllerDisconnectOutcome.timedOut, WirelessControllerDisconnectFailure.timedOut),
  ])
  func wirelessDisconnectSuspendsBeforeReturning(
    outcome: WirelessControllerDisconnectOutcome,
    expectedFailure: WirelessControllerDisconnectFailure?
  ) async throws {
    let probe = WirelessDisconnectProbe(outcome: outcome)
    let manager = DeviceManager(
      dispatcher: ControllerSessionOutputProbe(),
      wirelessControllerDisconnector: probe
    )
    await manager.handleHIDEvent(
      .connected(
        vendorID: 0x054C,
        productID: 0x09CC,
        serialNumber: "aa-bb-cc-dd-ee-ff",
        locationID: 71,
        productName: "Wireless Controller",

        transport: "Bluetooth",
        ownership: .exclusive
      )
    )
    let device = try #require(await manager.connectedDeviceDescriptions().first)

    let result = await manager.disconnectWirelessController(
      vendorID: device.vendorID,
      productID: device.productID,
      runtimeIdentifier: device.runtimeIdentifier
    )

    #expect(result.state == (expectedFailure == nil ? .suspended : .active))

    #expect(result.failure == expectedFailure)
    switch outcome {
    case .failed(let code):
      #expect(result.failedStage == .closeBluetoothConnection)
      #expect(result.systemCode == code)
      #expect(result.detail?.contains(String(code)) == true)
    case .timedOut:
      #expect(result.failedStage == .confirmBluetoothDisconnection)
      #expect(result.recovery != nil)
    case .disconnected, .stillConnected: break
    }
    #expect(probe.calls == ["AA:BB:CC:DD:EE:FF"])
    await manager.stop()
  }

  @Test(arguments: [
    ("USB", "AA:BB:CC:DD:EE:FF", WirelessControllerDisconnectFailure.notBluetooth),
    ("Bluetooth", nil as String?, WirelessControllerDisconnectFailure.missingAddress),
  ])
  func wirelessDisconnectRejectsInvalidPhysicalSelectionWithoutSuspending(
    connection: String,
    serialNumber: String?,
    expectedFailure: WirelessControllerDisconnectFailure
  ) async throws {
    let probe = WirelessDisconnectProbe(outcome: .disconnected)
    let manager = DeviceManager(
      dispatcher: ControllerSessionOutputProbe(),
      wirelessControllerDisconnector: probe
    )
    await manager.handleHIDEvent(
      .connected(
        vendorID: 0x054C,
        productID: 0x09CC,
        serialNumber: serialNumber,
        locationID: 72,
        productName: "Controller",
        transport: connection,
        ownership: .exclusive
      )
    )
    let device = try #require(await manager.connectedDeviceDescriptions().first)

    let result = await manager.disconnectWirelessController(
      vendorID: device.vendorID,
      productID: device.productID,
      runtimeIdentifier: device.runtimeIdentifier
    )

    #expect(result.state == .active)
    #expect(result.failure == expectedFailure)
    #expect(probe.calls.isEmpty)
    await manager.stop()
  }

  @Test
  func suspensionNeutralizesHeldInputAndIgnoresReportsUntilResume() async {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 1),
      parser: DS4Parser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x28, timestamp: 1))

    #expect(await pipeline.suspendControllerSession())
    #expect(await pipeline.controllerSessionState() == .suspended)
    #expect(await pipeline.inputState().isEffectivelyNeutral)
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x48, timestamp: 2))
    #expect(await pipeline.inputState().isEffectivelyNeutral)

    let suspended = output.snapshot()
    #expect(suspended.stopped == [identifier])
    #expect(suspended.batches.flatMap { $0 }.contains(.buttonReleased(.cross)))

    #expect(await pipeline.resumeControllerSession())
    #expect(await pipeline.controllerSessionState() == .active)
    await pipeline.stop()
  }

  @Test
  func suspendedControllersRemainInInventoryButAreNotCompatibilityTargets() async throws {
    let manager = DeviceManager(dispatcher: ControllerSessionOutputProbe())
    await manager.handleHIDEvent(
      .connected(
        vendorID: 0x054C,
        productID: 0x09CC,
        serialNumber: nil,
        locationID: 73,
        productName: "Controller",
        transport: "USB",
        ownership: .exclusive
      )
    )
    let device = try #require(await manager.connectedDeviceDescriptions().first)
    #expect(await manager.activeDeviceIdentifiers().count == 1)

    _ = await manager.suspendController(
      vendorID: device.vendorID,
      productID: device.productID,
      runtimeIdentifier: device.runtimeIdentifier
    )

    #expect(await manager.connectedDeviceDescriptions().count == 1)
    #expect(await manager.activeDeviceIdentifiers().isEmpty)
    await manager.stop()
  }

  @Test
  func ds4LivenessLossNeutralizesAndRequiresFreshNeutralReport() async throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 2),
      parser: DS4Parser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x28))
    try await Task.sleep(nanoseconds: 1_050_000_000)
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x48))
    #expect(output.snapshot().batches.flatMap { $0 }.contains(.buttonReleased(.cross)))

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, timestamp: 3))
    #expect(await pipeline.inputState().isEffectivelyNeutral)
    await pipeline.stop()
  }

  @Test
  func freshHeldReportsDoNotRecoverRetiredDS4Output() async throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 3),
      parser: DS4Parser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, rightStickX: 255, timestamp: 1))
    try await Task.sleep(nanoseconds: 1_050_000_000)

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, rightStickX: 255, timestamp: 2))
    #expect(await pipeline.inputHealth().state == .waitingForNeutral)
    #expect(output.snapshot().stopped == [identifier])

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, rightStickX: 255, timestamp: 3))
    #expect(await pipeline.inputHealth().state == .waitingForNeutral)
    #expect(await pipeline.inputHealth().recoveryCount == 0)

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, timestamp: 4))
    #expect(await pipeline.inputHealth().state == .healthy)
    #expect(await pipeline.inputHealth().recoveryCount == 1)
    await pipeline.stop()
  }

  @Test
  func repeatedNonAdvancingDS4ReportsBecomeStaleAndRetireOnce() async throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 4),
      parser: DS4Parser(),
      dispatcher: output,
      idleMonitorIntervalNanoseconds: 50_000_000
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x28, timestamp: 10))
    for _ in 0..<4 {
      try await Task.sleep(nanoseconds: 300_000_000)
      await pipeline.feedHIDData(ds4USBReport(buttons: 0x28, timestamp: 10))
    }

    #expect(await pipeline.inputHealth().state == .waitingForNeutral)
    #expect(await pipeline.inputHealth().failureReason == .freshnessNotAdvancing)
    #expect(output.snapshot().stopped == [identifier])
    await pipeline.stop()
  }

  @Test
  func missingDS4ReportsRetireOutputAndFreshNeutralRecovers() async throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 5),
      parser: DS4Parser(),
      dispatcher: output,
      idleMonitorIntervalNanoseconds: 50_000_000
    )
    await pipeline.start()
    try await Task.sleep(nanoseconds: 1_100_000_000)

    #expect(await pipeline.inputHealth().state == .waitingForNeutral)
    #expect(await pipeline.inputHealth().failureReason == .missingReports)
    #expect(output.snapshot().stopped == [identifier])

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08, timestamp: 1))
    #expect(await pipeline.inputHealth().state == .healthy)
    #expect(await pipeline.inputHealth().recoveryCount == 1)
    await pipeline.stop()
  }

  private func ds4USBReport(buttons: UInt8, rightStickX: UInt8 = 128, timestamp: UInt16 = 0) -> Data
  {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 1
    report[1] = 128
    report[2] = 128
    report[3] = rightStickX
    report[4] = 128
    report[5] = buttons
    report[10] = UInt8(truncatingIfNeeded: timestamp)
    report[11] = UInt8(truncatingIfNeeded: timestamp >> 8)
    return Data(report)
  }
}
