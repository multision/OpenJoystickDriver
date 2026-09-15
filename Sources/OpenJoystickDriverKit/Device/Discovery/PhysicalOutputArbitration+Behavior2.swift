import Foundation

extension DeviceManager {

  internal func sendEffectiveRumble(
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline,
    durationMs: Int
  ) async -> Bool {
    func byte(for motor: PhysicalRumbleMotor) -> UInt8 {
      guard
        case .rumble(_, let intensity) = physicalOutputOwnership.effectiveOutput(
          for: .rumble(motor),
          device: identifier
        )
      else { return 0 }
      return UInt8((intensity * 255).rounded())
    }
    let left = byte(for: .leftMain)
    let right = byte(for: .rightMain)
    let lt = byte(for: .leftTrigger)
    let rt = byte(for: .rightTrigger)
    let featureHaptics = await pipeline.hidFeatureHapticReports(
      left: byte(for: .leftHaptic),
      right: byte(for: .rightHaptic),
      durationMs: durationMs
    )
    if await pipeline.supportsHIDFeatureHaptics() {
      guard let locationID = identifier.locationID else { return false }
      for report in featureHaptics
      where !(await hidManager.setFeatureReport(locationID: locationID, report: report).succeeded) {
        return false
      }
      return true
    }
    let didSendUSB = await pipeline.sendRumble(left: left, right: right, lt: lt, rt: rt)
    if didSendUSB { return true }
    guard let locationID = identifier.locationID,
      let report = await pipeline.hidRumbleReport(left: left, right: right, lt: lt, rt: rt)
    else { return false }
    return await sendHIDOutputPlan(
      PhysicalHIDOutputPlan(reports: [report]),
      locationID: locationID,
      identifier: identifier,
      pipeline: pipeline
    )
  }

  func neutralizePhysicalOutputs(for identifier: DeviceIdentifier, pipeline: DevicePipeline) async {
    rumbleStopTasks.removeValue(forKey: identifier)?.cancel()
    rumbleStopTokens.remove(identifier)
    physicalOutputOwnership.removeDevice(identifier)
    let capabilities = await pipeline.physicalOutputCapabilities()
    if !capabilities.rumbleMotors.isEmpty {
      _ = await sendEffectiveRumble(for: identifier, pipeline: pipeline, durationMs: 0)
    }
    var channels = Set<PhysicalOutputChannel>()
    if capabilities.lightingFeatures.contains(.playerIndicator) {
      channels.insert(.playerIndicator)
    }
    if capabilities.lightingFeatures.contains(.programmableColor) { channels.insert(.color) }
    if capabilities.lightingFeatures.contains(.programmableBrightness) {
      channels.insert(.brightness)
    }
    channels.formUnion(capabilities.adaptiveTriggers.map(PhysicalOutputChannel.adaptiveTrigger))
    for channel in channels.sorted(by: { $0.sortKey < $1.sortKey }) {
      _ = await applyPhysicalChannel(channel, for: identifier, pipeline: pipeline)
    }
  }

  func discardPhysicalOutputs(for identifier: DeviceIdentifier) {
    rumbleStopTasks.removeValue(forKey: identifier)?.cancel()
    rumbleStopTokens.remove(identifier)
    physicalOutputOwnership.removeDevice(identifier)
  }

  internal func connectedIdentifier(
    matching model: DeviceIdentifier,
    runtimeIdentifier: String?
  ) -> DeviceIdentifier? {
    Self.connectedIdentifier(
      among: pipelines.keys,
      matching: model,
      runtimeIdentifier: runtimeIdentifier
    )
  }

  static func connectedIdentifier<Identifiers: Sequence>(
    among identifiers: Identifiers,
    matching model: DeviceIdentifier,
    runtimeIdentifier: String?
  ) -> DeviceIdentifier? where Identifiers.Element == DeviceIdentifier {
    let matches = identifiers.filter {
      $0.modelMatches(model)
        && (runtimeIdentifier == nil || $0.runtimeIdentifier == runtimeIdentifier)
    }
    return matches.count == 1 ? matches.first : nil
  }

  static func matchingPhysicalIdentifier<Identifiers: Sequence>(
    for candidate: DeviceIdentifier,
    among identifiers: Identifiers
  ) -> DeviceIdentifier? where Identifiers.Element == DeviceIdentifier {
    identifiers.first { $0.exactlyMatches(candidate) }
  }

  internal func enforcePhysicalHIDOutputInterval(
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline
  ) async throws {
    let minimum = await pipeline.minimumPhysicalOutputIntervalNanoseconds()
    guard minimum > 0 else { return }
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      let previous = lastPhysicalHIDOutputNanoseconds[identifier] ?? 0
      let elapsed = now >= previous ? now - previous : minimum
      if elapsed >= minimum {
        lastPhysicalHIDOutputNanoseconds[identifier] = now
        return
      }
      try await Task.sleep(nanoseconds: minimum - elapsed)
    }
  }

  internal func sendHIDOutputPlan(
    _ plan: PhysicalHIDOutputPlan,
    locationID: UInt32,
    identifier: DeviceIdentifier,
    pipeline: DevicePipeline
  ) async -> Bool {
    let queue = hidOutputQueues[identifier] ?? PhysicalHIDOutputSerialQueue()
    hidOutputQueues[identifier] = queue
    return await queue.perform { [weak self] in
      guard let self else { return false }
      return await self.performHIDOutputPlan(
        plan,
        locationID: locationID,
        identifier: identifier,
        pipeline: pipeline
      )
    }
  }

  private func performHIDOutputPlan(
    _ plan: PhysicalHIDOutputPlan,
    locationID: UInt32,
    identifier: DeviceIdentifier,
    pipeline: DevicePipeline
  ) async -> Bool {
    for (index, report) in plan.reports.enumerated() {
      if index > 0, plan.intervalNanoseconds > 0 {
        do { try await Task.sleep(nanoseconds: plan.intervalNanoseconds) } catch { return false }
      }
      guard pipelines[identifier] === pipeline else { return false }
      do { try await enforcePhysicalHIDOutputInterval(for: identifier, pipeline: pipeline) } catch {
        return false
      }
      guard await hidManager.setOutputReport(locationID: locationID, report: report).succeeded
      else { return false }
    }
    return true
  }
}
