import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct VirtualIdentityPresentationTests {
  @Test
  func microsoftIdentitiesUseXboxSymbols() {
    #expect(VirtualDeviceProfile.xbox360Wired.presentation == .xbox)
    #expect(VirtualDeviceProfile.xboxSeries.presentation == .xbox)
    #expect(VirtualDeviceProfile.xbox360Wired.presentation.controllerSymbolName == "xbox.logo")
    #expect(VirtualDeviceProfile.xbox360Wired.versionNumber == 0x0114)
    #expect(VirtualDeviceProfile.xboxSeries.productName == "Xbox Wireless Controller")
  }

  @Test
  func sonyIdentitiesUsePlayStationSymbolsKeyedFromVID() {
    #expect(VirtualDeviceProfile.dualShock4USB.presentation == .playstation)
    #expect(VirtualDeviceProfile.dualSenseUSB.presentation == .playstation)
    #expect(VirtualDeviceProfile.dualShock4USB.productName == "Wireless Controller")
    #expect(VirtualDeviceProfile.dualSenseUSB.productName == "Wireless Controller")
    #expect(VirtualDeviceProfile.switchProUSB.presentation == .nintendo)
    #expect(VirtualDeviceProfile.switchProUSB.productName == "Pro Controller")
  }

  @Test
  func genericHIDUsesGenericSymbol() {
    #expect(VirtualDeviceProfile.openJoystickDriverGenericHID.presentation == .generic)
  }

  @Test
  func publishedIdentityFollowsRequestedSpoofWhenAvailable() {
    let gamesir = ApplicationServiceDeviceDescription(
      name: "GameSir",
      vendorID: 0x3537,
      productID: 0x1010,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    let automatic = PublishedVirtualIdentity.profile(for: gamesir, requested: .automatic)
    #expect(automatic == .xboxSeries)
    #expect(automatic.productName == "Xbox Wireless Controller")
    #expect(automatic.publishedUSBIdentityLabel == "Xbox Wireless Controller (045E:0B13)")
    #expect(automatic.presentation.glyphFamily == .xbox)
    #expect(automatic.presentation.controllerSymbolName == "xbox.logo")
    #expect(
      VirtualDeviceProfile.dualShock4USB.publishedUSBIdentityLabel
        == "Wireless Controller (054C:09CC)"
    )
    #expect(
      VirtualDeviceProfile.dualSenseUSB.publishedUSBIdentityLabel
        == "Wireless Controller (054C:0CE6)"
    )
    #expect(
      VirtualDeviceProfile.switchProUSB.publishedUSBIdentityLabel == "Pro Controller (057E:2009)"
    )
    #expect(
      VirtualDeviceProfile.xbox360Wired.publishedUSBIdentityLabel
        == "Xbox 360 Wired Controller (045E:028E)"
    )
    #expect(
      PublishedVirtualIdentity.profile(for: gamesir, requested: .dualShock4) == .dualShock4USB
    )
    #expect(
      PublishedVirtualIdentity.presentation(for: gamesir, requested: .dualShock4).glyphFamily
        == .playstation
    )

    let ds4 = ApplicationServiceDeviceDescription(
      name: "DualShock 4",
      vendorID: 0x054C,
      productID: 0x09CC,
      parser: "DS4",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .dualShock4
    )
    #expect(PublishedVirtualIdentity.profile(for: ds4, requested: .automatic) == .dualShock4USB)
    #expect(PublishedVirtualIdentity.profile(for: ds4, requested: .dualShock4) == .dualShock4USB)
    #expect(
      PublishedVirtualIdentity.presentation(for: ds4, requested: .automatic).glyphFamily
        == .playstation
    )

    let dualSense = ApplicationServiceDeviceDescription(
      name: "DualSense",
      vendorID: 0x054C,
      productID: 0x0CE6,
      parser: "DualSense",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .dualSense
    )
    #expect(
      PublishedVirtualIdentity.profile(for: dualSense, requested: .automatic) == .dualSenseUSB
    )
    #expect(
      PublishedVirtualIdentity.presentation(for: dualSense, requested: .automatic).glyphFamily
        == .playstation
    )
  }
}

struct SonyUSBHIDReportFormatTests {
  @Test
  func sonyUSBReportsDeclareWiredFullBatteryStatus() {
    let states = [
      VirtualGamepadState(),
      VirtualGamepadState(
        buttons: 1 << GamepadHIDDescriptor.ButtonBit.a.rawValue,
        leftTrigger: 32_767,
        rightTrigger: 16_384
      ),
    ]

    for state in states {
      let dualShock4 = DualShock4USBHIDReportFormat().buildInputReport(from: state)
      let dualSense = DualSenseUSBHIDReportFormat().buildInputReport(from: state)
      #expect(dualShock4[30] == 0x1B)
      #expect(dualSense[53] == 0x2A)
      #expect(dualSense[54] == 0x08)
    }
  }

  @Test
  func dualShock4USBReportPreservesRawYDirection() {
    // Arrange
    let format = DualShock4USBHIDReportFormat()

    // Act
    let up = format.buildInputReport(
      from: VirtualGamepadState(leftStickY: -32_767, rightStickY: -32_767)
    )
    let down = format.buildInputReport(
      from: VirtualGamepadState(leftStickY: 32_767, rightStickY: 32_767)
    )

    // Assert
    #expect(up[2] <= 1)
    #expect(up[4] <= 1)
    #expect(down[2] >= 254)
    #expect(down[4] >= 254)
  }

  @Test
  func dualSenseUSBReportPreservesRawYDirection() {
    // Arrange
    let format = DualSenseUSBHIDReportFormat()

    // Act
    let up = format.buildInputReport(
      from: VirtualGamepadState(leftStickY: -32_767, rightStickY: -32_767)
    )
    let down = format.buildInputReport(
      from: VirtualGamepadState(leftStickY: 32_767, rightStickY: 32_767)
    )

    // Assert
    #expect(up[2] <= 1)
    #expect(up[4] <= 1)
    #expect(down[2] >= 254)
    #expect(down[4] >= 254)
  }

  @Test
  func dualShock4USBReportParsesThroughDS4Parser() throws {
    var state = VirtualGamepadState()
    state.buttons =
      (1 << GamepadHIDDescriptor.ButtonBit.a.rawValue)
      | (1 << GamepadHIDDescriptor.ButtonBit.leftBumper.rawValue)
      | (1 << GamepadHIDDescriptor.ButtonBit.guide.rawValue)
    state.leftStickX = 16_383
    state.leftStickY = -16_384
    state.rightStickY = 16_384
    state.leftTrigger = 16_383
    let report = DualShock4USBHIDReportFormat().buildInputReport(from: state)
    #expect(report.count == 64)
    #expect(report[0] == 0x01)

    let parser = DS4Parser()
    let events = try parser.parse(data: Data(report))
    #expect(events.contains(.buttonPressed(.cross)))
    #expect(events.contains(.buttonPressed(.l1)))
    #expect(events.contains(.buttonPressed(.ps)))
    #expect(
      events.contains { event in
        guard case .leftStickChanged(_, let y) = event else { return false }
        return y < 0
      }
    )
    #expect(
      events.contains { event in
        guard case .rightStickChanged(_, let y) = event else { return false }
        return y > 0
      }
    )
  }

  @Test
  func dualSenseUSBReportParsesThroughDualSenseParser() throws {
    var state = VirtualGamepadState()
    state.buttons = 1 << GamepadHIDDescriptor.ButtonBit.y.rawValue
    let report = DualSenseUSBHIDReportFormat().buildInputReport(from: state)
    #expect(report.count == 64)
    #expect(report[0] == 0x01)

    let parser = DualSenseParser()
    let events = try parser.parse(data: Data(report))
    #expect(events.contains(.buttonPressed(.triangle)))
  }

  @Test
  func dualShock4USBDescriptorExposesSticksHatButtonsAndTriggers() throws {
    let parsed = try #require(
      HIDReportDescriptorParser.parse(descriptor: DualShock4USBHIDDescriptor.descriptor)
    )
    #expect(
      parsed.payloadSizeBytesByReportID[0x01] == DualShock4USBHIDDescriptor.inputReportLength - 1
    )
    let report1 = parsed.fields.filter { $0.reportID == 0x01 }
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x30 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x31 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x32 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x35 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x39 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x33 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x34 })
    #expect(report1.filter { $0.usagePage == 0x09 }.count == 14)
  }

  @Test
  func dualSenseUSBDescriptorExposesSixAxesHatAndButtons() throws {
    let parsed = try #require(
      HIDReportDescriptorParser.parse(descriptor: DualSenseUSBHIDDescriptor.descriptor)
    )
    #expect(
      parsed.payloadSizeBytesByReportID[0x01] == DualSenseUSBHIDDescriptor.inputReportLength - 1
    )
    let report1 = parsed.fields.filter { $0.reportID == 0x01 }
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x30 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x33 })
    #expect(report1.contains { $0.usagePage == 0x01 && $0.usage == 0x39 })
    #expect(report1.filter { $0.usagePage == 0x09 }.count == 15)
  }
}
