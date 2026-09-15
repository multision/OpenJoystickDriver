import Foundation

extension DeviceManager {
  // MARK: - HID detection (class 0x03)

  func ensureHIDDetectionState(for state: PermissionManager.AccessState) async {
    switch state {
    case .granted:
      guard hidDetectionTask == nil else { return }
      hidDetectionTask = Task { await self.runHIDDetection() }
    case .unknown, .denied:
      hidDetectionTask?.cancel()
      hidDetectionTask = nil
      await removeHIDPipelines()
    }
  }

  private func runHIDDetection() async {
    print("[DeviceManager] HID detection started" + " (class 0x03)")
    let events = await hidManager.deviceEvents()
    for await event in events {
      switch event {
      case .connected(
        let vendorID,
        let productID,
        let serialNumber,
        let locationID,
        let productName,
        let transport,
        let ownership
      ):
        scheduleHIDDeviceInitialization(
          vendorID: vendorID,
          productID: productID,
          serialNumber: serialNumber,
          locationID: locationID,
          productName: productName,
          transport: transport,
          ownership: ownership
        )
      case .disconnected(_, _, let locationID):
        hidInitializationTasks.removeValue(forKey: locationID)?.cancel()
        await handleHIDEvent(event)
      case .ownershipChanged, .inputReport, .inputValue: await handleHIDEvent(event)
      }
    }
  }

  func scheduleHIDDeviceInitialization(
    vendorID: UInt16,
    productID: UInt16,
    serialNumber: String?,
    locationID: UInt32,
    productName: String?,
    transport: String?,
    ownership: HIDInputOwnership
  ) {
    hidInitializationTasks.removeValue(forKey: locationID)?.cancel()
    hidInitializationTasks[locationID] = Task { [weak self] in
      guard let self else { return }
      await self.handleHIDDeviceConnected(
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber,
        locationID: locationID,
        productName: productName,
        transport: transport,
        ownership: ownership
      )
      await self.finishHIDDeviceInitialization(locationID: locationID)
    }
  }

  func finishHIDDeviceInitialization(locationID: UInt32) {
    guard !Task.isCancelled else { return }
    hidInitializationTasks.removeValue(forKey: locationID)
  }

  /// Handles backend events in their delivered order, including ownership before input.
  func handleHIDEvent(_ event: HIDDeviceEvent) async {
    switch event {
    case .connected(
      let vid,
      let pid,
      let serial,
      let loc,
      let productName,
      let transport,
      let ownership
    ):
      await handleHIDDeviceConnected(
        vendorID: vid,
        productID: pid,
        serialNumber: serial,
        locationID: loc,
        productName: productName,
        transport: transport,
        ownership: ownership
      )
    case .ownershipChanged(let locationID, let ownership):
      await updateHIDOwnership(ownership, locationID: locationID)
    case .disconnected(let vid, let pid, let loc):
      await handleHIDDeviceDisconnected(vendorID: vid, productID: pid, locationID: loc)
    case .inputReport(let loc, _, let data): await routeHIDInputReport(locationID: loc, data: data)
    case .inputValue(let loc, let value): await routeHIDElementValue(locationID: loc, value: value)
    }
  }

  private func updateHIDOwnership(_ ownership: HIDInputOwnership, locationID: UInt32) async {
    let identifiers = deviceInfos.keys.filter { $0.locationID == locationID }
    for identifier in identifiers {
      guard let info = deviceInfos[identifier], case .hid = info.discoverySource else { continue }
      deviceInfos[identifier]?.hidInputOwnership = ownership
      if ownership == .ownedByAnotherClient, info.hidInputOwnership != .ownedByAnotherClient {
        if let pipeline = pipelines[identifier] {
          await neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)
          await pipeline.stop()
        }
      } else if ownership != .ownedByAnotherClient, info.hidInputOwnership == .ownedByAnotherClient
      {
        // A fresh parser and normalized state prevent replaying controls held before access loss.
        pipelines.removeValue(forKey: identifier)
        await handleHIDDeviceConnected(
          vendorID: identifier.vendorID,
          productID: identifier.productID,
          serialNumber: identifier.serialNumber,
          locationID: locationID,
          productName: info.name,
          transport: info.connection,
          ownership: ownership
        )
        continue
      }
      if let listener = dispatcher as? any ControllerInputOwnershipListener {
        await listener.controllerInputOwnershipChanged(ownership, for: identifier)
      }
    }
  }

  private func removeHIDPipelines() async {
    for task in hidInitializationTasks.values { task.cancel() }
    hidInitializationTasks = [:]
    let hidIdentifiers = pipelines.keys.filter {
      deviceInfos[$0]?.discoverySource.requiresInputMonitoring == true
    }

    for identifier in hidIdentifiers {
      guard let pipeline = pipelines.removeValue(forKey: identifier) else { continue }
      hidPeriodicOutputTasks.removeValue(forKey: identifier)?.cancel()
      hidOutputQueues.removeValue(forKey: identifier)
      await neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)
      deviceInfos.removeValue(forKey: identifier)
      lastPhysicalHIDOutputNanoseconds.removeValue(forKey: identifier)
      await pipeline.stop()
      print("[DeviceManager] HID pipeline removed: \(identifier)")
    }
  }

  private func handleHIDDeviceConnected(
    vendorID: UInt16,
    productID: UInt16,
    serialNumber: String?,
    locationID: UInt32,
    productName: String?,
    transport: String?,
    ownership: HIDInputOwnership
  ) async {
    guard !Task.isCancelled else { return }
    let identifier = DeviceIdentifier(
      vendorID: vendorID,
      productID: productID,
      serialNumber: serialNumber,
      locationID: locationID
    )

    guard pipelines[identifier] == nil else {
      await updateHIDOwnership(ownership, locationID: locationID)
      return
    }
    if let existingIdentifier = Self.matchingPhysicalIdentifier(
      for: identifier,
      among: pipelines.keys
    ) {
      guard case .rawUSB = deviceInfos[existingIdentifier]?.discoverySource else { return }
      let replacedPipeline = pipelines.removeValue(forKey: existingIdentifier)
      hidPeriodicOutputTasks.removeValue(forKey: existingIdentifier)?.cancel()
      hidOutputQueues.removeValue(forKey: existingIdentifier)
      if let replacedPipeline {
        await neutralizePhysicalOutputs(for: existingIdentifier, pipeline: replacedPipeline)
      }
      deviceInfos.removeValue(forKey: existingIdentifier)
      lastPhysicalHIDOutputNanoseconds.removeValue(forKey: existingIdentifier)
      await replacedPipeline?.stop()
      print("[DeviceManager] Replacing duplicate raw USB pipeline with HID: \(identifier)")
    }

    let name = controllerDisplayName(
      productName: productName,
      vendorID: vendorID,
      productID: productID
    )
    let connection = transport ?? "HID"
    deviceInfos[identifier] = DeviceInfo(
      name: name,
      connection: connection,
      serialNumber: serialNumber,
      discoverySource: .hid,
      hidInputOwnership: ownership
    )
    guard !Task.isCancelled else {
      deviceInfos.removeValue(forKey: identifier)
      return
    }
    await updateHIDOwnership(ownership, locationID: locationID)
    guard deviceInfos[identifier] != nil, pipelines[identifier] == nil else { return }
    print("[DeviceManager] HID device connected:" + " \(name) (\(identifier))")
    let parser: any InputParser
    if parserRegistry.parserName(for: identifier, transport: .hid) == "DS4",
      connection == "Bluetooth"
    {
      parser = DS4Parser(prefersBluetooth: true)
    } else if parserRegistry.parserName(for: identifier, transport: .hid) == "DualSense" {
      let profile = parserRegistry.runtimeProfile(for: identifier)
      parser = DualSenseParser(
        prefersBluetooth: connection == "Bluetooth",
        hasEdgeButtons: profile.quirks.contains("edgeButtons")
      )
    } else {
      parser = parserRegistry.parser(for: identifier, transport: .hid)
    }
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: locationID),
      parser: parser,
      dispatcher: dispatcher,
      externalOutputAllowed: false
    )
    let requiresSuccessfulStartupOutput = await pipeline.requiresSuccessfulHIDStartupOutput(
      transport: transport
    )
    if !requiresSuccessfulStartupOutput {
      await pipeline.setExternalOutputAllowed(externalOutputAllowed)
    }
    pipelines[identifier] = pipeline
    notifyControllerInventoryChanged()
    guard ownership != .ownedByAnotherClient else { return }
    await pipeline.start()
    guard pipelines[identifier] === pipeline else { return }
    let outputPrecedesFeatureReads = await pipeline.hidStartupOutputPrecedesFeatureReads()
    var startupOutputSucceeded = true
    if outputPrecedesFeatureReads {
      startupOutputSucceeded = await sendHIDStartupOutputReportsIfNeeded(
        pipeline: pipeline,
        locationID: locationID,
        transport: transport
      )
    }
    await sendHIDStartupFeatureReadRequestsIfNeeded(
      pipeline: pipeline,
      locationID: locationID,
      transport: transport
    )
    if !(await pipeline.requiresInputConnectionBeforeOutput()) {
      await sendHIDStartupFeatureReportsIfNeeded(
        pipeline: pipeline,
        locationID: locationID,
        transport: transport
      )
    }
    if !outputPrecedesFeatureReads {
      startupOutputSucceeded = await sendHIDStartupOutputReportsIfNeeded(
        pipeline: pipeline,
        locationID: locationID,
        transport: transport
      )
    }
    if requiresSuccessfulStartupOutput {
      guard startupOutputSucceeded else {
        print("[DeviceManager] Required HID startup output failed for loc=\(locationID)")
        return
      }
      await pipeline.setExternalOutputAllowed(externalOutputAllowed)
    }
    if !(await pipeline.requiresInputConnectionBeforeOutput()) {
      await dispatcher.dispatch(events: [], from: identifier)
    }
    await requestHIDInputConnectionStatusIfNeeded(pipeline: pipeline, locationID: locationID)
    scheduleHIDPeriodicOutput(for: identifier, pipeline: pipeline, locationID: locationID)
  }

  private func scheduleHIDPeriodicOutput(
    for identifier: DeviceIdentifier,
    pipeline: DevicePipeline,
    locationID: UInt32
  ) {
    hidPeriodicOutputTasks.removeValue(forKey: identifier)?.cancel()
    hidPeriodicOutputTasks[identifier] = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let plan = await pipeline.hidPeriodicOutputPlan(), plan.interval > 0 else { return }
        do { try await Task.sleep(nanoseconds: plan.interval) } catch { return }
        guard !Task.isCancelled, await self.isCurrentHIDStartupPipeline(pipeline) else { return }
        let outputPlan = PhysicalHIDOutputPlan(reports: plan.reports)
        if !(await self.sendHIDOutputPlan(
          outputPlan,
          locationID: locationID,
          identifier: identifier,
          pipeline: pipeline
        )) {
          print("[DeviceManager] HID periodic output failed for loc=\(locationID)")
        }
      }
    }
  }
}
