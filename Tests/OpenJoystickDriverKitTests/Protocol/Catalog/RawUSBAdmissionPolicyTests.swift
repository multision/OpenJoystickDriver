import Testing

@testable import OpenJoystickDriverKit

struct RawUSBAdmissionPolicyTests {
  private let registry = ParserRegistry()

  @Test
  func unknownDeviceUsingGenericHIDFallbackIsRejected() {
    let identifier = DeviceIdentifier(vendorID: 0x0001, productID: 0x0001)

    #expect(registry.parser(for: identifier) is GenericHIDParser)
    #expect(!registry.supportsRawUSBPipeline(for: identifier))
  }

  @Test
  func catalogedGIPDeviceIsAdmitted() {
    let identifier = DeviceIdentifier(vendorID: 1_118, productID: 721)

    #expect(registry.parser(for: identifier) is GIPParser)
    #expect(registry.supportsRawUSBPipeline(for: identifier))
  }

  @Test
  func catalogedXbox360DeviceIsAdmitted() {
    let identifier = DeviceIdentifier(vendorID: 1_118, productID: 1_817)

    #expect(registry.parser(for: identifier) is Xbox360Parser)
    #expect(registry.supportsRawUSBPipeline(for: identifier))
  }

  @Test
  func catalogedXIDDeviceIsAdmitted() {
    let identifier = DeviceIdentifier(vendorID: 0x045E, productID: 0x0202)

    #expect(registry.parser(for: identifier) is XIDParser)
    #expect(registry.supportsRawUSBPipeline(for: identifier))
  }

  @Test(arguments: [
    DeviceIdentifier(vendorID: 0x0E4C, productID: 0x3240),
    DeviceIdentifier(vendorID: 0xFFFF, productID: 0xFFFF),
  ])
  func uncatalogedIdentitiesRemainGenericHID(identifier: DeviceIdentifier) {
    #expect(registry.parser(for: identifier) is GenericHIDParser)
    #expect(!registry.supportsRawUSBPipeline(for: identifier))
  }

  @Test
  func specializedParsersRequireTheirCatalogedTransport() {
    let cases: [(DeviceIdentifier, ControllerCatalogTransport, ControllerCatalogTransport)] = [
      (DeviceIdentifier(vendorID: 0xD7D7, productID: 0x0041), .hid, .usb),
      (DeviceIdentifier(vendorID: 0x3537, productID: 0x1003), .usb, .hid),
      (DeviceIdentifier(vendorID: 0x045E, productID: 0x0202), .usb, .hid),
      (DeviceIdentifier(vendorID: 0x045E, productID: 0x028E), .usb, .hid),
      (DeviceIdentifier(vendorID: 0x045E, productID: 0x02EA), .usb, .hid),
    ]

    for (identifier, catalogedTransport, otherTransport) in cases {
      #expect(
        !(registry.parser(for: identifier, transport: catalogedTransport) is GenericHIDParser)
      )
      #expect(registry.parser(for: identifier, transport: otherTransport) is GenericHIDParser)
    }
  }
}
