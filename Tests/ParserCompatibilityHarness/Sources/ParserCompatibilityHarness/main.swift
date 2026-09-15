import Foundation
import ProtocolPacketFixtures
import OpenJoystickDriverKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

func hasEvent(_ events: [ControllerEvent], _ expected: ControllerEvent) -> Bool {
  events.contains(expected)
}

func runProfileMetadataChecks() {
  let registry = ParserRegistry()
  let ds3 = DeviceIdentifier(vendorID: 1356, productID: 616)
  let ds3Profile = registry.runtimeProfile(for: ds3)
  require(registry.parserName(for: ds3) == "DS3", "DS3 profile should select DS3 parser")
  require(ds3Profile.protocolVariant == .dualShock3, "DS3 profile should use dualShock3 variant")
  require(
    ds3Profile.quirks.isEmpty,
    "DS3 profile should not advertise unimplemented sensors or battery status"
  )

  for id in [
    DeviceIdentifier(vendorID: 1356, productID: 3302),
    DeviceIdentifier(vendorID: 1356, productID: 3570),
  ] {
    let profile = registry.runtimeProfile(for: id)
    require(registry.parserName(for: id) == "DualSense", "DualSense profile should select parser")
    require(profile.protocolVariant == .dualSense, "DualSense profile should use dualSense variant")
    require(
      profile.quirks == ["touchpad", "microphoneMute"]
        + (id.productID == 3570 ? ["edgeButtons"] : []),
      "DualSense profile should expose operational input flags"
    )
  }

  let steamWired = DeviceIdentifier(vendorID: 10462, productID: 4354)
  let steamWiredProfile = registry.runtimeProfile(for: steamWired)
  require(
    registry.parserName(for: steamWired) == "SteamController",
    "Steam wired should select parser"
  )
  require(steamWiredProfile.protocolVariant == .steamController, "Steam wired should use variant")
  require(
    steamWiredProfile.quirks == ["lizardMode", "trackpads"],
    "Steam wired profile should expose operational flags"
  )

  let steamWireless = DeviceIdentifier(vendorID: 10462, productID: 4418)
  let steamWirelessProfile = registry.runtimeProfile(for: steamWireless)
  require(
    registry.parserName(for: steamWireless) == "SteamController",
    "Steam wireless receiver should select parser"
  )
  require(
    steamWirelessProfile.protocolVariant == .steamController,
    "Steam wireless receiver should use variant"
  )
  require(
    steamWirelessProfile.quirks == ["lizardMode", "trackpads", "wirelessReceiver"],
    "Steam wireless receiver profile must retain wirelessReceiver lifecycle flag"
  )

  let switchPro = DeviceIdentifier(vendorID: 1406, productID: 8201)
  let switchProfile = registry.runtimeProfile(for: switchPro)
  require(
    registry.parserName(for: switchPro) == "SwitchPro",
    "Switch Pro profile should select parser"
  )
  require(switchProfile.protocolVariant == .switchPro, "Switch Pro profile should use variant")
  require(
    switchProfile.quirks == ["usbHandshake"],
    "Switch Pro profile should not advertise unimplemented calibration, rumble, or IMU"
  )
}

func runSteamInputAndFeatureChecks() throws {
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
  for expected in [
    Button.a, .b, .x, .y, .leftBumper, .rightBumper, .back, .guide, .start, .leftStick,
    .rightPadClick,
  ] {
    require(
      hasEvent(events, .buttonPressed(expected)),
      "Steam primary input should press \(expected)"
    )
  }
  require(hasEvent(events, .leftTriggerChanged(1.0)), "Steam should parse left trigger")
  require(hasEvent(events, .rightTriggerChanged(128.0 / 255.0)), "Steam should parse right trigger")
  require(hasEvent(events, .leftStickChanged(x: 1.0, y: 1.0)), "Steam should parse left stick")
  require(
    hasEvent(events, .rightStickChanged(x: -1.0, y: -1.0)),
    "Steam should parse right pad as right stick"
  )

  let leftPadOnly = SteamControllerParser()
  _ = try leftPadOnly.parse(data: ProtocolPacketFixtures.Steam.inputReport())
  let leftPadOnlyEvents = try leftPadOnly.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0, 0x08), left: (32767, -32767))
  )
  require(
    !hasEvent(leftPadOnlyEvents, .leftStickChanged(x: 1.0, y: 1.0)),
    "Steam left-pad-only coordinates should not create left-stick motion"
  )

  let leftPadAndJoy = SteamControllerParser()
  _ = try leftPadAndJoy.parse(data: ProtocolPacketFixtures.Steam.inputReport())
  let leftPadAndJoyEvents = try leftPadAndJoy.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0, 0x88), left: (32767, -32767))
  )
  require(
    !hasEvent(leftPadAndJoyEvents, .leftStickChanged(x: 1.0, y: 1.0)),
    "Steam interleaved pad coordinates must not overwrite the left stick"
  )

  let dpad = SteamControllerParser()
  _ = try dpad.parse(data: ProtocolPacketFixtures.Steam.inputReport())
  let upEvents = try dpad.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x01, 0))
  )
  let rightEvents = try dpad.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x02, 0))
  )
  let downEvents = try dpad.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x08, 0))
  )
  let leftEvents = try dpad.parse(
    data: ProtocolPacketFixtures.Steam.inputReport(buttons: (0, 0x04, 0))
  )
  require(hasEvent(upEvents, .dpadChanged(.north)), "Steam should parse d-pad north")
  require(hasEvent(rightEvents, .dpadChanged(.east)), "Steam should parse d-pad east")
  require(hasEvent(downEvents, .dpadChanged(.south)), "Steam should parse d-pad south")
  require(hasEvent(leftEvents, .dpadChanged(.west)), "Steam should parse d-pad west")

  let featureParser = SteamControllerParser()
  let startup = featureParser.hidStartupFeatureReports()
  require(startup.map(\.reportID) == [0, 0], "Steam lizard startup reports should use report ID 0")
  require(
    startup.map { $0.bytes.count } == [64, 64],
    "Steam lizard startup reports should be 64 bytes"
  )
  require(startup[0].bytes[0] == 0x81, "Steam startup should clear digital mappings")
  require(
    Array(startup[1].bytes.prefix(11)) == ProtocolPacketFixtures.Steam.startupSettingsPrefix,
    "Steam startup should disable trackpad mouse modes and request raw IMU data"
  )
  let shutdown = featureParser.hidShutdownFeatureReports()
  require(shutdown.map(\.reportID) == [0, 0], "Steam shutdown reports should use report ID 0")
  require(shutdown[0].bytes[0] == 0x85, "Steam shutdown should restore digital mappings")
  require(shutdown[1].bytes[0] == 0x8E, "Steam shutdown should load default settings")
}

runProfileMetadataChecks()
try runSteamInputAndFeatureChecks()
try runSteamStatusFallbackCheck()
try runSteamWirelessConnectDisconnectCheck()
try runDS3InputChecks()
try runDS3TransportAndBluetoothCheck()
try runDualSenseUSBChecks()
try runDualSenseUnknownReportCheck()
try runDualSenseBluetoothCRCCheck()
try runSwitchProTransportAndMappingCheck()
try runXIDInputChecks()
print("PASS: macOS-14-compatible parser harness")
