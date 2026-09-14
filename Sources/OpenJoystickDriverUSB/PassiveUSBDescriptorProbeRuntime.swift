import Foundation
import IOKit
import OpenJoystickDriverKit

public enum PassiveUSBDescriptorProbe {
  public static let authorizedTuples: Set<PassiveUSBDescriptorTuple> = [
    PassiveUSBDescriptorTuple(vendorID: 0x3537, productID: 0x1010)
  ]

  public static func contributorGate(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    _isDebugAssertConfiguration() && environment["OJD_ENABLE_CONTRIBUTOR_USB_PASSIVE"] == "1"
  }

  #if DEBUG
    public static let buildMode = "DEBUG"
  #else
    public static let buildMode = "RELEASE"
  #endif

  public static func scan(
    authorizedTuple tuple: PassiveUSBDescriptorTuple
  ) throws -> PassiveUSBProbeResult {
    guard contributorGate() else { throw PassiveUSBDescriptorProbeError.contributorGateRequired }
    return try scanWithoutGate(authorizedTuple: tuple, source: IOUSBHostPassiveUSBRegistrySource())
  }

  static func scanWithoutGate(
    authorizedTuple tuple: PassiveUSBDescriptorTuple,
    source: any PassiveUSBRegistrySource
  ) throws -> PassiveUSBProbeResult {
    guard authorizedTuples.contains(tuple) else {
      throw PassiveUSBDescriptorProbeError.tupleNotAuthorized
    }
    let matches = try source.matchingServices(
      className: "IOUSBHostDevice",
      numericProperties: ["idVendor": UInt64(tuple.vendorID), "idProduct": UInt64(tuple.productID)]
    )
    switch matches.count {
    case 0: throw PassiveUSBDescriptorProbeError.zeroMatches
    case 1: break
    default: throw PassiveUSBDescriptorProbeError.multipleMatches
    }
    let catalog = PassiveUSBCatalogInference(
      source: "OpenJoystickDriver catalog",
      record: "3537:1010",
      parser: "catalog-backed; not observed from descriptors",
      endpoints: [:]
    )
    return PassiveUSBRegistryFactParser.parse(
      root: matches[0],
      tuple: tuple,
      catalogInference: catalog
    )
  }

  /// Reads descriptor-backed transport facts without claiming an interface or
  /// issuing a USB transfer. This path is intentionally independent of the
  /// contributor gate and does not participate in raw-USB admission.
  static func transportObservation(
    for device: USBTransportDevice
  ) throws -> ControllerTransportObservation? {
    let tuple = PassiveUSBDescriptorTuple(vendorID: device.vendorID, productID: device.productID)
    let roots = try IOUSBHostPassiveUSBRegistrySource().matchingServices(
      className: "IOUSBHostDevice",
      numericProperties: ["idVendor": UInt64(tuple.vendorID), "idProduct": UInt64(tuple.productID)]
    )
    guard
      let root = roots.first(where: { node in
        guard case .unsignedInteger(let location) = node.properties["locationID"] else {
          return false
        }
        return UInt32(exactly: location) == device.locationID
      })
    else { return nil }

    let result = PassiveUSBRegistryFactParser.parse(
      root: root,
      tuple: tuple,
      catalogInference: PassiveUSBCatalogInference(
        source: "descriptor observation",
        record: "not resolved",
        parser: "not selected",
        endpoints: [:]
      )
    )
    let interfaces = (result.parsedDescriptorFacts.configuration?.interfaces ?? []).map {
      USBInterfaceTransportFacts(
        interfaceNumber: $0.number,
        alternateSetting: $0.alternateSetting,
        interfaceClass: $0.interfaceClass,
        interfaceSubclass: $0.interfaceSubclass,
        interfaceProtocol: $0.interfaceProtocol,
        configurationValue: result.observedUSBFacts.activeConfiguration,
        endpoints: $0.endpoints.map {
          USBEndpointTransportFacts(
            address: $0.address,
            transferType: endpointTransferType($0.transferType),
            direction: $0.address & 0x80 == 0 ? .out : .in,
            maxPacketSize: $0.maxPacketSize,
            interval: $0.interval
          )
        }
      )
    }
    return ControllerTransportObservation(device: device, interfaces: interfaces)
  }

  private static func endpointTransferType(_ value: String) -> USBEndpointTransferType {
    switch value.lowercased() {
    case "control": return .control
    case "isochronous", "isochronous-adaptive", "isochronous-synchronous": return .isochronous
    case "bulk": return .bulk
    case "interrupt": return .interrupt
    default: return .unknown
    }
  }

  #if DEBUG
    public static func scanUsingContributorSource(
      authorizedTuple tuple: PassiveUSBDescriptorTuple,
      source: any PassiveUSBRegistrySource
    ) throws -> PassiveUSBProbeResult {
      guard contributorGate() else { throw PassiveUSBDescriptorProbeError.contributorGateRequired }
      return try scanWithoutGate(authorizedTuple: tuple, source: source)
    }
  #endif
}
