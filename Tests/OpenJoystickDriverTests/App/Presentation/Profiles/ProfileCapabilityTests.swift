import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

struct ProfileCapabilityTests {
  @Test
  func resolverIntersectsMatchingLiveDevicesBeforeUsingCatalog() {
    let profile = makeProfile(vendorID: 0x054C, productID: 0x05C4)
    let full = device(
      input: PhysicalControllerInputCapabilities(
        rawMotion: true,
        touchContactsPerFrame: 2,
        additionalButtons: [.touchpad],
        touchSurfaces: [.primary]
      ),
      output: PhysicalControllerOutputCapabilities(
        rumbleMotors: [.leftMain, .rightMain],
        lightingFeatures: [.programmableColor]
      )
    )
    let limited = device(
      input: .none,
      output: PhysicalControllerOutputCapabilities(rumbleMotors: [.leftMain]),
      quirks: ["sticksToNull", "triggersToButtons"]
    )

    let result = ProfileCapabilityResolver.resolve(
      profile: profile,
      connectedDevices: [full, limited],
      registry: ParserRegistry()
    )

    #expect(result?.physicalOutput.rumbleMotors == [.leftMain])
    #expect(result?.physicalInput == PhysicalControllerInputCapabilities.none)
    #expect(result?.supportsStickAxes == false)
    #expect(result?.supportsAnalogTriggers == false)
  }

  @Test
  func resolverUsesExactCatalogOfflineAndRejectsUnknownIdentity() {
    #expect(
      ProfileCapabilityResolver.resolve(
        profile: makeProfile(vendorID: 0x054C, productID: 0x05C4),
        connectedDevices: [],
        registry: ParserRegistry()
      )?.physicalInput.rawMotion == true
    )
    #expect(
      ProfileCapabilityResolver.resolve(
        profile: makeProfile(vendorID: 0xFFFF, productID: 0xFFFF),
        connectedDevices: [],
        registry: ParserRegistry()
      ) == nil
    )
  }

  @Test
  func sourceAndDestinationOptionsRetainUnsupportedCurrentValuesOnly() {
    let capabilities = ControllerProfileCapabilities(
      physicalInput: PhysicalControllerInputCapabilities(additionalButtons: [.leftPaddle]),
      physicalOutput: PhysicalControllerOutputCapabilities(
        rumbleMotors: [.leftMain],
        lightingFeatures: [.programmableColor]
      ),
      supportsStickAxes: false,
      supportsAnalogTriggers: false
    )

    #expect(ProfileCapabilityPolicy.supports(.button(.leftPaddle), capabilities: capabilities))
    #expect(!ProfileCapabilityPolicy.supports(.button(.rightPaddle), capabilities: capabilities))
    #expect(!ProfileCapabilityPolicy.supports(.axis(.leftStickX), capabilities: capabilities))
    #expect(!ProfileCapabilityPolicy.supports(.motionLean(.left), capabilities: capabilities))
    #expect(!ProfileCapabilityPolicy.supports(.touchContact(.primary), capabilities: capabilities))

    let retainedSources = SourceOption.options(
      including: .motionLean(.left),
      capabilities: capabilities
    )
    #expect(retainedSources.last?.source == .motionLean(.left))
    #expect(retainedSources.last?.isSupported == false)

    let retainedDestination = RemappingDestination.physical(.brightness(0.5))
    let destinations = DestinationOption.options(
      for: .button(.south),
      including: retainedDestination,
      capabilities: capabilities
    )
    #expect(
      destinations.contains { $0.destination == .physical(.rumble(motor: .leftMain, intensity: 1)) }
    )
    #expect(
      !destinations.contains {
        $0.destination == .physical(.rumble(motor: .rightMain, intensity: 1))
      }
    )
    #expect(destinations.last?.destination == retainedDestination)
    #expect(destinations.last?.isSupported == false)
  }

  private func makeProfile(vendorID: UInt16, productID: UInt16) -> RemappingProfile {
    RemappingProfile(
      name: "Capability test",
      device: RemappingDeviceScope(vendorID: vendorID, productID: productID),
      applicationScope: .global,
      bindings: []
    )
  }

  private func device(
    input: PhysicalControllerInputCapabilities,
    output: PhysicalControllerOutputCapabilities,
    quirks: [String] = []
  ) -> ApplicationServiceDeviceDescription {
    ApplicationServiceDeviceDescription(
      name: "Controller",
      vendorID: 0x054C,
      productID: 0x05C4,
      parser: "DS4",
      connection: "HID",
      serialNumber: nil,
      quirks: quirks,
      physicalOutputCapabilities: output,
      physicalInputCapabilities: input
    )
  }
}
