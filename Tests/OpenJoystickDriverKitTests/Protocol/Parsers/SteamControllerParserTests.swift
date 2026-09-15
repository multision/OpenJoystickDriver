import Foundation
import ProtocolPacketFixtures
import Testing

@testable import OpenJoystickDriverKit

private func eventExists(_ events: [ControllerEvent], _ expected: ControllerEvent) -> Bool {
  events.contains(expected)
}

struct SteamControllerParserTests {
  @Test
  func testSteamControllerProfilesExposeOperationalFlags() {
    let registry = ParserRegistry()
    let identifiers = [
      DeviceIdentifier(vendorID: 10462, productID: 4354),
      DeviceIdentifier(vendorID: 10462, productID: 4418),
    ]

    let wired = registry.runtimeProfile(for: identifiers[0])
    #expect(wired.parserName == "SteamController")
    #expect(wired.protocolVariant == .steamController)
    #expect(wired.quirks == ["lizardMode", "trackpads"])

    let wireless = registry.runtimeProfile(for: identifiers[1])
    #expect(wireless.parserName == "SteamController")
    #expect(wireless.protocolVariant == .steamController)
    #expect(wireless.quirks == ["lizardMode", "trackpads", "wirelessReceiver"])
  }

  @Test
  func testSteamControllerReportParsesPrimaryControls() throws {
    let parser = ParserRegistry().parser(for: DeviceIdentifier(vendorID: 10462, productID: 4354))
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(
        buttons: (0xFC, 0x70, 0x44),
        triggers: (255, 128),
        left: (32767, -32767),
        rightPad: (-32767, 32767)
      )
    )

    #expect(eventExists(events, .buttonPressed(.a)))
    #expect(eventExists(events, .buttonPressed(.b)))
    #expect(eventExists(events, .buttonPressed(.x)))
    #expect(eventExists(events, .buttonPressed(.y)))
    #expect(eventExists(events, .buttonPressed(.leftBumper)))
    #expect(eventExists(events, .buttonPressed(.rightBumper)))
    #expect(eventExists(events, .buttonPressed(.back)))
    #expect(eventExists(events, .buttonPressed(.guide)))
    #expect(eventExists(events, .buttonPressed(.start)))
    #expect(eventExists(events, .buttonPressed(.leftStick)))
    #expect(eventExists(events, .buttonPressed(.rightPadClick)))
    #expect(eventExists(events, .leftTriggerChanged(1.0)))
    #expect(eventExists(events, .rightTriggerChanged(128.0 / 255.0)))
    #expect(eventExists(events, .leftStickChanged(x: 1.0, y: 1.0)))
    #expect(eventExists(events, .rightStickChanged(x: -1.0, y: -1.0)))
  }

  @Test
  func testSteamGripBitsHaveDistinctSources() throws {
    let parser = SteamControllerParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x80, 0x01))
    )
    #expect(events == [.buttonPressed(.leftGrip), .buttonPressed(.rightGrip)])
    let releases = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())
    #expect(releases == [.buttonReleased(.leftGrip), .buttonReleased(.rightGrip)])
  }

  @Test
  func testLeftPadTouchDoesNotCreateVirtualLeftStickMotion() throws {
    let parser = SteamControllerParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0, 0x08), left: (32767, -32767))
    )

    #expect(!eventExists(events, .leftStickChanged(x: 1.0, y: 1.0)))
  }

  @Test
  func testLeftPadAndJoyBitDoesNotReplaceStickWithPadCoordinates() throws {
    let parser = SteamControllerParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0, 0x88), left: (32767, -32767))
    )

    #expect(!eventExists(events, .leftStickChanged(x: 1.0, y: 1.0)))
  }

  @Test
  func testLeftPadTouchStaysOmitted() throws {
    let parser = SteamControllerParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0, 0x80))
    )

    #expect(events.isEmpty)
  }

  @Test
  func testSteamControllerReportParsesDpadDirections() throws {
    let parser = SteamControllerParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport())

    let upEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x01, 0))
    )
    let rightEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x02, 0))
    )
    let downEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x08, 0))
    )
    let leftEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x04, 0))
    )

    #expect(eventExists(upEvents, .dpadChanged(.north)))
    #expect(eventExists(rightEvents, .dpadChanged(.east)))
    #expect(eventExists(downEvents, .dpadChanged(.south)))
    #expect(eventExists(leftEvents, .dpadChanged(.west)))
  }

  @Test
  func testSteamControllerDisablesAndRestoresLizardModeWithFeatureReports() {
    let parser = SteamControllerParser()

    let startup = parser.hidStartupFeatureReports()
    #expect(startup.map(\.reportID) == [0, 0])
    #expect(startup.map { $0.bytes.count } == [64, 64])
    #expect(startup[0].bytes[0] == 0x81)
    #expect(
      Array(startup[1].bytes.prefix(11)) == ProtocolPacketFixtures.Steam.startupSettingsPrefix
    )

    let shutdown = parser.hidShutdownFeatureReports()
    #expect(shutdown.map(\.reportID) == [0, 0])
    #expect(shutdown.map { $0.bytes.count } == [64, 64])
    #expect(shutdown[0].bytes[0] == 0x85)
    #expect(shutdown[1].bytes[0] == 0x8E)
  }

  @Test
  func testSteamControllerBrightnessMatchesSDLSettingReport() {
    let report = SteamControllerParser().physicalBrightnessReport(197)

    #expect(report.reportID == 0)
    #expect(report.bytes.count == 64)
    #expect(Array(report.bytes.prefix(5)) == [0x87, 3, 45, 197, 0])
    #expect(report.bytes.dropFirst(5).allSatisfy { $0 == 0 })
  }

  @Test
  func testSteamControllerHapticReportsMatchLinuxFeatureCommand() {
    let reports = SteamControllerParser().physicalHapticReports(
      left: 255,
      right: 128,
      durationMs: 450
    )

    #expect(reports.count == 2)
    #expect(reports.allSatisfy { $0.reportID == 0 && $0.bytes.count == 64 })
    #expect(Array(reports[0].bytes.prefix(10)) == [0x8F, 8, 1, 0xFF, 0xFF, 0, 0, 7, 0, 0x06])
    #expect(Array(reports[1].bytes.prefix(10)) == [0x8F, 8, 0, 0xFF, 0xFF, 0, 0, 7, 0, 0xF7])
    #expect(reports.flatMap { $0.bytes.dropFirst(10) }.allSatisfy { $0 == 0 })
  }

  @Test
  func testSteamControllerHapticIntensityAndSafeHoldFallback() {
    let low = SteamControllerParser().physicalHapticReports(left: 1, right: 0, durationMs: 0)

    #expect(low.count == 1)
    #expect(Array(low[0].bytes.prefix(10)) == [0x8F, 8, 1, 0xE8, 0xFD, 0, 0, 1, 0, 0xE8])
    #expect(
      SteamControllerParser().physicalHapticReports(left: 0, right: 0, durationMs: 10).isEmpty
    )
  }

  @Test
  func testSteamWirelessHapticsRequireLogicalControllerConnection() throws {
    let parser = SteamControllerParser(isWirelessReceiver: true)
    #expect(parser.physicalHapticReports(left: 255, right: 0, durationMs: 100).isEmpty)

    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x02))
    #expect(parser.physicalHapticReports(left: 255, right: 0, durationMs: 100).count == 1)

    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x01))
    #expect(parser.physicalHapticReports(left: 255, right: 0, durationMs: 100).isEmpty)
  }

  @Test
  func testSteamWirelessReceiverStatusRequestReport() {
    let wired = SteamControllerParser()
    #expect(wired.inputConnectionStatusRequestReport() == nil)

    let wireless = SteamControllerParser(isWirelessReceiver: true)
    let report = wireless.inputConnectionStatusRequestReport()

    #expect(report?.reportID == 0)
    #expect(report?.bytes.count == 64)
    #expect(report?.bytes.first == 0xB4)
  }

  @Test
  func testSteamControllerTracksWirelessConnectDisconnectLifecycle() throws {
    let parser = SteamControllerParser(isWirelessReceiver: true)
    #expect(parser.requiresInputConnectionBeforeOutput)

    let preConnectEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
    )
    #expect(preConnectEvents.isEmpty)

    let connectEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x02)
    )
    #expect(connectEvents.isEmpty)
    #expect(parser.consumeInputConnectionStateChange() == .connected)
    #expect(parser.consumeInputConnectionStateChange() == nil)

    let inputEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
    )
    #expect(eventExists(inputEvents, .buttonPressed(.a)))

    let disconnectEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x01)
    )
    #expect(disconnectEvents.isEmpty)
    #expect(parser.consumeInputConnectionStateChange() == .disconnected)

    let postDisconnectEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
    )
    #expect(postDisconnectEvents.isEmpty)
  }

  @Test
  func testSteamWirelessStatusReportMarksReceiverConnectedWhenConnectEventWasMissed() throws {
    let parser = SteamControllerParser(isWirelessReceiver: true)

    let statusEvents = try parser.parse(data: ProtocolPacketFixtures.Steam.statusReport)

    #expect(statusEvents.isEmpty)
    #expect(parser.consumeInputConnectionStateChange() == .connected)

    let inputEvents = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
    )
    #expect(eventExists(inputEvents, .buttonPressed(.a)))
  }

  @Test
  func testSteamControllerIgnoresUnknownNonStateReports() throws {
    let parser = SteamControllerParser()
    var unknownEvent = Array(ProtocolPacketFixtures.Steam.inputReport())
    unknownEvent[2] = 0x04

    let events = try parser.parse(data: Data(unknownEvent))

    #expect(events.isEmpty)
  }

  @Test
  func rawMotionUsesReceiptTimeAndSuppressesDuplicateSequenceNumbers() throws {
    let parser: any InputParser = SteamControllerParser()
    var report = Array(ProtocolPacketFixtures.Steam.inputReport())
    report[4] = 255
    report[5] = 255
    report[6] = 255
    report[7] = 255
    ProtocolPacketFixtures.Steam.writeInt16LE(-32_768, into: &report, at: 28)
    ProtocolPacketFixtures.Steam.writeInt16LE(32_767, into: &report, at: 30)
    ProtocolPacketFixtures.Steam.writeInt16LE(-1, into: &report, at: 32)
    ProtocolPacketFixtures.Steam.writeInt16LE(123, into: &report, at: 34)
    let first = try parser.parse(data: Data(report), receivedAtNanoseconds: 100)
    guard case .motionSample(let sample) = first.first(where: isMotionEvent) else {
      Issue.record("Expected raw motion sample")
      return
    }
    #expect(sample.rawAccelerometer == ControllerRawSensorVector(x: -32_768, y: 32_767, z: -1))
    #expect(sample.rawGyroscope.x == 123)
    #expect(sample.timestamp.basis == .hostEstimate)
    #expect(sample.timestamp.rawCounter == .max)
    #expect(sample.timestamp.elapsedNanoseconds == 0)
    #expect(sample.timestamp.tickNanosecondsNumerator == nil)
    #expect(try parser.parse(data: Data(report), receivedAtNanoseconds: 110).isEmpty)
    report.replaceSubrange(4..<8, with: [0, 0, 0, 0])
    let second = try parser.parse(data: Data(report), receivedAtNanoseconds: 120)
    guard case .motionSample(let wrapped) = second.first(where: isMotionEvent) else {
      Issue.record("Expected sample after packet counter wrap")
      return
    }
    #expect(wrapped.timestamp.elapsedNanoseconds == 20)
    #expect(wrapped.timestamp.sequenceIndex == 1)
    report[4] = 1
    let backward = try parser.parse(data: Data(report), receivedAtNanoseconds: 90)
    guard case .motionSample(let clamped) = backward.first(where: isMotionEvent) else {
      Issue.record("Expected sample with clamped receipt time")
      return
    }
    #expect(clamped.timestamp.elapsedNanoseconds == 20)
  }

  @Test
  func receiverReconnectResetsMotionClockAndDuplicateTracking() throws {
    let parser = SteamControllerParser(isWirelessReceiver: true)
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.wirelessReport(status: 2))
    _ = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(),
      receivedAtNanoseconds: 100
    )
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.wirelessReport(status: 1))
    #expect(try parser.parse(data: ProtocolPacketFixtures.Steam.inputReport()).isEmpty)
    _ = try parser.parse(data: ProtocolPacketFixtures.Steam.wirelessReport(status: 2))
    let events = try parser.parse(
      data: ProtocolPacketFixtures.Steam.inputReport(),
      receivedAtNanoseconds: 10
    )
    guard case .motionSample(let sample) = events.first(where: isMotionEvent) else {
      Issue.record("Expected fresh receiver-session motion sample")
      return
    }
    #expect(sample.timestamp.sequenceIndex == 0)
    #expect(sample.timestamp.elapsedNanoseconds == 0)
  }

}

private func isMotionEvent(_ event: ControllerEvent) -> Bool {
  if case .motionSample = event { return true }
  return false
}
