import Foundation
import IOKit.hid
import Testing

@testable import OpenJoystickDriverKit

extension VirtualControllerBackendTests {
  @Test
  func testGameControllerHIDBackendCapability() {
    let capabilities = VirtualControllerBackendCatalog.gameControllerHIDCapabilities

    #expect(capabilities.isImplemented)
    #expect(capabilities.isSystemWide)
    #expect(capabilities.publishesConsumerGamepad)
    #expect(VirtualControllerBackendID.allCases.contains(.gameControllerHID))
    #expect(!capabilities.notes.isEmpty)
  }

  @Test
  func testCompatibilityIdentityIDs() {
    #expect(CompatibilityIdentity(rawValue: "generic-hid") == .genericHID)
    #expect(CompatibilityIdentity(rawValue: "sdl2-3") == .sdl2_3)
    #expect(CompatibilityIdentity(rawValue: "apple-gamecontroller") == .appleGameController)
    #expect(CompatibilityIdentity(rawValue: "xone-hid") == nil)
    #expect(CompatibilityIdentity(rawValue: "xbox360-hid") == .xbox360HID)
    #expect(CompatibilityIdentity(rawValue: "dualshock4") == .dualShock4)
    #expect(CompatibilityIdentity(rawValue: "dualsense") == .dualSense)
    #expect(CompatibilityIdentity(rawValue: "switchpro") == .switchPro)
    #expect(CompatibilityIdentity.allCases.contains(.xbox360HID))
    #expect(CompatibilityIdentity.allCases.count == 8)

    #expect(CompatibilityIdentity(rawValue: "not-a-profile") == nil)
  }

  @Test
  func unknownPersistedIdentitySanitizesToAutomatic() {
    let persistence = CompatibilityIdentity.persisted(from: "xone-hid")

    #expect(persistence.identity == .automatic)
    #expect(persistence.didRewrite)
  }

  @Test
  func unknownIdentityIsRejectedForNewMutation() {
    #expect(CompatibilityIdentity.mutationDecision(for: "xone-hid") == .rejected(.unknownIdentity))
  }

  @Test
  func selectableIdentitiesRemainAcceptedForMutation() {
    for identity in CompatibilityIdentity.allCases {
      #expect(identity.mutationDecision() == .accepted(identity))
    }
    #expect(
      CompatibilityIdentity.mutationDecision(for: "not-a-profile") == .rejected(.unknownIdentity)
    )
  }

  @Test
  func testUserSpaceSerialUsesStableHashedPhysicalIdentity() {
    let identifier = DeviceIdentifier(
      vendorID: 13623,
      productID: 4112,
      serialNumber: "physical-serial"
    )
    let serial = UserSpaceVirtualDeviceConstants.serialNumber(for: identifier)

    #expect(serial.hasPrefix(UserSpaceVirtualDeviceConstants.serialPrefix))
    #expect(serial.count == UserSpaceVirtualDeviceConstants.serialPrefix.count + 16)
    #expect(serial.suffix(16).allSatisfy { $0.isHexDigit })
    #expect(serial == UserSpaceVirtualDeviceConstants.serialNumber(for: identifier))
  }

  @Test
  func testCompatibilityProfileCatalog() {
    let generic = CompatibilityOutputProfileCatalog.profile(for: .genericHID)
    let sdl = CompatibilityOutputProfileCatalog.profile(for: .sdl2_3)
    let apple = CompatibilityOutputProfileCatalog.profile(for: .appleGameController)
    let xbox360 = CompatibilityOutputProfileCatalog.profile(for: .xbox360HID)

    #expect(generic.deviceProfile.productID == 0x4449)
    #expect(sdl.deviceProfile == .xbox360Wired)
    #expect(apple.deviceProfile == .xboxSeries)
    #expect(apple.deviceProfile.vendorID == 0x045E)
    #expect(apple.deviceProfile.productID == 0x0B13)
    #expect(apple.deviceProfile.transport == "Bluetooth")
    #expect(!generic.isHardwareSpoof)
    #expect(sdl.isHardwareSpoof)
    #expect(apple.isHardwareSpoof)
    #expect(sdl.deviceProfile.vendorID == 0x045E)
    #expect(sdl.deviceProfile.productID == 0x028E)
    #expect(sdl.deviceProfile.productName == "Xbox 360 Wired Controller")
    #expect(!apple.emitsXboxGuideReport)
    #expect(apple.evidence == .sourceBacked)
    #expect(sdl.evidence == .sourceBacked)
    #expect(generic.consumerFamily == .genericHID)
    #expect(sdl.consumerFamily == .sdlHIDAPI)
    #expect(sdl.automaticallyRecommended)
    #expect(!apple.automaticallyRecommended)
    #expect(apple.consumerFamily == .appleGameController)
    #expect(apple.evidenceByConsumer[.blinkGamepad] == .hardwareVerified)
    #expect(apple.evidenceByConsumer[.geckoGamepad] == .reportedFailure)
    #expect(xbox360.deviceProfile == .xbox360Wired)
    #expect(xbox360.consumerFamily == .xbox360HID)
    #expect(xbox360.displayName == "Xbox 360 HID")
    #expect(xbox360.evidence == .researchOnly)
    let ds4 = CompatibilityOutputProfileCatalog.profile(for: .dualShock4)
    let dualSense = CompatibilityOutputProfileCatalog.profile(for: .dualSense)
    #expect(ds4.deviceProfile == .dualShock4USB)
    #expect(ds4.deviceProfile.vendorID == 0x054C)
    #expect(ds4.deviceProfile.productID == 0x09CC)
    #expect(ds4.deviceProfile.productName == VirtualDeviceProfile.dualShock4USB.productName)
    #expect(ds4.deviceProfile.productName == "Wireless Controller")
    #expect(dualSense.deviceProfile == .dualSenseUSB)
    #expect(dualSense.deviceProfile.productID == 0x0CE6)
    #expect(dualSense.deviceProfile.productName == VirtualDeviceProfile.dualSenseUSB.productName)
    #expect(dualSense.deviceProfile.productName == "Wireless Controller")
    let switchPro = CompatibilityOutputProfileCatalog.profile(for: .switchPro)
    #expect(switchPro.deviceProfile == .switchProUSB)
    #expect(switchPro.deviceProfile.productID == 0x2009)
    #expect(switchPro.deviceProfile.productName == VirtualDeviceProfile.switchProUSB.productName)
    #expect(switchPro.deviceProfile.productName == "Pro Controller")
    #expect(apple.deviceProfile.productName == VirtualDeviceProfile.xboxSeries.productName)
    #expect(apple.deviceProfile.productName == "Xbox Wireless Controller")
    #expect(CompatibilityEvidenceStatus.reportedFailure != .hardwareVerified)
    #expect(CompatibilityEvidenceStatus.researchOnly != .sourceBacked)
  }

  @Test
  func automaticResolverPreservesPhysicalFamilyBoundaries() {
    let xbox = ApplicationServiceDeviceDescription(
      name: "GameSir G7 SE",
      vendorID: 0x3537,
      productID: 0x1010,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    let otherXbox = ApplicationServiceDeviceDescription(
      name: "Xbox One",
      vendorID: 0x045E,
      productID: 0x02FD,
      parser: "GIP",
      connection: "Bluetooth",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    let nintendo = ApplicationServiceDeviceDescription(
      name: "Switch",
      vendorID: 0x057E,
      productID: 0x2009,
      parser: "SwitchPro",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .switchPro
    )
    let ds4 = ApplicationServiceDeviceDescription(
      name: "DualShock 4",
      vendorID: 0x054C,
      productID: 0x05C4,
      parser: "DS4",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .dualShock4
    )
    let xinput = ApplicationServiceDeviceDescription(
      name: "XInput device",
      vendorID: 1,
      productID: 2,
      parser: "XInput",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    let xusb = ApplicationServiceDeviceDescription(
      name: "XUSB device",
      vendorID: 3,
      productID: 4,
      parser: "XUSB",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    #expect(AutomaticCompatibilityResolver.resolve(for: xbox).identity == .appleGameController)
    #expect(AutomaticCompatibilityResolver.resolve(for: otherXbox).identity == .appleGameController)
    #expect(AutomaticCompatibilityResolver.resolve(for: nintendo).identity == .switchPro)
    #expect(AutomaticCompatibilityResolver.resolve(for: ds4).identity == .dualShock4)
    let steam = ApplicationServiceDeviceDescription(
      name: "Steam Controller",
      vendorID: 0x28DE,
      productID: 0x1102,
      parser: "SteamController",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .steamController
    )
    let genericHID = ApplicationServiceDeviceDescription(
      name: "Generic",
      vendorID: 0x0001,
      productID: 0x0001,
      parser: "GenericHID",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .genericHID
    )
    #expect(AutomaticCompatibilityResolver.resolve(for: steam).identity == .genericHID)
    #expect(AutomaticCompatibilityResolver.resolve(for: genericHID).identity == .genericHID)
    #expect(
      AutomaticCompatibilityResolver.resolve(for: xbox, consumer: .sdlHIDAPI).subfamily == .gip
    )
    #expect(
      AutomaticCompatibilityResolver.resolve(for: otherXbox, consumer: .appleGameController)
        .consumer == .appleGameController
    )
    #expect(AutomaticCompatibilityResolver.resolve(for: xinput).subfamily == .gip)
    #expect(AutomaticCompatibilityResolver.resolve(for: xusb).subfamily == .gip)
    let wired360 = ApplicationServiceDeviceDescription(
      name: "Xbox 360",
      vendorID: 0x045E,
      productID: 0x028E,
      parser: "XUSB",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xbox360
    )
    #expect(AutomaticCompatibilityResolver.resolve(for: wired360).subfamily == .xusb)
    let idle360 = AutomaticCompatibilityResolver.resolve(for: wired360)
    #expect(idle360.identity == .sdl2_3)
    #expect(idle360.reason == .selectedExplicitIdentity)
    #expect(idle360.evidence == .sourceBacked)
    let steam360 = AutomaticCompatibilityResolver.resolve(for: wired360, consumer: .sdlHIDAPI)
    #expect(steam360.identity == .sdl2_3)
    #expect(steam360.reason == .selectedExplicitIdentity)
    #expect(steam360.evidence == .sourceBacked)
    for consumer: CompatibilityConsumerFamily in [
      .blinkGamepad, .webkitGamepad, .geckoGamepad, .unknownBrowserGamepad, .genericHID,
      .appleGameController,
    ] {
      let resolved = AutomaticCompatibilityResolver.resolve(for: wired360, consumer: consumer)
      #expect(resolved.identity == .sdl2_3)
      #expect(resolved.reason == .selectedExplicitIdentity)
    }
    let clone360 = ApplicationServiceDeviceDescription(
      name: "Xbox 360 clone",
      vendorID: 0x413D,
      productID: 0x2104,
      parser: "XUSB",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xbox360
    )
    let clone = AutomaticCompatibilityResolver.resolve(for: clone360, consumer: .sdlHIDAPI)
    #expect(clone.identity == .sdl2_3)
    #expect(clone.subfamily == .xusb)
    #expect(clone.reason == .selectedFamilyIdentity)
    #expect(
      CompatibilityOutputProfileCatalog.profile(for: clone.identity).deviceProfile == .xbox360Wired
    )
    let gipSDL = AutomaticCompatibilityResolver.resolve(for: xbox, consumer: .sdlHIDAPI)
    #expect(gipSDL.identity == .appleGameController)
    #expect(gipSDL.reason == .selectedCatalogTuple)
    #expect(gipSDL.evidence == .sourceBacked)
    #expect(
      CompatibilityOutputProfileCatalog.profile(for: gipSDL.identity).deviceProfile == .xboxSeries
    )
    let g7Apple = AutomaticCompatibilityResolver.resolve(for: xbox, consumer: .appleGameController)
    #expect(g7Apple.identity == .appleGameController)
    #expect(g7Apple.evidence == .hardwareVerified)
    #expect(g7Apple.reason == .selectedCatalogTuple)
    #expect(AutomaticCompatibilityResolver.resolve(for: xbox).subfamily == .gip)
    #expect(AutomaticCompatibilityResolver.resolve(for: nintendo).subfamily != .gip)
    #expect(AutomaticCompatibilityResolver.resolve(for: ds4).subfamily != .gip)
    let failedBluetooth = AutomaticCompatibilityResolver.resolve(
      for: otherXbox,
      consumer: .sdlHIDAPI
    )
    #expect(failedBluetooth.identity == .genericHID)
    #expect(failedBluetooth.evidence == .reportedFailure)
    #expect(failedBluetooth.reason == .reportedConsumerFailure)

    let sameIdentityOverUSB = ApplicationServiceDeviceDescription(
      name: "Xbox One over USB",
      vendorID: 0x045E,
      productID: 0x02FD,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne
    )
    let usbResolution = AutomaticCompatibilityResolver.resolve(
      for: sameIdentityOverUSB,
      consumer: .sdlHIDAPI
    )
    #expect(usbResolution.identity == .appleGameController)
    #expect(usbResolution.evidence == .sourceBacked)
    #expect(usbResolution.reason == .selectedFamilyIdentity)
    #expect(usbResolution.subfamily == .gip)
  }

  @Test
  func compatibilityFactoryKeepsProtocolTuplesAtomic() throws {
    let apple = try CompatibilityOutputCompositionFactory.make(identity: .appleGameController)
    let sdl = try CompatibilityOutputCompositionFactory.make(identity: .sdl2_3)
    let xbox360 = try CompatibilityOutputCompositionFactory.make(identity: .xbox360HID)

    #expect(apple.profile.deviceProfile == .xboxSeries)
    #expect(apple.format.descriptor == XboxOneBluetoothHIDDescriptor.seriesDescriptor)
    #expect(apple.format.inputReportID == 1)
    #expect(apple.format.outputReportID == VirtualRumbleOutputReportParser.xboxOneReportID)
    #expect(!apple.profile.emitsXboxGuideReport)
    #expect(sdl.profile.deviceProfile == .xbox360Wired)
    #expect(sdl.format.descriptor == Xbox360MacHIDReportFormat().descriptor)
    #expect(xbox360.profile.deviceProfile == .xbox360Wired)
    #expect(
      xbox360.format.descriptor
        == Xbox360MacHIDReportFormat(topLevelUsage: UInt8(kHIDUsage_GD_GamePad)).descriptor
    )
  }

  @Test
  func guideDispatchUsesXboxGuideReportContract() {
    #expect(UserSpaceOutputDispatcher.xboxGuideReport(for: .buttonPressed(.guide)) == [0x02, 0x01])
    #expect(
      UserSpaceOutputDispatcher.xboxGuideReport(for: .buttonReleased(.guide)) == [0x02, 0x00]
    )
    #expect(UserSpaceOutputDispatcher.xboxGuideReport(for: .buttonPressed(.a)) == nil)
  }

  @Test
  func nonStandardButtonsKeepDistinctNormalizedBits() {
    let dispatcher = UserSpaceOutputDispatcher { _ in
      throw UserSpaceOutputDispatcher.CreationError.createFailed
    }

    #expect(dispatcher.buttonBit(for: .share) == 15)
    #expect(dispatcher.buttonBit(for: .mute) == nil)
    #expect(dispatcher.buttonBit(for: .touchpad) == nil)
  }

}
