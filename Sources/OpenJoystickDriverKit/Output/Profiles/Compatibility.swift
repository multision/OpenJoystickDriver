/// First-class compatibility profiles exposed by the user-space HID backend.
public struct CompatibilityOutputProfile: Equatable, Sendable {
  public let identity: CompatibilityIdentity
  public let deviceProfile: VirtualDeviceProfile
  public let displayName: String
  public let notes: String
  public let isHardwareSpoof: Bool
  public let emitsXboxGuideReport: Bool
  public let evidence: CompatibilityEvidenceStatus
  public let consumerFamily: CompatibilityConsumerFamily
  public let automaticallyRecommended: Bool
  public let evidenceByConsumer: [CompatibilityConsumerFamily: CompatibilityEvidenceStatus]

  public init(
    identity: CompatibilityIdentity,
    deviceProfile: VirtualDeviceProfile,
    displayName: String,
    notes: String,
    isHardwareSpoof: Bool,
    emitsXboxGuideReport: Bool,
    evidence: CompatibilityEvidenceStatus = .sourceBacked,
    consumerFamily: CompatibilityConsumerFamily,
    automaticallyRecommended: Bool = false,
    evidenceByConsumer: [CompatibilityConsumerFamily: CompatibilityEvidenceStatus] = [:]
  ) {
    self.identity = identity
    self.deviceProfile = deviceProfile
    self.displayName = displayName
    self.notes = notes
    self.isHardwareSpoof = isHardwareSpoof
    self.emitsXboxGuideReport = emitsXboxGuideReport
    self.evidence = evidence
    self.consumerFamily = consumerFamily
    self.automaticallyRecommended = automaticallyRecommended
    self.evidenceByConsumer = evidenceByConsumer
  }
}

public enum CompatibilityEvidenceStatus: String, Codable, Sendable {
  case sourceBacked
  case hardwareVerified
  case reportedFailure
  case researchOnly
  case unavailable
}

public enum CompatibilityConsumerFamily: String, Codable, Sendable {
  case genericHID
  case sdlHIDAPI
  case appleGameController
  case blinkGamepad
  case webkitGamepad
  case geckoGamepad
  case unknownBrowserGamepad
  case xbox360HID
  case unknown
}

public enum AutomaticCompatibilityReportVariant: Sendable {
  case canonical
  case geckoXboxOneS
}

public struct AutomaticCompatibilityTarget: Equatable, Sendable {
  public let identity: CompatibilityIdentity
  public let reportVariant: AutomaticCompatibilityReportVariant

  public init(
    identity: CompatibilityIdentity,
    reportVariant: AutomaticCompatibilityReportVariant = .canonical
  ) {
    self.identity = identity
    self.reportVariant = reportVariant
  }

  public static let genericHID = Self(identity: .genericHID)
  public static let sdl2_3 = Self(identity: .sdl2_3)
  public static let appleGameController = Self(identity: .appleGameController)
  public static let xbox360HID = Self(identity: .xbox360HID)
  public static let dualShock4 = Self(identity: .dualShock4)
  public static let dualSense = Self(identity: .dualSense)
  public static let switchPro = Self(identity: .switchPro)
}

/// Official wire families. Krypton vs Argon is XUSB transport, not a backend.
public enum PhysicalProtocolSubfamily: String, Codable, CaseIterable, Sendable {
  case xid
  case xusb
  case gip
  case hid
}

/// Why a compatibility identity is unavailable for a physical protocol family.
public enum CompatibilityProfileAvailabilityReason: String, Codable, Sendable {
  case automaticRequiresResolution
  case xusbIdentityRequiresXUSBFamily
}

/// The result of the pure physical-family and explicit-identity compatibility policy.
public enum CompatibilityProfileAvailabilityDecision: Equatable, Sendable {
  case available
  case unavailable(reason: CompatibilityProfileAvailabilityReason)

  /// Whether the explicit identity is available for this physical family.
  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  /// The policy reason when the identity is unavailable.
  public var reason: CompatibilityProfileAvailabilityReason? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

/// Pure Kit-owned policy for physical-family to explicit virtual-identity compatibility.
public enum CompatibilityProfileAvailabilityPolicy {
  /// Evaluates one explicit identity for a connected physical device.
  public static func decision(
    for device: ApplicationServiceDeviceDescription,
    identity: CompatibilityIdentity
  ) -> CompatibilityProfileAvailabilityDecision {
    return decision(for: AutomaticCompatibilityResolver.subfamily(for: device), identity: identity)
  }

  /// Evaluates one explicit identity against one physical protocol subfamily.
  public static func decision(
    for subfamily: PhysicalProtocolSubfamily,
    identity: CompatibilityIdentity
  ) -> CompatibilityProfileAvailabilityDecision {
    switch identity {
    case .automatic: return .unavailable(reason: .automaticRequiresResolution)
    case .genericHID: return .available
    case .xbox360HID:
      return subfamily == .xusb ? .available : .unavailable(reason: .xusbIdentityRequiresXUSBFamily)
    case .sdl2_3, .appleGameController, .dualShock4, .dualSense, .switchPro:
      // Automatic routing stays family-strict. Explicit picker/CLI may publish
      // a first-party packer identity so live consumer-bind can be collected.
      return .available
    }
  }

}

public enum AutomaticCompatibilityDecisionReason: String, Codable, Sendable {
  case selectedCatalogTuple
  case selectedFamilyIdentity
  case selectedExplicitIdentity
  case reportedConsumerFailure
  case noAdjacentIdentity
  case unknownConsumer
}

public struct AutomaticCompatibilityResolution: Equatable, Sendable {
  public let identity: CompatibilityIdentity
  public let subfamily: PhysicalProtocolSubfamily
  public let consumer: CompatibilityConsumerFamily
  public let evidence: CompatibilityEvidenceStatus
  public let reason: AutomaticCompatibilityDecisionReason
}

public struct CompatibilityEvidenceRecord: Equatable, Sendable {
  public let vendorID: UInt16?
  public let productID: UInt16?
  public let subfamily: PhysicalProtocolSubfamily
  public let physicalTransport: String
  public let physicalMode: String
  public let connection: String
  public let consumer: CompatibilityConsumerFamily
  public let identity: CompatibilityIdentity
  public let evidence: CompatibilityEvidenceStatus
  public let reason: AutomaticCompatibilityDecisionReason
}
