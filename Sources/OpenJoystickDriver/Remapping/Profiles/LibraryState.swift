import Foundation
import OpenJoystickDriverKit

struct RemappingProfileLibrarySnapshot: Sendable {
  let profiles: [RemappingProfile]
  let activeProfiles: [RemappingActiveProfileSelection]
  let issues: [ApplicationServiceRemappingProfileIssue]
}

struct RemappingActiveProfileSelection: Sendable {
  let model: RemappingProfileModel
  let profileID: UUID
  let applicationScope: RemappingApplicationScope?
}

struct RemappingProfileMutationImpact: Sendable {
  let modelsNeedingRefresh: Set<RemappingProfileModel>
}

struct RemappingProfileLibraryCheckpoint: Sendable {
  let cachedLibrary: RemappingProfileLibraryState?
  let persistedData: Data?
  let parentExisted: Bool
  let parentPermissions: Int?
  let filePermissions: Int?
}

struct RemappingProfileLibraryState: Codable, Sendable {
  var profiles: [RemappingProfile] = []
  var activeProfiles: [RemappingPersistedActiveProfile] = []

  private enum CodingKeys: String, CodingKey {
    case profiles
    case activeProfiles
  }

  init() {}

  init(profiles: [RemappingProfile], activeProfiles: [RemappingPersistedActiveProfile]) {
    self.profiles = profiles
    self.activeProfiles = activeProfiles
  }

  init(from decoder: any Decoder) throws {
    let allKeys = try decoder.container(keyedBy: LibraryJSONKey.self).allKeys
    let unknown = Set(allKeys.map(\.stringValue)).subtracting(["profiles", "activeProfiles"])
    guard unknown.isEmpty else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unknown library field")
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profiles = try container.decode([RemappingProfile].self, forKey: .profiles)
    activeProfiles =
      try container.decodeIfPresent([RemappingPersistedActiveProfile].self, forKey: .activeProfiles)
      ?? []
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profiles, forKey: .profiles)
    try container.encode(activeProfiles, forKey: .activeProfiles)
  }
}

private struct LibraryJSONKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

struct RemappingPersistedActiveProfile: Codable, Sendable {
  let model: RemappingProfileModel
  let profileID: UUID
  let applicationScope: RemappingApplicationScope?

  init(
    model: RemappingProfileModel,
    profileID: UUID,
    applicationScope: RemappingApplicationScope? = nil
  ) {
    self.model = model
    self.profileID = profileID
    self.applicationScope = applicationScope
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case profileID
    case applicationScope
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decode(RemappingProfileModel.self, forKey: .model)
    profileID = try container.decode(UUID.self, forKey: .profileID)
    applicationScope = try container.decodeIfPresent(
      RemappingApplicationScope.self,
      forKey: .applicationScope
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(profileID, forKey: .profileID)
    try container.encodeIfPresent(applicationScope, forKey: .applicationScope)
  }
}

struct RemappingProfileModel: Codable, Equatable, Hashable, Sendable {
  let vendorID: UInt16
  let productID: UInt16

  init(_ device: RemappingDeviceScope) {
    self.init(vendorID: device.vendorID, productID: device.productID)
  }

  init(vendorID: UInt16, productID: UInt16) {
    self.vendorID = vendorID
    self.productID = productID
  }

  private enum CodingKeys: String, CodingKey {
    case vendorID
    case productID
  }
}
