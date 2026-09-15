import Foundation
import ProtocolPacketFixtures
import Testing

@testable import OpenJoystickDriverUSB

extension PassiveUSBDescriptorProbeTests {
  @Test
  func identicalAliasesParseAndDifferentAliasesAreAmbiguous() throws {
    let bytes = ProtocolPacketFixtures.PassiveUSB.emptyConfiguration
    let root = PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostDevice",
      properties: [
        "Configuration Descriptor": .bytes(bytes), "kUSBConfigurationDescriptor": .bytes(bytes),
      ]
    )
    let same = PassiveUSBRegistryFactParser.parse(
      root: root,
      tuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
      catalogInference: catalogInference()
    )
    #expect(same.parsedDescriptorFacts.state == .parsed)
    #expect(same.parsedDescriptorFacts.sources.count == 2)
    let different = PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostDevice",
      properties: [
        "Configuration Descriptor": .bytes(bytes),
        "kUSBConfigurationDescriptor": .bytes(bytes + [0]),
      ]
    )
    let ambiguous = PassiveUSBRegistryFactParser.parse(
      root: different,
      tuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
      catalogInference: catalogInference()
    )
    #expect(ambiguous.parsedDescriptorFacts.state == .ambiguous)
    #expect(ambiguous.parsedDescriptorFacts.configuration == nil)
  }
  @Test
  func boundedBlobAndOwnershipBoundaryCasesAreIndependent() throws {
    #expect(throws: PassiveUSBDescriptorBlobError.unsafeSize) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse([])
    }
    #expect(throws: PassiveUSBDescriptorBlobError.unsafeSize) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(
        [UInt8](repeating: 0, count: PassiveUSBConfigurationDescriptorParser.maxBlobSize + 1)
      )
    }
    var exactMaximum = [UInt8](repeating: 0x99, count: 65_535)
    exactMaximum[0] = 9
    exactMaximum[1] = 2
    exactMaximum[2] = 0xFF
    exactMaximum[3] = 0xFF
    exactMaximum[4] = 0
    exactMaximum[5] = 1
    exactMaximum[6] = 0
    exactMaximum[7] = 0x80
    exactMaximum[8] = 0x32
    for offset in stride(from: 9, to: 65_535, by: 2) {
      exactMaximum[offset] = 2
      if offset + 1 < exactMaximum.count { exactMaximum[offset + 1] = 0x99 }
    }
    #expect(throws: Never.self) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(exactMaximum)
    }
    #expect(throws: PassiveUSBDescriptorBlobError.truncated) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse([1])
    }
    let interface = ProtocolPacketFixtures.PassiveUSB.vendorInterface
    let base = ProtocolPacketFixtures.PassiveUSB.configurationHeader(totalLength: 27)
    #expect(throws: PassiveUSBDescriptorBlobError.duplicateInterfaceOwnership) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(base + interface + interface)
    }
    #expect(throws: PassiveUSBDescriptorBlobError.impossibleEndpointOwnership) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse([
        9, 2, 23, 0, 1, 1, 0, 0x80, 0x32, 7, 5, 1, 3, 64, 0, 1, 7, 5, 1, 3, 64, 0, 1,
      ])
    }
    #expect(throws: PassiveUSBDescriptorBlobError.impossibleEndpointOwnership) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse([
        9, 2, 16, 0, 1, 1, 0, 0x80, 0x32, 7, 5, 1, 3, 64, 0, 1,
      ])
    }
  }
  @Test
  func matchingFailuresRemainTypedAndInterpolated() {
    let source = SpySource(error: .matchingFailed(-536_870_181))
    #expect(throws: PassiveUSBDescriptorProbeError.matchingFailed(-536_870_181)) {
      try PassiveUSBDescriptorProbe.scanWithoutGate(
        authorizedTuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
        source: source
      )
    }
    #expect(
      PassiveUSBDescriptorProbeError.matchingFailed(-7).errorDescription?.contains("-7") == true
    )
  }
  @Test
  func speedAliasesAreObservedOrAmbiguousWithoutPromotingUnknownSpeed() {
    let root = fixtureRoot()
    let observed = PassiveUSBRegistryFactParser.parse(
      root: PassiveUSBRegistryNode(
        serviceClass: root.serviceClass,
        properties: root.properties.merging([
          "USBSpeed": .string("high"), "Device Speed": .unsignedInteger(2),
        ]) { _, new in new },
        children: root.children
      ),
      tuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
      catalogInference: catalogInference()
    )
    #expect(observed.observedUSBFacts.speedObservation.state == .observed)
    #expect(observed.observedUSBFacts.speedObservation.speed == .high)
    let ambiguous = PassiveUSBRegistryFactParser.parse(
      root: PassiveUSBRegistryNode(
        serviceClass: root.serviceClass,
        properties: root.properties.merging([
          "USBSpeed": .string("high"), "Device Speed": .string("full"),
        ]) { _, new in new },
        children: root.children
      ),
      tuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
      catalogInference: catalogInference()
    )
    #expect(ambiguous.observedUSBFacts.speedObservation.state == .ambiguous)
    #expect(ambiguous.parsedDescriptorFacts.state == .parsed)
  }
  func fixtureRoot(children: [PassiveUSBRegistryNode]? = nil) -> PassiveUSBRegistryNode {
    let interface = interface(number: 0, alternate: 0, endpoint: 0)
    return PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostDevice",
      properties: [
        "USB Product Name": .string("GameSir-G7 SE Controller for Xbox"),
        "bDeviceClass": .unsignedInteger(0xFF), "bDeviceSubClass": .unsignedInteger(0xFF),
        "bDeviceProtocol": .unsignedInteger(0xFF), "bNumConfigurations": .unsignedInteger(1),
        "kUSBCurrentConfiguration": .unsignedInteger(0),
        "Configuration Descriptor": .bytes([
          9, 2, 0x19, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, 3, 0, 0,
          1,
        ]),
      ],
      children: children ?? [interface]
    )
  }
  func interface(number: UInt8, alternate: UInt8, endpoint: UInt8) -> PassiveUSBRegistryNode {
    let endpoint = PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostPipe",
      properties: [
        "bEndpointAddress": .unsignedInteger(UInt64(endpoint)),
        "wMaxPacketSize": .unsignedInteger(0), "bInterval": .unsignedInteger(0),
        "transferType": .string("interrupt"),
      ]
    )
    return PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostInterface",
      properties: [
        "bInterfaceNumber": .unsignedInteger(UInt64(number)),
        "bAlternateSetting": .unsignedInteger(UInt64(alternate)),
        "bInterfaceClass": .unsignedInteger(0xFF), "bInterfaceSubClass": .unsignedInteger(0x47),
        "bInterfaceProtocol": .unsignedInteger(0xD0),
      ],
      children: [endpoint]
    )
  }
  func catalogInference() -> PassiveUSBCatalogInference {
    PassiveUSBCatalogInference(
      source: "OpenJoystickDriver catalog",
      record: "3537:1010",
      parser: "catalog-backed; not observed from descriptors",
      endpoints: ["input": 0x81]
    )
  }
  func noSensitiveKeys(_ value: Any) -> Bool {
    if let dictionary = value as? [String: Any] {
      return dictionary.allSatisfy { key, child in
        !["serviceID", "locationID", "serialNumber", "uuid", "registryEntryID"].contains(key)
          && noSensitiveKeys(child)
      }
    }
    if let array = value as? [Any] { return array.allSatisfy(noSensitiveKeys) }
    return true
  }
}
