import Foundation
import OpenJoystickDriverKit

extension MappingProfileEditor {

  static func outputPolicy(
    _ options: MappingOptions,
    defaultValue: RemappingOutputPolicy = .systemInput
  ) throws -> RemappingOutputPolicy {
    let virtualRaw = options["--virtual-gamepad"] ?? defaultValue.virtualGamepad.rawValue
    let physicalRaw = options["--physical-input"] ?? defaultValue.physicalInput.rawValue
    guard let virtual = RemappingVirtualGamepadPolicy(rawValue: virtualRaw),
      let physical = RemappingPhysicalInputPolicy(rawValue: physicalRaw)
    else {
      throw MappingCommandError.invalidArguments(
        CLILocalized.text(
          "cli.mapping.output_policy_invalid",
          """
          --virtual-gamepad: disabled|mapped|passthrough
          --physical-input: shared|exclusive
          """
        )
      )
    }
    return RemappingOutputPolicy(virtualGamepad: virtual, physicalInput: physical)
  }

  static func joyConPairSettings(
    _ options: MappingOptions,
    defaultValue: RemappingJoyConPairSettings? = nil
  ) throws -> RemappingJoyConPairSettings? {
    guard let raw = options["--joy-con-pair-gyro"] else { return defaultValue }
    if raw == "none" { return nil }
    guard let selection = RemappingJoyConGyroSelection(rawValue: raw) else {
      throw MappingCommandError.invalidArguments("--joy-con-pair-gyro: left|right|disabled|none")
    }
    return RemappingJoyConPairSettings(gyroSelection: selection)
  }

  static func applicationScope(
    _ options: MappingOptions,
    defaultValue: RemappingApplicationScope? = nil
  ) throws -> RemappingApplicationScope {
    let bundleID = options["--target-app"]
    let global = options.contains("--global")
    guard bundleID == nil || !global else {
      throw MappingCommandError.invalidArguments(
        CLILocalized.text(
          "cli.mapping.scope_conflict",
          "Pass only one of --target-app or --global."
        )
      )
    }
    if let bundleID { return .application(bundleIdentifier: bundleID) }
    if global { return .global }
    guard let defaultValue else {
      throw MappingCommandError.invalidArguments(
        CLILocalized.text("cli.mapping.scope_required", "Pass one of --target-app or --global.")
      )
    }
    return defaultValue
  }

  internal static func copy(
    _ profile: RemappingProfile,
    bindings: [RemappingBinding]? = nil,
    chords: [RemappingChord]? = nil,
    sequences: [RemappingSequence]? = nil,
    layers: [RemappingLayer]? = nil
  ) -> RemappingProfile {
    RemappingProfile(
      id: profile.id,
      name: profile.name,
      device: profile.device,
      applicationScope: profile.applicationScope,
      outputPolicy: profile.outputPolicy,
      physicalColor: profile.physicalColor,
      motionTuning: profile.motionTuning,
      gyroOutput: profile.gyroOutput,
      joyConPair: profile.joyConPair,
      stickMappings: profile.stickMappings,
      triggerMappings: profile.triggerMappings,
      touchMappings: profile.touchMappings,
      bindings: bindings ?? profile.bindings,
      chords: chords ?? profile.chords,
      sequences: sequences ?? profile.sequences,
      layers: layers ?? profile.layers
    )
  }

  internal static func copyAndValidate(_ profile: RemappingProfile) throws -> RemappingProfile {
    try profile.validate()
    return profile
  }
}
