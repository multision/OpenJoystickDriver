import Foundation
import OpenJoystickDriverKit

extension RuntimeProfileDraft {

  func addingChord(
    sources: Set<RemappingSource>,
    destination: RemappingDestination,
    mode: RemappingChordMode = .modifier,
    windowMs: Double = 50
  ) throws -> Self {
    try replacingProfile(
      chords: profile.chords + [
        RemappingChord(sources: sources, destination: destination, mode: mode, windowMs: windowMs)
      ]
    )
  }

  func removingChord(_ chordID: UUID) throws -> Self {
    guard profile.chords.contains(where: { $0.id == chordID }) else {
      throw RuntimeProfileDraftError.chordNotFound(chordID)
    }
    return try replacingProfile(chords: profile.chords.filter { $0.id != chordID })
  }

  func addingSequence(
    sources: [RemappingSource],
    windowMs: Double,
    destination: RemappingDestination
  ) throws -> Self {
    try replacingProfile(
      sequences: profile.sequences + [
        RemappingSequence(sources: sources, windowMs: windowMs, destination: destination)
      ]
    )
  }

  func removingSequence(_ sequenceID: UUID) throws -> Self {
    guard profile.sequences.contains(where: { $0.id == sequenceID }) else {
      throw RuntimeProfileDraftError.sequenceNotFound(sequenceID)
    }
    return try replacingProfile(sequences: profile.sequences.filter { $0.id != sequenceID })
  }

  func addingLayer(
    name: String,
    activator: RemappingSource,
    activationMode: RemappingLayerActivation
  ) throws -> Self {
    try replacingProfile(
      layers: profile.layers + [
        RemappingLayer(name: name, activationMode: activationMode, activator: activator)
      ]
    )
  }

  func removingLayer(_ layerID: UUID) throws -> Self {
    guard profile.layers.contains(where: { $0.id == layerID }) else {
      throw RuntimeProfileDraftError.layerNotFound(layerID)
    }
    return try replacingProfile(layers: profile.layers.filter { $0.id != layerID })
  }

  func settingLayerBinding(
    layerID: UUID,
    source: RemappingSource,
    destination: RemappingDestination,
    axisTuning: RemappingAxisTuning? = nil,
    turbo: RemappingTurbo? = nil,
    longHold: RemappingLongHold? = nil,
    doubleTap: RemappingDoubleTap? = nil
  ) throws -> Self {
    guard let index = profile.layers.firstIndex(where: { $0.id == layerID }) else {
      throw RuntimeProfileDraftError.layerNotFound(layerID)
    }
    var layers = profile.layers
    let layer = layers[index]
    let existingID = layer.bindings.first { $0.source == source }?.id
    let binding = RemappingBinding(
      id: existingID ?? UUID(),
      source: source,
      destination: destination,
      behavior: layer.bindings.first { $0.source == source }?.behavior ?? .hold,
      pulseDurationMs: layer.bindings.first { $0.source == source }?.pulseDurationMs
        ?? RemappingBinding.defaultPulseDurationMs,
      axisTuning: axisTuning ?? Self.defaultTuning(for: source),
      turbo: turbo,
      longHold: longHold,
      doubleTap: doubleTap,
      additionalActions: layer.bindings.first { $0.source == source }?.additionalActions ?? []
    )
    layers[index] = RemappingLayer(
      id: layer.id,
      name: layer.name,
      activationMode: layer.activationMode,
      activator: layer.activator,
      bindings: layer.bindings.filter { $0.source != source } + [binding],
      chords: layer.chords,
      sequences: layer.sequences,
      motionTuning: layer.motionTuning
    )
    return try replacingProfile(layers: layers)
  }

  func settingLayerBindingAxisTuning(
    layerID: UUID,
    bindingID: UUID,
    axisTuning: RemappingAxisTuning
  ) throws -> Self {
    try replacingLayerBinding(layerID: layerID, bindingID: bindingID) { binding in
      RemappingBinding(
        id: binding.id,
        source: binding.source,
        destination: binding.destination,
        behavior: binding.behavior,
        pulseDurationMs: binding.pulseDurationMs,
        axisTuning: axisTuning,
        turbo: binding.turbo,
        longHold: binding.longHold,
        doubleTap: binding.doubleTap,
        additionalActions: binding.additionalActions
      )
    }
  }

  func settingLayerBindingBehaviors(
    behavior: RemappingBindingBehavior? = nil,
    pulseDurationMs: Double? = nil,
    layerID: UUID,
    bindingID: UUID,
    turbo: RemappingTurbo?,
    longHold: RemappingLongHold?,
    doubleTap: RemappingDoubleTap?
  ) throws -> Self {
    try replacingLayerBinding(layerID: layerID, bindingID: bindingID) { binding in
      RemappingBinding(
        id: binding.id,
        source: binding.source,
        destination: binding.destination,
        behavior: behavior ?? binding.behavior,
        pulseDurationMs: (behavior ?? binding.behavior) == .pulse
          ? pulseDurationMs ?? binding.pulseDurationMs : RemappingBinding.defaultPulseDurationMs,
        axisTuning: binding.axisTuning,
        turbo: turbo,
        longHold: longHold,
        doubleTap: doubleTap,
        additionalActions: binding.additionalActions
      )
    }
  }

  func removingLayerBinding(layerID: UUID, bindingID: UUID) throws -> Self {
    guard let index = profile.layers.firstIndex(where: { $0.id == layerID }) else {
      throw RuntimeProfileDraftError.layerNotFound(layerID)
    }
    var layers = profile.layers
    let layer = layers[index]
    guard layer.bindings.contains(where: { $0.id == bindingID }) else {
      throw RuntimeProfileDraftError.bindingNotFound(bindingID)
    }
    layers[index] = RemappingLayer(
      id: layer.id,
      name: layer.name,
      activationMode: layer.activationMode,
      activator: layer.activator,
      bindings: layer.bindings.filter { $0.id != bindingID },
      chords: layer.chords,
      sequences: layer.sequences,
      motionTuning: layer.motionTuning
    )
    return try replacingProfile(layers: layers)
  }

  func replacingLayerBinding(
    layerID: UUID,
    bindingID: UUID,
    transform: (RemappingBinding) -> RemappingBinding
  ) throws -> Self {
    guard let layerIndex = profile.layers.firstIndex(where: { $0.id == layerID }) else {
      throw RuntimeProfileDraftError.layerNotFound(layerID)
    }
    var layers = profile.layers
    let layer = layers[layerIndex]
    guard let bindingIndex = layer.bindings.firstIndex(where: { $0.id == bindingID }) else {
      throw RuntimeProfileDraftError.bindingNotFound(bindingID)
    }
    var bindings = layer.bindings
    bindings[bindingIndex] = transform(bindings[bindingIndex])
    layers[layerIndex] = RemappingLayer(
      id: layer.id,
      name: layer.name,
      activationMode: layer.activationMode,
      activator: layer.activator,
      bindings: bindings,
      chords: layer.chords,
      sequences: layer.sequences,
      motionTuning: layer.motionTuning
    )
    return try replacingProfile(layers: layers)
  }

  func replacingBinding(
    _ bindingID: UUID,
    _ makeBinding: (RemappingBinding) -> RemappingBinding
  ) throws -> Self {
    guard let index = profile.bindings.firstIndex(where: { $0.id == bindingID }) else {
      throw RuntimeProfileDraftError.bindingNotFound(bindingID)
    }
    var bindings = profile.bindings
    bindings[index] = makeBinding(bindings[index])
    let candidate = RemappingProfile(
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
      bindings: bindings,
      chords: profile.chords,
      sequences: profile.sequences,
      layers: profile.layers
    )
    return Self(profile: try Self.validate(candidate))
  }

  func replacingProfile(
    name: String? = nil,
    device: RemappingDeviceScope? = nil,
    applicationScope: RemappingApplicationScope? = nil,
    bindings: [RemappingBinding]? = nil,
    chords: [RemappingChord]? = nil,
    sequences: [RemappingSequence]? = nil,
    layers: [RemappingLayer]? = nil
  ) throws -> Self {
    let candidate = RemappingProfile(
      id: profile.id,
      name: name ?? profile.name,
      device: device ?? profile.device,
      applicationScope: applicationScope ?? profile.applicationScope,
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
    return Self(profile: try Self.validate(candidate))
  }

  static func defaultTuning(for source: RemappingSource) -> RemappingAxisTuning? {
    switch source {
    case .axis, .axisDirection: .default
    case .button, .dpad, .triggerStage, .motionLean, .touchContact, .touchGrid, .touchSwipe: nil
    }
  }
  static func validate(_ profile: RemappingProfile) throws -> RemappingProfile {
    do {
      try profile.validate()
      return profile
    } catch let error as RemappingValidationError {
      throw RuntimeProfileDraftError.validation(error)
    } catch { throw RuntimeProfileDraftError.validation(.encodingFailed) }
  }
}
