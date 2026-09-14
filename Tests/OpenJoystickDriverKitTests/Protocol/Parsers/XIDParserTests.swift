import Foundation
import Testing

@testable import OpenJoystickDriverKit

private func makeXIDReport(
  digital: UInt8 = 0,
  analogA: UInt8 = 0,
  analogB: UInt8 = 0,
  analogX: UInt8 = 0,
  analogY: UInt8 = 0,
  black: UInt8 = 0,
  white: UInt8 = 0,
  lt: UInt8 = 0,
  rt: UInt8 = 0,
  lsx: Int16 = 0,
  lsy: Int16 = 0
) -> Data {
  var r = [UInt8](repeating: 0, count: 20)
  r[0] = 0x00
  r[1] = 0x14
  r[2] = digital
  r[4] = analogA
  r[5] = analogB
  r[6] = analogX
  r[7] = analogY
  r[8] = black
  r[9] = white
  r[10] = lt
  r[11] = rt
  let lsxBits = UInt16(bitPattern: lsx)
  r[12] = UInt8(lsxBits & 0xFF)
  r[13] = UInt8(lsxBits >> 8)
  let lsyBits = UInt16(bitPattern: lsy)
  r[14] = UInt8(lsyBits & 0xFF)
  r[15] = UInt8(lsyBits >> 8)
  return Data(r)
}

struct XIDParserTests {
  @Test
  func rumbleUsesXIDBigEndianFullRangeMotorsAndCatalogEndpoint() throws {
    let parser = XIDParser(outEndpoint: 0x07)
    let catalogParser = try #require(
      ParserRegistry().parser(for: DeviceIdentifier(vendorID: 0x045E, productID: 0x0202))
        as? XIDParser
    )

    #expect(parser.physicalRumbleMotors == [.leftMain, .rightMain])
    #expect(parser.supportsPhysicalRumble)
    #expect(catalogParser.physicalRumblePacket(left: 0, right: 0, lt: 0, rt: 0).endpoint == 0x02)
    #expect(
      parser.physicalRumblePacket(left: 0, right: 0, lt: 255, rt: 255)
        == PhysicalUSBOutputPacket(
          endpoint: 0x07,
          bytes: [0x00, 0x06, 0x00, 0x00, 0x00, 0x00],
          timeoutMilliseconds: 2_000
        )
    )
    #expect(
      parser.physicalRumblePacket(left: 0x12, right: 0x34, lt: 0, rt: 0).bytes == [
        0x00, 0x06, 0x12, 0x12, 0x34, 0x34,
      ]
    )
    #expect(
      parser.physicalRumblePacket(left: 255, right: 255, lt: 0, rt: 0).bytes == [
        0x00, 0x06, 0xFF, 0xFF, 0xFF, 0xFF,
      ]
    )
  }

  @Test(arguments: UInt8(0)...UInt8(15))
  func allDpadMasks(mask: UInt8) throws {
    let directions: [DpadDirection] = [
      .neutral, .north, .south, .neutral, .west, .northWest, .southWest, .neutral, .east,
      .northEast, .southEast, .neutral, .neutral, .neutral, .neutral, .neutral,
    ]
    let parser = XIDParser()
    _ = try parser.parse(data: makeXIDReport(digital: mask == 1 ? 2 : 1))
    let events = try parser.parse(data: makeXIDReport(digital: mask))
    #expect(events == [.dpadChanged(directions[Int(mask)])])
  }

  @Test
  func shortReportIsIgnored() throws {
    #expect(try XIDParser().parse(data: Data([0x00, 0x14, 0x00])).isEmpty)
  }

  @Test
  func analogABecomesDigitalPress() throws {
    let parser = XIDParser()
    _ = try parser.parse(data: makeXIDReport())
    let events = try parser.parse(data: makeXIDReport(analogA: 0xFF))
    #expect(events.contains(.buttonPressed(.a)))
  }

  @Test
  func digitalStartAndDpadMatchLinuxXpad() throws {
    let parser = XIDParser()
    _ = try parser.parse(data: makeXIDReport())
    let events = try parser.parse(data: makeXIDReport(digital: 0x11))
    #expect(events.contains(.buttonPressed(.start)))
    #expect(events.contains(.dpadChanged(.north)))
  }

  @Test
  func analogTriggersAndBlackWhiteShoulders() throws {
    let parser = XIDParser()
    _ = try parser.parse(data: makeXIDReport())
    let events = try parser.parse(data: makeXIDReport(black: 0x80, white: 0x40, lt: 128, rt: 255))
    #expect(events.contains(.buttonPressed(.leftBumper)))
    #expect(events.contains(.buttonPressed(.rightBumper)))
    #expect(events.contains(.leftTriggerChanged(128.0 / 255.0)))
    #expect(events.contains(.rightTriggerChanged(1)))
  }

  @Test
  func analogZeroReleasesFaceButton() throws {
    let parser = XIDParser()
    _ = try parser.parse(data: makeXIDReport(analogY: 0x20))
    let events = try parser.parse(data: makeXIDReport(analogY: 0))
    #expect(events.contains(.buttonReleased(.y)))
  }
}
