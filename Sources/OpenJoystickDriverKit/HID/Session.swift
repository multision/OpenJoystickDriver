import Foundation
import IOKit

public enum PhysicalHIDFailure: Sendable, Equatable {
  case ioReturn(IOReturn)
  case coreHID(String)
}

public enum PhysicalHIDReportResult<Value: Sendable>: Sendable {
  case success(Value)
  case unavailable
  case failed(PhysicalHIDFailure)
}

extension PhysicalHIDReportResult {
  var value: Value? {
    guard case .success(let value) = self else { return nil }
    return value
  }

  var succeeded: Bool {
    if case .success = self { return true }
    return false
  }

  var failureDescription: String {
    switch self {
    case .success: "success"
    case .unavailable: "HID interface unavailable"
    case .failed(.ioReturn(let code)): "IOKit code \(code)"
    case .failed(.coreHID(let detail)): "CoreHID error \(detail)"
    }
  }
}

public enum PhysicalHIDClaimResult: Sendable, Equatable {
  case released
  case reacquired
  case unavailable
  case failed(PhysicalHIDFailure)
}

protocol HIDAccessBackend: Sendable {
  func deviceEvents() async -> AsyncStream<HIDDeviceEvent>
  func setOutputReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void>
  func setFeatureReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void>
  func getFeatureReport(
    locationID: UInt32,
    request: PhysicalHIDFeatureReadRequest
  ) async -> PhysicalHIDReportResult<Data>
  func releaseInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult
  func reacquireInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult
}

@available(macOS, introduced: 10.15, obsoleted: 15.0)
private final class IOHIDAccessBackend: HIDAccessBackend, Sendable {
  private let stream: HIDDeviceStream

  init(virtualProfile: VirtualDeviceProfile, additionalProfileIdentifiers: [DeviceIdentifier]) {
    stream = HIDDeviceStream(
      virtualProfile: virtualProfile,
      additionalProfileIdentifiers: additionalProfileIdentifiers
    )
  }

  func deviceEvents() async -> AsyncStream<HIDDeviceEvent> {
    await Task.yield()
    return stream.deviceEvents()
  }

  func setOutputReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) -> PhysicalHIDReportResult<Void> {
    stream.setOutputReport(locationID: locationID, report: report)
  }

  func setFeatureReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) -> PhysicalHIDReportResult<Void> {
    stream.setFeatureReport(locationID: locationID, report: report)
  }

  func getFeatureReport(
    locationID: UInt32,
    request: PhysicalHIDFeatureReadRequest
  ) -> PhysicalHIDReportResult<Data> {
    stream.getFeatureReport(locationID: locationID, request: request)
  }

  func releaseInputClaim(locationID: UInt32) -> PhysicalHIDClaimResult {
    stream.releaseInputClaim(locationID: locationID)
  }

  func reacquireInputClaim(locationID: UInt32) -> PhysicalHIDClaimResult {
    stream.reacquireInputClaim(locationID: locationID)
  }
}

/// Availability-selecting app HID access wrapper.
///
/// IOHIDManager owns macOS 10.15–14. CoreHID owns macOS 15 and later. Callers
/// depend only on this wrapper and never repeat availability checks.
public final class HIDManager: Sendable {
  private let backend: any HIDAccessBackend

  public init(
    virtualProfile: VirtualDeviceProfile = .default,
    additionalProfileIdentifiers: [DeviceIdentifier] = []
  ) {
    if #available(macOS 15, *) {
      backend = CoreHIDAccessBackend(
        virtualProfile: virtualProfile,
        additionalProfileIdentifiers: additionalProfileIdentifiers
      )
    } else {
      backend = IOHIDAccessBackend(
        virtualProfile: virtualProfile,
        additionalProfileIdentifiers: additionalProfileIdentifiers
      )
    }
  }

  public func deviceEvents() async -> AsyncStream<HIDDeviceEvent> { await backend.deviceEvents() }

  public func setOutputReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void> {
    await backend.setOutputReport(locationID: locationID, report: report)
  }

  public func setFeatureReport(
    locationID: UInt32,
    report: PhysicalHIDOutputReport
  ) async -> PhysicalHIDReportResult<Void> {
    await backend.setFeatureReport(locationID: locationID, report: report)
  }

  public func getFeatureReport(
    locationID: UInt32,
    request: PhysicalHIDFeatureReadRequest
  ) async -> PhysicalHIDReportResult<Data> {
    await backend.getFeatureReport(locationID: locationID, request: request)
  }

  public func releaseInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult {
    await backend.releaseInputClaim(locationID: locationID)
  }

  public func reacquireInputClaim(locationID: UInt32) async -> PhysicalHIDClaimResult {
    await backend.reacquireInputClaim(locationID: locationID)
  }
}
