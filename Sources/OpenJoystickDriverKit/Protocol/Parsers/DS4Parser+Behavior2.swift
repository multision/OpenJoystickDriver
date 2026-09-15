import Foundation

extension DS4Parser {

  func parseSticks(
    bytes: [UInt8]
  ) -> (events: [ControllerEvent], raws: (UInt8, UInt8, UInt8, UInt8)) {
    let lsxRaw = bytes[ReportOffset.leftStickX]
    let lsyRaw = bytes[ReportOffset.leftStickY]
    let rsxRaw = bytes[ReportOffset.rightStickX]
    let rsyRaw = bytes[ReportOffset.rightStickY]
    var events: [ControllerEvent] = []
    if lsxRaw != prevLSX || lsyRaw != prevLSY {

      let lx = normalizeHID(lsxRaw)
      let ly = normalizeHID(lsyRaw)
      events.append(.leftStickChanged(x: lx, y: ly))
    }
    if rsxRaw != prevRSX || rsyRaw != prevRSY {
      let rx = normalizeHID(rsxRaw)
      let ry = normalizeHID(rsyRaw)

      events.append(.rightStickChanged(x: rx, y: ry))
    }
    return (events, (lsxRaw, lsyRaw, rsxRaw, rsyRaw))
  }

  func parseTriggers(bytes: [UInt8]) -> (events: [ControllerEvent], values: (UInt8, UInt8)) {
    let l2 = bytes[ReportOffset.l2Trigger]
    let r2 = bytes[ReportOffset.r2Trigger]
    var events: [ControllerEvent] = []
    if l2 != prevL2 { events.append(.leftTriggerChanged(Float(l2) / ds4TriggerMax)) }
    if r2 != prevR2 { events.append(.rightTriggerChanged(Float(r2) / ds4TriggerMax)) }
    return (events, (l2, r2))
  }

  func parseDpad(bytes: [UInt8]) -> (events: [ControllerEvent], value: UInt8) {
    let hat = bytes[ReportOffset.buttons0] & 0x0F
    var events: [ControllerEvent] = []
    if hat != prevHat { events.append(.dpadChanged(mapHat(hat))) }
    return (events, hat)
  }

  func parseFaceButtons(bytes: [UInt8]) -> (events: [ControllerEvent], value: UInt8) {
    let face = bytes[ReportOffset.buttons0]
    let events = diffButtons(
      prev: prevFace,
      curr: face,
      mapping: [(0x10, .square), (0x20, .cross), (0x40, .circle), (0x80, .triangle)]
    )
    return (events, face)
  }

  func parseShoulderButtons(bytes: [UInt8]) -> (events: [ControllerEvent], value: UInt8) {
    let shoulders = bytes[ReportOffset.buttons1]
    let events = diffButtons(
      prev: prevShoulders,
      curr: shoulders,
      mapping: [
        (0x01, .l1), (0x02, .r1), (0x10, .share), (0x20, .options), (0x40, .leftStick),
        (0x80, .rightStick),
      ]
    )
    return (events, shoulders)
  }

  func parseSystemButtons(bytes: [UInt8]) -> (events: [ControllerEvent], value: UInt8) {
    let system = bytes[ReportOffset.buttons2]
    let events = diffButtons(

      prev: prevSystem,
      curr: system,
      mapping: [(0x01, .ps), (0x02, .touchpad)]
    )
    return (events, system)
  }

  private func normalizeHID(_ raw: UInt8) -> Float {
    let normalized = (Float(raw) - ds4AxisCenter) / ds4AxisCenter
    if abs(normalized) < ds4AxisDeadzone { return 0 }
    return normalized

  }

  private func mapHat(_ hat: UInt8) -> DpadDirection {
    switch hat {
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

  func ds4BluetoothCRC32(report: [UInt8]) -> UInt32 {

    var crc = updateCRC32(0xFFFF_FFFF, byte: ds4BluetoothHIDOutputHeader)
    for byte in report.dropLast(4) { crc = updateCRC32(crc, byte: byte) }
    return ~crc
  }

  func updateCRC32(_ current: UInt32, byte: UInt8) -> UInt32 {
    var crc = current ^ UInt32(byte)
    for _ in 0..<8 { if crc & 1 == 1 { crc = (crc >> 1) ^ 0xEDB8_8320 } else { crc >>= 1 } }
    return crc
  }

}
