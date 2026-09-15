import Foundation
import IOKit.hid
import Testing

@testable import OpenJoystickDriverKit

extension PhysicalRumbleOutputTests {
  @Test
  func testDs4ColorReportsUseExactUsbAndBluetoothLayouts() {
    let usb = DS4Parser().physicalColorReport(red: 12, green: 34, blue: 56)
    #expect(usb.reportID == 0x05)
    #expect(usb.bytes.count == 32)
    #expect(usb.bytes[1] == 0x02)
    #expect(Array(usb.bytes[6...8]) == [12, 34, 56])

    let bluetooth = DS4Parser(prefersBluetooth: true).physicalColorReport(
      red: 12,
      green: 34,
      blue: 56
    )
    #expect(bluetooth.reportID == 0x11)
    #expect(bluetooth.bytes[1] == 0xC4)
    #expect(bluetooth.bytes[3] == 0x02)
    #expect(Array(bluetooth.bytes[8...10]) == [12, 34, 56])
    #expect(Array(bluetooth.bytes[74...77]) == [0xD7, 0xFA, 0x17, 0x24])
  }

  @Test
  func testDualSenseColorReportsUseExactUsbAndBluetoothLayouts() {
    let usb = DualSenseParser().physicalColorReport(red: 12, green: 34, blue: 56)
    #expect(usb.reportID == 0x02)
    #expect(usb.bytes.count == 63)
    #expect(usb.bytes[2] == 0x04)
    #expect(Array(usb.bytes[45...47]) == [12, 34, 56])

    let bluetooth = DualSenseParser(prefersBluetooth: true).physicalColorReport(
      red: 12,
      green: 34,
      blue: 56
    )
    #expect(bluetooth.reportID == 0x31)
    #expect(bluetooth.bytes[4] == 0x04)
    #expect(Array(bluetooth.bytes[47...49]) == [12, 34, 56])
    #expect(Array(bluetooth.bytes[74...77]) == [0x4C, 0x5A, 0x92, 0x60])
  }

  @Test
  func testDs4PhysicalRumbleReportUsesUSBHIDOutputReport() {
    let report = DS4Parser().physicalRumbleReport(left: 180, right: 90, lt: 255, rt: 64)

    #expect(report.reportID == 0x05)
    #expect(report.bytes.count == 32)
    #expect(report.bytes[0] == 0x05)
    #expect(report.bytes[1] == 0x01)
    #expect(report.bytes[4] == 90)
    #expect(report.bytes[5] == 180)
    #expect(report.bytes.dropFirst(6).allSatisfy { $0 == 0 })
  }

  @Test
  func testDs4PhysicalRumbleReportUsesBluetoothReportAfterBluetoothInput() throws {
    let parser = DS4Parser(prefersBluetooth: true)

    let report = parser.physicalRumbleReport(left: 180, right: 90, lt: 255, rt: 64)

    #expect(report.reportID == 0x11)
    #expect(report.bytes.count == 78)
    #expect(report.bytes[0] == 0x11)
    #expect(report.bytes[1] == 0xC4)
    #expect(report.bytes[3] == 0x01)
    #expect(report.bytes[6] == 90)
    #expect(report.bytes[7] == 180)
    #expect(report.bytes[74...77].contains { $0 != 0 })
  }

  @Test
  func testDs4PreferredBluetoothParserUsesBluetoothPhysicalRumbleBeforeInput() {
    let report = DS4Parser(prefersBluetooth: true).physicalRumbleReport(
      left: 180,
      right: 90,
      lt: 255,
      rt: 64
    )

    #expect(report.reportID == 0x11)
    #expect(report.bytes.count == 78)
    #expect(report.bytes[6] == 90)
    #expect(report.bytes[7] == 180)
  }

  func hasPhysicalRumble(_ parser: any InputParser) -> Bool {
    parser is PhysicalRumbleOutput || parser is PhysicalHIDRumbleOutput
      || parser is PhysicalHIDFeatureHapticOutput
  }
}
