import Testing

@testable import OpenJoystickDriverKit

struct ControllerProfileCapabilitiesTests {
  @Test
  func exactCatalogLookupDistinguishesKnownAndUnknownControllers() {
    let registry = ParserRegistry()
    let dualShock4 = registry.profileCapabilities(
      for: DeviceIdentifier(vendorID: 0x054C, productID: 0x05C4)
    )

    #expect(dualShock4?.physicalInput.rawMotion == true)
    #expect(dualShock4?.physicalInput.touchContactsPerFrame == 2)
    #expect(
      registry.profileCapabilities(for: DeviceIdentifier(vendorID: 0xFFFF, productID: 0xFFFF))
        == nil
    )
  }

  @Test
  func intersectionKeepsOnlyCapabilitiesSharedByEveryController() {
    let first = ControllerProfileCapabilities(
      physicalInput: PhysicalControllerInputCapabilities(
        rawMotion: true,
        touchContactsPerFrame: 2,
        additionalButtons: [.touchpad, .mute],
        touchSurfaces: [.primary, .left]
      ),
      physicalOutput: PhysicalControllerOutputCapabilities(
        rumbleMotors: [.leftMain, .rightMain],
        lightingFeatures: [.programmableColor, .programmableBrightness],
        adaptiveTriggers: [.left, .right]
      )
    )
    let second = ControllerProfileCapabilities(
      physicalInput: PhysicalControllerInputCapabilities(
        rawMotion: false,
        touchContactsPerFrame: 1,
        additionalButtons: [.touchpad],
        touchSurfaces: [.primary]
      ),
      physicalOutput: PhysicalControllerOutputCapabilities(
        rumbleMotors: [.rightMain],
        lightingFeatures: [.programmableColor],
        adaptiveTriggers: [.right]
      ),
      supportsStickAxes: false
    )

    let result = first.intersecting(second)
    #expect(!result.physicalInput.rawMotion)
    #expect(result.physicalInput.touchContactsPerFrame == 1)
    #expect(result.physicalInput.additionalButtons == [.touchpad])
    #expect(result.physicalInput.touchSurfaces == [.primary])
    #expect(result.physicalOutput.rumbleMotors == [.rightMain])
    #expect(result.physicalOutput.lightingFeatures == [.programmableColor])
    #expect(result.physicalOutput.adaptiveTriggers == [.right])
    #expect(!result.supportsStickAxes)
  }
}
