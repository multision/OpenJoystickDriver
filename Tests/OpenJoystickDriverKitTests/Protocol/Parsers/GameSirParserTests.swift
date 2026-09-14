import Foundation
import OpenJoystickDriverKit
import Testing

struct GameSirParserTests {
  @Test
  func enhancedReportMapsGameplayExtrasBatteryAndMotion() throws {
    let parser = GameSirParser(protocol: .enhancedHID, model: .g7Pro8K)
    _ = try parser.parse(data: enhanced())
    let events = try parser.parse(
      data: enhanced(
        leftX: 255,
        leftY: 0,
        rightX: 0,
        rightY: 255,
        face: 0x20 | 1,
        meta: 0x01,
        leftTrigger: 255,
        rightTrigger: 128,
        counter: 1,
        extras: 0x08 | 0x10 | 0x20 | 0x40 | 0x80,
        battery: 84,
        charging: true
      ),
      receivedAtNanoseconds: 1_000
    )

    #expect(events.contains(.buttonPressed(.a)))
    #expect(events.contains(.buttonPressed(.leftBumper)))
    #expect(events.contains(.dpadChanged(.northEast)))
    #expect(events.contains(.leftStickChanged(x: 1, y: 1)))
    #expect(events.contains(.rightStickChanged(x: -1, y: -1)))
    #expect(events.contains(.leftTriggerChanged(1)))
    #expect(events.contains(.buttonPressed(.leftPaddle)))
    #expect(events.contains(.buttonPressed(.rightPaddle)))
    #expect(events.contains(.buttonPressed(.leftGrip)))
    #expect(events.contains(.buttonPressed(.rightGrip)))
    #expect(events.contains(.buttonPressed(.leftFunction)))
    #expect(events.contains { if case .motionSample = $0 { true } else { false } })
    #expect(parser.batteryTelemetry?.percentage == 84)
    #expect(parser.batteryTelemetry?.chargingState == .charging)
  }

  @Test
  func enhancedMotionUsesCounterAndMalformedFramesPreserveState() throws {
    let parser = GameSirParser(protocol: .enhancedHID, model: .cyclone2)
    let pressed = enhanced(face: 0x20 | 7, counter: 9, extras: 0x08)
    let first = try parser.parse(data: pressed, receivedAtNanoseconds: 100)
    #expect(first.contains(.buttonPressed(.a)))
    #expect(first.contains(.dpadChanged(.northWest)))
    #expect(first.contains { if case .motionSample = $0 { true } else { false } })
    #expect(try parser.parse(data: Data([0x12, 1, 2])).isEmpty)
    let repeated = try parser.parse(data: pressed, receivedAtNanoseconds: 200)
    #expect(repeated.isEmpty)
    let released = try parser.parse(data: enhanced(counter: 10))
    #expect(released.contains(.buttonReleased(.a)))
    #expect(released.contains(.buttonReleased(.leftPaddle)))
    #expect(released.contains(.dpadChanged(.north)))
  }

  @Test
  func g7UsesStandardXInputForGameplayAndVendorStreamForExtras() throws {
    let parser = GameSirParser(protocol: .g7ProUSB, model: .g7Pro)
    var standard = [UInt8](repeating: 0, count: 20)
    standard[1] = 0x14
    standard[2] = 0x01
    standard[3] = 0x10
    standard[4] = 255
    let gameplay = try parser.parse(data: Data(standard))
    #expect(gameplay.contains(.buttonPressed(.a)))
    #expect(gameplay.contains(.dpadChanged(.north)))
    #expect(gameplay.contains(.leftTriggerChanged(1)))

    var telemetry = [UInt8](repeating: 0, count: 64)
    telemetry[0] = 0x10
    telemetry[3] = 0x3C
    telemetry[4] = 0xE0
    telemetry[32] = 1
    telemetry[33] = 73
    telemetry[60] = 0x08 | 0x40
    let extras = try parser.parse(data: Data(telemetry))
    #expect(extras == [.buttonPressed(.leftPaddle), .buttonPressed(.leftGrip)])
    #expect(parser.batteryTelemetry?.percentage == 73)
  }

  @Test
  func parserSpecificHeartbeatFramingAndCadence() {
    let enhanced = GameSirParser(protocol: .enhancedHID, model: .cyclone2)
    #expect(enhanced.hidPeriodicOutputIntervalNanoseconds == 500_000_000)
    #expect(Array(enhanced.hidPeriodicOutputReports()[0].bytes.prefix(2)) == [0x0F, 0xF2])
    #expect(enhanced.hidStartupReports().count == 2)

    let g7 = GameSirParser(protocol: .g7ProUSB, model: .g7Pro)
    #expect(g7.usbKeepAliveIntervalNanoseconds == 500_000_000)
    let first = g7.usbKeepAlivePacket()
    let second = g7.usbKeepAlivePacket()
    #expect(Array(first?.bytes.prefix(6) ?? []) == [0x0F, 0x00, 0x01, 0x02, 0xF2, 0x00])
    #expect(second?.bytes[2] == 2)
  }

  @Test
  func enhancedOutputsRequireCurrentSessionAndLightingSlot() throws {
    let parser = GameSirParser(protocol: .enhancedHID, model: .cyclone2)
    #expect(parser.physicalColorOutputPlan(red: 1, green: 2, blue: 3) == nil)
    _ = try parser.parse(data: enhanced())
    #expect(parser.physicalColorOutputPlan(red: 1, green: 2, blue: 3) == nil)
    var slot = [UInt8](repeating: 0, count: 64)
    slot[0] = 0x10
    slot[1] = 0x05
    slot[2] = 0x20
    slot[5] = 1
    slot[6] = 2
    _ = try parser.parse(data: Data(slot))

    let color = try #require(parser.physicalColorOutputPlan(red: 1, green: 2, blue: 3))
    #expect(color.reports.count == 4)
    #expect(
      Array(color.reports[0].bytes.prefix(10)) == [0x0F, 0x03, 0x20, 0x00, 0xF9, 48, 1, 5, 20, 100]
    )
    #expect(Array(color.reports[3].bytes.prefix(7)) == [0x0F, 0x03, 0x20, 0, 0, 1, 2])
    let brightness = try #require(parser.physicalBrightnessOutputPlan(255))
    #expect(Array(brightness.reports[0].bytes.prefix(7)) == [0x0F, 0x03, 0x20, 0, 0xFC, 1, 100])
    #expect(
      Array(parser.physicalRumbleReport(left: 7, right: 9, lt: 1, rt: 2).bytes.prefix(6)) == [
        0x0F, 0x20, 0x66, 0x55, 7, 9,
      ]
    )

    parser.resetProtocolState()
    #expect(parser.physicalBrightnessOutputPlan(100) == nil)
    #expect(parser.batteryTelemetry == nil)
  }

  @Test
  func eightKColorWritesAllQuadrantsAndBrightnessRegister() throws {
    let parser = GameSirParser(protocol: .enhancedHID, model: .g7Pro8K)
    _ = try parser.parse(data: enhanced())
    let color = try #require(parser.physicalColorOutputPlan(red: 255, green: 0, blue: 0))
    #expect(color.reports.count == 4)
    #expect(
      color.reports.map { Array($0.bytes[3...4]) } == [[0, 12], [0, 16], [0, 20], [0, 24]]
    )
    #expect(color.reports.allSatisfy { Array($0.bytes[6...8]) == [0, 0, 100] })
    let brightness = try #require(parser.physicalBrightnessOutputPlan(128))
    #expect(Array(brightness.reports[0].bytes.prefix(7)) == [0x0F, 0x03, 0x20, 0, 1, 1, 50])
  }

  @Test
  func g7ExposesOnlyDockBrightnessAfterGameplayStarts() throws {
    let parser = GameSirParser(protocol: .g7ProUSB, model: .g7Pro)
    #expect(parser.physicalRumbleMotors.isEmpty)
    #expect(parser.physicalLightingFeatures == [.programmableBrightness])
    #expect(parser.physicalBrightnessOutputPackets(255) == nil)
    var report = [UInt8](repeating: 0, count: 20)
    report[1] = 0x14
    _ = try parser.parse(data: Data(report))
    let packet = try #require(parser.physicalBrightnessOutputPackets(255)?.first)
    #expect(
      Array(packet.bytes.prefix(10)) == [0x0F, 0, 1, 0x3C, 0x03, 0x20, 0x01, 0xF9, 0x01, 100]
    )
  }

  private func enhanced(
    leftX: UInt8 = 128,
    leftY: UInt8 = 128,
    rightX: UInt8 = 128,
    rightY: UInt8 = 128,
    face: UInt8 = 0,
    meta: UInt8 = 0,
    leftTrigger: UInt8 = 0,
    rightTrigger: UInt8 = 0,
    counter: UInt8 = 0,
    extras: UInt8 = 0,
    battery: UInt8 = 50,
    charging: Bool = false
  ) -> Data {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 0x12
    report[1] = leftX
    report[2] = leftY
    report[3] = rightX
    report[4] = rightY
    report[5] = face
    report[6] = meta
    report[7] = counter
    report[8] = leftTrigger
    report[9] = rightTrigger
    report[35] = charging ? 1 : 0
    report[36] = battery
    report[60] = extras
    return Data(report)
  }
}

struct GameSirCatalogTests {
  @Test
  func routesSourceBackedIdentitiesWithoutChangingExistingLinuxPaths() {
    let registry = ParserRegistry()
    let g7: [UInt16] = [0x1003, 0x105D, 0x105E, 0x109B, 0x109C, 0x10BA]
    let enhanced: [UInt16] = [0x0575, 0x100B, 0x1053, 0x10C5, 0x10C6, 0x10C7, 0x10C8]
    for productID in g7 + enhanced {
      let identifier = DeviceIdentifier(vendorID: 0x3537, productID: productID)
      #expect(registry.parserName(for: identifier) == "GameSir")
      #expect(registry.parser(for: identifier) is GameSirParser)
    }
    #expect(
      registry.parserName(for: DeviceIdentifier(vendorID: 0x3537, productID: 0x1004)) == "XUSB"
    )
    #expect(
      registry.parserName(for: DeviceIdentifier(vendorID: 0x3537, productID: 0x100F)) == "XUSB"
    )
    #expect(
      registry.parserName(for: DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)) == "GIP"
    )
    for productID: UInt16 in [0x02FD, 0x02FF] {
      #expect(
        registry.parserName(for: DeviceIdentifier(vendorID: 0x045E, productID: productID))
          != "GameSir"
      )
    }
  }

  @Test
  func inputOnlyIdentitiesDoNotExposeConfigurationOutputs() {
    let registry = ParserRegistry()
    let transition = DeviceIdentifier(vendorID: 0x3537, productID: 0x100A)
    let native = DeviceIdentifier(vendorID: 0x3537, productID: 0x1022)
    #expect(registry.parser(for: transition) is GenericHIDParser)
    #expect((registry.parser(for: native) as? GIPParser)?.physicalRumbleMotors.isEmpty == true)
    #expect(registry.runtimeProfile(for: native).quirks == ["inputOnly"])
  }
}
