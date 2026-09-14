public enum CompatibilityOutputProfileCatalog {
  public static func profile(for identity: CompatibilityIdentity) -> CompatibilityOutputProfile {
    switch identity {
    case .automatic: return profile(for: .genericHID)
    case .genericHID:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .openJoystickDriverGenericHID,
        displayName: "Generic HID",
        notes: "OJD-owned HID GamePad identity for descriptor-driven consumers.",
        isHardwareSpoof: false,
        emitsXboxGuideReport: false,
        consumerFamily: .genericHID,
        evidenceByConsumer: [.genericHID: .sourceBacked]
      )
    case .sdl2_3:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .xbox360Wired,
        displayName: "SDL 2/3",
        notes: "SDL HIDAPI first-party identity for the physical protocol. XUSB "
          + "pads publish Microsoft 045E:028E. Other families use the protocol catalog.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .sourceBacked,
        consumerFamily: .sdlHIDAPI,
        automaticallyRecommended: true,
        evidenceByConsumer: [.sdlHIDAPI: .sourceBacked]
      )
    case .appleGameController:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .xboxSeries,
        displayName: "Apple GameController",
        notes: "Apple GameController profile using the Xbox Series Bluetooth layout. "
          + "Blink is hardware-verified. Gecko currently mis-maps this otherwise unchanged "
          + "native Xbox Series report.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .sourceBacked,
        consumerFamily: .appleGameController,
        evidenceByConsumer: [
          .appleGameController: .sourceBacked, .blinkGamepad: .hardwareVerified,
          .geckoGamepad: .reportedFailure,
        ]
      )
    case .xbox360HID:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .xbox360Wired,
        displayName: "Xbox 360 HID",
        notes: "Xbox 360-family generic-HID compatibility profile; not Windows XUSB22.sys.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .researchOnly,
        consumerFamily: .xbox360HID,
        evidenceByConsumer: [.xbox360HID: .researchOnly]
      )
    case .dualShock4:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .dualShock4USB,
        displayName: "DualShock 4",
        notes: "Sony DualShock 4 USB 054C:09CC. Custom SDL HIDAPI PS4 and "
          + "GCController.supportsHIDDevice bound this identity from an explicit "
          + "GIP picker publish. Automatic for DualShock 4 physical devices.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .sourceBacked,
        consumerFamily: .sdlHIDAPI,
        evidenceByConsumer: [.sdlHIDAPI: .sourceBacked, .appleGameController: .sourceBacked]
      )
    case .dualSense:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .dualSenseUSB,
        displayName: "DualSense",
        notes: "Sony DualSense USB 054C:0CE6. Custom SDL HIDAPI PS5 and "
          + "GCController.supportsHIDDevice bound this identity from an explicit "
          + "GIP picker publish. Automatic for DualSense physical devices.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .sourceBacked,
        consumerFamily: .sdlHIDAPI,
        evidenceByConsumer: [.sdlHIDAPI: .sourceBacked, .appleGameController: .sourceBacked]
      )
    case .switchPro:
      return CompatibilityOutputProfile(
        identity: identity,
        deviceProfile: .switchProUSB,
        displayName: "Switch Pro",
        notes: "Nintendo Switch Pro USB 057E:2009. Explicit GIP picker published "
          + "Pro Controller; GCController.supportsHIDDevice bound and custom "
          + "HIDAPI SDL_OpenGamepad opened switchpro. Automatic for Switch Pro "
          + "physical devices.",
        isHardwareSpoof: true,
        emitsXboxGuideReport: false,
        evidence: .sourceBacked,
        consumerFamily: .sdlHIDAPI,
        evidenceByConsumer: [.sdlHIDAPI: .sourceBacked, .appleGameController: .sourceBacked]
      )
    }
  }

}

public struct CompatibilityOutputComposition: Sendable {
  public let profile: CompatibilityOutputProfile
  public let format: any VirtualGamepadReportFormat

  public init(profile: CompatibilityOutputProfile, format: any VirtualGamepadReportFormat) {
    self.profile = profile
    self.format = format
  }
}

public enum CompatibilityOutputCompositionFactory {
  public static func make(
    target: AutomaticCompatibilityTarget
  ) throws -> CompatibilityOutputComposition {
    guard target.reportVariant == .geckoXboxOneS else { return try make(identity: target.identity) }
    let base = CompatibilityOutputProfileCatalog.profile(for: target.identity)
    let profile = CompatibilityOutputProfile(
      identity: base.identity,
      deviceProfile: .firefoxXboxOneS,
      displayName: base.displayName,
      notes: base.notes,
      isHardwareSpoof: base.isHardwareSpoof,
      emitsXboxGuideReport: base.emitsXboxGuideReport,
      evidence: base.evidence,
      consumerFamily: base.consumerFamily,
      automaticallyRecommended: base.automaticallyRecommended,
      evidenceByConsumer: base.evidenceByConsumer
    )
    return CompatibilityOutputComposition(profile: profile, format: try XboxGeckoHIDReportFormat())
  }

  public static func make(identity: CompatibilityIdentity) throws -> CompatibilityOutputComposition
  {
    let profile = CompatibilityOutputProfileCatalog.profile(for: identity)
    let format: any VirtualGamepadReportFormat
    switch identity {
    case .automatic: format = OJDGenericGamepadFormat()
    case .genericHID: format = OJDGenericGamepadFormat()
    case .sdl2_3: format = Xbox360MacHIDReportFormat()
    case .appleGameController:
      format = try HIDDescriptorReportFormat(
        descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor,
        outputReportID: VirtualRumbleOutputReportParser.xboxOneReportID,
        outputReportPayloadSize: VirtualRumbleOutputReportParser.xboxOneReportPayloadSize,
        buttonUsageMap: XboxOneBluetoothHIDDescriptor.buttonUsageMap,
        digitalUsageMap: XboxOneBluetoothHIDDescriptor.seriesDigitalUsageMap
      )
    case .xbox360HID: format = Xbox360MacHIDReportFormat(topLevelUsage: 0x05)
    case .dualShock4: format = DualShock4USBHIDReportFormat()
    case .dualSense: format = DualSenseUSBHIDReportFormat()
    case .switchPro: format = SwitchProUSBHIDReportFormat()
    }
    return CompatibilityOutputComposition(profile: profile, format: format)
  }
}
