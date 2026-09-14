import OpenJoystickDriverKit
import Testing

struct SCUFEnvisionParserTests {
  private func parser() -> GenericHIDParser {
    GenericHIDParser(identifier: DeviceIdentifier(vendorID: 0x2E95, productID: 0x434D))
  }

  @Test
  func mapsConfirmedButtonsAndRejectsUnverifiedButtons() {
    let parser = parser()
    let buttons: [Button] = [
      .a, .b, .x, .y, .leftBumper, .rightBumper, .back, .start, .leftStick, .rightStick,
    ]
    for (index, button) in buttons.enumerated() {
      #expect(
        parser.parse(elementValue: value(page: 9, usage: UInt32(index + 1), integer: 1)) == [
          .buttonPressed(button)
        ]
      )
      #expect(
        parser.parse(elementValue: value(page: 9, usage: UInt32(index + 1), integer: 0)) == [
          .buttonReleased(button)
        ]
      )
    }
    for usage: UInt32 in 11...19 {
      #expect(parser.parse(elementValue: value(page: 9, usage: usage, integer: 1)).isEmpty)
    }
  }

  @Test
  func acceptsOnlyReportSix() {
    let parser = parser()
    for reportID: UInt32? in [nil, 0, 1, 7, 256] {
      #expect(
        parser.parse(elementValue: value(page: 9, usage: 1, integer: 1, reportID: reportID)).isEmpty
      )
    }
    #expect(
      parser.parse(elementValue: value(page: 9, usage: 1, integer: 1, reportID: 6)) == [
        .buttonPressed(.a)
      ]
    )
  }

  @Test
  func mapsSignedSticksAndIndependentTriggers() {
    let parser = parser()
    #expect(
      parser.parse(elementValue: value(usage: 0x30, integer: 32_767)) == [
        .leftStickChanged(x: 1, y: 0)
      ]
    )
    #expect(
      parser.parse(elementValue: value(usage: 0x31, integer: -32_768)) == [
        .leftStickChanged(x: 1, y: 1)
      ]
    )
    #expect(
      parser.parse(elementValue: value(usage: 0x32, integer: -32_768)) == [
        .rightStickChanged(x: -1, y: 0)
      ]
    )
    #expect(
      parser.parse(elementValue: value(usage: 0x35, integer: 32_767)) == [
        .rightStickChanged(x: -1, y: -1)
      ]
    )
    #expect(
      parser.parse(elementValue: value(usage: 0x33, integer: 1_023, minimum: 0, maximum: 1_023))
        == [.leftTriggerChanged(1)]
    )
    #expect(
      parser.parse(elementValue: value(usage: 0x34, integer: 512, minimum: 0, maximum: 1_023)) == [
        .rightTriggerChanged(Float(512) / 1_023)
      ]
    )
  }

  @Test
  func mapsHatDiagonalsAndNeutral() {
    let parser = parser()
    let directions: [DpadDirection] = [
      .north, .northEast, .east, .southEast, .south, .southWest, .west, .northWest, .neutral,
    ]
    for (position, direction) in directions.enumerated() {
      #expect(
        parser.parse(elementValue: value(usage: 0x39, integer: position, minimum: 0, maximum: 7))
          == [.dpadChanged(direction)]
      )
    }
  }

  @Test
  func ordinaryGenericControllerStillUsesDescriptorDefaults() {
    let parser = GenericHIDParser(identifier: DeviceIdentifier(vendorID: 1, productID: 2))
    #expect(
      parser.parse(
        elementValue: value(usage: 0x32, integer: 255, minimum: 0, maximum: 255, reportID: nil)
      ) == [.leftTriggerChanged(1)]
    )
    #expect(
      parser.parse(elementValue: value(page: 9, usage: 11, integer: 1, reportID: 99)) == [
        .buttonPressed(.guide)
      ]
    )
  }

  private func value(
    page: UInt32 = 1,
    usage: UInt32,
    integer: Int,
    minimum: Int = -32_768,
    maximum: Int = 32_767,
    reportID: UInt32? = 6
  ) -> HIDElementValue {
    HIDElementValue(
      usagePage: page,
      usage: usage,
      logicalMinimum: minimum,
      logicalMaximum: maximum,
      integerValue: integer,
      reportID: reportID
    )
  }
}
