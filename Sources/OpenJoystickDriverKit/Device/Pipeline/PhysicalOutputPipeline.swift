extension DevicePipeline {
  func hidFeatureHapticReports(
    left: UInt8,
    right: UInt8,
    durationMs: Int
  ) -> [PhysicalHIDOutputReport] {
    (parser as? PhysicalHIDFeatureHapticOutput)?.physicalHapticReports(
      left: left,
      right: right,
      durationMs: durationMs
    ) ?? []
  }

  func supportsHIDFeatureHaptics() -> Bool { parser is PhysicalHIDFeatureHapticOutput }

  func minimumPhysicalOutputIntervalNanoseconds() -> UInt64 {
    (parser as? PhysicalHIDRumbleOutput)?.minimumPhysicalOutputIntervalNanoseconds ?? 0
  }

  func hidRumbleReport(left: UInt8, right: UInt8, lt: UInt8, rt: UInt8) -> PhysicalHIDOutputReport?
  {
    guard let rumbleOutput = parser as? PhysicalHIDRumbleOutput else { return nil }
    return rumbleOutput.physicalRumbleReport(left: left, right: right, lt: lt, rt: rt)
  }

  func hidColorReport(red: UInt8, green: UInt8, blue: UInt8) -> PhysicalHIDOutputReport? {
    (parser as? PhysicalHIDColorOutput)?.physicalColorReport(red: red, green: green, blue: blue)
  }

  func hidColorOutputPlan(red: UInt8, green: UInt8, blue: UInt8) -> PhysicalHIDOutputPlan? {
    if let provider = parser as? PhysicalHIDColorOutputPlan {
      return provider.physicalColorOutputPlan(red: red, green: green, blue: blue)
    }
    return hidColorReport(red: red, green: green, blue: blue).map {
      PhysicalHIDOutputPlan(reports: [$0])
    }
  }

  func physicalDefaultColor() -> (red: UInt8, green: UInt8, blue: UInt8)? {
    (parser as? PhysicalHIDColorOutput)?.physicalDefaultColor
      ?? (parser as? PhysicalHIDColorOutputPlan)?.physicalDefaultColor
  }

  func hidBrightnessReport(_ brightness: UInt8) -> PhysicalHIDOutputReport? {
    (parser as? PhysicalHIDFeatureBrightnessOutput)?.physicalBrightnessReport(brightness)
  }

  func hidBrightnessOutputPlan(_ brightness: UInt8) -> PhysicalHIDOutputPlan? {
    (parser as? PhysicalHIDBrightnessOutputPlan)?.physicalBrightnessOutputPlan(brightness)
  }

  func sendUSBBrightness(_ brightness: UInt8) async -> Bool {
    guard let handle = usbHandle,
      let packets = (parser as? PhysicalUSBBrightnessOutputPlan)?.physicalBrightnessOutputPackets(
        brightness
      )
    else { return false }
    do {
      for packet in packets {
        _ = try await handle.writeInterruptPacket(
          endpoint: packet.endpoint,
          data: packet.bytes,
          timeout: packet.timeoutMilliseconds
        )
        appendToPacketLog(bytes: packet.bytes, direction: "tx")
      }
      return true
    } catch {
      print("[DevicePipeline] Brightness send failed for \(identifier): \(error)")
      return false
    }
  }

  func hidPeriodicOutputPlan() -> (reports: [PhysicalHIDOutputReport], interval: UInt64)? {
    guard isActive, let provider = parser as? any HIDPeriodicOutputProvider else { return nil }
    return (provider.hidPeriodicOutputReports(), provider.hidPeriodicOutputIntervalNanoseconds)
  }

  func hidPlayerIndicatorReport(_ indicator: PhysicalPlayerIndicator) -> PhysicalHIDOutputReport? {
    (parser as? PhysicalHIDPlayerIndicatorOutput)?.physicalPlayerIndicatorReport(indicator)
  }

  func hidAdaptiveTriggerReport(
    _ trigger: PhysicalAdaptiveTrigger,
    effect: PhysicalAdaptiveTriggerEffect
  ) -> PhysicalHIDOutputReport? {
    (parser as? PhysicalHIDAdaptiveTriggerOutput)?.physicalAdaptiveTriggerReport(
      trigger,
      effect: effect
    )
  }

  func sendPlayerIndicator(_ indicator: PhysicalPlayerIndicator) async -> Bool {
    guard let handle = usbHandle, let lightingOutput = parser as? PhysicalPlayerIndicatorOutput
    else { return false }
    do {
      let packet = lightingOutput.physicalPlayerIndicatorPacket(indicator)
      _ = try await handle.writeInterruptPacket(
        endpoint: packet.endpoint,
        data: packet.bytes,
        timeout: packet.timeoutMilliseconds
      )
      return true
    } catch {
      print("[DevicePipeline] Player indicator send failed for \(identifier): \(error)")
      return false
    }
  }
}
