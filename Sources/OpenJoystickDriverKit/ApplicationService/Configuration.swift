import Foundation

/// Which identity/protocol the user-space Compatibility virtual device should publish.
///
/// IMPORTANT:
/// - `sdl2-3` targets SDL 2/3 with the first-party HIDAPI identity for that
///   physical protocol family (Xbox 360 Wired `045E:028E` today).
/// - `generic-hid` is the fallback for consumers that inspect standard HID descriptors directly.
/// - `apple-gamecontroller` publishes the HID surface accepted by Apple's GameController.framework.
/// - `xbox360-hid` is a family-adjacent XUSB HID profile. It is not Windows XUSB22.sys.
/// - `dualshock4` / `dualsense` / `switchpro` are first-party USB HID identities.
///   Automatic routing selects them when the physical pad is that dialect.
public enum CompatibilityIdentity: Codable, CaseIterable, Sendable, Equatable {
  case automatic
  case genericHID
  case sdl2_3
  case appleGameController
  case xbox360HID
  case dualShock4
  case dualSense
  case switchPro

  /// The result of validating a persisted/raw identity for a new mutation.
  public enum MutationDecision: Equatable, Sendable {
    case accepted(CompatibilityIdentity)
    case rejected(CompatibilityIdentityMutationRejection)
  }

  public func mutationDecision() -> MutationDecision { .accepted(self) }

  public static func mutationDecision(for rawValue: String) -> MutationDecision {
    guard let identity = Self(rawValue: rawValue) else { return .rejected(.unknownIdentity) }
    return identity.mutationDecision()
  }

  /// Resolves a UserDefaults-stored identity. Unknown values become `.automatic`.
  public static func persisted(from rawValue: String?) -> (identity: Self, didRewrite: Bool) {
    guard let rawValue, !rawValue.isEmpty else { return (.automatic, false) }
    if let identity = Self(rawValue: rawValue) { return (identity, false) }
    return (.automatic, true)
  }

  public init?(rawValue: String) {
    switch rawValue {
    case "automatic": self = .automatic
    case "generic-hid": self = .genericHID
    case "sdl2-3": self = .sdl2_3
    case "apple-gamecontroller": self = .appleGameController
    case "xbox360-hid": self = .xbox360HID
    case "dualshock4": self = .dualShock4
    case "dualsense": self = .dualSense
    case "switchpro": self = .switchPro
    default: return nil
    }
  }

  public var rawValue: String {
    switch self {
    case .automatic: "automatic"
    case .genericHID: "generic-hid"
    case .sdl2_3: "sdl2-3"
    case .appleGameController: "apple-gamecontroller"
    case .xbox360HID: "xbox360-hid"
    case .dualShock4: "dualshock4"
    case .dualSense: "dualsense"
    case .switchPro: "switchpro"
    }
  }

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let value = Self(rawValue: raw) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Unknown compatibility identity: \(raw)"
        )
      )
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum CompatibilityIdentityMutationRejection: String, Equatable, Sendable {
  case unknownIdentity
}

public enum CompatibilityIdentityTransitionPhase: String, Codable, Equatable, Sendable {
  case validation
  case stage
  case feedbackQuiescence = "feedback-quiescence"
  case candidateClose = "candidate-close"
  case activation
  case rollbackStage = "rollback-stage"
  case rollbackActivation = "rollback-activation"
  case zeroDeviceInterval = "zero-device-interval"
}

public enum CompatibilityIdentityTransitionCause: String, Codable, Equatable, Sendable {
  case invalidIdentity = "invalid-identity"
  case timedOut = "timed-out"
  case unavailable
  case serverStopped = "server-stopped"
}

public struct CompatibilityIdentityTransitionFailure: Codable, Equatable, Sendable {
  public let phase: CompatibilityIdentityTransitionPhase
  public let cause: CompatibilityIdentityTransitionCause
  /// Operation-specific system or backend detail, when the service supplied it.
  public let detail: String?

  public init(
    phase: CompatibilityIdentityTransitionPhase,
    cause: CompatibilityIdentityTransitionCause,
    detail: String? = nil
  ) {
    self.phase = phase
    self.cause = cause
    self.detail = detail
  }
}

/// Detailed result for an identity request. `liveIdentity` is the identity actually published.
public struct CompatibilityIdentityTransitionResult: Codable, Equatable, Sendable {
  public let requestedIdentity: CompatibilityIdentity?
  public let liveIdentity: CompatibilityIdentity?
  public let retainedIdentity: CompatibilityIdentity?
  public let failure: CompatibilityIdentityTransitionFailure?

  public init(
    requestedIdentity: CompatibilityIdentity?,
    liveIdentity: CompatibilityIdentity?,
    retainedIdentity: CompatibilityIdentity?,
    failure: CompatibilityIdentityTransitionFailure?
  ) {
    self.requestedIdentity = requestedIdentity
    self.liveIdentity = liveIdentity
    self.retainedIdentity = retainedIdentity
    self.failure = failure
  }

  public var succeeded: Bool { failure == nil && requestedIdentity == liveIdentity }
}
