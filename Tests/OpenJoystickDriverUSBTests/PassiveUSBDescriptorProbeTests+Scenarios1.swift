import Foundation
import Testing

@testable import OpenJoystickDriverUSB

extension PassiveUSBDescriptorProbeTests {
  @Test
  func exactTupleAuthorizationAndContributorGate() {
    let tuple = PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010)
    #expect(PassiveUSBDescriptorProbe.authorizedTuples.contains(tuple))
    #expect(
      !PassiveUSBDescriptorProbe.authorizedTuples.contains(
        PassiveUSBDescriptorTuple(vendorID: 1, productID: 2)
      )
    )
    #expect(PassiveUSBDescriptorProbe.contributorGate(environment: [:]) == false)
    #expect(
      PassiveUSBDescriptorProbe.contributorGate(environment: [
        "OJD_ENABLE_CONTRIBUTOR_USB_PASSIVE": "1"
      ])
    )
  }
  @Test
  func constrainedScanRejectsUnauthorizedZeroAndMultipleAndDoesNotAskSource() throws {
    let source = SpySource(matches: [])
    let unauthorized = PassiveUSBDescriptorTuple(vendorID: 1, productID: 2)
    #expect(throws: PassiveUSBDescriptorProbeError.tupleNotAuthorized) {
      try PassiveUSBDescriptorProbe.scanWithoutGate(authorizedTuple: unauthorized, source: source)
    }
    #expect(source.calls.isEmpty)
    let tuple = PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010)
    #expect(throws: PassiveUSBDescriptorProbeError.zeroMatches) {
      try PassiveUSBDescriptorProbe.scanWithoutGate(authorizedTuple: tuple, source: source)
    }
    source.matches = [fixtureRoot(), fixtureRoot()]
    #expect(throws: PassiveUSBDescriptorProbeError.multipleMatches) {
      try PassiveUSBDescriptorProbe.scanWithoutGate(authorizedTuple: tuple, source: source)
    }
    #expect(
      source.calls.allSatisfy {
        $0.className == "IOUSBHostDevice"
          && $0.properties == ["idVendor": 0x3537, "idProduct": 0x1010]
      }
    )
  }
  @Test
  func nestedRegistryParserPreservesOwnershipAndZeroDescriptors() throws {
    let tuple = PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010)
    let result = PassiveUSBRegistryFactParser.parse(
      root: fixtureRoot(),
      tuple: tuple,
      catalogInference: catalogInference()
    )
    let interface = try #require(result.parsedDescriptorFacts.configuration?.interfaces.first)
    let endpoint = try #require(interface.endpoints.first)
    #expect(interface.number == 0 && interface.alternateSetting == 0)
    #expect(endpoint.address == 1 && endpoint.maxPacketSize == 0 && endpoint.interval == 1)
    #expect(endpoint.address & 0x80 == 0)
    #expect(result.observedUSBFacts.interfacesState == .unverified)
    #expect(result.parsedDescriptorFacts.state == .parsed)
  }
  @Test
  func layersAndContradictionsAreTypedAndInferenceCannotBecomeObservation() throws {
    let tuple = PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010)
    let result = PassiveUSBRegistryFactParser.parse(
      root: fixtureRoot(),
      tuple: tuple,
      catalogInference: catalogInference()
    )
    #expect(result.catalogInference.parser == "catalog-backed; not observed from descriptors")
    #expect(result.catalogInference.endpoints["input"] == 0x81)
    #expect(result.parsedDescriptorFacts.configuration?.interfaces.first?.endpoints.count == 1)
    #expect(result.protocolClassification.status == "device-descriptor vendor-specific")
    var contradictory = fixtureRoot()
    contradictory = PassiveUSBRegistryNode(
      serviceClass: contradictory.serviceClass,
      properties: contradictory.properties.merging(["bDeviceProtocol": .unsignedInteger(0)]) {
        _,
        rhs in rhs
      },
      children: contradictory.children
    )
    let contradiction = PassiveUSBRegistryFactParser.parse(
      root: contradictory,
      tuple: tuple,
      catalogInference: catalogInference()
    )
    #expect(contradiction.protocolClassification.status == "UNVERIFIED")
    #expect(contradiction.protocolClassification.wireProtocol == "UNVERIFIED")
    let verification = result.observedUSBFacts.verification
    #expect(verification.endpointState == .unverified)
    #expect(verification.hidDescriptorState == .unverified)
    #expect(verification.hidCollectionsState == .unverified)
    #expect(verification.hidUsagesState == .unverified)
    #expect(verification.mappingState == .unverified)
    #expect(verification.inputState == .unverified)
    #expect(verification.outputState == .unverified)
    #expect(verification.reconnectState == .unverified)
    #expect(verification.latencyState == .unverified)
    #expect(verification.consumerRecognitionState == .unverified)
    #expect(verification.supportState == .unverified)
    let data = try JSONEncoder().encode(result)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      object.keys.sorted() == [
        "catalogInference", "observedUSBFacts", "parsedDescriptorFacts", "protocolClassification",
        "specificationInference", "userReportedPolling",
      ]
    )
    #expect(noSensitiveKeys(object))
  }
  @Test
  func alternateSettingsKeepTheirOwnEndpoints() throws {
    let root = PassiveUSBRegistryNode(
      serviceClass: "IOUSBHostDevice",
      properties: [
        "bDeviceClass": .unsignedInteger(0xFF), "bDeviceSubClass": .unsignedInteger(0xFF),
        "bDeviceProtocol": .unsignedInteger(0xFF), "bNumConfigurations": .unsignedInteger(1),
        "Configuration Descriptor": .bytes([
          9, 2, 0x29, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 0x81, 3, 0,
          0, 1, 9, 4, 0, 1, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 2, 3, 0, 0, 1,
        ]),
      ],
      children: []
    )
    let result = PassiveUSBRegistryFactParser.parse(
      root: root,
      tuple: PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010),
      catalogInference: catalogInference()
    )
    let interfaces = try #require(result.parsedDescriptorFacts.configuration?.interfaces)
    #expect(interfaces.map(\.alternateSetting) == [0, 1])
    #expect(interfaces.map { $0.endpoints.map(\.address) } == [[0x81], [0x02]])
  }
  @Test
  func descriptorParserRejectsMalformedBlobsAndKeepsUnknownDescriptors() throws {
    #expect(throws: PassiveUSBDescriptorBlobError.missingConfiguration) {
      try PassiveUSBConfigurationDescriptorParser.parse([9, 4, 0, 0, 0, 0, 0, 0, 0])
    }
    #expect(throws: PassiveUSBDescriptorBlobError.zeroLength) {
      try PassiveUSBConfigurationDescriptorParser.parse([0, 2])
    }
    #expect(throws: PassiveUSBDescriptorBlobError.descriptorOverrun) {
      try PassiveUSBConfigurationDescriptorParser.parse([9, 2, 9, 0])
    }
    #expect(throws: PassiveUSBDescriptorBlobError.totalLengthMismatch) {
      try PassiveUSBConfigurationDescriptorParser.parse([9, 2, 10, 0, 0, 1, 0, 0, 0])
    }
    let parsed = try PassiveUSBConfigurationDescriptorParser.parse([
      9, 2, 0x15, 0, 1, 1, 0, 0x80, 0x32, 3, 0x99, 0, 9, 4, 0, 0, 0, 0xFF, 0x47, 0xD0, 0,
    ])
    #expect(parsed.descriptors.map(\.type) == [2, 0x99, 4])
    #expect(parsed.interfaces.count == 1)
    #expect(parsed.interfaces[0].endpoints.isEmpty)
  }
  @Test
  func endpointCountsAddressesAttributesAndIntervalsAreStrict() throws {
    func blob(endpointCount: UInt8, endpoint: [UInt8]) -> [UInt8] {
      [
        9, 2, UInt8(18 + endpoint.count), 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, endpointCount, 0xFF,
        0x47, 0xD0, 0,
      ] + endpoint
    }
    #expect(throws: PassiveUSBDescriptorBlobError.totalLengthMismatch) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 2, endpoint: [7, 5, 1, 3, 0, 0, 1])
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidEndpointAddress) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 1, endpoint: [7, 5, 0, 3, 0, 0, 1])
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidEndpointAddress) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 1, endpoint: [7, 5, 0x71, 3, 0, 0, 1])
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
      try PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 1, endpoint: [7, 5, 1, 0xC3, 0, 0, 1])
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidInterval) {
      try PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 1, endpoint: [7, 5, 1, 3, 0, 0, 0]),
        negotiatedSpeed: .full
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidInterval) {
      try PassiveUSBConfigurationDescriptorParser.parse(
        blob(endpointCount: 1, endpoint: [7, 5, 1, 1, 0, 0, 17]),
        negotiatedSpeed: .high
      )
    }
  }
  @Test
  func intervalBoundariesAreSpeedAndTransferScoped() throws {
    func parse(
      _ transfer: UInt8,
      _ interval: UInt8,
      _ speed: PassiveUSBNegotiatedSpeed
    ) throws -> UInt64? {
      try PassiveUSBConfigurationDescriptorParser.parse(
        [
          9, 2, 25, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, transfer,
          0, 0, interval,
        ],
        negotiatedSpeed: speed
      ).interfaces[0].endpoints[0].nominalIntervalMicroseconds
    }
    #expect(try parse(3, 1, .full) == 1_000)
    #expect(try parse(3, 255, .full) == 255_000)
    #expect(try parse(3, 1, .high) == 125)
    #expect(try parse(3, 16, .high) == 4_096_000)
    #expect(try parse(1, 1, .full) == 1_000)
    #expect(try parse(1, 16, .full) == 32_768_000)
    #expect(try parse(2, 1, .high) == nil)
    #expect(try parse(0, 1, .high) == nil)
  }
  @Test
  func endpointUsageAndLowSpeedTransferRulesAreIndependent() throws {
    func blob(attributes: UInt8, interval: UInt8) -> [UInt8] {
      [
        9, 2, 25, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, attributes,
        64, 0, interval,
      ]
    }
    for usage in [UInt8(0x03), UInt8(0x13)] {
      var base = blob(attributes: usage, interval: usage == 0x13 ? 8 : 1)
      base[2] = 31
      let parsed = try PassiveUSBConfigurationDescriptorParser.parse(
        base + [6, 0x30, 0, 0, 64, 0],
        negotiatedSpeed: .superSpeedPlus
      )
      #expect(parsed.interfaces[0].endpoints.count == 1)
    }
    for usage in [UInt8(0x23), UInt8(0x33)] {
      #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
        try PassiveUSBConfigurationDescriptorParser.parse(
          blob(attributes: usage, interval: 1),
          negotiatedSpeed: .superSpeed
        )
      }
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
      try PassiveUSBConfigurationDescriptorParser.parse(blob(attributes: 0x13, interval: 8))
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
      try PassiveUSBConfigurationDescriptorParser.parse(
        blob(attributes: 2, interval: 1),
        negotiatedSpeed: .low
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
      try PassiveUSBConfigurationDescriptorParser.parse(
        blob(attributes: 1, interval: 1),
        negotiatedSpeed: .low
      )
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidInterval) {
      try PassiveUSBConfigurationDescriptorParser.parse(blob(attributes: 1, interval: 17))
    }
  }
  @Test


  func isochronousUsageValuesAcceptZeroOneTwoAndRejectThree() throws {
    func blob(_ attributes: UInt8) -> [UInt8] {
      [
        9, 2, 25, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, attributes,
        0, 2, 1,
      ]
    }
    for attributes in [UInt8(1), UInt8(0x11), UInt8(0x21)] {

      #expect(throws: Never.self) {
        try _ = PassiveUSBConfigurationDescriptorParser.parse(blob(attributes))
      }
    }
    #expect(throws: PassiveUSBDescriptorBlobError.invalidTransferAttributes) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(blob(0x31))
    }
  }
  @Test
  func isochronousSynchronizationValuesAreAllAccepted() throws {
    func blob(_ attributes: UInt8) -> [UInt8] {
      [
        9, 2, 25, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, attributes,
        0, 2, 1,
      ]
    }
    for attributes in [UInt8(1), UInt8(5), UInt8(9), UInt8(13)] {
      #expect(throws: Never.self) {
        try _ = PassiveUSBConfigurationDescriptorParser.parse(blob(attributes))
      }
    }
  }
  @Test
  func periodicZeroIsInvalidBeforeSpeedIsKnown() {
    let bytes: [UInt8] = [
      9, 2, 25, 0, 1, 1, 0, 0x80, 0x32, 9, 4, 0, 0, 1, 0xFF, 0x47, 0xD0, 0, 7, 5, 1, 3, 0, 0, 0,
    ]
    #expect(throws: PassiveUSBDescriptorBlobError.invalidInterval) {
      try _ = PassiveUSBConfigurationDescriptorParser.parse(bytes)
    }
  }
}
