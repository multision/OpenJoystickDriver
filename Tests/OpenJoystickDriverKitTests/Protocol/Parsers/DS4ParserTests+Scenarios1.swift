import Foundation
import Testing

@testable import OpenJoystickDriverKit

extension DS4ParserTests {
  @Test
  func testValidatedReportsExposeAbsoluteControlsAndAdvancingTimestamp() throws {
    let parser = DS4Parser()

    _ = try parser.parse(
      data: makeDS4Report(rightStickX: 255, buttons0: 0x28, sensorTimestamp: 0xFFFF)
    )
    #expect(parser.latestInputReportObservation?.isFresh == true)
    #expect(
      parser.latestInputReportObservation?.controls.contains(
        .rightStickChanged(x: 127.0 / 128.0, y: 0)
      ) == true
    )
    #expect(parser.latestInputReportObservation?.controls.contains(.buttonPressed(.cross)) == true)

    _ = try parser.parse(data: makeDS4Report(sensorTimestamp: 0xFFFF))
    #expect(parser.latestInputReportObservation?.isFresh == false)
    _ = try parser.parse(data: makeDS4Report(sensorTimestamp: 0))
    #expect(parser.latestInputReportObservation?.isFresh == true)
    _ = try parser.parse(data: makeDS4Report(sensorTimestamp: 0xFFFF))
    #expect(parser.latestInputReportObservation?.isFresh == false)
  }

  @Test
  func testInvalidBluetoothReportDoesNotReplaceTheLastObservation() throws {
    let parser = DS4Parser(prefersBluetooth: true)
    _ = try parser.parse(data: makeDS4BluetoothReport(sensorTimestamp: 1))
    let observation = parser.latestInputReportObservation
    var invalidReport = Array(makeDS4BluetoothReport(sensorTimestamp: 2))
    invalidReport[20] ^= 1

    #expect(throws: DS4ParserError.invalidBluetoothCRC) {
      try parser.parse(data: Data(invalidReport))
    }
    #expect(parser.latestInputReportObservation?.isFresh == observation?.isFresh)
  }

  @Test
  func testUSBReportsBatteryBucketsAndCableStates() throws {
    let parser = DS4Parser()

    _ = try parser.parse(data: makeDS4Report(includesReportID: true, status: 0x00))
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 5,
          percentageRange: 0...9,
          chargingState: .discharging,
          cableState: .disconnected
        )
    )

    _ = try parser.parse(data: makeDS4Report(includesReportID: true, status: 0x13))
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 35,
          percentageRange: 30...39,
          chargingState: .charging,
          cableState: .connected
        )
    )

    _ = try parser.parse(data: makeDS4Report(includesReportID: true, status: 0x1B))
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(percentage: 100, chargingState: .full, cableState: .connected)
    )
  }

  @Test(arguments: Array(UInt8(0)...UInt8(9)))
  func testEveryBatteryBucketPreservesItsReportedRange(_ level: UInt8) throws {
    let parser = DS4Parser()

    _ = try parser.parse(data: makeDS4Report(status: level))

    #expect(parser.batteryTelemetry?.percentage == Int(level) * 10 + 5)
    #expect(parser.batteryTelemetry?.percentageRange == Int(level) * 10...(Int(level) * 10 + 9))
    #expect(
      parser.batteryTelemetry?.percentageDescription == "\(Int(level) * 10)–\(Int(level) * 10 + 9)%"
    )
  }

  @Test
  func testBluetoothReportParsesBatteryTelemetry() throws {
    let parser = DS4Parser(prefersBluetooth: true)

    _ = try parser.parse(data: makeDS4BluetoothReport(status: 0x1A))

    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 100,
          chargingState: .charging,
          cableState: .connected
        )
    )
  }

  @Test
  func testLevelTenRetainsTheObservedConnectionState() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report(status: 0x0A))
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 100,
          chargingState: .discharging,
          cableState: .disconnected
        )
    )

    _ = try parser.parse(data: makeDS4Report(status: 0x1A))
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 100,
          chargingState: .charging,
          cableState: .connected
        )
    )
  }

  @Test
  func testInvalidAndMinimalBatteryTelemetryRemainUnknown() throws {
    let wired = DS4Parser()
    _ = try wired.parse(data: makeDS4Report(status: 0x0F))
    #expect(
      wired.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: nil,
          chargingState: .unknown,
          cableState: .disconnected
        )
    )

    _ = try wired.parse(data: makeDS4Report(status: 0x1E))
    #expect(
      wired.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: nil,
          chargingState: .unknown,
          cableState: .connected
        )
    )

    let minimal = DS4Parser(prefersBluetooth: true)
    _ = try minimal.parse(data: Data([0x01, 128, 128, 128, 128, 0x08, 0, 0, 0, 0]))
    #expect(minimal.batteryTelemetry == nil)
  }

  @Test
  func testWiredReportWithoutReportIDIsRejected() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    #expect(throws: DS4ParserError.invalidReportFraming) {
      try parser.parse(data: makeDS4Report(includesReportID: false, buttons0: 0x28))
    }
  }
  @Test
  func testUSBFaceButtonTransitionsRemainOrderedAcrossUnrelatedInput() throws {
    try assertFaceButtonContinuity { buttons, leftStickX, rightStickX in
      makeDS4Report(
        includesReportID: true,
        leftStickX: leftStickX,
        rightStickX: rightStickX,
        buttons0: buttons
      )
    }
  }
  @Test
  func testBluetoothFaceButtonTransitionsRemainOrderedAcrossUnrelatedInput() throws {
    try assertFaceButtonContinuity { buttons, leftStickX, rightStickX in
      makeDS4BluetoothReport(leftStickX: leftStickX, rightStickX: rightStickX, buttons0: buttons)
    }
  }
  @Test
  func testBluetoothHIDTransactionReportParsesSticksTriggersAndSystemButtons() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4BluetoothReport(includesHIDTransaction: true))

    let events = try parser.parse(
      data: makeDS4BluetoothReport(
        includesHIDTransaction: true,
        leftStickX: 255,
        leftStickY: 0,
        rightStickX: 0,
        rightStickY: 255,
        buttons1: 0x30,
        buttons2: 0x03,
        leftTrigger: 255,
        rightTrigger: 128
      )
    )

    #expect(containsEvent(events, .leftStickChanged(x: 127.0 / 128.0, y: -1.0)))
    #expect(containsEvent(events, .rightStickChanged(x: -1.0, y: 127.0 / 128.0)))
    #expect(containsEvent(events, .leftTriggerChanged(1.0)))

    #expect(containsEvent(events, .rightTriggerChanged(128.0 / 255.0)))
    #expect(containsEvent(events, .buttonPressed(.share)))
    #expect(containsEvent(events, .buttonPressed(.options)))
    #expect(containsEvent(events, .buttonPressed(.ps)))
    #expect(containsEvent(events, .buttonPressed(.touchpad)))
  }
  @Test
  func testBluetoothPayloadWithoutReportIDIsRejected() throws {

    let parser = DS4Parser()
    #expect(throws: DS4ParserError.invalidReportFraming) {
      try parser.parse(data: makeDS4BluetoothReport(includesReportID: false))
    }
  }
  @Test
  func testBluetoothShortReportWithHIDTransactionParsesFaceButtons() throws {
    let parser = DS4Parser(prefersBluetooth: true)
    let neutral: [UInt8] = [0xA1, 0x01, 128, 128, 128, 128, 0x08, 0, 0, 0, 0]
    _ = try parser.parse(data: Data(neutral))

    var pressed = neutral
    pressed[6] = 0x28
    let events = try parser.parse(data: Data(pressed))

    #expect(containsEvent(events, .buttonPressed(.cross)))
  }
  @Test
  func testCompleteBluetoothReportRejectsInvalidCRC() throws {
    let parser = DS4Parser(prefersBluetooth: true)
    let observedPrefix: [UInt8] = [
      0x11, 0xC0, 0x00, 0x7A, 0x81, 0x81, 0x82, 0x08, 0x00, 0xCC, 0x00, 0x00, 0xF5, 0xD1, 0x0C,
      0xF6, 0xFF, 0x0B, 0x00, 0xF3, 0xFF, 0x78, 0x00, 0x8E,
    ]
    let observedReport = Data(observedPrefix + [UInt8](repeating: 0, count: 54))

    #expect(throws: DS4ParserError.invalidBluetoothCRC) { try parser.parse(data: observedReport) }
  }
  @Test
  func testWiredIOHIDReportParsesSticksTriggersAndSystemButtons() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let events = try parser.parse(
      data: makeDS4Report(
        leftStickX: 255,
        leftStickY: 0,
        rightStickX: 0,
        rightStickY: 255,
        buttons1: 0x30,
        buttons2: 0x03,
        leftTrigger: 255,
        rightTrigger: 128
      )
    )

    let expectedLeftStick = ControllerEvent.leftStickChanged(x: 127.0 / 128.0, y: -1.0)
    let expectedRightStick = ControllerEvent.rightStickChanged(x: -1.0, y: 127.0 / 128.0)
    let expectedLeftTrigger = ControllerEvent.leftTriggerChanged(1.0)
    let expectedRightTrigger = ControllerEvent.rightTriggerChanged(128.0 / 255.0)

    #expect(containsEvent(events, expectedLeftStick))
    #expect(containsEvent(events, expectedRightStick))
    #expect(containsEvent(events, expectedLeftTrigger))
    #expect(containsEvent(events, expectedRightTrigger))
    #expect(containsEvent(events, .buttonPressed(.share)))
    #expect(containsEvent(events, .buttonPressed(.options)))
    #expect(containsEvent(events, .buttonPressed(.ps)))
    #expect(containsEvent(events, .buttonPressed(.touchpad)))
  }
  @Test
  func testWiredIOHIDReportParsesDpadDirections() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let upEvents = try parser.parse(data: makeDS4Report(buttons0: 0x00))
    let rightEvents = try parser.parse(data: makeDS4Report(buttons0: 0x02))
    let downEvents = try parser.parse(data: makeDS4Report(buttons0: 0x04))
    let leftEvents = try parser.parse(data: makeDS4Report(buttons0: 0x06))

    #expect(containsEvent(upEvents, .dpadChanged(.north)))
    #expect(containsEvent(rightEvents, .dpadChanged(.east)))
    #expect(containsEvent(downEvents, .dpadChanged(.south)))
    #expect(containsEvent(leftEvents, .dpadChanged(.west)))
  }
  @Test
  func testSmallDS4StickJitterIsNormalizedToIdle() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let events = try parser.parse(
      data: makeDS4Report(leftStickX: 123, leftStickY: 126, rightStickX: 126, rightStickY: 130)
    )

    #expect(containsEvent(events, .leftStickChanged(x: 0, y: 0)))
    #expect(containsEvent(events, .rightStickChanged(x: 0, y: 0)))
  }

  private func assertFaceButtonContinuity(makeReport: (UInt8, UInt8, UInt8) -> Data) throws {
    let faceButtons: [(mask: UInt8, button: Button)] = [
      (0x10, .square), (0x20, .cross), (0x40, .circle), (0x80, .triangle),
    ]

    for faceButton in faceButtons {
      let parser = DS4Parser()
      _ = try parser.parse(data: makeReport(0x08, 128, 128))

      let pressed = try parser.parse(data: makeReport(0x08 | faceButton.mask, 128, 128))
      let held = try parser.parse(data: makeReport(0x08 | faceButton.mask, 255, 128))
      let released = try parser.parse(data: makeReport(0x08, 255, 128))
      let laterInput = try parser.parse(data: makeReport(0x08, 255, 0))

      #expect(pressed.contains(.buttonPressed(faceButton.button)))
      #expect(!held.contains(.buttonPressed(faceButton.button)))
      #expect(!held.contains(.buttonReleased(faceButton.button)))
      #expect(held.contains(.leftStickChanged(x: 127.0 / 128.0, y: 0)))
      #expect(released.contains(.buttonReleased(faceButton.button)))
      #expect(laterInput.contains(.rightStickChanged(x: -1, y: 0)))
    }
  }
  @Test
  func testObservedDS4LeftStickXDriftIsNormalizedToIdle() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let events = try parser.parse(data: makeDS4Report(leftStickX: 120))

    #expect(containsEvent(events, .leftStickChanged(x: 0, y: 0)))
  }
  @Test
  func testDs4StickReportsRawHIDNormalizedRange() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let events = try parser.parse(
      data: makeDS4Report(leftStickX: 254, leftStickY: 2, rightStickX: 2, rightStickY: 254)
    )

    let expectedLeftStick = ControllerEvent.leftStickChanged(x: 126.0 / 128.0, y: -126.0 / 128.0)
    let expectedRightStick = ControllerEvent.rightStickChanged(x: -126.0 / 128.0, y: 126.0 / 128.0)

    #expect(containsEvent(events, expectedLeftStick))
    #expect(containsEvent(events, expectedRightStick))
  }
  @Test
  func testBothStickYAxesReportUpCenterAndDown() throws {
    let parser = DS4Parser()

    let up = try parser.parse(data: makeDS4Report(leftStickY: 0, rightStickY: 0))
    let center = try parser.parse(data: makeDS4Report(leftStickY: 128, rightStickY: 128))
    let down = try parser.parse(data: makeDS4Report(leftStickY: 255, rightStickY: 255))

    #expect(containsEvent(up, .leftStickChanged(x: 0, y: -1)))
    #expect(containsEvent(up, .rightStickChanged(x: 0, y: -1)))
    #expect(containsEvent(center, .leftStickChanged(x: 0, y: 0)))
    #expect(containsEvent(center, .rightStickChanged(x: 0, y: 0)))
    #expect(containsEvent(down, .leftStickChanged(x: 0, y: 127.0 / 128.0)))
    #expect(containsEvent(down, .rightStickChanged(x: 0, y: 127.0 / 128.0)))
  }
}
