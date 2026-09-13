import Testing

@testable import OpenJoystickDriverKit

struct AutomaticCompatibilityTargetTests {
  private let xbox = ApplicationServiceDeviceDescription(
    name: "Xbox family",
    vendorID: 0x3537,
    productID: 0x1010,
    parser: "GIP",
    connection: "USB",
    serialNumber: nil,
    protocolVariant: .xboxOne
  )

  @Test
  func browserEnginesSelectOnlyTheAutomaticReportVariant() throws {
    let blink = AutomaticCompatibilityResolver.target(for: xbox, consumer: .blinkGamepad)
    let webkit = AutomaticCompatibilityResolver.target(for: xbox, consumer: .webkitGamepad)
    let unknownBrowser = AutomaticCompatibilityResolver.target(
      for: xbox,
      consumer: .unknownBrowserGamepad
    )
    let gecko = AutomaticCompatibilityResolver.target(for: xbox, consumer: .geckoGamepad)

    #expect(blink == .appleGameController)
    #expect(webkit == .appleGameController)
    #expect(unknownBrowser == .appleGameController)
    #expect(gecko.identity == .appleGameController)
    #expect(gecko.reportVariant == .geckoXboxOneS)
    #expect(
      try CompatibilityOutputCompositionFactory.make(target: blink).profile.deviceProfile
        == .xboxSeries
    )
    #expect(
      try CompatibilityOutputCompositionFactory.make(target: gecko).profile.deviceProfile
        == .firefoxXboxOneS
    )
  }

  @Test
  func automaticBrowserMatrixIsFamilyAware() {
    let knownBrowsers: [CompatibilityConsumerFamily] = [
      .blinkGamepad, .geckoGamepad, .webkitGamepad,
    ]
    let ds4 = device(.dualShock4)
    let dualSense = device(.dualSense)
    for browser in knownBrowsers {
      #expect(AutomaticCompatibilityResolver.target(for: ds4, consumer: browser) == .dualShock4)
      #expect(
        AutomaticCompatibilityResolver.target(for: dualSense, consumer: browser) == .dualSense
      )
    }
    #expect(
      AutomaticCompatibilityResolver.target(for: ds4, consumer: .unknownBrowserGamepad)
        == .appleGameController
    )
    #expect(
      AutomaticCompatibilityResolver.target(for: dualSense, consumer: .unknownBrowserGamepad)
        == .appleGameController
    )

    for variant: ControllerProtocolVariant in [
      .xid, .xbox360, .dualShock3, .switchPro, .steamController, .flydigi, .genericHID, .unknown,
    ] {
      let physical = device(variant)
      #expect(
        AutomaticCompatibilityResolver.target(for: physical, consumer: .blinkGamepad)
          == .appleGameController
      )
      #expect(
        AutomaticCompatibilityResolver.target(for: physical, consumer: .webkitGamepad)
          == .appleGameController
      )
      #expect(
        AutomaticCompatibilityResolver.target(for: physical, consumer: .unknownBrowserGamepad)
          == .appleGameController
      )
      #expect(
        AutomaticCompatibilityResolver.target(for: physical, consumer: .geckoGamepad)
          == AutomaticCompatibilityTarget(
            identity: .appleGameController,
            reportVariant: .geckoXboxOneS
          )
      )
    }
  }

  @Test
  func automaticDS4OutputPreservesConventionalYDirection() throws {
    let target = AutomaticCompatibilityResolver.target(
      for: device(.dualShock4),
      consumer: .blinkGamepad
    )
    let composition = try CompatibilityOutputCompositionFactory.make(target: target)
    let report = composition.format.buildInputReport(
      from: VirtualGamepadState(leftStickY: -32_767, rightStickY: 32_767)
    )

    #expect(target == .dualShock4)
    #expect(report[2] <= 1)
    #expect(report[4] >= 254)
  }

  @Test
  func nonBrowserRoutingDoesNotUseTheBrowserMatrix() {
    let switchPro = device(.switchPro)
    #expect(
      AutomaticCompatibilityResolver.target(for: switchPro, consumer: .sdlHIDAPI).identity
        == AutomaticCompatibilityResolver.resolve(for: switchPro, consumer: .sdlHIDAPI).identity
    )
    #expect(
      AutomaticCompatibilityResolver.target(for: switchPro, consumer: .unknown).identity
        == AutomaticCompatibilityResolver.resolve(for: switchPro, consumer: .unknown).identity
    )
  }

  @Test
  func explicitAppleGameControllerAlwaysUsesCanonicalXboxSeriesContract() throws {
    let explicit = try CompatibilityOutputCompositionFactory.make(identity: .appleGameController)

    #expect(explicit.profile.deviceProfile == .xboxSeries)
    #expect(explicit.format.descriptor == XboxOneBluetoothHIDDescriptor.seriesDescriptor)
  }

  @Test
  func geckoReportUsesHatOnlyDpadAndOmitsShareWithoutChangingAxes() throws {
    let target = AutomaticCompatibilityResolver.target(for: xbox, consumer: .geckoGamepad)
    let composition = try CompatibilityOutputCompositionFactory.make(target: target)
    let report = composition.format.buildInputReport(
      from: VirtualGamepadState(
        buttons: UInt32.max,
        leftStickX: 32_767,
        leftStickY: 16_384,
        rightStickX: -32_767,
        rightStickY: -16_384,
        leftTrigger: 32_767,
        rightTrigger: 16_384,
        hat: .east
      )
    )

    #expect(composition.profile.deviceProfile.vendorID == 0x045E)
    #expect(composition.profile.deviceProfile.productID == 0x02E0)
    #expect(
      Array(report[1...12]) == [
        0xFF, 0xFF, 0x00, 0xC0, 0x01, 0x00, 0x00, 0x40, 0xFF, 0x03, 0xFF, 0x01,
      ]
    )
    #expect(report[13] == 0x03)
    #expect(report[14] == 0xFF)
    #expect(report[15] == 0x07)
    #expect(report[16] == 0)
  }

  private func device(_ variant: ControllerProtocolVariant) -> ApplicationServiceDeviceDescription {
    ApplicationServiceDeviceDescription(
      name: String(describing: variant),
      vendorID: 1,
      productID: 1,
      parser: "Fixture",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: variant
    )
  }
}
