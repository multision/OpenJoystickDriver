import Foundation
import OpenJoystickDriverKit

/// Stable failures from the locally persisted remapping-profile library.
enum RemappingProfileLibraryError: Error, Equatable, LocalizedError, Sendable {
  case corruptLibrary
  case duplicateName(String)
  case invalidProfile(RemappingValidationError)
  case librarySizeExceeded(Int)
  case profileCountExceeded(Int)
  case profileAlreadyExists(UUID)
  case profileNotFound(UUID)
  case pairProfileRequiresExplicitSession
  case profileUpdateConflict(UUID)
  case unreadableLibrary
  case unwritableLibrary
  case profileRecoveryRequired
  case profileIssueNotFound(UUID)

  var errorDescription: String? {
    switch self {
    case .corruptLibrary: "The remapping profile library is corrupt."
    case .duplicateName(let name): "A remapping profile named \(name) already exists."
    case .invalidProfile(let error): error.localizedDescription
    case .librarySizeExceeded(let size):
      "The remapping profile library is too large (\(size) bytes)."
    case .profileCountExceeded(let count):
      "The remapping profile library cannot contain \(count) profiles."
    case .profileAlreadyExists(let id): "The remapping profile \(id.uuidString) already exists."
    case .profileNotFound(let id): "The remapping profile \(id.uuidString) does not exist."
    case .pairProfileRequiresExplicitSession:
      "Paired Joy-Con profiles are started with an explicit pair session."
    case .profileUpdateConflict(let id):
      "The remapping profile \(id.uuidString) changed since it was read."
    case .unreadableLibrary: "The remapping profile library could not be read."
    case .unwritableLibrary: "The remapping profile library could not be written."
    case .profileRecoveryRequired: "Damaged profiles must be repaired before changing the library."
    case .profileIssueNotFound: "The selected damaged profile is no longer current."
    }
  }
}

/// The single application-service writer for locally authored remapping profiles.
actor RemappingProfileLibrary {
  static let maximumProfileCount = RemappingPayloadLimits.maximumProfileCount
  static let maximumEncodedBytes = RemappingPayloadLimits.maximumEncodedBytes

  let fileURL: URL
  private var library: RemappingProfileLibraryState?
  private enum RecoveryIssue {
    case damagedProfile(index: Int)
    case unusableLibrary
  }

  private var profileIssues: [UUID: RecoveryIssue] = [:]
  private var originalRecoveryData: Data?

  init(fileURL: URL = RemappingProfileLibrary.defaultFileURL) { self.fileURL = fileURL }

  static var defaultFileURL: URL {
    let manager = FileManager.default
    let directory =
      manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return directory.appendingPathComponent("OpenJoystickDriver", isDirectory: true)
      .appendingPathComponent("RemappingProfiles.json", isDirectory: false)
  }

  func profiles() throws -> [RemappingProfile] {
    try loadIfNeeded().profiles.sorted(by: Self.profileOrder)
  }

  func snapshot() throws -> RemappingProfileLibrarySnapshot {
    let loaded = try loadIfNeeded()
    return RemappingProfileLibrarySnapshot(
      profiles: loaded.profiles.sorted(by: Self.profileOrder),
      activeProfiles: loaded.activeProfiles.map {
        RemappingActiveProfileSelection(
          model: $0.model,
          profileID: $0.profileID,
          applicationScope: $0.applicationScope
        )
      }.sorted(by: Self.activeProfileOrder),
      issues: profileIssues.keys.sorted { $0.uuidString < $1.uuidString }.map { issueID in
        let kind: ApplicationServiceRemappingProfileIssue.Kind =
          switch profileIssues[issueID] {
          case .damagedProfile: .damagedProfile
          case .unusableLibrary, nil: .unusableLibrary
          }
        return ApplicationServiceRemappingProfileIssue(
          id: issueID,
          kind: kind,
          message: kind == .damagedProfile
            ? "This saved profile could not be read and can be removed."
            : "The saved profile library could not be read and must be reset."
        )
      }
    )
  }

  func profile(id: UUID) throws -> RemappingProfile? {
    let loaded = try loadIfNeeded()
    try requireUsableLibrary()
    return loaded.profiles.first { $0.id == id }
  }

  @discardableResult
  func deleteDamagedProfile(issueID: UUID) throws -> RemappingProfileMutationImpact {
    _ = try loadIfNeeded()
    guard case .damagedProfile(let index) = profileIssues[issueID], let originalRecoveryData else {
      throw RemappingProfileLibraryError.profileIssueNotFound(issueID)
    }
    try requireCurrentRecoveryData(originalRecoveryData, issueID: issueID)
    var root = try Self.libraryRoot(from: originalRecoveryData)
    var profiles = try Self.profileObjects(from: root)
    guard profiles.indices.contains(index) else {
      throw RemappingProfileLibraryError.profileIssueNotFound(issueID)
    }
    profiles.remove(at: index)
    root["profiles"] = profiles
    let recovered = try recoverProfiles(
      from: try JSONSerialization.data(withJSONObject: root),
      requireDamagedProfile: false
    )
    root["activeProfiles"] = try recovered.activeProfiles.map {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
    }
    try backUp(originalRecoveryData)
    try replaceRawLibrary(try JSONSerialization.data(withJSONObject: root), clearRecovery: true)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [])
  }

  @discardableResult
  func resetDamagedLibrary(issueID: UUID) throws -> RemappingProfileMutationImpact {
    _ = try loadIfNeeded()
    guard case .unusableLibrary = profileIssues[issueID], let originalRecoveryData else {
      throw RemappingProfileLibraryError.profileIssueNotFound(issueID)
    }
    try requireCurrentRecoveryData(originalRecoveryData, issueID: issueID)
    try backUp(originalRecoveryData)
    try replace(with: RemappingProfileLibraryState())
    profileIssues = [:]
    self.originalRecoveryData = nil
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [])
  }

  func checkpoint() throws -> RemappingProfileLibraryCheckpoint {
    let manager = FileManager.default
    let parentURL = fileURL.deletingLastPathComponent()
    let parentExisted = manager.fileExists(atPath: parentURL.path)
    let parentPermissions = try Self.permissions(at: parentURL, ifPresent: parentExisted)
    let fileExisted = manager.fileExists(atPath: fileURL.path)
    let filePermissions = try Self.permissions(at: fileURL, ifPresent: fileExisted)
    let persistedData: Data?
    if fileExisted {
      do { persistedData = try Data(contentsOf: fileURL) } catch {
        throw RemappingProfileLibraryError.unreadableLibrary
      }
    } else {
      persistedData = nil
    }
    let cachedLibrary = library
    _ = try loadIfNeeded()
    return RemappingProfileLibraryCheckpoint(
      cachedLibrary: cachedLibrary,
      persistedData: persistedData,
      parentExisted: parentExisted,
      parentPermissions: parentPermissions,
      filePermissions: filePermissions
    )
  }

  func restore(_ checkpoint: RemappingProfileLibraryCheckpoint) throws {
    let manager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    do {
      if let data = checkpoint.persistedData {
        try manager.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes(
          [.posixPermissions: checkpoint.parentPermissions ?? 0o700],
          ofItemAtPath: directory.path
        )
        try manager.setAttributes(
          [.posixPermissions: checkpoint.filePermissions ?? 0o600],
          ofItemAtPath: fileURL.path
        )
      } else {
        if manager.fileExists(atPath: fileURL.path) { try manager.removeItem(at: fileURL) }
        if !checkpoint.parentExisted, manager.fileExists(atPath: directory.path),
          try manager.contentsOfDirectory(atPath: directory.path).isEmpty
        {
          try manager.removeItem(at: directory)
        } else if let permissions = checkpoint.parentPermissions {
          try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
        }
      }
    } catch { throw RemappingProfileLibraryError.unwritableLibrary }
    library = checkpoint.cachedLibrary
  }

  @discardableResult
  func create(_ profile: RemappingProfile) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    guard !proposed.profiles.contains(where: { $0.id == profile.id }) else {
      throw RemappingProfileLibraryError.profileAlreadyExists(profile.id)
    }
    try validate(profile, in: proposed.profiles)
    proposed.profiles.append(profile)
    try replace(with: proposed)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [])
  }

  func requireCurrent(_ expectedCurrent: RemappingProfile, profileID: UUID) throws {
    guard expectedCurrent.id == profileID else {
      throw RemappingProfileLibraryError.profileUpdateConflict(profileID)
    }
    let loaded = try loadIfNeeded()
    guard let current = loaded.profiles.first(where: { $0.id == profileID }) else {
      throw RemappingProfileLibraryError.profileNotFound(profileID)
    }
    guard current == expectedCurrent else {
      throw RemappingProfileLibraryError.profileUpdateConflict(profileID)
    }
  }

  @discardableResult
  func update(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile
  ) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    guard let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) else {
      throw RemappingProfileLibraryError.profileNotFound(profile.id)
    }
    guard expectedCurrent.id == profile.id, proposed.profiles[index] == expectedCurrent else {
      throw RemappingProfileLibraryError.profileUpdateConflict(profile.id)
    }
    var peers = proposed.profiles
    peers.remove(at: index)
    try validate(profile, in: peers)
    let previousModel = RemappingProfileModel(proposed.profiles[index].device)
    let wasActive = proposed.activeProfiles.contains { $0.profileID == profile.id }
    proposed.profiles[index] = profile
    let currentModel = RemappingProfileModel(profile.device)
    if previousModel != currentModel || profile.joyConPair != nil {
      proposed.activeProfiles.removeAll { $0.profileID == profile.id }
    }
    try replace(with: proposed)
    return RemappingProfileMutationImpact(
      modelsNeedingRefresh: wasActive ? [previousModel, currentModel] : []
    )
  }

  /// Imports a profile, replacing the existing profile with the same identifier.
  @discardableResult
  func importProfile(_ profile: RemappingProfile) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    var modelsNeedingRefresh: Set<RemappingProfileModel> = []
    if let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) {
      var peers = proposed.profiles
      peers.remove(at: index)
      try validate(profile, in: peers)
      let previousModel = RemappingProfileModel(proposed.profiles[index].device)
      let currentModel = RemappingProfileModel(profile.device)
      if proposed.activeProfiles.contains(where: { $0.profileID == profile.id }) {
        modelsNeedingRefresh.insert(previousModel)
        modelsNeedingRefresh.insert(currentModel)
      }
      proposed.profiles[index] = profile
      if previousModel != currentModel || profile.joyConPair != nil {
        proposed.activeProfiles.removeAll { $0.profileID == profile.id }
      }
    } else {
      try validate(profile, in: proposed.profiles)
      proposed.profiles.append(profile)
    }
    try replace(with: proposed)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: modelsNeedingRefresh)
  }

  @discardableResult
  func delete(id: UUID) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    guard let index = proposed.profiles.firstIndex(where: { $0.id == id }) else {
      throw RemappingProfileLibraryError.profileNotFound(id)
    }
    let profile = proposed.profiles.remove(at: index)
    let wasActive = proposed.activeProfiles.contains { $0.profileID == id }
    proposed.activeProfiles.removeAll { $0.profileID == id }
    try replace(with: proposed)
    return RemappingProfileMutationImpact(
      modelsNeedingRefresh: wasActive ? [RemappingProfileModel(profile.device)] : []
    )
  }

  @discardableResult
  func activate(profileID: UUID) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    guard let profile = proposed.profiles.first(where: { $0.id == profileID }) else {
      throw RemappingProfileLibraryError.profileNotFound(profileID)
    }
    guard profile.joyConPair == nil else {
      throw RemappingProfileLibraryError.pairProfileRequiresExplicitSession
    }
    let model = RemappingProfileModel(profile.device)
    // Remove any existing active entry for this exact profile, then re-add.
    // Multiple profiles per device are allowed — one per application scope.
    proposed.activeProfiles.removeAll { $0.profileID == profileID }
    proposed.activeProfiles.append(
      RemappingPersistedActiveProfile(
        model: model,
        profileID: profile.id,
        applicationScope: profile.applicationScope
      )
    )
    try replace(with: proposed)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [model])
  }

  @discardableResult
  func deactivate(profileID: UUID) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    guard let existing = proposed.activeProfiles.first(where: { $0.profileID == profileID }) else {
      throw RemappingProfileLibraryError.profileNotFound(profileID)
    }
    proposed.activeProfiles.removeAll { $0.profileID == profileID }
    try replace(with: proposed)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [existing.model])
  }

  @discardableResult
  func deactivateAll(vendorID: UInt16, productID: UInt16) throws -> RemappingProfileMutationImpact {
    var proposed = try loadIfNeeded()
    try requireRecoveredLibrary()
    let model = RemappingProfileModel(vendorID: vendorID, productID: productID)
    proposed.activeProfiles.removeAll { $0.model == model }
    try replace(with: proposed)
    return RemappingProfileMutationImpact(modelsNeedingRefresh: [model])
  }

  func activeProfile(vendorID: UInt16, productID: UInt16) throws -> RemappingProfile? {
    try activeProfile(vendorID: vendorID, productID: productID, frontmostBundleIdentifier: nil)
  }

  func activeProfile(
    vendorID: UInt16,
    productID: UInt16,
    frontmostBundleIdentifier: String?
  ) throws -> RemappingProfile? {
    let loaded = try loadIfNeeded()
    try requireUsableLibrary()
    let model = RemappingProfileModel(vendorID: vendorID, productID: productID)
    let candidates = loaded.activeProfiles.filter { $0.model == model }
    guard !candidates.isEmpty else { return nil }
    let profilesByID = Dictionary(uniqueKeysWithValues: loaded.profiles.map { ($0.id, $0) })

    // Prefer an app-scoped profile matching the frontmost app (last activated wins)
    if let bundleID = frontmostBundleIdentifier {
      if let appMatch = candidates.last(where: { entry in
        guard case .application(let scope) = entry.applicationScope else { return false }
        return scope == bundleID
      }), let profile = profilesByID[appMatch.profileID] {
        return profile
      }
    }

    // Fall back to the last-activated global-scope profile
    if let globalMatch = candidates.last(where: { entry in entry.applicationScope == .global }),
      let profile = profilesByID[globalMatch.profileID]
    {
      return profile
    }

    // Fall back to the last active profile for this model
    if let last = candidates.last, let profile = profilesByID[last.profileID] { return profile }

    return nil
  }

  private func loadIfNeeded() throws -> RemappingProfileLibraryState {
    if let library { return library }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      let empty = RemappingProfileLibraryState()
      library = empty
      return empty
    }

    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      throw RemappingProfileLibraryError.unreadableLibrary
    }
    guard data.count <= Self.maximumEncodedBytes else { return loadUnusableLibrary(data) }

    let decoded: RemappingProfileLibraryState
    do { decoded = try JSONDecoder().decode(RemappingProfileLibraryState.self, from: data) } catch {
      do {
        let recovered = try recoverProfiles(from: data)
        library = recovered
        originalRecoveryData = data
        return recovered
      } catch { return loadUnusableLibrary(data) }
    }
    do {
      try validate(decoded)
      library = decoded
      return decoded
    } catch {
      do {
        let recovered = try recoverProfiles(from: data)
        library = recovered
        originalRecoveryData = data
        return recovered
      } catch { return loadUnusableLibrary(data) }
    }
  }

  private func replace(with proposed: RemappingProfileLibraryState) throws {
    try validate(proposed)
    let data: Data
    do { data = try JSONEncoder().encode(proposed) } catch {
      throw RemappingProfileLibraryError.unwritableLibrary
    }
    guard data.count <= Self.maximumEncodedBytes else {
      throw RemappingProfileLibraryError.librarySizeExceeded(data.count)
    }

    let manager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    do {
      try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try data.write(to: fileURL, options: .atomic)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch { throw RemappingProfileLibraryError.unwritableLibrary }
    library = proposed
    profileIssues = [:]
    originalRecoveryData = nil
  }

  private func requireRecoveredLibrary() throws {
    guard profileIssues.isEmpty else { throw RemappingProfileLibraryError.profileRecoveryRequired }
  }

  private func requireUsableLibrary() throws {
    guard
      !profileIssues.values.contains(where: {
        if case .unusableLibrary = $0 { return true }
        return false
      })
    else { throw RemappingProfileLibraryError.corruptLibrary }
  }

  private func recoverProfiles(
    from data: Data,
    requireDamagedProfile: Bool = true
  ) throws -> RemappingProfileLibraryState {
    let root = try Self.libraryRoot(from: data)
    let objects = try Self.profileObjects(from: root)
    var profiles: [RemappingProfile] = []
    var issues: [UUID: RecoveryIssue] = [:]
    for (index, object) in objects.enumerated() {
      do {
        let profileData = try JSONSerialization.data(withJSONObject: object)
        let profile = try JSONDecoder().decode(RemappingProfile.self, from: profileData)
        try validate(profile, in: profiles)
        profiles.append(profile)
      } catch { issues[UUID()] = .damagedProfile(index: index) }
    }
    if requireDamagedProfile, issues.isEmpty { throw RemappingProfileLibraryError.corruptLibrary }
    let retainedIDs = Set(profiles.map(\.id))
    let activeProfiles: [RemappingPersistedActiveProfile] = (root["activeProfiles"] as? [Any] ?? [])
      .compactMap { object in
        guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let active = try? JSONDecoder().decode(RemappingPersistedActiveProfile.self, from: data),
          retainedIDs.contains(active.profileID)
        else { return nil }
        return active
      }
    profileIssues = issues
    return RemappingProfileLibraryState(profiles: profiles, activeProfiles: activeProfiles)
  }

  private func loadUnusableLibrary(_ data: Data) -> RemappingProfileLibraryState {
    let empty = RemappingProfileLibraryState()
    profileIssues = [UUID(): .unusableLibrary]
    originalRecoveryData = data
    library = empty
    return empty
  }

  private func backUp(_ data: Data) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
      fileURL.lastPathComponent + ".backup-" + formatter.string(from: Date()) + "-"
        + UUID().uuidString
    )
    do { try data.write(to: backup, options: .atomic) } catch {
      throw RemappingProfileLibraryError.unwritableLibrary
    }
  }

  private func requireCurrentRecoveryData(_ expected: Data, issueID: UUID) throws {
    let current: Data
    do { current = try Data(contentsOf: fileURL) } catch {
      throw RemappingProfileLibraryError.unreadableLibrary
    }
    guard current == expected else {
      library = nil
      profileIssues = [:]
      originalRecoveryData = nil
      throw RemappingProfileLibraryError.profileIssueNotFound(issueID)
    }
  }

  private func replaceRawLibrary(_ data: Data, clearRecovery: Bool) throws {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch { throw RemappingProfileLibraryError.unwritableLibrary }
    library = nil
    if clearRecovery {
      profileIssues = [:]
      originalRecoveryData = nil
    }
  }

  private static func libraryRoot(from data: Data) throws -> [String: Any] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys).isSubset(of: ["profiles", "activeProfiles"]), root["profiles"] != nil
    else { throw RemappingProfileLibraryError.corruptLibrary }
    return root
  }

  private static func profileObjects(from root: [String: Any]) throws -> [Any] {
    guard let profiles = root["profiles"] as? [Any] else {
      throw RemappingProfileLibraryError.corruptLibrary
    }
    return profiles
  }

  private func validate(_ profile: RemappingProfile, in peers: [RemappingProfile]) throws {
    do { try profile.validate() } catch let error as RemappingValidationError {
      throw RemappingProfileLibraryError.invalidProfile(error)
    } catch { throw RemappingProfileLibraryError.invalidProfile(.encodingFailed) }
    let normalizedName = Self.normalizedName(profile.name)
    guard !peers.contains(where: { Self.normalizedName($0.name) == normalizedName }) else {
      throw RemappingProfileLibraryError.duplicateName(profile.name)
    }
  }

  private func validate(_ library: RemappingProfileLibraryState) throws {
    guard library.profiles.count <= Self.maximumProfileCount else {
      throw RemappingProfileLibraryError.profileCountExceeded(library.profiles.count)
    }
    var profileIDs: Set<UUID> = []
    for profile in library.profiles {
      guard profileIDs.insert(profile.id).inserted else {
        throw RemappingProfileLibraryError.corruptLibrary
      }
      try validate(profile, in: library.profiles.filter { $0.id != profile.id })
    }
    let profilesByID = Dictionary(uniqueKeysWithValues: library.profiles.map { ($0.id, $0) })
    // Each active profile entry must reference a real profile with a matching device model.
    // Multiple active profiles per model are allowed (per-app auto-switch).
    var seenActiveKeys: Set<String> = []
    for active in library.activeProfiles {
      guard let profile = profilesByID[active.profileID] else {
        throw RemappingProfileLibraryError.corruptLibrary
      }
      guard active.model == RemappingProfileModel(profile.device) else {
        throw RemappingProfileLibraryError.corruptLibrary
      }
      guard profile.joyConPair == nil else { throw RemappingProfileLibraryError.corruptLibrary }
      // No duplicate (model, profileID, scope) entries
      let scopeKey = String(describing: active.applicationScope)
      let key = "\(active.model.vendorID):\(active.model.productID):\(active.profileID):\(scopeKey)"
      guard seenActiveKeys.insert(key).inserted else {
        throw RemappingProfileLibraryError.corruptLibrary
      }
    }
  }

  private static func normalizedName(_ name: String) -> String {
    name.lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  private static func profileOrder(_ lhs: RemappingProfile, _ rhs: RemappingProfile) -> Bool {
    let leftName = normalizedName(lhs.name)
    let rightName = normalizedName(rhs.name)
    if leftName != rightName { return leftName < rightName }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func permissions(at url: URL, ifPresent: Bool) throws -> Int? {
    guard ifPresent else { return nil }
    do {
      return try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    } catch { throw RemappingProfileLibraryError.unreadableLibrary }
  }

  private static func activeProfileOrder(
    _ lhs: RemappingActiveProfileSelection,
    _ rhs: RemappingActiveProfileSelection
  ) -> Bool {
    if lhs.model.vendorID != rhs.model.vendorID { return lhs.model.vendorID < rhs.model.vendorID }
    if lhs.model.productID != rhs.model.productID {
      return lhs.model.productID < rhs.model.productID
    }
    return lhs.profileID.uuidString < rhs.profileID.uuidString
  }
}
