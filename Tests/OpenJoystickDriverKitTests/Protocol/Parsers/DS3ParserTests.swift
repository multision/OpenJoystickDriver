import Foundation
import ProtocolPacketFixtures
import Testing

@testable import OpenJoystickDriverKit

private func eventExists(_ events: [ControllerEvent], _ expected: ControllerEvent) -> Bool {
  events.contains(expected)
}

struct DS3ParserTests {
  @Test
  func testDS3ProfileIsExperimentalAndUnverified() {
    let registry = ParserRegistry()
    let identifier = DeviceIdentifier(vendorID: 1356, productID: 616)
    let profile = registry.runtimeProfile(for: identifier)

    #expect(registry.parserName(for: identifier) == "DS3")
    #expect(profile.protocolVariant == .dualShock3)
    #expect(profile.quirks.isEmpty)
    #expect(registry.transportProfile(for: identifier).inputEndpoint == 0x82)
    #expect(registry.transportProfile(for: identifier).outputEndpoint == 0x02)
  }

  @Test
  func testDS3ReportParsesPrimaryButtonsAndDpad() throws {
    let parser = DS3Parser()
    _ = try parser.parse(data: ProtocolPacketFixtures.DS3.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.DS3.inputReport(buttons: (0x3F, 0xFF, true))
    )

    #expect(eventExists(events, .buttonPressed(.back)))
    #expect(eventExists(events, .buttonPressed(.leftStick)))
    #expect(eventExists(events, .buttonPressed(.rightStick)))
    #expect(eventExists(events, .buttonPressed(.start)))
    #expect(eventExists(events, .buttonPressed(.l2Digital)))
    #expect(eventExists(events, .buttonPressed(.r2Digital)))
    #expect(eventExists(events, .buttonPressed(.l1)))
    #expect(eventExists(events, .buttonPressed(.r1)))
    #expect(eventExists(events, .buttonPressed(.triangle)))
    #expect(eventExists(events, .buttonPressed(.circle)))
    #expect(eventExists(events, .buttonPressed(.cross)))
    #expect(eventExists(events, .buttonPressed(.square)))
    #expect(eventExists(events, .buttonPressed(.ps)))
    #expect(eventExists(events, .dpadChanged(.northEast)))
  }

  @Test
  func testDS3ReportParsesSticksAndAnalogTriggers() throws {
    let parser = DS3Parser()
    _ = try parser.parse(data: ProtocolPacketFixtures.DS3.inputReport())

    let events = try parser.parse(
      data: ProtocolPacketFixtures.DS3.inputReport(
        sticks: ((255, 0), (0, 255)),
        triggers: (255, 128)
      )
    )

    #expect(eventExists(events, .leftStickChanged(x: 1.0, y: 1.0)))
    #expect(eventExists(events, .rightStickChanged(x: -1.0, y: -1.0)))
    #expect(eventExists(events, .leftTriggerChanged(1.0)))
    #expect(eventExists(events, .rightTriggerChanged(128.0 / 255.0)))
  }

  @Test
  func testDS3OperationalFeatureReadRequestsMatchLinuxUsbInitNeed() {
    let requests = DS3Parser().hidStartupFeatureReadRequests()

    #expect(
      requests == [
        PhysicalHIDFeatureReadRequest(reportID: 0xF2, length: 17),
        PhysicalHIDFeatureReadRequest(reportID: 0xF5, length: 8),
      ]
    )
  }

  @Test
  func testDS3StartupReportsAreTransportScoped() {
    let parser = DS3Parser()

    #expect(
      parser.hidStartupFeatureReadRequests(transport: "USB") == [
        PhysicalHIDFeatureReadRequest(reportID: 0xF2, length: 17),
        PhysicalHIDFeatureReadRequest(reportID: 0xF5, length: 8),
      ]
    )
    #expect(parser.hidStartupFeatureReadRequests(transport: "Bluetooth").isEmpty)
    #expect(parser.hidStartupFeatureReadRequests(transport: nil).isEmpty)
    #expect(parser.hidStartupFeatureReports(transport: "USB").isEmpty)
    #expect(
      parser.hidStartupFeatureReports(transport: "Bluetooth") == [
        PhysicalHIDOutputReport(
          reportID: ProtocolPacketFixtures.DS3.bluetoothOperationalReportID,
          bytes: ProtocolPacketFixtures.DS3.bluetoothOperationalReport
        )
      ]
    )
  }

  @Test
  func testDS3IgnoresBogusBluetoothStatusReport() throws {
    let parser = DS3Parser()
    var report = Array(
      ProtocolPacketFixtures.DS3.inputReport(
        buttons: (0x10, 0x40, false),
        sticks: ((255, 128), (128, 128)),
        triggers: (255, 0)
      )
    )
    report[1] = 0xFF

    let events = try parser.parse(data: Data(report))

    #expect(events.isEmpty)
  }

  @Test
  func testDS3IgnoresUnsupportedReports() throws {
    let parser = DS3Parser()
    let events = try parser.parse(data: Data([0x02, 0, 0, 0]))

    #expect(events.isEmpty)
  }
}
