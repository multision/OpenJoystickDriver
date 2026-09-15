import Foundation

extension RemappingEngineState {

  mutating func setProfile(
    _ profile: RemappingProfile?,
    for identifier: DeviceIdentifier
  ) -> [RemappingEngineAction] {
    guard devices[identifier]?.profile != profile else { return [] }
    let actions = releaseController(identifier)
    if let profile {
      devices[identifier] = RemappingDeviceState(profile: profile, identifier: identifier)
    }
    return actions
  }

  mutating func process(
    events: [ControllerEvent],
    from identifier: DeviceIdentifier,
    profile: RemappingProfile,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    var actions = setProfile(profile, for: identifier)
    let monotonicUptime = max(uptimeNanoseconds, devices[identifier]?.lastUptime ?? 0)
    for event in events {
      if var device = devices[identifier] {
        device.lastUptime = monotonicUptime
        actions += processChords(for: &device)
        actions += replayPendingChordPresses(device: &device, at: monotonicUptime)
        devices[identifier] = device
      }
      actions += process(event: event, from: identifier, at: monotonicUptime)
      if var device = devices[identifier] {
        actions += device.updatePassthrough()
        devices[identifier] = device
      }
    }
    return actions
  }

  mutating func process(
    event: ControllerEvent,
    from identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    switch event {
    case .buttonPressed(let button):
      guard let source = inputSource(for: button, identifier: identifier) else { return [] }
      return setSource(source, isActive: true, for: identifier, at: uptimeNanoseconds)
    case .buttonReleased(let button):
      guard let source = inputSource(for: button, identifier: identifier) else { return [] }
      return setSource(source, isActive: false, for: identifier, at: uptimeNanoseconds)
    case .dpadChanged(let direction):
      return setDpad(direction, for: identifier, at: uptimeNanoseconds)
    case .leftStickChanged(let x, let y):
      let actions = processAdvancedStick(.left, x: x, y: y, for: identifier, at: uptimeNanoseconds)
      return actions
        + processAxes([(.leftStickX, x), (.leftStickY, y)], for: identifier, at: uptimeNanoseconds)
    case .rightStickChanged(let x, let y):
      let actions = processAdvancedStick(.right, x: x, y: y, for: identifier, at: uptimeNanoseconds)
      return actions
        + processAxes(
          [(.rightStickX, x), (.rightStickY, y)],
          for: identifier,
          at: uptimeNanoseconds
        )
    case .leftTriggerChanged(let value):
      return processAdvancedTrigger(.left, value: value, for: identifier, at: uptimeNanoseconds)
        + processAxes([(.leftTrigger, value)], for: identifier, at: uptimeNanoseconds)
    case .rightTriggerChanged(let value):
      return processAdvancedTrigger(.right, value: value, for: identifier, at: uptimeNanoseconds)
        + processAxes([(.rightTrigger, value)], for: identifier, at: uptimeNanoseconds)
    case .motionSample(let sample): return processMotion(sample, for: identifier)
    case .touchSample(let sample):
      return processTouch(sample, for: identifier, at: uptimeNanoseconds)
    }
  }

  mutating func setDpad(
    _ direction: DpadDirection,
    for identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    guard var device = devices[identifier] else { return [] }
    let nextDirections = Self.cardinalDirections(for: direction)
    let removed = device.dpadDirections.subtracting(nextDirections)
    let added = nextDirections.subtracting(device.dpadDirections)
    device.dpadDirections = nextDirections
    devices[identifier] = device

    var actions: [RemappingEngineAction] = []
    for direction in removed.sorted(by: Self.dpadLessThan) {
      actions += setSource(
        .dpad(direction),
        isActive: false,
        for: identifier,
        at: uptimeNanoseconds
      )
    }
    for direction in added.sorted(by: Self.dpadLessThan) {
      actions += setSource(.dpad(direction), isActive: true, for: identifier, at: uptimeNanoseconds)
    }
    return actions
  }

  mutating func processAxes(
    _ values: [(RemappingAxis, Float)],
    for identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    var actions: [RemappingEngineAction] = []
    for (axis, value) in values {
      actions += processAxis(axis, value: value, for: identifier, at: uptimeNanoseconds)
    }
    return actions
  }

  mutating func processAxis(
    _ axis: RemappingAxis,
    value rawValue: Float,
    for identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    guard var device = devices[identifier] else { return [] }
    device.physicalAxes[axis] = rawValue
    let oldContinuous = continuousTotals()
    var actions: [RemappingEngineAction] = []

    for binding in device.binding(for: .axis(axis))?.expandedActions ?? [] {
      if let tuning = binding.axisTuning, case .gamepadAxis(let destination) = binding.destination {
        let value = RemappingTransform.value(rawValue, tuning: tuning)
        device.virtualAxisBindings.insert(binding.id)
        if let state = device.gamepad.update(
          RemappingGamepadState(axes: [destination: value]),
          for: binding.id
        ) {
          actions.append(.gamepad(state, identifier))
        }
      }

      if let tuning = binding.axisTuning,
        let continuousDestination = RemappingContinuousDestination(binding.destination)
      {
        let transformed = RemappingTransform.value(rawValue, tuning: tuning)
        if transformed == 0 {
          device.continuous.removeValue(forKey: binding.id)
        } else {
          device.continuous[binding.id] = RemappingContinuousOutput(
            destination: continuousDestination,
            amount: transformed
          )
        }
      }
    }

    for direction in [RemappingAxisDirection.negative, .positive] {
      let source = RemappingSource.axisDirection(axis, direction)
      guard let tuning = device.directionTuning(for: source) else { continue }
      let transformed = RemappingTransform.value(rawValue, tuning: tuning)
      let wasActive = device.activeSources.contains(source)
      let isActive = RemappingTransform.isDirectionActive(
        value: transformed,
        direction: direction,
        threshold: tuning.digitalActivationThreshold,
        wasActive: wasActive
      )
      devices[identifier] = device
      actions += setSource(source, isActive: isActive, for: identifier, at: uptimeNanoseconds)
      guard let updated = devices[identifier] else { return actions }
      device = updated
    }
    devices[identifier] = device
    actions += stoppedContinuousActions(previous: oldContinuous)
    return actions
  }

  mutating func setSource(
    _ source: RemappingSource,
    isActive: Bool,
    for identifier: DeviceIdentifier,
    at uptimeNanoseconds: UInt64
  ) -> [RemappingEngineAction] {
    guard var device = devices[identifier] else { return [] }
    let wasActive = device.activeSources.contains(source)
    let gyroWasActive = device.isGyroActive
    guard wasActive != isActive else { return [] }
    var actions: [RemappingEngineAction] = []
    if !isActive { actions += processChords(for: &device, releasing: source) }
    actions += replayPendingChordPresses(
      device: &device,
      at: uptimeNanoseconds,
      releasing: isActive ? nil : source
    )
    if isActive {
      device.activeSources.insert(source)
      device.sourcePressTimes[source] = uptimeNanoseconds
    } else {
      device.activeSources.remove(source)
      device.sourcePressTimes.removeValue(forKey: source)
    }
    if device.profile.gyroOutput.activationSource == source {
      if isActive, device.profile.gyroOutput.activationMode == .toggle {
        device.gyroToggleActive.toggle()
      }
      if gyroWasActive != device.isGyroActive {
        device.gyroAwaitingBaseline = true
        if !device.isGyroActive { actions += device.clearGyroStick() }
      }
    }

    let oldContinuous = continuousTotals()
    if let layerActions = handleLayerActivator(source, isActive: isActive, device: &device) {
      devices[identifier] = device
      return actions + layerActions + stoppedContinuousActions(previous: oldContinuous)
    }

    let wasConsumed = device.consumedChordSources.contains(source)
    let buffered = isActive && device.bufferChordPress(source, at: uptimeNanoseconds)
    let modifierOwned = device.effectiveChords.contains {
      $0.mode == .modifier && $0.sources.contains(source)
    }
    let suppress =
      buffered || wasConsumed || modifierOwned
      || (isActive && sourceCompletesChord(source, in: device))
    for binding in device.binding(for: source)?.expandedActions ?? [] {
      actions += processAction(
        binding,
        isActive: isActive,
        suppressed: suppress,
        device: &device,
        at: uptimeNanoseconds
      )
    }
    if isActive && !wasConsumed {
      device.sequenceHistory.append(
        RemappingSequenceHistoryEntry(
          source: source,
          uptime: uptimeNanoseconds,
          awaitingChord: buffered
        )
      )
    }
    if !isActive {
      device.consumedChordSources.remove(source)
      device.replayedChordSources.remove(source)
    }
    actions += processChords(for: &device)
    actions += processSequences(for: &device, at: uptimeNanoseconds)
    devices[identifier] = device
    return actions
  }

  private func inputSource(for button: Button, identifier _: DeviceIdentifier) -> RemappingSource? {
    return Self.source(for: button)
  }

  static func source(for button: Button) -> RemappingSource? {
    switch button {
    case .a, .cross: .button(.south)
    case .b, .circle: .button(.east)
    case .x, .square: .button(.west)
    case .y, .triangle: .button(.north)
    case .leftBumper, .l1: .button(.leftShoulder)
    case .rightBumper, .r1: .button(.rightShoulder)
    case .leftStick: .button(.leftStick)
    case .rightStick: .button(.rightStick)
    case .start: .button(.start)
    case .back: .button(.back)
    case .guide, .ps: .button(.guide)
    case .share: .button(.share)
    case .options: .button(.options)
    case .touchpad: .button(.touchpad)
    case .l2Digital: .button(.leftTriggerClick)
    case .r2Digital: .button(.rightTriggerClick)
    case .mute: .button(.mute)
    case .leftGrip: .button(.leftGrip)
    case .rightGrip: .button(.rightGrip)
    case .leftPadClick: .button(.leftPadClick)
    case .rightPadClick: .button(.rightPadClick)
    case .leftSL: .button(.leftSL)
    case .leftSR: .button(.leftSR)
    case .rightSL: .button(.rightSL)
    case .rightSR: .button(.rightSR)
    case .leftFunction: .button(.leftFunction)
    case .rightFunction: .button(.rightFunction)
    case .leftPaddle: .button(.leftPaddle)
    case .rightPaddle: .button(.rightPaddle)
    case .dpadUp: .dpad(.up)
    case .dpadDown: .dpad(.down)
    case .dpadLeft: .dpad(.left)
    case .dpadRight: .dpad(.right)
    }
  }

  private static func cardinalDirections(
    for direction: DpadDirection
  ) -> Set<RemappingDpadDirection> {
    switch direction {
    case .neutral: []
    case .north: [.up]
    case .northEast: [.up, .right]
    case .east: [.right]
    case .southEast: [.down, .right]
    case .south: [.down]
    case .southWest: [.down, .left]
    case .west: [.left]
    case .northWest: [.up, .left]
    }
  }

  private static func dpadLessThan(
    _ lhs: RemappingDpadDirection,
    _ rhs: RemappingDpadDirection
  ) -> Bool { lhs.rawValue < rhs.rawValue }
}
