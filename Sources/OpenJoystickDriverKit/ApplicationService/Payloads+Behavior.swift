import Foundation

extension ApplicationServiceDeviceDescription {

  enum CodingKeys: String, CodingKey {
    case name
    case runtimeIdentifier
    case vendorID
    case productID
    case parser
    case connection
    case discoverySource
    case physicalOwnership
    case hidInputOwnership
    case duplicateExposureRisk
    case serialNumber
    case protocolVariant
    case quirks
    case inputEndpoint
    case outputEndpoint
    case needsSetConfiguration
    case postHandshakeSettleMs
    case preferredBackends
    case physicalOutputCapabilities
    case physicalInputCapabilities
    case battery
    case sessionState
    case startupCommandStatus
    case inputHealth
  }
}
