import Foundation

private let gameSirReportLength = 64
private let gameSirHeartbeatIntervalNanoseconds: UInt64 = 500_000_000
private let gameSirCommandIntervalNanoseconds: UInt64 = 20_000_000

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
  private let gameSirProtocol: GameSirProtocol
  private let model: GameSirModel
  private let stateLock = NSLock()
  private var standardParser = Xbox360Parser()
  private var previousFace: UInt8 = 0
  private var previousMeta: UInt8 = 0
  private var previousExtras: UInt8 = 0
  private var previousLeftX: UInt8 = 128
  private var previousLeftY: UInt8 = 128
  private var previousRightX: UInt8 = 128
  private var previousRightY: UInt8 = 128
  private var previousLeftTrigger: UInt8 = 0
  private var previousRightTrigger: UInt8 = 0
  private var previousMotionCounter: UInt8?
  private var motionFirstReceipt: UInt64?
  private var motionElapsed: UInt64 = 0
  private var motionSequence: UInt64 = 0
  private var sequence: UInt8 = 0
  private var sessionReady = false
  private var activeLightingSlot: UInt8?
  private var lightingBrightness: UInt8 = 100
  private var storedBatteryTelemetry: ControllerBatteryTelemetry?

  public init(protocol gameSirProtocol: GameSirProtocol, model: GameSirModel) {
    self.gameSirProtocol = gameSirProtocol
    self.model = model
  }

  public var physicalInputCapabilities: PhysicalControllerInputCapabilities {
    let buttons: [Button]
    switch model {
    case .g7Pro: buttons = [.leftPaddle, .rightPaddle, .leftGrip, .rightGrip, .leftFunction]
    case .cyclone2: buttons = [.leftPaddle, .rightPaddle, .leftFunction]
    case .g7Pro8K: buttons = [.leftPaddle, .rightPaddle, .leftGrip, .rightGrip, .leftFunction]
    }
    return PhysicalControllerInputCapabilities(
      rawMotion: gameSirProtocol == .enhancedHID,
      additionalButtons: buttons
    )
  }

  public var batteryTelemetry: ControllerBatteryTelemetry? {
    stateLock.withLock { storedBatteryTelemetry }
  }

  public func parse(data: Data) throws -> [ControllerEvent] {
    try parse(data: data, receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }

  public func parse(data: Data, receivedAtNanoseconds: UInt64) throws -> [ControllerEvent] {
    let bytes = [UInt8](data)
    return stateLock.withLock {
      switch gameSirProtocol {
      case .g7ProUSB:
        if bytes.count == 20, bytes.prefix(2) == [0x00, 0x14] {
          sessionReady = true
          return (try? standardParser.parse(data: data)) ?? []
        }
        return parseG7Telemetry(bytes, receivedAtNanoseconds: receivedAtNanoseconds)
      case .enhancedHID: return parseEnhanced(bytes, receivedAtNanoseconds: receivedAtNanoseconds)
      }
    }
  }

  public func resetProtocolState() {
    stateLock.withLock {
      standardParser = Xbox360Parser()
      previousFace = 0
      previousMeta = 0
      previousExtras = 0
      previousLeftX = 128
      previousLeftY = 128
      previousRightX = 128
      previousRightY = 128
      previousLeftTrigger = 0
      previousRightTrigger = 0
      previousMotionCounter = nil
      motionFirstReceipt = nil
      motionElapsed = 0
      motionSequence = 0
      sequence = 0
      sessionReady = false
      activeLightingSlot = nil
      lightingBrightness = 100
      storedBatteryTelemetry = nil
    }
  }

  public func hidStartupReports() -> [PhysicalHIDOutputReport] {
    guard gameSirProtocol == .enhancedHID else { return [] }
    var reports = [Self.hidReport([0x0F, 0xF2])]
    if model == .cyclone2 { reports.append(Self.hidReport([0x0F, 0x04, 0x20, 0x00, 0x00, 0x01])) }
    return reports
  }

  public func hidStartupReportIntervalNanoseconds(transport _: String?) -> UInt64 {
    gameSirCommandIntervalNanoseconds
  }

  public var hidPeriodicOutputIntervalNanoseconds: UInt64 { gameSirHeartbeatIntervalNanoseconds }

  public func hidPeriodicOutputReports() -> [PhysicalHIDOutputReport] {
    gameSirProtocol == .enhancedHID ? [Self.hidReport([0x0F, 0xF2])] : []
  }

  public var usbKeepAliveIntervalNanoseconds: UInt64 { gameSirHeartbeatIntervalNanoseconds }

  public func usbKeepAlivePacket() -> PhysicalUSBOutputPacket? {
    guard gameSirProtocol == .g7ProUSB else { return nil }
    return stateLock.withLock {
      PhysicalUSBOutputPacket(
        endpoint: 0x02,
        bytes: g7Packet(command: 0x02, payload: [0xF2, 0x00]),
        timeoutMilliseconds: 2_000
      )
    }
  }

  public var physicalRumbleMotors: [PhysicalRumbleMotor] {
    gameSirProtocol == .enhancedHID ? [.leftMain, .rightMain] : []
  }

  public var physicalBinaryRumbleMotors: [PhysicalRumbleMotor] { [] }
  public var minimumPhysicalOutputIntervalNanoseconds: UInt64 { gameSirCommandIntervalNanoseconds }

  public func physicalRumbleReport(
    left: UInt8,
    right: UInt8,
    lt _: UInt8,
    rt _: UInt8
  ) -> PhysicalHIDOutputReport { Self.hidReport([0x0F, 0x20, 0x66, 0x55, left, right]) }

  public var physicalLightingFeatures: [PhysicalLightingFeature] {
    switch (gameSirProtocol, model) {
    case (.g7ProUSB, .g7Pro): [.programmableBrightness]
    case (.enhancedHID, .cyclone2), (.enhancedHID, .g7Pro8K):
      [.programmableColor, .programmableBrightness]
    default: []
    }
  }

  public var physicalDefaultColor: (red: UInt8, green: UInt8, blue: UInt8) { (0, 128, 255) }

  public func physicalColorOutputPlan(
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) -> PhysicalHIDOutputPlan? {
    stateLock.withLock {
      guard gameSirProtocol == .enhancedHID, sessionReady else { return nil }
      switch model {
      case .cyclone2:
        guard let slot = activeLightingSlot, slot <= 4 else { return nil }
        let frame = Self.solidColorFrame(red: red, green: green, blue: blue)
        let record: [UInt8] =
          [0x01, 0x05, 0x14, lightingBrightness] + Array(repeating: frame, count: 8).flatMap { $0 }
        var reports = Self.bareWriteReports(
          bank: 0x20,
          address: 0x0001 + UInt16(slot) * 0x007C,
          data: record
        )
        reports += Self.bareWriteReports(bank: 0x20, address: 0x0000, data: [slot])
        return PhysicalHIDOutputPlan(
          reports: reports,
          intervalNanoseconds: gameSirCommandIntervalNanoseconds
        )
      case .g7Pro8K:
        let (hue, saturation) = Self.hueAndSaturation(red: red, green: green, blue: blue)
        let data = [UInt8(hue >> 8), UInt8(hue & 0xFF), saturation]
        let reports = [0x000C, 0x0010, 0x0014, 0x0018].flatMap {
          Self.bareWriteReports(bank: 0x20, address: UInt16($0), data: data)
        }
        return PhysicalHIDOutputPlan(
          reports: reports,
          intervalNanoseconds: gameSirCommandIntervalNanoseconds
        )
      case .g7Pro: return nil
      }
    }
  }

  public func physicalBrightnessOutputPlan(_ brightness: UInt8) -> PhysicalHIDOutputPlan? {
    stateLock.withLock {
      guard gameSirProtocol == .enhancedHID, sessionReady else { return nil }
      let value = UInt8((Double(brightness) * 100 / 255).rounded())
      lightingBrightness = value
      let address: UInt16
      switch model {
      case .cyclone2:
        guard let slot = activeLightingSlot, slot <= 4 else { return nil }
        address = 0x0001 + UInt16(slot) * 0x007C + 3
      case .g7Pro8K: address = 0x0001
      case .g7Pro: return nil
      }
      return PhysicalHIDOutputPlan(
        reports: Self.bareWriteReports(bank: 0x20, address: address, data: [value])
      )
    }
  }

  public func physicalBrightnessOutputPackets(_ brightness: UInt8) -> [PhysicalUSBOutputPacket]? {
    stateLock.withLock {
      guard gameSirProtocol == .g7ProUSB, model == .g7Pro, sessionReady else { return nil }
      let value = UInt8((Double(brightness) * 100 / 255).rounded())
      return [
        PhysicalUSBOutputPacket(
          endpoint: 0x02,
          bytes: g7Packet(command: 0x3C, payload: [0x03, 0x20, 0x01, 0xF9, 0x01, value]),
          timeoutMilliseconds: 2_000
        )
      ]
    }
  }

  private func parseG7Telemetry(
    _ bytes: [UInt8],
    receivedAtNanoseconds _: UInt64
  ) -> [ControllerEvent] {
    guard bytes.count == gameSirReportLength, bytes[0] == 0x10 else { return [] }
    if bytes[1] == 0x05, bytes[2] == 0x20, bytes[3] == 0, bytes[4] == 0, bytes[5] == 1,
      bytes[6] <= 4
    {
      activeLightingSlot = bytes[6]
      return []
    }
    guard bytes[3] == 0x3C, bytes[4] == 0xE0 else { return [] }
    sessionReady = true
    updateBattery(percentage: bytes[33], charging: bytes[32] == 1)
    return extraButtonEvents(current: bytes[60], includesInnerGrips: true)
  }

  private func parseEnhanced(_ bytes: [UInt8], receivedAtNanoseconds: UInt64) -> [ControllerEvent] {
    guard bytes.count == gameSirReportLength else { return [] }
    if bytes[0] == 0x10, bytes[1] == 0x05, bytes[2] == 0x20, bytes[3] == 0, bytes[4] == 0,
      bytes[5] == 1, bytes[6] <= 4, model == .cyclone2
    {
      activeLightingSlot = bytes[6]
      return []
    }
    guard bytes[0] == 0x12 else { return [] }
    sessionReady = true
    updateBattery(percentage: bytes[36], charging: bytes[35] & 1 != 0)
    var events: [ControllerEvent] = []
    events += baseButtonEvents(face: bytes[5], meta: bytes[6])
    events += axisEvents(bytes)
    events += extraButtonEvents(current: bytes[60], includesInnerGrips: model == .g7Pro8K)
    if let motion = motionEvent(bytes, receivedAtNanoseconds: receivedAtNanoseconds) {
      events.append(.motionSample(motion))
    }
    previousFace = bytes[5]
    previousMeta = bytes[6]
    previousLeftX = bytes[1]
    previousLeftY = bytes[2]
    previousRightX = bytes[3]
    previousRightY = bytes[4]
    previousLeftTrigger = bytes[8]
    previousRightTrigger = bytes[9]
    return events
  }

  private func updateBattery(percentage: UInt8, charging: Bool) {
    storedBatteryTelemetry = ControllerBatteryTelemetry(
      percentage: min(Int(percentage), 100),
      chargingState: charging ? .charging : .discharging,
      cableState: charging ? .connected : .unknown
    )
  }

  private func baseButtonEvents(face: UInt8, meta: UInt8) -> [ControllerEvent] {
    var events = diffButtons(
      prev: previousFace,
      curr: face,
      mapping: [(0x10, .x), (0x20, .a), (0x40, .b), (0x80, .y)]
    )
    events += diffButtons(
      prev: previousMeta,
      curr: meta,
      mapping: [
        (0x01, .leftBumper), (0x02, .rightBumper), (0x10, .back), (0x20, .start),
        (0x40, .leftStick), (0x80, .rightStick),
      ]
    )
    if face & 0x0F != previousFace & 0x0F {
      events.append(.dpadChanged(Self.dpadDirection(face & 0x0F)))
    }
    return events
  }

  private func axisEvents(_ bytes: [UInt8]) -> [ControllerEvent] {
    var events: [ControllerEvent] = []
    if bytes[1] != previousLeftX || bytes[2] != previousLeftY {
      events.append(.leftStickChanged(x: Self.axis(bytes[1]), y: -Self.axis(bytes[2])))
    }
    if bytes[3] != previousRightX || bytes[4] != previousRightY {
      events.append(.rightStickChanged(x: Self.axis(bytes[3]), y: -Self.axis(bytes[4])))
    }
    if bytes[8] != previousLeftTrigger { events.append(.leftTriggerChanged(Float(bytes[8]) / 255)) }
    if bytes[9] != previousRightTrigger {
      events.append(.rightTriggerChanged(Float(bytes[9]) / 255))
    }
    return events
  }

  private func extraButtonEvents(current: UInt8, includesInnerGrips: Bool) -> [ControllerEvent] {
    var mapping: [(UInt8, Button)] = [
      (0x01, .guide), (0x02, .share), (0x08, .leftPaddle), (0x10, .rightPaddle),
      (0x20, .leftFunction),
    ]
    if includesInnerGrips { mapping += [(0x40, .leftGrip), (0x80, .rightGrip)] }
    let events = diffButtons(prev: previousExtras, curr: current, mapping: mapping)
    previousExtras = current
    return events
  }

  private func motionEvent(
    _ bytes: [UInt8],
    receivedAtNanoseconds: UInt64
  ) -> ControllerMotionSample? {
    let counter = bytes[7]
    guard previousMotionCounter != counter else { return nil }
    previousMotionCounter = counter
    if let first = motionFirstReceipt {
      motionElapsed = max(
        motionElapsed,
        receivedAtNanoseconds >= first ? receivedAtNanoseconds - first : 0
      )
    } else {
      motionFirstReceipt = receivedAtNanoseconds
    }
    let sample = ControllerMotionSample(
      timestamp: ControllerSampleTimestamp(
        rawCounter: UInt32(counter),
        elapsedNanoseconds: motionElapsed,
        tickNanosecondsNumerator: nil,
        tickNanosecondsDenominator: nil,
        sequenceIndex: motionSequence,
        basis: .hostEstimate
      ),
      rawGyroscope: Self.vector(bytes, at: 14),
      rawAccelerometer: Self.vector(bytes, at: 20)
    )
    motionSequence += 1
    return sample
  }

  private func g7Packet(command: UInt8, payload: [UInt8]) -> [UInt8] {
    sequence &+= 1
    return Self.padded([0x0F, 0x00, sequence, command] + payload)
  }

  private static func hidReport(_ bytes: [UInt8]) -> PhysicalHIDOutputReport {
    PhysicalHIDOutputReport(reportID: 0x0F, bytes: padded(bytes))
  }

  private static func bareWriteReports(
    bank: UInt8,
    address: UInt16,
    data: [UInt8]
  ) -> [PhysicalHIDOutputReport] {
    stride(from: 0, to: data.count, by: 48).map { offset in
      let chunk = Array(data[offset..<min(data.count, offset + 48)])
      let currentAddress = address + UInt16(offset)
      return hidReport(
        [
          0x0F, 0x03, bank, UInt8(currentAddress >> 8), UInt8(currentAddress & 0xFF),
          UInt8(chunk.count),
        ] + chunk
      )
    }
  }

  private static func padded(_ bytes: [UInt8]) -> [UInt8] {
    Array((bytes + Array(repeating: 0, count: gameSirReportLength)).prefix(gameSirReportLength))
  }

  private static func axis(_ value: UInt8) -> Float {
    let centered = Float(Int(value) - 128)
    return max(-1, min(1, centered / (centered < 0 ? 128 : 127)))
  }

  private static func dpadDirection(_ value: UInt8) -> DpadDirection {
    switch value {
    case 0: .north
    case 1: .northEast
    case 2: .east
    case 3: .southEast
    case 4: .south
    case 5: .southWest
    case 6: .west
    case 7: .northWest
    default: .neutral
    }
  }

  private static func vector(_ bytes: [UInt8], at offset: Int) -> ControllerRawSensorVector {
    func value(_ index: Int) -> Int16 {
      Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
    }
    return ControllerRawSensorVector(x: value(offset), y: value(offset + 2), z: value(offset + 4))
  }

  private static func hueAndSaturation(red: UInt8, green: UInt8, blue: UInt8) -> (UInt16, UInt8) {
    let r = Double(red) / 255
    let g = Double(green) / 255
    let b = Double(blue) / 255
    let maximum = max(r, g, b)
    let minimum = min(r, g, b)
    let delta = maximum - minimum
    let saturation = maximum == 0 ? 0 : UInt8((delta / maximum * 100).rounded())
    guard delta > 0 else { return (0, saturation) }
    let rawHue: Double
    if maximum == r {
      rawHue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maximum == g {
      rawHue = 60 * ((b - r) / delta + 2)
    } else {
      rawHue = 60 * ((r - g) / delta + 4)
    }
    return (UInt16((rawHue < 0 ? rawHue + 360 : rawHue).rounded()) % 360, saturation)
  }

  private static func solidColorFrame(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
    stride(from: 0, to: 15, by: 3).reduce(into: [UInt8](repeating: 0, count: 15)) {
      result,
      offset in
      result[offset] = red
      result[offset + 1] = green
      result[offset + 2] = blue
    }
  }
}
