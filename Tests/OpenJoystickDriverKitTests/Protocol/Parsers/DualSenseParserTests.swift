import Foundation
import ProtocolPacketFixtures
import Testing

@testable import OpenJoystickDriverKit

private func hasEvent(_ events: [ControllerEvent], _ expected: ControllerEvent) -> Bool {
  events.contains(expected)
}

struct DualSenseParserTests {
  @Test
  func testDualSenseUSBReportParsesPrimaryControls() throws {
    let identifier = DeviceIdentifier(vendorID: 1356, productID: 3302)
    let parser = ParserRegistry().parser(for: identifier)
    _ = try parser.parse(data: ProtocolPacketFixtures.DualSense.usbInputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.DualSense.usbInputReport(
        sticks: ((255, 0), (0, 255)),
        triggers: (255, 128),
        buttons: (0x28, 0x30, 0x03)
      )
    )

    #expect(hasEvent(events, .leftStickChanged(x: 1.0, y: 1.0)))
    #expect(hasEvent(events, .rightStickChanged(x: -1.0, y: -1.0)))
    #expect(hasEvent(events, .leftTriggerChanged(1.0)))
    #expect(hasEvent(events, .rightTriggerChanged(128.0 / 255.0)))
    #expect(hasEvent(events, .buttonPressed(.cross)))
    #expect(hasEvent(events, .buttonPressed(.share)))
    #expect(hasEvent(events, .buttonPressed(.options)))
    #expect(hasEvent(events, .buttonPressed(.ps)))
    #expect(hasEvent(events, .buttonPressed(.touchpad)))
  }

  @Test
  func testDualSenseBluetoothReportParsesPrimaryControlsWithCRC() throws {
    let parser = DualSenseParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.DualSense.bluetoothInputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.DualSense.bluetoothInputReport(
        sticks: ((255, 0), (0, 255)),
        triggers: (255, 128),
        buttons: (0x28, 0x30, 0x07)
      )
    )

    #expect(hasEvent(events, .leftStickChanged(x: 1.0, y: 1.0)))
    #expect(hasEvent(events, .rightStickChanged(x: -1.0, y: -1.0)))
    #expect(hasEvent(events, .leftTriggerChanged(1.0)))
    #expect(hasEvent(events, .rightTriggerChanged(128.0 / 255.0)))
    #expect(hasEvent(events, .buttonPressed(.cross)))
    #expect(hasEvent(events, .buttonPressed(.share)))
    #expect(hasEvent(events, .buttonPressed(.options)))
    #expect(hasEvent(events, .buttonPressed(.ps)))
    #expect(hasEvent(events, .buttonPressed(.touchpad)))
    #expect(hasEvent(events, .buttonPressed(.mute)))
  }

  @Test
  func testDualSenseUnknownReportIDIsIgnored() throws {
    let parser = DualSenseParser()
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 0x02
    report[1] = 255
    report[2] = 0
    report[5] = 255
    report[8] = 0x28

    let events = try parser.parse(data: Data(report))

    #expect(events.isEmpty)
  }

  @Test
  func testDualSenseBluetoothReportRejectsInvalidCRC() throws {
    let parser = DualSenseParser()
    var report = Array(ProtocolPacketFixtures.DualSense.bluetoothInputReport(buttons: (0x28, 0, 0)))
    report[77] ^= 0xFF

    do {
      _ = try parser.parse(data: Data(report))
      #expect(Bool(false))
    } catch let error as DualSenseParserError { #expect(error == .invalidBluetoothCRC) } catch {
      #expect(Bool(false))
    }
  }

  @Test
  func testDualSenseUSBReportParsesMicrophoneMute() throws {
    let parser = DualSenseParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.DualSense.usbInputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.DualSense.usbInputReport(buttons: (0x08, 0, 0x04))
    )

    #expect(hasEvent(events, .buttonPressed(.mute)))
  }

  @Test
  func testDualSenseProfilesAreExperimentalAndUnverified() {
    let registry = ParserRegistry()
    let identifiers = [
      DeviceIdentifier(vendorID: 1356, productID: 3302),
      DeviceIdentifier(vendorID: 1356, productID: 3570),
    ]

    for identifier in identifiers {
      let profile = registry.runtimeProfile(for: identifier)
      #expect(profile.parserName == "DualSense")
      #expect(profile.protocolVariant.rawValue == "dualSense")
      #expect(
        profile.quirks == ["touchpad", "microphoneMute"]
          + (identifier.productID == 3570 ? ["edgeButtons"] : [])
      )
    }
  }

  @Test
  func bluetoothSensorPayloadMatchesUSBAndBadCRCCannotAdvanceClock() throws {
    var report = Array(ProtocolPacketFixtures.DualSense.bluetoothInputReport())
    report[17] = 0xFF
    report[18] = 0xFF
    report[29] = 3
    let crc = ProtocolPacketFixtures.DualSense.bluetoothInputCRC32(report)
    for index in 0..<4 { report[74 + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
    let parser = DualSenseParser()
    let first = try parser.parse(data: Data([0xA1] + report))
    let motion = try #require(
      first.compactMap { event -> ControllerMotionSample? in
        if case .motionSample(let sample) = event { return sample }
        return nil
      }.first
    )
    #expect(motion.rawGyroscope.x == -1)
    #expect(motion.timestamp.rawCounter == 3)
    report[29] = 6
    #expect(throws: DualSenseParserError.invalidBluetoothCRC) {
      try parser.parse(data: Data(report))
    }
    let repeated = try parser.parse(data: ProtocolPacketFixtures.DualSense.bluetoothInputReport())
    let next = try #require(
      repeated.compactMap { event -> ControllerMotionSample? in
        if case .motionSample(let sample) = event { return sample }
        return nil
      }.first
    )
    #expect(next.timestamp.sequenceIndex == 1)
  }

}

extension DualSenseParserTests {
  @Test(arguments: [
    (UInt8(0x10), Button.leftFunction, RemappingButton.leftFunction),
    (UInt8(0x20), Button.rightFunction, RemappingButton.rightFunction),
    (UInt8(0x40), Button.leftPaddle, RemappingButton.leftPaddle),
    (UInt8(0x80), Button.rightPaddle, RemappingButton.rightPaddle),
  ])
  func edgeButtonMapsFromUSBAndBluetooth(
    mask: UInt8,
    physical: Button,
    source: RemappingButton
  ) throws {
    for bluetooth in [false, true] {
      let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x0DF2)
      let parser = ParserRegistry().parser(for: identifier)
      let report =
        bluetooth
        ? ProtocolPacketFixtures.DualSense.bluetoothInputReport(buttons: (0x08, 0, mask))
        : ProtocolPacketFixtures.DualSense.usbInputReport(buttons: (0x08, 0, mask))
      let neutral =
        bluetooth
        ? ProtocolPacketFixtures.DualSense.bluetoothInputReport()
        : ProtocolPacketFixtures.DualSense.usbInputReport()
      let profile = RemappingProfile(
        name: "Edge mapping",
        device: RemappingDeviceScope(vendorID: 0x054C, productID: 0x0DF2),
        applicationScope: .global,
        outputPolicy: RemappingOutputPolicy(virtualGamepad: .passthrough),
        bindings: [RemappingBinding(source: .button(source), destination: .gamepadButton(.south))]
      )
      try profile.validate()
      let pressed = try parser.parse(data: report)
      #expect(pressed.contains(.buttonPressed(physical)))
      var engine = RemappingEngineState()
      #expect(
        engine.process(events: pressed, from: identifier, profile: profile, at: 0) == [
          .gamepad(RemappingGamepadState(buttons: [.south]), identifier)
        ]
      )
      #expect(!((try parser.parse(data: report)).contains(.buttonPressed(physical))))
      #expect(
        engine.process(
          events: try parser.parse(data: neutral),
          from: identifier,
          profile: profile,
          at: 1
        ) == [.gamepad(.neutral, identifier)]
      )
    }
  }

  @Test
  func ordinaryDualSenseDoesNotDecodeEdgeButtonBits() throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x0CE6)
    let parser = ParserRegistry().parser(for: identifier)
    let events = try parser.parse(
      data: ProtocolPacketFixtures.DualSense.usbInputReport(buttons: (0x08, 0, 0xF0))
    )
    #expect(
      !events.contains {
        if case .buttonPressed = $0 { return true }
        return false
      }
    )
    #expect(!parser.physicalInputCapabilities.additionalButtons.contains(.leftPaddle))
  }

  @Test
  func badBluetoothCRCCannotConsumeAnEdgeButtonPress() throws {
    let parser = DualSenseParser(hasEdgeButtons: true)
    let valid = ProtocolPacketFixtures.DualSense.bluetoothInputReport(buttons: (0x08, 0, 0x40))
    var bad = valid
    bad[77] ^= 0xFF
    #expect(throws: DualSenseParserError.invalidBluetoothCRC) { try parser.parse(data: bad) }
    #expect(try parser.parse(data: valid).contains(.buttonPressed(.leftPaddle)))
    #expect(
      try parser.parse(data: ProtocolPacketFixtures.DualSense.bluetoothInputReport()).contains(
        .buttonReleased(.leftPaddle)
      )
    )
  }

  @Test
  func adaptiveTriggerResistanceUsesBoundedUSBEffectPayload() throws {
    let parser = DualSenseParser()
    let report = parser.physicalAdaptiveTriggerReport(
      .left,
      effect: PhysicalAdaptiveTriggerEffect(kind: .resistance, startPosition: 0.5, strength: 0.75)
    )

    #expect(report.reportID == 0x02)
    #expect(report.bytes[1] == 0x08)
    #expect(Array(report.bytes[22..<25]) == [0x01, 5, 6])
    #expect(Array(report.bytes[11..<22]) == [UInt8](repeating: 0, count: 11))
  }

  @Test
  func adaptiveTriggerBluetoothReportCarriesCRCAndExactSide() throws {
    let parser = DualSenseParser(prefersBluetooth: true)
    let report = parser.physicalAdaptiveTriggerReport(
      .right,
      effect: PhysicalAdaptiveTriggerEffect(kind: .resistance, startPosition: 1, strength: 1)
    )

    #expect(report.reportID == 0x31)
    #expect(report.bytes[3] == 0x04)
    #expect(Array(report.bytes[13..<16]) == [0x01, 9, 8])
    #expect(Array(report.bytes[24..<35]) == [UInt8](repeating: 0, count: 11))
    let storedCRC =
      UInt32(report.bytes[74]) | (UInt32(report.bytes[75]) << 8) | (UInt32(report.bytes[76]) << 16)
      | (UInt32(report.bytes[77]) << 24)
    #expect(ProtocolPacketFixtures.DualSense.bluetoothOutputCRC32(report.bytes) == storedCRC)
  }

  @Test
  func invalidAdaptiveTriggerEffectFailsClosedWithoutIntegerConversion() {
    let parser = DualSenseParser()
    let report = parser.physicalAdaptiveTriggerReport(
      .left,
      effect: PhysicalAdaptiveTriggerEffect(
        kind: .resistance,
        startPosition: .infinity,
        strength: .nan
      )
    )

    #expect(Array(report.bytes[22..<33]) == [UInt8](repeating: 0, count: 11))
  }
}
