import Foundation

extension DeviceManager {
  public func sendRumble(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil,
    left: UInt8,
    right: UInt8,
    lt: UInt8,
    rt: UInt8,
    durationMs: Int
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[key]
    else { return false }
    let values: [(PhysicalRumbleMotor, UInt8)] = [
      (.leftMain, left), (.rightMain, right), (.leftTrigger, lt), (.rightTrigger, rt),
      (.leftHaptic, left), (.rightHaptic, right),
    ]
    let supportedMotors = Set(await pipeline.physicalOutputCapabilities().rumbleMotors)
    guard values.contains(where: { supportedMotors.contains($0.0) }) else { return false }
    let previousOwnership = physicalOutputOwnership
    for (motor, value) in values where supportedMotors.contains(motor) {
      _ = physicalOutputOwnership.setManual(
        .rumble(motor: motor, intensity: Double(value) / 255),
        for: key
      )
    }
    guard await sendEffectiveRumble(for: key, pipeline: pipeline, durationMs: durationMs) else {
      physicalOutputOwnership = previousOwnership
      return false
    }
    let clampedDurationMs = max(0, min(durationMs, maxRumbleDurationMs))
    if clampedDurationMs == 0 {
      _ = physicalOutputOwnership.releaseManualRumble(for: key)
      return await sendEffectiveRumble(for: key, pipeline: pipeline, durationMs: 0)
    }
    scheduleRumbleStop(
      for: key,
      pipeline: pipeline,
      durationMs: clampedDurationMs,
      hasActiveMotor: left != 0 || right != 0 || lt != 0 || rt != 0
    )
    return true
  }

  internal func scheduleRumbleStop(
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline,
    durationMs: Int,
    hasActiveMotor: Bool
  ) {
    rumbleStopTasks.removeValue(forKey: identifier)?.cancel()
    let generation = rumbleStopTokens.replace(for: identifier)
    guard durationMs > 0, hasActiveMotor else {
      rumbleStopTokens.remove(identifier)
      return
    }
    rumbleStopTasks[identifier] = Task { [weak self] in
      do {
        try await Task.sleep(
          nanoseconds: UInt64(durationMs) * deviceDiscoveryNanosecondsPerMillisecond
        )
      } catch { return }
      await self?.finishScheduledRumbleStop(
        for: identifier,
        pipeline: pipeline,
        generation: generation
      )
    }
  }

  internal func finishScheduledRumbleStop(
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline,
    generation: UInt64
  ) async {
    guard rumbleStopTokens.isCurrent(generation, for: identifier),
      pipelines[identifier] === pipeline
    else { return }
    _ = physicalOutputOwnership.releaseManualRumble(for: identifier)
    _ = await sendEffectiveRumble(for: identifier, pipeline: pipeline, durationMs: 0)
    guard rumbleStopTokens.isCurrent(generation, for: identifier) else { return }
    rumbleStopTasks.removeValue(forKey: identifier)
    rumbleStopTokens.remove(identifier)
  }

  /// Sets an RGB physical lightbar when the active protocol supports it.
  public func setPhysicalColor(
    for identifier: DeviceIdentifier,

    runtimeIdentifier: String? = nil,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[key],
      await pipeline.physicalOutputCapabilities().lightingFeatures.contains(.programmableColor)
    else { return false }
    let previousOwnership = physicalOutputOwnership
    physicalOutputOwnership.setManualColor(.color(red: red, green: green, blue: blue), for: key)

    let delivered = await applyPhysicalChannel(.color, for: key, pipeline: pipeline)
    if !delivered { physicalOutputOwnership = previousOwnership }
    return delivered
  }

  public func previewPhysicalColor(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil,
    token: UUID,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[key],
      await pipeline.physicalOutputCapabilities().lightingFeatures.contains(.programmableColor)
    else { return false }
    let previousOwnership = physicalOutputOwnership
    physicalOutputOwnership.setTemporaryColor(
      .color(red: red, green: green, blue: blue),
      token: token,
      for: key
    )
    let delivered = await applyPhysicalChannel(.color, for: key, pipeline: pipeline)
    if !delivered { physicalOutputOwnership = previousOwnership }
    return delivered
  }

  public func releasePhysicalColorPreview(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil,
    token: UUID
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier)
    else { return true }
    physicalOutputOwnership.releaseTemporaryColor(token: token, for: key)
    guard let pipeline = pipelines[key] else { return true }
    return await applyPhysicalChannel(.color, for: key, pipeline: pipeline)
  }

  public func setProfilePhysicalColor(
    _ color: RemappingPhysicalColor?,
    for identifier: DeviceIdentifier
  ) async -> Bool {
    let output = color.map {
      RemappingPhysicalOutput.color(red: $0.red, green: $0.green, blue: $0.blue)
    }
    physicalOutputOwnership.setProfileColor(output, for: identifier)
    guard let pipeline = pipelines[identifier],
      await pipeline.physicalOutputCapabilities().lightingFeatures.contains(.programmableColor)
    else { return true }
    return await applyPhysicalChannel(.color, for: identifier, pipeline: pipeline)
  }

  /// Sets scalar physical LED brightness when the active protocol supports it.
  public func setPhysicalBrightness(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil,
    brightness: UInt8
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[key],
      await pipeline.physicalOutputCapabilities().lightingFeatures.contains(.programmableBrightness)
    else { return false }
    let previousOwnership = physicalOutputOwnership
    _ = physicalOutputOwnership.setManual(.brightness(Double(brightness) / 255), for: key)
    let delivered = await applyPhysicalChannel(.brightness, for: key, pipeline: pipeline)
    if !delivered { physicalOutputOwnership = previousOwnership }
    return delivered
  }

  /// Sets the physical numbered player indicator when the active protocol supports it.
  public func sendPlayerIndicator(
    for identifier: DeviceIdentifier,
    runtimeIdentifier: String? = nil,
    indicator: PhysicalPlayerIndicator
  ) async -> Bool {
    guard let key = connectedIdentifier(matching: identifier, runtimeIdentifier: runtimeIdentifier),
      let pipeline = pipelines[key],
      await pipeline.physicalOutputCapabilities().lightingFeatures.contains(.playerIndicator)
    else { return false }
    let previousOwnership = physicalOutputOwnership
    _ = physicalOutputOwnership.setManual(.playerIndicator(indicator), for: key)
    let delivered = await applyPhysicalChannel(.playerIndicator, for: key, pipeline: pipeline)
    if !delivered { physicalOutputOwnership = previousOwnership }
    return delivered
  }

  /// Applies or releases one remapping claim for an exact connected controller.
  public func setMappingPhysicalOutput(
    _ output: RemappingPhysicalOutput,
    active: Bool,
    owner: UUID,
    for identifier: DeviceIdentifier
  ) async -> Bool {
    do { try output.validate() } catch { return false }
    guard let pipeline = pipelines[identifier] else {
      if !active {
        _ = physicalOutputOwnership.setMapping(output, active: false, owner: owner, for: identifier)
        return true
      }
      return false
    }
    guard supports(output, capabilities: await pipeline.physicalOutputCapabilities()) else {
      return false
    }
    let previousOwnership = physicalOutputOwnership
    let channel = physicalOutputOwnership.setMapping(
      output,
      active: active,
      owner: owner,
      for: identifier
    )
    let delivered = await applyPhysicalChannel(channel, for: identifier, pipeline: pipeline)
    if !delivered { physicalOutputOwnership = previousOwnership }
    return delivered
  }

  /// Releases every remapping claim for an exact controller without targeting a replacement.
  public func releaseMappingPhysicalOutputs(for identifier: DeviceIdentifier) async -> Bool {
    let channels = physicalOutputOwnership.releaseMappings(for: identifier)
    guard let pipeline = pipelines[identifier] else { return true }
    var delivered = true
    for channel in channels.sorted(by: { $0.sortKey < $1.sortKey }) {
      guard await applyPhysicalChannel(channel, for: identifier, pipeline: pipeline) else {
        delivered = false
        continue
      }
    }
    return delivered
  }

  internal func supports(
    _ output: RemappingPhysicalOutput,
    capabilities: PhysicalControllerOutputCapabilities
  ) -> Bool {
    switch output {
    case .rumble(let motor, _): capabilities.rumbleMotors.contains(motor)
    case .playerIndicator: capabilities.lightingFeatures.contains(.playerIndicator)
    case .color: capabilities.lightingFeatures.contains(.programmableColor)
    case .brightness: capabilities.lightingFeatures.contains(.programmableBrightness)
    case .adaptiveTrigger(let trigger, _): capabilities.adaptiveTriggers.contains(trigger)
    }
  }

  internal func applyPhysicalChannel(
    _ channel: PhysicalOutputChannel,
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline
  ) async -> Bool {
    switch channel {
    case .rumble:
      return await sendEffectiveRumble(for: identifier, pipeline: pipeline, durationMs: 0)
    case .playerIndicator:
      let indicator: PhysicalPlayerIndicator
      if case .playerIndicator(let value) = physicalOutputOwnership.effectiveOutput(
        for: channel,
        device: identifier
      ) {
        indicator = value
      } else {
        indicator = .off
      }
      let didSendUSB = await pipeline.sendPlayerIndicator(indicator)
      if didSendUSB { return true }
      guard let locationID = identifier.locationID,
        let report = await pipeline.hidPlayerIndicatorReport(indicator)
      else { return false }
      return await sendHIDOutputPlan(
        PhysicalHIDOutputPlan(reports: [report]),
        locationID: locationID,
        identifier: identifier,
        pipeline: pipeline
      )
    case .color:
      let value = physicalOutputOwnership.effectiveOutput(for: channel, device: identifier)
      let components: (UInt8, UInt8, UInt8)
      if case .color(let red, let green, let blue) = value {
        components = (red, green, blue)
      } else if let defaultColor = await pipeline.physicalDefaultColor() {
        components = defaultColor
      } else {
        return false
      }
      guard let locationID = identifier.locationID,
        let plan = await pipeline.hidColorOutputPlan(
          red: components.0,
          green: components.1,
          blue: components.2
        )
      else { return false }
      return await sendHIDOutputPlan(
        plan,
        locationID: locationID,
        identifier: identifier,
        pipeline: pipeline
      )
    case .brightness:
      let value = physicalOutputOwnership.effectiveOutput(for: channel, device: identifier)
      let brightness: UInt8
      if case .brightness(let intensity) = value {
        brightness = UInt8((intensity * 255).rounded())
      } else {
        brightness = 0
      }
      if await pipeline.sendUSBBrightness(brightness) { return true }
      guard let locationID = identifier.locationID else { return false }
      if let plan = await pipeline.hidBrightnessOutputPlan(brightness) {
        return await sendHIDOutputPlan(
          plan,
          locationID: locationID,
          identifier: identifier,
          pipeline: pipeline
        )
      }
      guard let report = await pipeline.hidBrightnessReport(brightness) else { return false }
      return await hidManager.setFeatureReport(locationID: locationID, report: report).succeeded
    case .adaptiveTrigger(let trigger):
      let value = physicalOutputOwnership.effectiveOutput(for: channel, device: identifier)
      let effect: PhysicalAdaptiveTriggerEffect
      if case .adaptiveTrigger(_, let currentEffect) = value {
        effect = currentEffect
      } else {
        effect = .off
      }
      guard let locationID = identifier.locationID,
        let report = await pipeline.hidAdaptiveTriggerReport(trigger, effect: effect)
      else { return false }
      return await sendHIDOutputPlan(
        PhysicalHIDOutputPlan(reports: [report]),
        locationID: locationID,
        identifier: identifier,
        pipeline: pipeline
      )
    }
  }
}
