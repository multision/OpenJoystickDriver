import Foundation

let gameSirReportLength = 64
let gameSirHeartbeatIntervalNanoseconds: UInt64 = 500_000_000
let gameSirCommandIntervalNanoseconds: UInt64 = 20_000_000
let gameSirUSBTimeoutMilliseconds: UInt32 = 2_000
let gameSirEnhancedHIDHeartbeatPayload: [UInt8] = [0x0F, 0xF2]

/// GameSir protocol families backed by the vendor's observed report streams.
public enum GameSirProtocol: Sendable, Equatable {
  case g7ProUSB
  case enhancedHID
}

/// Product-specific capabilities layered on the shared GameSir framing.
public enum GameSirModel: Sendable, Equatable {
  case g7Pro
  case cyclone2
  case g7Pro8K
}

/// Parser and output encoder for source-backed GameSir controller identities.
public final class GameSirParser: InputParser, InputParserSessionLifecycle,
  HIDStartupOutputReportProvider, HIDPeriodicOutputProvider, USBKeepAliveOutputProvider,
  ControllerBatteryTelemetryProvider, PhysicalHIDRumbleOutput, PhysicalHIDColorOutputPlan,
  PhysicalHIDBrightnessOutputPlan, PhysicalUSBBrightnessOutputPlan
{
  let gameSirProtocol: GameSirProtocol
  let model: GameSirModel
  let stateLock = NSLock()
  var standardParser = Xbox360Parser()
  var previousFace: UInt8 = 0
  var previousMeta: UInt8 = 0
  var previousExtras: UInt8 = 0
  var previousLeftX: UInt8 = 128
  var previousLeftY: UInt8 = 128
  var previousRightX: UInt8 = 128
  var previousRightY: UInt8 = 128
  var previousLeftTrigger: UInt8 = 0
  var previousRightTrigger: UInt8 = 0
  var previousMotionCounter: UInt8?
  var motionFirstReceipt: UInt64?
  var motionElapsed: UInt64 = 0
  var motionSequence: UInt64 = 0
  var sequence: UInt8 = 0
  var sessionReady = false
  var activeLightingSlot: UInt8?
  var lightingBrightness: UInt8 = 100
  var storedBatteryTelemetry: ControllerBatteryTelemetry?

  public init(protocol gameSirProtocol: GameSirProtocol, model: GameSirModel) {
    self.gameSirProtocol = gameSirProtocol
    self.model = model
  }
}
