import Foundation
import IOKit
import IOKit.hid

enum IOHIDElementReportID { static func value(_ reportID: UInt32) -> UInt32 { reportID } }

/// Watches for HID-class game controllers using Apple's IOKit HID framework.
///
/// Creates an `AsyncStream` of device connect, disconnect, and input report
/// events. IOKit delivers callbacks on the main run loop, and this class
/// forwards them into the stream for safe async consumption.
@available(macOS, introduced: 10.15, obsoleted: 15.0)
public final class HIDDeviceStream: @unchecked Sendable {

  // MARK: - Thread safety
  //
  // @unchecked Sendable safety:
  // - All IOKit callbacks are scheduled on the main run loop
  // - `continuation` is written only from `deviceEvents()` and `cleanup()`,
  //   both called from the main thread
  // - `deviceEvents()` terminates any existing stream before creating a new one

  let manager: IOHIDManager
  var continuation: AsyncStream<HIDDeviceEvent>.Continuation?
  let seizeLock = NSLock()
  var seizedByLocation: [UInt32: [IOHIDDevice]] = [:]
  var releasedByLocation: [UInt32: [IOHIDDevice]] = [:]
  let eventAdapter = SynchronizedPhysicalHIDBackendEventAdapter()

  /// Creates a new stream that matches HID gamepad devices.
  ///
  /// - Parameter virtualProfile: The virtual device profile to exclude from detection.
  public init(
    virtualProfile _: VirtualDeviceProfile = .default,
    additionalProfileIdentifiers: [DeviceIdentifier] = []
  ) {
    manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var matches: [[String: Any]] = [
      [
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
      ]
    ]
    matches += additionalProfileIdentifiers.map {
      [kIOHIDVendorIDKey: Int($0.vendorID), kIOHIDProductIDKey: Int($0.productID)]
    }
    matches = matches.map { AppleGameControllerSyntheticHID.ioHIDMatchingExcludingSynthetics($0) }
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
  }

  // MARK: - C-convention callbacks

  static let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDDeviceStream>.fromOpaque(context).takeUnretainedValue().handleDeviceAdded(device)
  }

  static let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDDeviceStream>.fromOpaque(context).takeUnretainedValue().handleDeviceRemoved(device)
  }

  static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    Unmanaged<HIDDeviceStream>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
  }

  static let inputReportCallback: IOHIDReportCallback = {
    context,
    _,
    sender,
    _,
    reportID,
    report,
    length in
    guard let context, let sender else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let loc = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
    let stream = Unmanaged<HIDDeviceStream>.fromOpaque(context).takeUnretainedValue()
    stream.handleInputReport(
      deviceID: stream.trackingID(for: device),
      locationID: UInt32(truncatingIfNeeded: loc),
      reportID: UInt8(truncatingIfNeeded: reportID),
      report: report,
      reportLength: length
    )
  }
}
