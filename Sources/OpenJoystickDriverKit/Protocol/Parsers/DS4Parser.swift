import Foundation

let ds4AxisCenter: Float = 128
let ds4AxisDeadzone: Float = 0.08
private let ds4HatNeutral: UInt8 = 0xFF
let ds4TriggerMax: Float = 255
let ds4USBInputReportID: UInt8 = 0x01
let ds4BluetoothInputReportID: UInt8 = 0x11
let ds4BluetoothHIDInputTransaction: UInt8 = 0xA1
let ds4BluetoothHIDOutputHeader: UInt8 = 0xA2
let ds4USBOutputReportID: UInt8 = 0x05
let ds4USBOutputReportLength = 32
let ds4BluetoothOutputReportID: UInt8 = 0x11
let ds4BluetoothOutputReportLength = 78
let ds4OutputValidFlagMotor: UInt8 = 0x01
let ds4OutputValidFlagColor: UInt8 = 0x02
let ds4BluetoothOutputHIDAndCRCFlag: UInt8 = 0xC0
let ds4BluetoothOutputPollInterval: UInt8 = 0x04

public enum DS4Transport: String, Codable, Equatable, Sendable {
  case usb
  case bluetooth
}

public enum DS4ParserError: Error, Equatable, Sendable {
  case invalidReportFraming
  case invalidBluetoothCRC
}

/// Parser for Sony DualShock 4 controllers.
///
/// DS4 sends input reports automatically over USB, with no handshake.
/// IOKit reports the DS4 report ID separately, so wired HID input can arrive
/// with or without the leading `0x01` report ID byte.
/// Bluetooth input report `0x11` carries the same controller state after its
/// transport/control prefix.
public final class DS4Parser: InputParser, PhysicalHIDRumbleOutput, PhysicalHIDColorOutput,
  HIDStartupOutputReportProvider, HIDStartupFeatureReadRequestProvider, HIDFeatureReportConsumer,
  ControllerBatteryTelemetryProvider, ControllerInputReportLivenessProvider,
  ControllerInputReportObserver, ControllerInputReportFormatProvider
{

  var sensorClock = SonySensorClock(mask: 0xFFFF, tickNumerator: 16_000)
  var motionCalibration = SonyMotionCalibration.nominal
  var prevFace: UInt8 = 0
  var prevShoulders: UInt8 = 0
  var prevSystem: UInt8 = 0
  var prevHat: UInt8 = ds4HatNeutral
  var prevL2: UInt8 = 0
  var prevR2: UInt8 = 0
  var prevLSX = UInt8(ds4AxisCenter)
  var prevLSY = UInt8(ds4AxisCenter)
  var prevRSX = UInt8(ds4AxisCenter)
  var prevRSY = UInt8(ds4AxisCenter)
  var previousSensorTimestamp: UInt16?
  public internal(set) var transport: DS4Transport = .usb
  public internal(set) var batteryTelemetry: ControllerBatteryTelemetry?
  public let inputReportLivenessTimeoutNanoseconds: UInt64 = 1_000_000_000
  public internal(set) var latestInputReportObservation: ControllerInputReportObservation?
  public internal(set) var latestInputReportFormat: String?

  /// Creates a new DS4Parser.
  public init(prefersBluetooth: Bool = false) { transport = prefersBluetooth ? .bluetooth : .usb }
}
