import Foundation

/// Turns raw bytes from a controller into ``ControllerEvent`` values.
///
/// Each controller protocol (GIP for Xbox, DS4 for PlayStation, GenericHID)
/// has its own implementation. Add a new conforming type when you need to
/// support a new protocol.

/// Receiver-backed controllers can report logical controller connect/disconnect
/// independently from the HID device that carries reports.
public enum ControllerInputConnectionState: Sendable, Equatable {
  case connected
  case disconnected
}

/// Optional parser hook for logical controller lifecycle inside a physical input transport.
public protocol ControllerInputConnectionLifecycle: AnyObject {
  /// True when output should not be created until a logical controller connect event arrives.
  var requiresInputConnectionBeforeOutput: Bool { get }

  /// Returns and clears the most recent logical connection state change, if any.
  func consumeInputConnectionStateChange() -> ControllerInputConnectionState?
}

/// Optional parser hook for receiver status requests over HID feature reports.
public protocol HIDInputConnectionStatusRequester: AnyObject {
  /// Feature report that asks the receiver to emit its current logical connection state.
  func inputConnectionStatusRequestReport() -> PhysicalHIDOutputReport?
}

/// Optional parser hook for startup output reports sent through a HID transport.
public protocol HIDStartupOutputReportProvider: AnyObject {
  /// Source-backed startup reports needed before the controller emits full input reports.
  func hidStartupReports() -> [PhysicalHIDOutputReport]
  func hidStartupReports(transport: String?) -> [PhysicalHIDOutputReport]

  /// Minimum interval between startup reports for the selected transport.
  func hidStartupReportIntervalNanoseconds(transport: String?) -> UInt64

  /// Whether startup output must be delivered before startup feature reads.
  var hidStartupOutputPrecedesFeatureReads: Bool { get }

  /// Whether failed startup output must prevent virtual activation for this transport.
  func requiresSuccessfulHIDStartupOutput(transport: String?) -> Bool
}

extension HIDStartupOutputReportProvider {
  /// Source-backed startup reports for a specific HID transport, when transport matters.
  public func hidStartupReports(transport _: String?) -> [PhysicalHIDOutputReport] {
    hidStartupReports()
  }

  public func hidStartupReportIntervalNanoseconds(transport _: String?) -> UInt64 { 0 }

  public var hidStartupOutputPrecedesFeatureReads: Bool { false }
  public func requiresSuccessfulHIDStartupOutput(transport _: String?) -> Bool { false }
}

/// Parser-owned report liveness used when stale state can leave virtual controls held.
public protocol ControllerInputReportLivenessProvider: AnyObject {
  var inputReportLivenessTimeoutNanoseconds: UInt64 { get }
  var latestInputReportIsNeutral: Bool { get }
}

/// Bounded follow-up reads for startup protocols whose replies arrive through the input stream.
public protocol HIDStartupRecoveryProvider: AnyObject {
  func pendingHIDStartupReports() -> [PhysicalHIDOutputReport]
  func expireHIDStartupRequests()
}

/// Optional USB output emitted when a receiver-backed controller connects or disconnects.
public protocol USBInputConnectionOutputProvider: AnyObject {
  /// Source-backed packets for one logical controller lifecycle transition.
  func usbInputConnectionOutputPackets(for state: ControllerInputConnectionState) -> [[UInt8]]
}

/// Optional parser hook for startup output packets sent through a USB interrupt OUT endpoint.
public protocol USBStartupOutputProvider: AnyObject {
  /// Source-backed startup packets needed when OJD starts consuming a USB controller.
  func usbStartupOutputPackets() -> [[UInt8]]
  var usbStartupOutputIntervalNanoseconds: UInt64 { get }
  var usbStartupRetryDelays: [UInt64] { get }
}

extension USBStartupOutputProvider {
  public var usbStartupOutputIntervalNanoseconds: UInt64 { 0 }
  public var usbStartupRetryDelays: [UInt64] { [] }
}

public protocol USBKeepAliveOutputProvider: AnyObject {
  func usbKeepAlivePacket() -> PhysicalUSBOutputPacket?
  var usbKeepAliveIntervalNanoseconds: UInt64 { get }
}

extension USBKeepAliveOutputProvider {
  public var usbKeepAliveIntervalNanoseconds: UInt64 { 4_000_000_000 }
}

/// Optional parser hook for a controller-specific periodic HID output cadence.
public protocol HIDPeriodicOutputProvider: AnyObject {
  var hidPeriodicOutputIntervalNanoseconds: UInt64 { get }
  func hidPeriodicOutputReports() -> [PhysicalHIDOutputReport]
}

/// Resets protocol state whenever a physical transport session starts or ends.
public protocol InputParserSessionLifecycle: AnyObject { func resetProtocolState() }

/// Optional parser hook for transport packets produced while parsing input.
///
/// Protocol parsing remains synchronous and deterministic. The owning pipeline
/// drains these packets and performs the asynchronous USB writes in order.
public protocol USBDeferredOutputProvider: AnyObject { func consumeUSBOutputPackets() -> [[UInt8]] }

/// Optional parser hook for startup feature reports sent through a HID transport.
public protocol HIDStartupFeatureReportProvider: AnyObject {
  /// Source-backed feature reports needed when OJD starts consuming the physical input.
  func hidStartupFeatureReports() -> [PhysicalHIDOutputReport]
  func hidStartupFeatureReports(transport: String?) -> [PhysicalHIDOutputReport]
}

extension HIDStartupFeatureReportProvider {
  /// Source-backed feature reports for a specific HID transport, when transport matters.
  public func hidStartupFeatureReports(transport _: String?) -> [PhysicalHIDOutputReport] {
    hidStartupFeatureReports()
  }
}

/// Optional parser hook for shutdown feature reports sent through a HID transport.
public protocol HIDShutdownFeatureReportProvider: AnyObject {
  /// Source-backed feature reports needed when OJD stops consuming the physical input.
  func hidShutdownFeatureReports() -> [PhysicalHIDOutputReport]
}

/// Optional parser hook for startup feature-report reads sent through a HID transport.
public protocol HIDStartupFeatureReadRequestProvider: AnyObject {
  /// Source-backed feature reads needed to put the controller into operational mode.
  func hidStartupFeatureReadRequests() -> [PhysicalHIDFeatureReadRequest]
  func hidStartupFeatureReadRequests(transport: String?) -> [PhysicalHIDFeatureReadRequest]
}

extension HIDStartupFeatureReadRequestProvider {
  /// Source-backed feature reads for a specific HID transport, when transport matters.
  public func hidStartupFeatureReadRequests(transport _: String?) -> [PhysicalHIDFeatureReadRequest]
  { hidStartupFeatureReadRequests() }
}

/// Receives feature-read replies on the owning pipeline actor, serialized with input parsing.
public protocol HIDFeatureReportConsumer: AnyObject {
  /// False means the report was rejected and the previous parser state remains valid.
  func consumeHIDFeatureReport(
    _ data: Data,
    request: PhysicalHIDFeatureReadRequest,
    transport: String?
  ) -> Bool
}

/// Optional semantic input path for descriptor-defined HID gamepads.
public protocol HIDElementValueParser: AnyObject {
  /// Whether the parser maps this descriptor element into controller input.
  func acceptsElement(usagePage: UInt32, usage: UInt32) -> Bool

  /// Converts one IOKit-decoded HID element value into controller events.
  func parse(elementValue: HIDElementValue) -> [ControllerEvent]
}

/// Optional parser state exposed to diagnostics without entering the controller event stream.
public protocol ControllerBatteryTelemetryProvider: AnyObject {
  var batteryTelemetry: ControllerBatteryTelemetry? { get }
}

public protocol InputParser: AnyObject {
  /// Immutable sample-format capabilities implemented by this parser.
  var physicalInputCapabilities: PhysicalControllerInputCapabilities { get }

  /// Reads one raw data packet and returns zero or more controller events.
  ///
  /// Called once for every USB interrupt transfer or HID input report the
  /// system receives from the controller.
  func parse(data: Data) throws -> [ControllerEvent]

  /// Receives the host receipt time for protocols without a reliable device sample clock.
  func parse(data: Data, receivedAtNanoseconds: UInt64) throws -> [ControllerEvent]

}

extension InputParser {
  public func parse(data: Data, receivedAtNanoseconds _: UInt64) throws -> [ControllerEvent] {
    try parse(data: data)
  }

  public var physicalInputCapabilities: PhysicalControllerInputCapabilities { .none }

}
