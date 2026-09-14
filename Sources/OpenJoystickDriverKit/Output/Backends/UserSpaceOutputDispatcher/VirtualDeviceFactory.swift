import CoreHID
import Darwin
import Foundation
import IOKit
import IOKit.hid
import Security

extension UserSpaceOutputDispatcher {
  internal func createEntry(for identifier: DeviceIdentifier) async throws -> Entry {
    guard lifecycle.isOpen else { throw CancellationError() }
    if let testBackendFactory {
      let backend = try await testBackendFactory(identifier)
      guard lifecycle.isOpen else {
        backend.close()
        throw CancellationError()
      }
      return Entry(backend: backend, inputReportState: UserSpaceInputReportState(format: format))
    }
    if #available(macOS 15, *) { return try await createCoreHIDEntry(for: identifier) }
    return try createIOKitEntry(for: identifier)
  }

  @available(macOS 15, *)
  internal func createCoreHIDEntry(for identifier: DeviceIdentifier) async throws -> Entry {
    let properties = Self.virtualDeviceProperties(
      profile: profile,
      format: format,
      identifier: identifier,
      productNameOverride: productNameOverride
    )
    guard let device = HIDVirtualDevice(properties: properties) else {
      let error = Self.coreHIDCreationFailure()
      print("[UserSpaceOutputDispatcher] CoreHID HIDVirtualDevice create returned nil: \(error)")
      throw error
    }
    Self.applyPublishedIOHIDTransport(Self.ioHIDTransportValue(for: profile), to: device)
    let inputReportState = UserSpaceInputReportState(format: format)
    let sender = UserSpaceReportSender()
    let delegate = CoreHIDDelegate(
      handler: hostReportHandler(identifier: identifier, input: inputReportState, sender: sender)
    )
    let entry = Entry(
      backend: CoreHIDBackend(device: device, delegate: delegate),
      inputReportState: inputReportState,
      sender: sender
    )
    guard lifecycle.isOpen else {
      await entry.close()
      throw CancellationError()
    }
    await device.activate(delegate: delegate)
    guard lifecycle.isOpen else {
      await entry.close()
      throw CancellationError()
    }
    Self.applyPublishedIOHIDTransport(Self.ioHIDTransportValue(for: profile), to: device)
    print("[UserSpaceOutputDispatcher] Created CoreHID virtual device for \(identifier)")
    return entry
  }

  internal func hostReportHandler(
    identifier: DeviceIdentifier,
    input: UserSpaceInputReportState,
    sender: UserSpaceReportSender
  ) -> UserSpaceHostReportHandler {
    let isOpen: @Sendable () -> Bool = { [lifecycle] in lifecycle.isOpen }
    return UserSpaceHostReportHandler(
      identifier: identifier,
      input: input,
      sender: sender,
      isOpen: isOpen,
      onRumble: onRumbleCommand
    ) { [weak self] status in self?.registryLock.withLock { self?._lastRumbleStatus = status } }
  }

  @available(macOS, introduced: 10.15, obsoleted: 15.0)
  internal func createIOKitEntry(for identifier: DeviceIdentifier) throws -> Entry {
    guard PermissionManager.currentInputMonitoringAccessState() == .granted else {
      throw CreationError.inputMonitoringDenied
    }
    guard PermissionManager.currentAccessibilityAccessState() == .granted else {
      throw CreationError.accessibilityDenied
    }

    let baseProperties = Self.deviceProperties(
      profile: profile,
      format: format,
      identifier: identifier,
      productNameOverride: productNameOverride
    )
    let attempts = Self.deviceCreationAttempts(
      baseProperties: baseProperties,
      primaryUsage: primaryUsage
    )
    let candidateLocationIDs: [UInt32?] = [
      UserSpaceVirtualDeviceConstants.locationID(for: identifier), 0x1000_0002, nil,
    ]

    var device: IOHIDUserDevice?
    attemptLoop: for attempt in attempts {
      for locationID in candidateLocationIDs {
        var properties = attempt.properties
        if let locationID {
          properties[kIOHIDLocationIDKey as String] = Int64(locationID)
        } else {
          properties.removeValue(forKey: kIOHIDLocationIDKey as String)
        }
        device = IOHIDUserDeviceCreateWithProperties(
          kCFAllocatorDefault,
          properties as CFDictionary,
          attempt.options
        )
        if device != nil { break attemptLoop }
      }
    }
    guard let device else { throw CreationError.createFailed }
    guard lifecycle.isOpen else {
      IOHIDUserDeviceCancel(device)
      throw CancellationError()
    }

    let queue = DispatchQueue(
      label: "com.openjoystickdriver.iokit-hid.\(identifier.vendorID).\(identifier.productID)"
    )
    let inputReportState = UserSpaceInputReportState(format: format)
    let entry = Entry(
      backend: IOHIDBackend(device: device, queue: queue),
      inputReportState: inputReportState
    )
    let handler = hostReportHandler(
      identifier: identifier,
      input: inputReportState,
      sender: entry.sender
    )
    IOHIDUserDeviceRegisterGetReportBlock(device) { type, reportID, report, reportLength in
      do {
        guard let identifier = UInt32(exactly: reportID) else {
          throw VirtualHostReportError.malformed
        }
        let bytes = try handler.getReport(
          type: UserSpaceHostReportHandler.reportType(type),
          reportID: identifier,
          maxSize: Int(reportLength.pointee)
        )
        for (index, byte) in bytes.enumerated() { report[index] = byte }
        reportLength.pointee = bytes.count
        return kIOReturnSuccess
      } catch {
        reportLength.pointee = 0
        return UserSpaceHostReportHandler.ioKitError(error)
      }
    }
    IOHIDUserDeviceRegisterSetReportBlock(device) { type, reportID, report, reportLength in
      do {
        guard reportLength >= 0 else { throw VirtualHostReportError.malformed }
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
        _ = try handler.setReport(
          type: UserSpaceHostReportHandler.reportType(type),
          reportID: reportID,
          bytes: bytes
        )
        return kIOReturnSuccess
      } catch { return UserSpaceHostReportHandler.ioKitError(error) }
    }
    IOHIDUserDeviceSetDispatchQueue(device, queue)
    IOHIDUserDeviceActivate(device)
    print("[UserSpaceOutputDispatcher] Created IOKit virtual device for \(identifier)")
    return entry
  }

  /// IOHID `Transport` string HIDAPI matches (`kIOHIDTransportBluetoothValue` prefix).
  ///
  /// CoreHID `HIDVirtualDevice` still stamps `Transport=Virtual` unless this value is
  /// also passed through `extraProperties` and applied on the backing `IOHIDUserDevice`.
  static func ioHIDTransportValue(for profile: VirtualDeviceProfile) -> String {
    switch profile.transport {
    case kIOHIDTransportBluetoothValue, kIOHIDTransportBluetoothLowEnergyValue:
      kIOHIDTransportBluetoothValue
    default: kIOHIDTransportUSBValue
    }
  }

  @available(macOS 15, *)
  static func hidDeviceTransport(for profile: VirtualDeviceProfile) -> HIDDeviceTransport {
    ioHIDTransportValue(for: profile) == kIOHIDTransportBluetoothValue ? .bluetooth : .usb
  }

  static func virtualDeviceExtraProperties(profile: VirtualDeviceProfile) -> [String: any AnyObject]
  { [kIOHIDTransportKey as String: ioHIDTransportValue(for: profile) as CFString] }

  @available(macOS 15, *)
  static func applyPublishedIOHIDTransport(_ value: String, to device: HIDVirtualDevice) {
    if #available(macOS 26, *), let userDevice = device.hidDevice {
      IOHIDUserDeviceSetProperty(userDevice, kIOHIDTransportKey as CFString, value as CFString)
    }
  }

  @available(macOS 15, *)
  static func virtualDeviceProperties(
    profile: VirtualDeviceProfile,
    format: any VirtualGamepadReportFormat,
    identifier: DeviceIdentifier,
    productNameOverride: String? = nil
  ) -> HIDVirtualDevice.Properties {
    HIDVirtualDevice.Properties(
      descriptor: Data(format.descriptor),
      vendorID: UInt32(profile.vendorID),
      productID: UInt32(profile.productID),
      transport: hidDeviceTransport(for: profile),
      product: productNameOverride ?? profile.productName,
      manufacturer: profile.manufacturer,
      versionNumber: UInt64(profile.versionNumber),
      serialNumber: UserSpaceVirtualDeviceConstants.serialNumber(for: identifier),
      locationID: UInt64(UserSpaceVirtualDeviceConstants.locationID(for: identifier)),
      extraProperties: virtualDeviceExtraProperties(profile: profile)
    )
  }

  static func deviceProperties(
    profile: VirtualDeviceProfile,
    format: any VirtualGamepadReportFormat,
    identifier: DeviceIdentifier,
    productNameOverride: String? = nil
  ) -> [String: Any] {
    var properties: [String: Any] = [
      kIOHIDReportDescriptorKey as String: Data(format.descriptor),
      kIOHIDVendorIDKey as String: profile.vendorID,
      kIOHIDProductIDKey as String: profile.productID,
      kIOHIDVersionNumberKey as String: profile.versionNumber,
      kIOHIDProductKey as String: productNameOverride ?? profile.productName,
      kIOHIDManufacturerKey as String: profile.manufacturer,
      kIOHIDSerialNumberKey as String: UserSpaceVirtualDeviceConstants.serialNumber(
        for: identifier
      ), kIOHIDTransportKey as String: ioHIDTransportValue(for: profile),
      kIOHIDMaxInputReportSizeKey as String: reportBufferSize(
        payloadSize: format.inputReportPayloadSize,
        reportID: format.inputReportID
      ),
    ]
    if let outputSize = format.outputReportPayloadSize {
      properties[kIOHIDMaxOutputReportSizeKey as String] = reportBufferSize(
        payloadSize: outputSize,
        reportID: format.outputReportID
      )
    }
    properties[kIOHIDLocationIDKey as String] = Int64(
      UserSpaceVirtualDeviceConstants.locationID(for: identifier)
    )
    return properties
  }

  public static func defaultPrimaryUsage(for format: any VirtualGamepadReportFormat) -> Int {
    if let xbox360 = format as? Xbox360MacHIDReportFormat { return Int(xbox360.topLevelUsage) }
    return Int(kHIDUsage_GD_GamePad)
  }

  internal static func reportBufferSize(payloadSize: Int, reportID: UInt8?) -> Int {
    reportID == nil ? payloadSize : payloadSize + 1
  }

  /// Classifies a nil CoreHID `HIDVirtualDevice` (macOS 15+ wraps IOHIDUserDevice;
  /// Accessibility / PostEvent deny surfaces as `IOServiceOpen` `kIOReturnNotPermitted`).
  /// Input Monitoring / ListenEvent is not mapped: it blocks `IOHIDDeviceOpen` and
  /// `GC.supportsHIDDevice`, not virtual-device create.
  static func mappedCoreHIDCreationFailure(
    provisioning: VirtualHIDProvisioningHost.Authorization,
    accessibility: PermissionManager.AccessState
  ) -> CreationError {
    if provisioning == .excludesHost { return .provisioningProfileExcludesHost }
    if accessibility != .granted { return .accessibilityDenied }
    return .createFailed
  }

  @available(macOS 15, *)
  internal static func coreHIDCreationFailure() -> CreationError {
    mappedCoreHIDCreationFailure(
      provisioning: VirtualHIDProvisioningHost.currentAuthorization(),
      accessibility: PermissionManager.currentAccessibilityAccessState()
    )
  }

  internal static func hasEntitlement(_ entitlement: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil),
      let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil),
      CFGetTypeID(value) == CFBooleanGetTypeID()
    else { return false }
    return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
  }
}
