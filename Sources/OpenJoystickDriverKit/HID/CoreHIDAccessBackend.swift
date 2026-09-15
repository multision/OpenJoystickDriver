import CoreHID
import Foundation

@available(macOS 15, *)
enum CoreHIDInputSubscriptionPlan {
  case rawReports
  case elements(any HIDElementValueParser)

  enum NotificationKind {
    case rawReport
    case elementUpdates
  }

  static func resolve(
    for identifier: DeviceIdentifier,
    registry: ParserRegistry = ParserRegistry()
  ) -> Self {
    guard
      let parser = registry.parser(for: identifier, transport: .hid) as? any HIDElementValueParser
    else { return .rawReports }
    return .elements(parser)
  }

  var monitorsRawReports: Bool {
    if case .rawReports = self { return true }
    return false
  }

  func subscribesToElement(usagePage: UInt32, usage: UInt32) -> Bool {
    switch self {
    case .rawReports: false
    case .elements(let parser): parser.acceptsElement(usagePage: usagePage, usage: usage)
    }
  }

  func forwards(_ notification: NotificationKind) -> Bool {
    switch (self, notification) {
    case (.rawReports, .rawReport), (.elements, .elementUpdates): true
    case (.rawReports, .elementUpdates), (.elements, .rawReport): false
    }
  }
}

@available(macOS 15, *)
enum CoreHIDInputReport {
  static func normalizedBytes(reportID: HIDReportID?, data: Data) -> [UInt8] {
    var bytes = [UInt8](data)
    if let reportID, bytes.first != reportID.rawValue { bytes.insert(reportID.rawValue, at: 0) }
    return bytes
  }
}

@available(macOS 15, *)
enum CoreHIDElementReportID {
  static func value(_ reportID: HIDReportID?) -> UInt32? { reportID.map { UInt32($0.rawValue) } }
}

@available(macOS 15, *)
enum CoreHIDPhysicalReportRequest {
  static let timeout: Duration = .seconds(2)

  static func perform(_ operation: (Duration) async throws -> Void) async -> Result<Void, any Error>
  {
    do {
      try await operation(timeout)
      return .success(())
    } catch { return .failure(error) }
  }
}

@available(macOS 15, *)
actor CoreHIDAccessBackend: HIDAccessBackend {

  let manager = HIDDeviceManager()
  let matchingCriteria: [HIDDeviceManager.DeviceMatchingCriteria]
  var managerTask: Task<Void, Never>?
  var sessionID: UUID?
  var continuation: AsyncStream<HIDDeviceEvent>.Continuation?
  var pendingAdmissions: [UInt64: UUID] = [:]
  var recordsByDeviceID: [UInt64: ClientRecord] = [:]
  var deviceIDsByLocation: [UInt32: Set<UInt64>] = [:]
  var releasedReferencesByLocation: [UInt32: [HIDDeviceClient.DeviceReference]] = [:]
  let eventAdapter = SynchronizedPhysicalHIDBackendEventAdapter()

  init(virtualProfile _: VirtualDeviceProfile, additionalProfileIdentifiers: [DeviceIdentifier]) {
    var criteria = [
      AppleGameControllerSyntheticHID.coreHIDMatchingCriteria(
        primaryUsage: .genericDesktop(.gamepad)
      ),
      AppleGameControllerSyntheticHID.coreHIDMatchingCriteria(
        primaryUsage: .genericDesktop(.joystick)
      ),
      AppleGameControllerSyntheticHID.coreHIDMatchingCriteria(
        primaryUsage: .genericDesktop(.multiAxisController)
      ),
    ]
    criteria += additionalProfileIdentifiers.map {
      AppleGameControllerSyntheticHID.coreHIDMatchingCriteria(
        vendorID: UInt32($0.vendorID),
        productID: UInt32($0.productID)
      )
    }
    matchingCriteria = criteria
  }
}
