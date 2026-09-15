import Foundation
import ProtocolPacketFixtures
import OpenJoystickDriverKit

func runSteamStatusFallbackCheck() throws {
  let parser = SteamControllerParser(isWirelessReceiver: true)
  let statusEvents = try parser.parse(data: ProtocolPacketFixtures.Steam.statusReport)
  require(statusEvents.isEmpty, "Steam status report should not emit input events")
  require(
    parser.consumeInputConnectionStateChange() == .connected,
    "Steam status report should mark receiver connected"
  )
  let inputEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
  )
  require(
    hasEvent(inputEvents, .buttonPressed(.a)),
    "Steam input after status fallback should parse A press"
  )
}

func runSteamWirelessConnectDisconnectCheck() throws {
  let parser = SteamControllerParser(isWirelessReceiver: true)
  require(parser.requiresInputConnectionBeforeOutput, "Steam wireless receiver should gate output")

  let preConnectEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
  )
  require(preConnectEvents.isEmpty, "Steam wireless input before logical connect should be ignored")

  let connectEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x02)
  )
  require(connectEvents.isEmpty, "Steam wireless connect report should not emit input")
  require(
    parser.consumeInputConnectionStateChange() == .connected,
    "Steam wireless connect report should emit connected lifecycle"
  )
  require(
    parser.consumeInputConnectionStateChange() == nil,
    "Steam wireless lifecycle should be consumed once"
  )

  let inputEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
  )
  require(
    hasEvent(inputEvents, .buttonPressed(.a)),
    "Steam wireless input after connect should parse A press"
  )

  let disconnectEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.wirelessReport(status: 0x01)
  )
  require(disconnectEvents.isEmpty, "Steam wireless disconnect report should not emit input")
  require(
    parser.consumeInputConnectionStateChange() == .disconnected,
    "Steam wireless disconnect report should emit disconnected lifecycle"
  )

  let postDisconnectEvents = try parser.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0x80, 0, 0))
  )
  require(postDisconnectEvents.isEmpty, "Steam wireless input after disconnect should be ignored")
}

func runDS3InputChecks() throws {
  let parser = DS3Parser()
  _ = try parser.parse(data: ProtocolPacketFixtures.DS3.inputReport())
  let buttonEvents = try parser.parse(
    data: ProtocolPacketFixtures.DS3.inputReport(buttons: (0x3F, 0xFF, true))
  )
  for expected in [
    Button.back, .leftStick, .rightStick, .start, .l2Digital, .r2Digital, .l1, .r1, .triangle,
    .circle, .cross, .square, .ps,
  ] {
    require(
      hasEvent(buttonEvents, .buttonPressed(expected)),
      "DS3 primary input should press \(expected)"
    )
  }
  require(hasEvent(buttonEvents, .dpadChanged(.northEast)), "DS3 should parse d-pad north-east")

  let axisParser = DS3Parser()
  _ = try axisParser.parse(data: ProtocolPacketFixtures.DS3.inputReport())
  let axisEvents = try axisParser.parse(
    data: ProtocolPacketFixtures.DS3.inputReport(sticks: ((255, 0), (0, 255)), triggers: (255, 128))
  )
  require(hasEvent(axisEvents, .leftStickChanged(x: 1.0, y: 1.0)), "DS3 should parse left stick")
  require(
    hasEvent(axisEvents, .rightStickChanged(x: -1.0, y: -1.0)),
    "DS3 should parse right stick"
  )
  require(hasEvent(axisEvents, .leftTriggerChanged(1.0)), "DS3 should parse left analog trigger")
  require(
    hasEvent(axisEvents, .rightTriggerChanged(128.0 / 255.0)),
    "DS3 should parse right analog trigger"
  )
}

func runDS3TransportAndBluetoothCheck() throws {
  let parser = DS3Parser()
  require(
    parser.hidStartupFeatureReadRequests(transport: "USB") == [
      PhysicalHIDFeatureReadRequest(reportID: 0xF2, length: 17),
      PhysicalHIDFeatureReadRequest(reportID: 0xF5, length: 8),
    ],
    "DS3 USB startup reads should match Linux"
  )
  require(
    parser.hidStartupFeatureReadRequests(transport: "Bluetooth").isEmpty,
    "DS3 Bluetooth should not send USB feature reads"
  )
  require(
    parser.hidStartupFeatureReadRequests(transport: nil).isEmpty,
    "DS3 unknown transport should not send USB feature reads"
  )
  require(
    parser.hidStartupFeatureReports(transport: "USB").isEmpty,
    "DS3 USB should not send Bluetooth feature report"
  )
  require(
    parser.hidStartupFeatureReports(transport: "Bluetooth") == [
      PhysicalHIDOutputReport(
        reportID: ProtocolPacketFixtures.DS3.bluetoothOperationalReportID,
        bytes: ProtocolPacketFixtures.DS3.bluetoothOperationalReport
      )
    ],
    "DS3 Bluetooth operational feature report should match Linux"
  )
  var bogus = Array(
    ProtocolPacketFixtures.DS3.inputReport(
      buttons: (0x10, 0x40, false),
      sticks: ((255, 128), (128, 128)),
      triggers: (255, 0)
    )
  )
  bogus[1] = 0xFF
  let events = try parser.parse(data: Data(bogus))
  require(events.isEmpty, "DS3 bogus Bluetooth status report should be ignored")
}

func runDualSenseUSBChecks() throws {
  let parser = ParserRegistry().parser(for: DeviceIdentifier(vendorID: 1356, productID: 3302))
  _ = try parser.parse(data: ProtocolPacketFixtures.DualSense.usbInputReport())
  let events = try parser.parse(
    data: ProtocolPacketFixtures.DualSense.usbInputReport(
      sticks: ((255, 0), (0, 255)),
      triggers: (255, 128),
      buttons: (0x28, 0x30, 0x03)
    )
  )
  require(
    hasEvent(events, .leftStickChanged(x: 1.0, y: 1.0)),
    "DualSense USB should parse left stick"
  )
  require(
    hasEvent(events, .rightStickChanged(x: -1.0, y: -1.0)),
    "DualSense USB should parse right stick"
  )
  require(hasEvent(events, .leftTriggerChanged(1.0)), "DualSense USB should parse left trigger")
  require(
    hasEvent(events, .rightTriggerChanged(128.0 / 255.0)),
    "DualSense USB should parse right trigger"
  )
  for expected in [Button.cross, .share, .options, .ps, .touchpad] {
    require(hasEvent(events, .buttonPressed(expected)), "DualSense USB should press \(expected)")
  }

  let micParser = DualSenseParser()
  _ = try micParser.parse(data: ProtocolPacketFixtures.DualSense.usbInputReport())
  let micEvents = try micParser.parse(
    data: ProtocolPacketFixtures.DualSense.usbInputReport(buttons: (0x08, 0, 0x04))
  )
  require(hasEvent(micEvents, .buttonPressed(.mute)), "DualSense USB should parse mic mute")
}

func runDualSenseUnknownReportCheck() throws {
  let parser = DualSenseParser()
  var report = [UInt8](repeating: 0, count: 64)
  report[0] = 0x02
  report[1] = 255
  report[2] = 0
  report[5] = 255
  report[8] = 0x28
  let events = try parser.parse(data: Data(report))
  require(events.isEmpty, "DualSense unknown report IDs should be ignored")
}

func runDualSenseBluetoothCRCCheck() throws {
  let parser = DualSenseParser()
  _ = try parser.parse(data: ProtocolPacketFixtures.DualSense.bluetoothInputReport())
  let events = try parser.parse(
    data: ProtocolPacketFixtures.DualSense.bluetoothInputReport(
      sticks: ((255, 0), (0, 255)),
      triggers: (255, 128),
      buttons: (0x28, 0x30, 0x07)
    )
  )
  require(
    hasEvent(events, .leftStickChanged(x: 1.0, y: 1.0)),
    "DualSense Bluetooth should parse left stick"
  )
  require(
    hasEvent(events, .rightStickChanged(x: -1.0, y: -1.0)),
    "DualSense Bluetooth should parse right stick"
  )
  require(
    hasEvent(events, .leftTriggerChanged(1.0)),
    "DualSense Bluetooth should parse left trigger"
  )
  require(
    hasEvent(events, .rightTriggerChanged(128.0 / 255.0)),
    "DualSense Bluetooth should parse right trigger"
  )
  require(hasEvent(events, .buttonPressed(.cross)), "DualSense Bluetooth should parse Cross")
  require(hasEvent(events, .buttonPressed(.share)), "DualSense Bluetooth should parse Create/Share")
  require(hasEvent(events, .buttonPressed(.options)), "DualSense Bluetooth should parse Options")
  require(hasEvent(events, .buttonPressed(.ps)), "DualSense Bluetooth should parse PS")
  require(hasEvent(events, .buttonPressed(.touchpad)), "DualSense Bluetooth should parse touchpad")
  require(hasEvent(events, .buttonPressed(.mute)), "DualSense Bluetooth should parse mic mute")

  var badCRC = Array(ProtocolPacketFixtures.DualSense.bluetoothInputReport(buttons: (0x28, 0, 0)))
  badCRC[77] ^= 0xFF
  do {
    _ = try parser.parse(data: Data(badCRC))
    require(false, "DualSense Bluetooth invalid CRC should throw")
  } catch let error as DualSenseParserError {
    require(
      error == .invalidBluetoothCRC,
      "DualSense Bluetooth invalid CRC should throw invalidBluetoothCRC"
    )
  }
}

func runSwitchProTransportAndMappingCheck() throws {
  let parser = SwitchProParser()
  let bluetoothStartup = parser.hidStartupReports(transport: "Bluetooth")
  require(
    bluetoothStartup.map(\.reportID) == ProtocolPacketFixtures.SwitchPro.bluetoothStartupReportIDs,
    "Switch Pro Bluetooth should send subcommand startup reports"
  )
  require(
    bluetoothStartup.map { $0.bytes[10] }
      == ProtocolPacketFixtures.SwitchPro.bluetoothStartupSubcommands,
    "Switch Pro Bluetooth startup should select full reports, enable IMU and rumble, "
      + "and request calibration"
  )
  require(
    parser.hidStartupReports(transport: nil).isEmpty,
    "Switch Pro unknown transport should skip USB startup reports"
  )
  require(
    parser.hidStartupReports(transport: "USB").map(\.reportID)
      == ProtocolPacketFixtures.SwitchPro.usbStartupReportIDs,
    "Switch Pro USB startup report IDs should match Linux init slice"
  )

  let expectations: [(UInt32, Button)] = [
    (0x0000_0008, .b), (0x0000_0004, .a), (0x0000_0002, .y), (0x0000_0001, .x),
  ]
  for (mask, button) in expectations {
    let parser = SwitchProParser()
    _ = try parser.parse(data: ProtocolPacketFixtures.SwitchPro.inputReport())
    let events = try parser.parse(data: ProtocolPacketFixtures.SwitchPro.inputReport(buttons: mask))
    require(
      hasEvent(events, .buttonPressed(button)),
      "Switch Pro face-button mask \(mask) should map to \(button)"
    )
  }

  let inputParser = SwitchProParser()
  _ = try inputParser.parse(data: ProtocolPacketFixtures.SwitchPro.inputReport())
  let allPrimaryButtons: UInt32 = 0x00CA_3FCF
  let buttonEvents = try inputParser.parse(
    data: ProtocolPacketFixtures.SwitchPro.inputReport(buttons: allPrimaryButtons)
  )
  for expected in [
    Button.a, .b, .x, .y, .leftBumper, .rightBumper, .l2Digital, .r2Digital, .back, .start,
    .leftStick, .rightStick, .guide, .share,
  ] {
    require(
      hasEvent(buttonEvents, .buttonPressed(expected)),
      "Switch Pro primary input should press \(expected)"
    )
  }
  require(
    hasEvent(buttonEvents, .dpadChanged(.northWest)),
    "Switch Pro should parse d-pad north-west"
  )

  let stickParser = SwitchProParser()
  _ = try stickParser.parse(data: ProtocolPacketFixtures.SwitchPro.inputReport())
  let stickEvents = try stickParser.parse(
    data: ProtocolPacketFixtures.SwitchPro.inputReport(sticks: ((4095, 0), (0, 4095)))
  )
  require(
    hasEvent(stickEvents, .leftStickChanged(x: 1.0, y: 1.0)),
    "Switch Pro should parse left 12-bit stick"
  )
  require(
    hasEvent(stickEvents, .rightStickChanged(x: -1.0, y: -1.0)),
    "Switch Pro should parse right 12-bit stick"
  )

  let startupReports = SwitchProParser().hidStartupReports()
  require(
    startupReports.map(\.reportID) == ProtocolPacketFixtures.SwitchPro.usbStartupReportIDs,
    "Switch Pro USB startup report IDs should match Linux"
  )
  require(
    startupReports.map { Array($0.bytes.prefix(2)) } == [
      [0x80, 0x02], [0x80, 0x03], [0x80, 0x02], [0x80, 0x04], [0x01, 0x00], [0x01, 0x01],
      [0x01, 0x02], [0x01, 0x03], [0x01, 0x04],
    ],
    "Switch Pro USB startup reports should match Linux init prefixes"
  )
  require(
    startupReports[4].bytes[10] == 0x03,
    "Switch Pro startup should set full report mode subcommand"
  )
  require(
    startupReports[4].bytes[11] == 0x30,
    "Switch Pro startup should request full report mode 0x30"
  )
  require(startupReports[5].bytes[10] == 0x40, "Switch Pro startup should enable IMU")
  require(
    startupReports[6].bytes[10] == 0x48 && startupReports[6].bytes[11] == 1,
    "Switch Pro startup should enable rumble"
  )
  require(startupReports[5].bytes[11] == 0x01, "Switch Pro startup should enable IMU data")
}

func makeXIDReport(digital: UInt8 = 0, analogA: UInt8 = 0) -> Data {
  var report = [UInt8](repeating: 0, count: 20)
  report[1] = 0x14
  report[2] = digital
  report[4] = analogA
  return Data(report)
}
