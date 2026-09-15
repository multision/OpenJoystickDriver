import CoreHID
import Foundation

@available(macOS 15, *)
extension CoreHIDAccessBackend {

  func receiveNotifications(
    client: HIDDeviceClient,
    deviceID: UInt64,
    locationID: UInt32,
    continuation: AsyncStream<HIDDeviceEvent>.Continuation,
    sessionID: UUID
  ) async -> Bool {
    guard eventAdapter.isTracked(deviceID: deviceID) else { return false }
    let identifier = DeviceIdentifier(
      vendorID: UInt16(truncatingIfNeeded: await client.vendorID),
      productID: UInt16(truncatingIfNeeded: await client.productID)
    )
    let subscriptionPlan = CoreHIDInputSubscriptionPlan.resolve(for: identifier)
    let reportIDsToMonitor = subscriptionPlan.monitorsRawReports ? [HIDReportID.allReports] : []
    let elementsToMonitor = await client.elements.filter {
      $0.type == .input
        && subscriptionPlan.subscribesToElement(
          usagePage: UInt32($0.usage.page),
          usage: UInt32($0.usage.usage ?? 0)
        )
    }
    guard self.sessionID == sessionID, !Task.isCancelled else { return false }
    let notifications = await client.monitorNotifications(
      reportIDsToMonitor: reportIDsToMonitor,
      elementsToMonitor: elementsToMonitor
    )
    do {
      for try await notification in notifications {
        if Task.isCancelled || self.sessionID != sessionID { break }
        switch notification {
        case .inputReport(let reportID, let data, _):
          guard subscriptionPlan.forwards(.rawReport), eventAdapter.acceptsInput(deviceID: deviceID)
          else { continue }
          continuation.yield(
            .inputReport(
              locationID: locationID,
              reportID: reportID?.rawValue ?? 0,
              data: Data(CoreHIDInputReport.normalizedBytes(reportID: reportID, data: data))
            )
          )
        case .elementUpdates(let values):
          guard subscriptionPlan.forwards(.elementUpdates),
            eventAdapter.acceptsInput(deviceID: deviceID)
          else { continue }
          for value in values {
            let element = value.element
            continuation.yield(
              .inputValue(
                locationID: locationID,
                value: HIDElementValue(
                  usagePage: UInt32(element.usage.page),
                  usage: UInt32(element.usage.usage ?? 0),
                  logicalMinimum: Int(element.logicalMinimum ?? 0),
                  logicalMaximum: Int(element.logicalMaximum ?? 0),
                  integerValue: value.integerValue(asTypeTruncatingIfNeeded: Int.self),
                  reportID: CoreHIDElementReportID.value(element.reportID)
                )
              )
            )
          }
        case .deviceRemoved: return false
        case .deviceSeized:
          eventAdapter.updateOwnership(.ownedByAnotherClient, deviceID: deviceID)
          continuation.yield(
            .ownershipChanged(
              locationID: locationID,
              ownership: eventAdapter.ownership(locationID: locationID)
            )
          )
        case .deviceUnseized: return true
        @unknown default: break
        }
      }
    } catch {
      if !Task.isCancelled {
        print("[CoreHIDAccessBackend] Device notification failed at \(locationID): \(error)")
      }
    }
    return false
  }

  func remove(
    reference: HIDDeviceClient.DeviceReference,
    continuation: AsyncStream<HIDDeviceEvent>.Continuation,
    cancelNotification: Bool = true
  ) {
    pendingAdmissions.removeValue(forKey: reference.deviceID)
    let removal = eventAdapter.remove(deviceID: reference.deviceID)
    guard let record = recordsByDeviceID.removeValue(forKey: reference.deviceID) else {
      for locationID in Array(deviceIDsByLocation.keys) {
        deviceIDsByLocation[locationID]?.remove(reference.deviceID)
        if deviceIDsByLocation[locationID]?.isEmpty == true {
          deviceIDsByLocation.removeValue(forKey: locationID)
        }
      }
      return
    }
    let deviceID = reference.deviceID
    if removal.shouldCancelNotification, cancelNotification { record.notificationTask.cancel() }
    deviceIDsByLocation[record.locationID]?.remove(deviceID)
    if deviceIDsByLocation[record.locationID]?.isEmpty == true {
      deviceIDsByLocation.removeValue(forKey: record.locationID)
    }
    if removal.shouldEmitDisconnect {
      continuation.yield(
        .disconnected(
          vendorID: record.vendorID,
          productID: record.productID,
          locationID: record.locationID
        )
      )
    } else if removal.wasTracked {
      continuation.yield(
        .ownershipChanged(
          locationID: record.locationID,
          ownership: eventAdapter.ownership(locationID: record.locationID)
        )
      )
    }
  }

  func stop(sessionID: UUID? = nil) {
    if let sessionID, self.sessionID != sessionID { return }
    self.sessionID = nil
    continuation = nil
    managerTask?.cancel()
    managerTask = nil
    recordsByDeviceID.values.forEach { $0.notificationTask.cancel() }
    recordsByDeviceID.removeAll()
    pendingAdmissions.removeAll()
    deviceIDsByLocation.removeAll()
    releasedReferencesByLocation.removeAll()
    eventAdapter.reset()
  }

  static func ownershipAfterAcquisitionFailure(_ error: any Error) -> HIDInputOwnership {
    switch error as? HIDDeviceError {
    case .exclusiveAccess: .ownedByAnotherClient
    case .notPermitted, .notPrivileged: .accessDenied
    default: .acquisitionFailed
    }
  }

  static func transportName(_ transport: HIDDeviceTransport?) -> String? {
    guard let transport else { return nil }
    return switch transport {
    case .usb: "USB"
    case .bluetooth: "Bluetooth"
    case .bluetoothLowEnergy: "Bluetooth Low Energy"
    case .bluetoothAACP: "Bluetooth AACP"
    case .aid: "AID"
    case .i2c: "I2C"
    case .spi: "SPI"
    case .serial: "Serial"
    case .iap: "iAP"
    case .airPlay: "AirPlay"
    case .spu: "SPU"
    case .fifo: "FIFO"
    case .inductiveInBand: "Inductive In-Band"
    case .virtual: "Virtual"
    case .unknown(let value): value
    @unknown default: nil
    }
  }
}
