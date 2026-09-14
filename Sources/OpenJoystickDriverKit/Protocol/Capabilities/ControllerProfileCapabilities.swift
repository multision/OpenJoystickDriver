/// Controller features that can be selected safely while editing a remapping profile.
public struct ControllerProfileCapabilities: Equatable, Sendable {
  public let physicalInput: PhysicalControllerInputCapabilities
  public let physicalOutput: PhysicalControllerOutputCapabilities
  public let supportsStickAxes: Bool
  public let supportsAnalogTriggers: Bool

  public static let unsupported = Self(
    physicalInput: .none,
    physicalOutput: .none,
    supportsStickAxes: false,
    supportsAnalogTriggers: false
  )

  public init(
    physicalInput: PhysicalControllerInputCapabilities,
    physicalOutput: PhysicalControllerOutputCapabilities,
    supportsStickAxes: Bool = true,
    supportsAnalogTriggers: Bool = true
  ) {
    self.physicalInput = physicalInput
    self.physicalOutput = physicalOutput
    self.supportsStickAxes = supportsStickAxes
    self.supportsAnalogTriggers = supportsAnalogTriggers
  }

  public init(parser: any InputParser, mappingOptions: ControllerMappingOptions = []) {
    self.init(
      physicalInput: parser.physicalInputCapabilities,
      physicalOutput: Self.physicalOutputCapabilities(for: parser),
      supportsStickAxes: !mappingOptions.contains(.sticksToNull),
      supportsAnalogTriggers: !mappingOptions.contains(.triggersToButtons)
    )
  }

  public func intersecting(_ other: Self) -> Self {
    Self(
      physicalInput: PhysicalControllerInputCapabilities(
        rawMotion: physicalInput.rawMotion && other.physicalInput.rawMotion,
        touchContactsPerFrame: min(
          physicalInput.touchContactsPerFrame,
          other.physicalInput.touchContactsPerFrame
        ),
        additionalButtons: intersection(
          physicalInput.additionalButtons,
          other.physicalInput.additionalButtons
        ),
        touchSurfaces: intersection(physicalInput.touchSurfaces, other.physicalInput.touchSurfaces)
      ),
      physicalOutput: PhysicalControllerOutputCapabilities(
        rumbleMotors: intersection(physicalOutput.rumbleMotors, other.physicalOutput.rumbleMotors),
        lightingFeatures: intersection(
          physicalOutput.lightingFeatures,
          other.physicalOutput.lightingFeatures
        ),
        binaryRumbleMotors: intersection(
          physicalOutput.binaryRumbleMotors,
          other.physicalOutput.binaryRumbleMotors
        ),
        adaptiveTriggers: intersection(
          physicalOutput.adaptiveTriggers,
          other.physicalOutput.adaptiveTriggers
        )
      ),
      supportsStickAxes: supportsStickAxes && other.supportsStickAxes,
      supportsAnalogTriggers: supportsAnalogTriggers && other.supportsAnalogTriggers
    )
  }

  public static func physicalOutputCapabilities(
    for parser: any InputParser
  ) -> PhysicalControllerOutputCapabilities {
    let rumbleMotors: [PhysicalRumbleMotor]
    if let output = parser as? PhysicalRumbleOutput {
      rumbleMotors = output.physicalRumbleMotors
    } else if let output = parser as? PhysicalHIDRumbleOutput {
      rumbleMotors = output.physicalRumbleMotors
    } else if let output = parser as? PhysicalHIDFeatureHapticOutput {
      rumbleMotors = output.physicalRumbleMotors
    } else {
      rumbleMotors = []
    }

    var lightingFeatures: [PhysicalLightingFeature] = []
    lightingFeatures += (parser as? PhysicalPlayerIndicatorOutput)?.physicalLightingFeatures ?? []
    lightingFeatures +=
      (parser as? PhysicalHIDPlayerIndicatorOutput)?.physicalLightingFeatures ?? []
    lightingFeatures += (parser as? PhysicalHIDColorOutput)?.physicalLightingFeatures ?? []
    lightingFeatures += (parser as? PhysicalHIDColorOutputPlan)?.physicalLightingFeatures ?? []
    lightingFeatures +=
      (parser as? PhysicalHIDFeatureBrightnessOutput)?.physicalLightingFeatures ?? []
    lightingFeatures += (parser as? PhysicalHIDBrightnessOutputPlan)?.physicalLightingFeatures ?? []
    lightingFeatures += (parser as? PhysicalUSBBrightnessOutputPlan)?.physicalLightingFeatures ?? []

    return PhysicalControllerOutputCapabilities(
      rumbleMotors: rumbleMotors,
      lightingFeatures: lightingFeatures,
      binaryRumbleMotors: (parser as? PhysicalHIDRumbleOutput)?.physicalBinaryRumbleMotors ?? [],
      adaptiveTriggers: (parser as? PhysicalHIDAdaptiveTriggerOutput)?.physicalAdaptiveTriggers
        ?? []
    )
  }
}

private func intersection<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> [Element] {
  lhs.filter(rhs.contains)
}
