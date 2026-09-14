import OpenJoystickDriverKit

enum ProfileCapabilityResolver {
  static func resolve(
    profile: RemappingProfile,
    connectedDevices: [ApplicationServiceDeviceDescription],
    registry: ParserRegistry
  ) -> ControllerProfileCapabilities? {
    let matchingDevices = connectedDevices.filter {
      $0.vendorID == profile.device.vendorID && $0.productID == profile.device.productID
    }
    if let first = matchingDevices.first {
      return matchingDevices.dropFirst().reduce(capabilities(for: first)) {
        $0.intersecting(capabilities(for: $1))
      }
    }
    return registry.profileCapabilities(
      for: DeviceIdentifier(vendorID: profile.device.vendorID, productID: profile.device.productID)
    )
  }

  private static func capabilities(
    for device: ApplicationServiceDeviceDescription
  ) -> ControllerProfileCapabilities {
    ControllerProfileCapabilities(
      physicalInput: device.physicalInputCapabilities,
      physicalOutput: device.physicalOutputCapabilities,
      supportsStickAxes: !device.quirks.contains("sticksToNull"),
      supportsAnalogTriggers: !device.quirks.contains("triggersToButtons")
    )
  }
}

enum ProfileCapabilityPolicy {
  static func supports(
    _ source: RemappingSource,
    capabilities: ControllerProfileCapabilities?
  ) -> Bool {
    guard capabilities != nil else { return true }
    switch source {
    case .dpad: return true
    case .button(let button):
      if baseButtons.contains(button) { return true }
      return capabilities?.physicalInput.additionalButtons.contains(button.physicalButton) == true
    case .axis(let axis), .axisDirection(let axis, _):
      return supports(axis, capabilities: capabilities)
    case .triggerStage: return capabilities?.supportsAnalogTriggers == true
    case .motionLean: return capabilities?.physicalInput.rawMotion == true
    case .touchContact(let surface): return supports(surface, capabilities: capabilities)
    case .touchGrid(let source): return supports(source.surface, capabilities: capabilities)
    case .touchSwipe(let source): return supports(source.surface, capabilities: capabilities)
    }
  }

  static func supports(
    _ destination: RemappingDestination,
    capabilities: ControllerProfileCapabilities?
  ) -> Bool {
    guard capabilities != nil else { return true }
    guard case .physical(let output) = destination else { return true }
    guard let physical = capabilities?.physicalOutput else { return false }
    switch output {
    case .rumble(let motor, _): return physical.rumbleMotors.contains(motor)
    case .playerIndicator: return physical.lightingFeatures.contains(.playerIndicator)
    case .color: return physical.lightingFeatures.contains(.programmableColor)
    case .brightness: return physical.lightingFeatures.contains(.programmableBrightness)
    case .adaptiveTrigger(let trigger, _): return physical.adaptiveTriggers.contains(trigger)
    }
  }

  private static func supports(
    _ axis: RemappingAxis,
    capabilities: ControllerProfileCapabilities?
  ) -> Bool {
    switch axis {
    case .leftStickX, .leftStickY, .rightStickX, .rightStickY:
      return capabilities?.supportsStickAxes == true
    case .leftTrigger, .rightTrigger: return capabilities?.supportsAnalogTriggers == true
    }
  }

  private static func supports(
    _ surface: RemappingTouchSurface,
    capabilities: ControllerProfileCapabilities?
  ) -> Bool {
    guard let input = capabilities?.physicalInput, input.touchContactsPerFrame > 0 else {
      return false
    }
    let physicalSurface: ControllerTouchSurface
    switch surface {
    case .primary: physicalSurface = .primary
    case .left: physicalSurface = .left
    case .right: physicalSurface = .right
    }
    return input.touchSurfaces.contains(physicalSurface)
  }

  private static let baseButtons: Set<RemappingButton> = [
    .south, .east, .west, .north, .leftShoulder, .rightShoulder, .leftStick, .rightStick, .start,
    .back, .guide,
  ]
}

private extension RemappingButton {
  var physicalButton: Button {
    switch self {
    case .south: return .a
    case .east: return .b
    case .west: return .x
    case .north: return .y
    case .leftShoulder: return .leftBumper
    case .rightShoulder: return .rightBumper
    case .leftStick: return .leftStick
    case .rightStick: return .rightStick
    case .start: return .start
    case .back: return .back
    case .guide: return .guide
    case .share: return .share
    case .options: return .options
    case .touchpad: return .touchpad
    case .mute: return .mute
    case .leftTriggerClick: return .l2Digital
    case .rightTriggerClick: return .r2Digital
    case .leftGrip: return .leftGrip
    case .rightGrip: return .rightGrip
    case .leftPadClick: return .leftPadClick
    case .rightPadClick: return .rightPadClick
    case .leftSL: return .leftSL
    case .leftSR: return .leftSR
    case .rightSL: return .rightSL
    case .rightSR: return .rightSR
    case .leftFunction: return .leftFunction
    case .rightFunction: return .rightFunction
    case .leftPaddle: return .leftPaddle
    case .rightPaddle: return .rightPaddle
    }
  }
}
