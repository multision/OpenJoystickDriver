import Foundation

extension DeviceManager {

  func sendHIDStartupFeatureReadRequestsIfNeeded(
    pipeline: DevicePipeline,
    locationID: UInt32,
    transport: String?
  ) async {
    let plan = await pipeline.hidStartupFeatureReadPlan(transport: transport)
    for request in plan.requests {
      let outcome = await HIDFeatureReadRetry.run(maximumAttempts: plan.validatesReplies ? 3 : 1) {
        await self.attemptHIDStartupFeatureRead(
          pipeline: pipeline,
          request: request,
          locationID: locationID,
          transport: transport
        )
      }
      switch outcome {
      case .accepted: break
      case .stopped: return
      case .retry: print("[DeviceManager] HID startup feature read exhausted for loc=\(locationID)")
      }
    }
  }

  private func attemptHIDStartupFeatureRead(
    pipeline: DevicePipeline,
    request: PhysicalHIDFeatureReadRequest,
    locationID: UInt32,
    transport: String?
  ) async -> HIDFeatureReadAttempt {
    guard await isCurrentHIDStartupPipeline(pipeline) else { return .stopped }
    let result = await hidManager.getFeatureReport(locationID: locationID, request: request)
    guard await isCurrentHIDStartupPipeline(pipeline) else { return .stopped }
    guard let data = result.value else {
      print(
        "[DeviceManager] HID startup feature read failed for controller=\(pipeline.identifier) "
          + "loc=\(locationID) report=\(request.reportID): \(result.failureDescription)"
      )
      return .retry
    }
    guard await pipeline.acceptsHIDFeatureReportReplies() else { return .accepted }
    let accepted = await pipeline.consumeHIDFeatureReport(
      data,
      request: request,
      transport: transport
    )
    return accepted ? .accepted : .retry
  }

  func sendHIDStartupFeatureReportsIfNeeded(
    pipeline: DevicePipeline,
    locationID: UInt32,
    transport: String?
  ) async {
    for report in await pipeline.hidStartupFeatureReports(transport: transport) {
      let result = await hidManager.setFeatureReport(locationID: locationID, report: report)
      if !result.succeeded {
        print(
          "[DeviceManager] HID startup feature report failed for controller=\(pipeline.identifier) "
            + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
        )
      }
    }
  }

  func sendHIDStartupOutputReportsIfNeeded(
    pipeline: DevicePipeline,
    locationID: UInt32,
    transport: String?
  ) async -> Bool {
    guard await isCurrentHIDStartupPipeline(pipeline) else { return false }
    let (reports, interval) = await pipeline.hidStartupOutputPlan(transport: transport)
    var succeeded = true
    if interval == 0 {
      for report in reports {
        guard await isCurrentHIDStartupPipeline(pipeline) else { return false }
        let result = await hidManager.setOutputReport(locationID: locationID, report: report)
        succeeded = succeeded && result.succeeded
        if !result.succeeded {
          let controller = pipeline.identifier
          print(
            "[DeviceManager] HID startup output report failed for controller=\(controller) "
              + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
          )
        }
      }
      await runHIDStartupRecovery(pipeline: pipeline, locationID: locationID, interval: interval)
      return succeeded
    }
    for (index, report) in reports.enumerated() {
      if index > 0 { do { try await Task.sleep(nanoseconds: interval) } catch { return false } }
      guard !Task.isCancelled, await isCurrentHIDStartupPipeline(pipeline) else { return false }
      let result = await hidManager.setOutputReport(locationID: locationID, report: report)
      succeeded = succeeded && result.succeeded
      if !result.succeeded {
        print(
          "[DeviceManager] HID startup output report failed for controller=\(pipeline.identifier) "
            + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
        )
      }
    }
    await runHIDStartupRecovery(pipeline: pipeline, locationID: locationID, interval: interval)
    return succeeded
  }

  private func runHIDStartupRecovery(
    pipeline: DevicePipeline,
    locationID: UInt32,
    interval: UInt64
  ) async {
    guard await pipeline.supportsHIDStartupRecovery() else { return }
    for round in 0..<3 {
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
      guard !Task.isCancelled, await isCurrentHIDStartupPipeline(pipeline) else { return }
      if round == 2 {
        await pipeline.expireHIDStartupRequests()
        return
      }
      let reports = await pipeline.pendingHIDStartupReports()
      for (index, report) in reports.enumerated() {
        if index > 0 { do { try await Task.sleep(nanoseconds: interval) } catch { return } }
        guard !Task.isCancelled, await isCurrentHIDStartupPipeline(pipeline) else { return }
        _ = await hidManager.setOutputReport(locationID: locationID, report: report)
      }
    }
  }

  func isCurrentHIDStartupPipeline(_ pipeline: DevicePipeline) async -> Bool {
    guard await pipeline.isActive else { return false }
    // Recheck identity after the actor hop: a reconnect may reuse the same location and IDs.
    return pipelines[pipeline.identifier] === pipeline
      && deviceInfos[pipeline.identifier]?.hidInputOwnership != .ownedByAnotherClient
  }

  func requestHIDInputConnectionStatusIfNeeded(pipeline: DevicePipeline, locationID: UInt32) async {
    guard let report = await pipeline.hidInputConnectionStatusRequestReport() else { return }
    let result = await hidManager.setFeatureReport(locationID: locationID, report: report)
    if !result.succeeded {
      let controller = pipeline.identifier
      print(
        "[DeviceManager] HID connection-status request failed for controller=\(controller) "
          + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
      )
    }
  }

  func handleHIDDeviceDisconnected(vendorID: UInt16, productID: UInt16, locationID: UInt32) async {
    hidInitializationTasks.removeValue(forKey: locationID)?.cancel()
    if let key = pipelines.keys.first(where: { $0.locationID == locationID }) {
      let pipeline = pipelines.removeValue(forKey: key)
      hidPeriodicOutputTasks.removeValue(forKey: key)?.cancel()
      hidOutputQueues.removeValue(forKey: key)
      if let pipeline { await neutralizePhysicalOutputs(for: key, pipeline: pipeline) }
      deviceInfos.removeValue(forKey: key)
      notifyControllerInventoryChanged()
      lastPhysicalHIDOutputNanoseconds.removeValue(forKey: key)
      await sendHIDShutdownFeatureReportsIfNeeded(pipeline: pipeline, locationID: locationID)
      await pipeline?.stop()
      print(
        "[DeviceManager] HID device disconnected:" + " VID=\(vendorID) PID=\(productID)"
          + " loc=\(locationID)"
      )
    }
  }

  func sendHIDShutdownFeatureReportsIfNeeded(pipeline: DevicePipeline?, locationID: UInt32) async {
    guard let pipeline else { return }
    for report in await pipeline.hidShutdownFeatureReports() {
      let result = await hidManager.setFeatureReport(locationID: locationID, report: report)
      if !result.succeeded {
        let controller = pipeline.identifier
        print(
          "[DeviceManager] HID shutdown feature report failed for controller=\(controller) "
            + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
        )
      }
    }
  }

  func routeHIDElementValue(locationID: UInt32, value: HIDElementValue) async {
    guard let key = pipelines.keys.first(where: { $0.locationID == locationID }),
      let pipeline = pipelines[key]
    else { return }
    await pipeline.feedHIDElementValue(value)
  }

  func routeHIDInputReport(locationID: UInt32, data: Data) async {
    if let key = pipelines.keys.first(where: { $0.locationID == locationID }),
      let featureReports = await pipelines[key]?.feedHIDData(data)
    {
      for report in featureReports {
        let result = await hidManager.setFeatureReport(locationID: locationID, report: report)
        if !result.succeeded {
          print(
            "[DeviceManager] HID lifecycle feature report failed for controller=\(key) "
              + "loc=\(locationID) report=\(report.reportID): \(result.failureDescription)"
          )
        }
      }
    }
  }
}
