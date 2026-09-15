import CoreHID
import Foundation

@available(macOS 15, *)
extension CoreHIDAccessBackend {
  struct ClientRecord {
    let client: HIDDeviceClient
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let notificationTask: Task<Void, Never>
  }

  func deviceEvents() -> AsyncStream<HIDDeviceEvent> {
    stop()
    let sessionID = UUID()
    self.sessionID = sessionID
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.stop(sessionID: sessionID) }
      }
      managerTask = Task { [weak self] in
        await self?.monitorManager(continuation: continuation, sessionID: sessionID)
      }
    }
  }

  func setOutputReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void> {
    await setReport(locationID: locationID, report: report, type: .output)
  }

  func setFeatureReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void> {
    await setReport(locationID: locationID, report: report, type: .feature)
  }

  func getFeatureReport(
    locationID: UInt32,
    request: PhysicalHIDFeatureReadRequest
  ) async -> PhysicalHIDReportResult<Data> {
    guard eventAdapter.acceptsFeedback(locationID: locationID) else { return .unavailable }
    var lastFailure: PhysicalHIDFailure?
    for client in clients(at: locationID) {
      do {
        let data = try await client.dispatchGetReportRequest(
          type: .feature,
          id: HIDReportID(rawValue: request.reportID),
          timeout: .seconds(2)
        )
        guard recordsByDeviceID[client.deviceReference.deviceID]?.client === client,
          eventAdapter.acceptsFeedback(locationID: locationID)
        else { continue }
        return .success(Data(data.prefix(request.length)))
      } catch { lastFailure = .coreHID(String(reflecting: error)) }
    }
    return lastFailure.map(PhysicalHIDReportResult.failed) ?? .unavailable
  }

  func releaseInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult {
    let deviceIDs = deviceIDsByLocation.removeValue(forKey: locationID) ?? []
    guard !deviceIDs.isEmpty else { return .unavailable }
    var references: [HIDDeviceClient.DeviceReference] = []
    var tasks: [Task<Void, Never>] = []
    for deviceID in deviceIDs {
      guard let record = recordsByDeviceID.removeValue(forKey: deviceID) else { continue }
      references.append(record.client.deviceReference)
      tasks.append(record.notificationTask)
      record.notificationTask.cancel()
      _ = eventAdapter.remove(deviceID: deviceID)
    }
    for task in tasks { await task.value }
    guard !references.isEmpty else { return .unavailable }
    releasedReferencesByLocation[locationID] = references
    return .released
  }

  func reacquireInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult {
    guard let references = releasedReferencesByLocation.removeValue(forKey: locationID),
      let continuation, let sessionID
    else { return .unavailable }
    for reference in references {
      await add(reference: reference, continuation: continuation, sessionID: sessionID)
    }
    guard deviceIDsByLocation[locationID]?.isEmpty == false else { return .unavailable }
    let ownership = eventAdapter.ownership(locationID: locationID)
    return ownership == .exclusive ? .reacquired : .failed(.coreHID(ownership.rawValue))
  }

  private func setReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport,
    type: HIDReportType
  ) async -> PhysicalHIDReportResult<Void> {
    guard eventAdapter.acceptsFeedback(locationID: locationID) else { return .unavailable }
    var lastFailure: PhysicalHIDFailure?
    for client in clients(at: locationID) {
      let result = await CoreHIDPhysicalReportRequest.perform { timeout in
        try await client.dispatchSetReportRequest(
          type: type,
          id: HIDReportID(rawValue: report.reportID),
          data: Data(report.bytes),
          timeout: timeout
        )
      }
      switch result {
      case .success: return .success(())
      case .failure(let error):
        lastFailure = .coreHID(String(reflecting: error))
        print(
          "[CoreHIDAccessBackend] Set-report failed at \(locationID) "
            + "type=\(type) id=\(report.reportID): \(error)"
        )
      }
    }
    return lastFailure.map(PhysicalHIDReportResult.failed) ?? .unavailable
  }

  private func clients(at locationID: UInt32) -> [HIDDeviceClient] {
    (deviceIDsByLocation[locationID] ?? []).compactMap {
      eventAdapter.acceptsInput(deviceID: $0) ? recordsByDeviceID[$0]?.client : nil
    }
  }

  private func monitorManager(
    continuation: AsyncStream<HIDDeviceEvent>.Continuation,
    sessionID: UUID
  ) async {
    let notifications = await manager.monitorNotifications(matchingCriteria: matchingCriteria)
    do {
      for try await notification in notifications {
        if Task.isCancelled || self.sessionID != sessionID { break }
        switch notification {
        case .deviceMatched(let reference):
          await add(reference: reference, continuation: continuation, sessionID: sessionID)
        case .deviceRemoved(let reference): remove(reference: reference, continuation: continuation)
        @unknown default: break
        }
      }
    } catch { print("[CoreHIDAccessBackend] Device monitoring failed: \(error)") }
    continuation.finish()
  }

  private func add(
    reference: HIDDeviceClient.DeviceReference,
    continuation: AsyncStream<HIDDeviceEvent>.Continuation,
    sessionID: UUID
  ) async {
    guard self.sessionID == sessionID, !Task.isCancelled else { return }
    guard recordsByDeviceID[reference.deviceID] == nil, pendingAdmissions[reference.deviceID] == nil
    else { return }
    let admissionID = UUID()
    pendingAdmissions[reference.deviceID] = admissionID
    defer {
      if pendingAdmissions[reference.deviceID] == admissionID {
        pendingAdmissions.removeValue(forKey: reference.deviceID)
      }
    }
    guard !AppleGameControllerSyntheticHID.isSyntheticRegistryEntry(id: reference.deviceID) else {
      return
    }
    guard let client = HIDDeviceClient(deviceReference: reference) else { return }

    let vendorID = UInt16(truncatingIfNeeded: await client.vendorID)
    let productID = UInt16(truncatingIfNeeded: await client.productID)
    let serialNumber = await client.serialNumber
    let productName = await client.product
    let locationID = UInt32(truncatingIfNeeded: await client.locationID ?? reference.deviceID)
    let syntheticProperty = await client[AppleGameControllerSyntheticHID.propertyKey]?.unsafeObject
    let transport = Self.transportName(await client.transport)
    guard self.sessionID == sessionID, !Task.isCancelled,
      pendingAdmissions[reference.deviceID] == admissionID
    else { return }
    guard
      PhysicalHIDBackendEventPolicy.acceptsDevice(
        serialNumber: serialNumber,
        productName: productName,
        transport: transport,
        locationID: locationID,
        syntheticProperty: syntheticProperty
      )
    else { return }
    guard
      eventAdapter.add(
        deviceID: reference.deviceID,
        locationID: locationID,
        syntheticProperty: syntheticProperty
      )
    else { return }

    let ownership: HIDInputOwnership
    do {
      try await client.seizeDevice()
      ownership = .exclusive
    } catch {
      ownership = Self.ownershipAfterAcquisitionFailure(error)
      print("[CoreHIDAccessBackend] Non-exclusive access for \(vendorID):\(productID): \(error)")
    }
    guard self.sessionID == sessionID, !Task.isCancelled,
      pendingAdmissions[reference.deviceID] == admissionID
    else { return }
    eventAdapter.updateOwnership(ownership, deviceID: reference.deviceID)

    let task = Task { [weak self] in
      guard let self else { return }
      await self.monitor(
        client: client,
        deviceID: reference.deviceID,
        locationID: locationID,
        continuation: continuation,
        sessionID: sessionID
      )
    }
    recordsByDeviceID[reference.deviceID] = ClientRecord(
      client: client,
      vendorID: vendorID,
      productID: productID,
      locationID: locationID,
      notificationTask: task
    )
    deviceIDsByLocation[locationID, default: []].insert(reference.deviceID)
    continuation.yield(
      .connected(
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber,
        locationID: locationID,
        productName: productName,
        transport: transport,
        ownership: eventAdapter.ownership(locationID: locationID)
      )
    )
  }

  private func monitor(
    client: HIDDeviceClient,
    deviceID: UInt64,
    locationID: UInt32,
    continuation: AsyncStream<HIDDeviceEvent>.Continuation,
    sessionID: UUID
  ) async {
    let reacquire = await receiveNotifications(
      client: client,
      deviceID: deviceID,
      locationID: locationID,
      continuation: continuation,
      sessionID: sessionID
    )
    guard self.sessionID == sessionID, !Task.isCancelled,
      recordsByDeviceID[deviceID]?.client === client
    else { return }
    remove(reference: client.deviceReference, continuation: continuation, cancelNotification: false)
    if reacquire {
      // The notification stream has ended before a fresh client attempts exclusive access.
      await add(reference: client.deviceReference, continuation: continuation, sessionID: sessionID)
    }
  }
}
