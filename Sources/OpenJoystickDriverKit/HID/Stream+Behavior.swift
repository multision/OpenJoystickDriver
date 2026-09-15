import Foundation
import IOKit
import IOKit.hid

@available(macOS, introduced: 10.15, obsoleted: 15.0)
extension HIDDeviceStream {

  /// Returns a live stream of HID device events (connect, disconnect, input report).
  ///
  /// Only one stream can be active at a time. The stream ends when its
  /// consuming task is cancelled.
  public func deviceEvents() -> AsyncStream<HIDDeviceEvent> {
    if continuation != nil { cleanup() }
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in self?.cleanup() }
      self.registerCallbacks()
    }
  }

  // MARK: - Callback registration

  /// Registers IOKit callbacks for device matching, removal, and input reports,
  /// then opens the HID manager on the main run loop.
  private func registerCallbacks() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchingCallback, context)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removalCallback, context)
    IOHIDManagerRegisterInputReportCallback(manager, Self.inputReportCallback, context)
    IOHIDManagerRegisterInputValueCallback(manager, Self.inputValueCallback, context)
    // CRITICAL: schedule BEFORE open
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  /// Unschedules the HID manager from the run loop, closes it, and finishes
  /// the async stream.
  func cleanup() {
    IOHIDManagerUnscheduleFromRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.defaultMode.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    seizeLock.withLock {
      for devices in seizedByLocation.values {
        for device in devices {
          IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
      }
      seizedByLocation.removeAll()
      releasedByLocation.removeAll()
    }
    eventAdapter.reset()
    continuation?.finish()
    continuation = nil
  }

  public func setOutputReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) -> PhysicalHIDReportResult<Void> {
    setReport(locationID: locationID, report: report, type: kIOHIDReportTypeOutput, label: "Output")
  }

  public func setFeatureReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) -> PhysicalHIDReportResult<Void> {
    setReport(
      locationID: locationID,
      report: report,
      type: kIOHIDReportTypeFeature,
      label: "Feature"
    )
  }

  public func getFeatureReport(
    locationID: UInt32,

    request: PhysicalHIDFeatureReadRequest
  ) -> PhysicalHIDReportResult<Data> {
    guard eventAdapter.acceptsFeedback(locationID: locationID) else { return .unavailable }
    let devices = seizeLock.withLock { seizedByLocation[locationID] ?? [] }
    guard !devices.isEmpty else { return .unavailable }

    var lastResult = kIOReturnNotFound
    for device in devices {
      var bytes = [UInt8](repeating: 0, count: request.length)

      var reportLength = request.length
      let result = bytes.withUnsafeMutableBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return kIOReturnBadArgument }
        return IOHIDDeviceGetReport(
          device,
          kIOHIDReportTypeFeature,
          CFIndex(request.reportID),
          baseAddress,
          &reportLength
        )
      }
      if result == kIOReturnSuccess { return .success(Data(bytes.prefix(reportLength))) }
      lastResult = result
    }
    print(
      "[HIDDeviceStream] Feature report read failed for loc=\(locationID)"
        + " report=0x\(String(format: "%02X", request.reportID)) kr=\(lastResult)"
    )
    return .failed(.ioReturn(lastResult))
  }

  public func releaseInputClaim(locationID: UInt32) -> PhysicalHIDClaimResult {
    seizeLock.withLock {
      guard let devices = seizedByLocation.removeValue(forKey: locationID), !devices.isEmpty else {
        return .unavailable
      }
      var lastFailure: IOReturn?
      for device in devices {
        let result = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess { lastFailure = result }
      }
      if let lastFailure { return .failed(.ioReturn(lastFailure)) }
      releasedByLocation[locationID] = devices
      return .released
    }
  }

  public func reacquireInputClaim(locationID: UInt32) -> PhysicalHIDClaimResult {
    seizeLock.withLock {
      guard let devices = releasedByLocation[locationID], !devices.isEmpty else {
        return .unavailable
      }
      var acquired: [IOHIDDevice] = []
      for device in devices {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
          for acquiredDevice in acquired {
            IOHIDDeviceClose(acquiredDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
          }
          return .failed(.ioReturn(result))
        }
        acquired.append(device)
      }
      releasedByLocation.removeValue(forKey: locationID)
      seizedByLocation[locationID] = acquired
      return .reacquired
    }
  }

  private func setReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport,
    type: IOHIDReportType,
    label: String
  ) -> PhysicalHIDReportResult<Void> {
    guard eventAdapter.acceptsFeedback(locationID: locationID) else { return .unavailable }
    let devices = seizeLock.withLock { seizedByLocation[locationID] ?? [] }
    guard !devices.isEmpty else { return .unavailable }

    var lastResult = kIOReturnNotFound
    for device in devices {
      var bytes = report.bytes
      let reportLength = bytes.count
      let result = bytes.withUnsafeMutableBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return kIOReturnBadArgument }
        return IOHIDDeviceSetReport(
          device,
          type,
          CFIndex(report.reportID),
          baseAddress,
          reportLength
        )
      }
      if result == kIOReturnSuccess { return .success(()) }
      lastResult = result
    }
    print(
      "[HIDDeviceStream] \(label) report failed for loc=\(locationID)"
        + " report=0x\(String(format: "%02X", report.reportID)) kr=\(lastResult)"
    )
    return .failed(.ioReturn(lastResult))
  }

  // MARK: - Event handlers

  /// Reads device properties and yields a `.connected` event into the stream.
  func handleDeviceAdded(_ device: IOHIDDevice) {
    guard !AppleGameControllerSyntheticHID.isSynthetic(device: device) else { return }
    let vid = deviceProperty(device, kIOHIDVendorIDKey)
    let pid = deviceProperty(device, kIOHIDProductIDKey)
    let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
    let syntheticProperty = IOHIDDeviceGetProperty(
      device,
      AppleGameControllerSyntheticHID.propertyKey as CFString
    )
    let loc = deviceProperty(device, kIOHIDLocationIDKey)
    let locationID = UInt32(truncatingIfNeeded: loc)
    guard
      PhysicalHIDBackendEventPolicy.acceptsDevice(
        serialNumber: serial,
        productName: productName,
        transport: transport.isEmpty ? nil : transport,
        locationID: locationID,
        syntheticProperty: syntheticProperty
      )
    else { return }
    guard
      eventAdapter.add(
        deviceID: trackingID(for: device),
        locationID: locationID,
        syntheticProperty: syntheticProperty
      )
    else { return }

    // Preserve shared input for existing profiles, but report whether isolation was acquired.
    let seizeKr = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    if seizeKr == kIOReturnSuccess {
      seizeLock.withLock {
        var devices = seizedByLocation[locationID] ?? []
        if !devices.contains(where: { CFEqual($0, device) }) {
          devices.append(device)
          seizedByLocation[locationID] = devices
        }
      }
    }
    let ownership: HIDInputOwnership
    switch seizeKr {
    case kIOReturnSuccess: ownership = .exclusive
    case kIOReturnExclusiveAccess: ownership = .ownedByAnotherClient
    case kIOReturnNotPermitted, kIOReturnNotPrivileged: ownership = .accessDenied
    default: ownership = .acquisitionFailed
    }
    eventAdapter.updateOwnership(ownership, deviceID: trackingID(for: device))

    continuation?.yield(
      .connected(
        vendorID: UInt16(truncatingIfNeeded: vid),
        productID: UInt16(truncatingIfNeeded: pid),
        serialNumber: serial,
        locationID: locationID,
        productName: productName,
        transport: transport.isEmpty ? nil : transport,
        ownership: eventAdapter.ownership(locationID: locationID)
      )
    )
  }

  /// Yields a `.disconnected` event when IOKit reports a device removal.
  func handleDeviceRemoved(_ device: IOHIDDevice) {
    let deviceID = trackingID(for: device)
    let removal = eventAdapter.remove(deviceID: deviceID)
    guard removal.wasTracked else { return }
    let vid = deviceProperty(device, kIOHIDVendorIDKey)
    let pid = deviceProperty(device, kIOHIDProductIDKey)
    let loc = deviceProperty(device, kIOHIDLocationIDKey)
    let locationID = UInt32(truncatingIfNeeded: loc)
    seizeLock.withLock {
      releasedByLocation[locationID]?.removeAll { CFEqual($0, device) }
      if releasedByLocation[locationID]?.isEmpty == true {
        releasedByLocation.removeValue(forKey: locationID)
      }
      guard var devices = seizedByLocation[locationID] else { return }
      let removed = devices.filter { CFEqual($0, device) }
      devices.removeAll { CFEqual($0, device) }
      for removedDevice in removed {
        IOHIDDeviceClose(removedDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
      }
      if devices.isEmpty {
        seizedByLocation.removeValue(forKey: locationID)
        return
      }
      seizedByLocation[locationID] = devices
    }
    if removal.shouldEmitDisconnect {
      continuation?.yield(
        .disconnected(
          vendorID: UInt16(truncatingIfNeeded: vid),
          productID: UInt16(truncatingIfNeeded: pid),
          locationID: locationID
        )
      )
    } else {
      continuation?.yield(
        .ownershipChanged(
          locationID: locationID,
          ownership: eventAdapter.ownership(locationID: locationID)
        )
      )
    }
  }

  /// Copies raw report bytes and yields an `.inputReport` event.
  func handleInputReport(
    deviceID: UInt64,
    locationID: UInt32,
    reportID: UInt8,
    report: UnsafePointer<UInt8>,
    reportLength: CFIndex
  ) {
    guard eventAdapter.acceptsInput(deviceID: deviceID) else { return }
    var bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
    if reportID != 0, bytes.first != reportID { bytes.insert(reportID, at: 0) }
    continuation?.yield(.inputReport(locationID: locationID, reportID: reportID, data: Data(bytes)))
  }

  /// Yields one descriptor-decoded input element value.
  func handleInputValue(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    let loc = deviceProperty(device, kIOHIDLocationIDKey)
    let deviceID = trackingID(for: device)
    guard eventAdapter.acceptsInput(deviceID: deviceID) else { return }
    let semanticValue = HIDElementValue(
      usagePage: IOHIDElementGetUsagePage(element),
      usage: IOHIDElementGetUsage(element),
      logicalMinimum: IOHIDElementGetLogicalMin(element),
      logicalMaximum: IOHIDElementGetLogicalMax(element),
      integerValue: IOHIDValueGetIntegerValue(value),
      reportID: IOHIDElementReportID.value(IOHIDElementGetReportID(element))
    )
    continuation?.yield(
      .inputValue(locationID: UInt32(truncatingIfNeeded: loc), value: semanticValue)
    )
  }

  func trackingID(for device: IOHIDDevice) -> UInt64 {
    UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
  }

  /// Reads an integer property from an IOKit HID device.
  ///
  /// Returns 0 if missing.
  private func deviceProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
  }
}
