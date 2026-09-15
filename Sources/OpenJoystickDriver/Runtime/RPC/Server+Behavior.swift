import Foundation
import IOKit
import IOKit.hid
import OpenJoystickDriverKit
import Security

extension ApplicationServiceServer {

  struct UserSpaceDispatcherBuild: Sendable {
    let dispatcher: any CompatibilityUserSpaceOutputDispatching
    let status: String
    let closeSlot: CompatibilityBackendCloseSlot

    init(
      dispatcher: any CompatibilityUserSpaceOutputDispatching,
      status: String,
      closeSlot: CompatibilityBackendCloseSlot? = nil
    ) {
      self.dispatcher = dispatcher
      self.status = status
      self.closeSlot = closeSlot ?? CompatibilityBackendCloseSlot(dispatcher)
    }
  }

  public func stop() async {
    rpcServer?.stop()
    rpcServer = nil
    userSpaceLock.withLock { compatibilityServerStopped = true }
    await compatibilityTransitionCoordinator.stop()
    let identifiers = await connectedIdentifierProvider()
    _ = await feedbackGate.quiesceAndNeutralize(
      identifiers,
      timeout: compatibilityTransitionTimeouts.feedbackNanoseconds,
      clock: compatibilityTransitionClock
    )
    let detached = userSpaceLock.withLock {
      () -> (
        backend: (any CompatibilityUserSpaceOutputDispatching)?,
        slot: CompatibilityBackendCloseSlot?
      ) in
      dispatcher.setBackend(nil)
      let old = userSpaceDispatcher
      let slot = userSpaceCloseSlot
      userSpaceDispatcher = nil
      userSpaceCloseSlot = nil
      userSpaceEnabled = false
      compatibilityLiveIdentity = nil
      userSpaceStatus = "off"
      return (old, slot)
    }
    _ = await closeCompatibilityBackend(detached.backend, slot: detached.slot)
  }

  static func isTrustedClient(processIdentifier: Int32) -> Bool {
    guard let expected = signingIdentityForCurrentProcess() else { return false }
    let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
    var guestCode: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode) == errSecSuccess,
      let guestCode, let actual = signingIdentity(for: guestCode)
    else { return false }
    return actual == expected
  }

  private static func signingIdentityForCurrentProcess() -> SigningIdentity? {
    var currentCode: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &currentCode) == errSecSuccess, let currentCode else {
      return nil
    }
    return signingIdentity(for: currentCode)
  }

  private static func signingIdentity(for code: SecCode) -> SigningIdentity? {
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String
    else { return nil }
    return SigningIdentity(
      identifier: identifier,
      teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String
    )
  }

  private struct SigningIdentity: Equatable {
    let identifier: String
    let teamIdentifier: String?
  }

  // MARK: - Private

  func buildUserSpaceDispatcher(identity: CompatibilityIdentity) throws -> UserSpaceDispatcherBuild
  {
    if let userSpaceDispatcherBuilder {
      let dispatcher = try userSpaceDispatcherBuilder(identity)
      return UserSpaceDispatcherBuild(dispatcher: dispatcher, status: dispatcher.status)
    }
    if identity == .automatic {
      let automatic = AutomaticUserSpaceOutputDispatcher(
        deviceManager: deviceManager,
        consumerProvider: CompatibilityConsumerRouting.current
      ) { [weak self] target in
        guard let self else { throw UserSpaceOutputDispatcher.CreationError.createFailed }
        return try self.buildAutomaticUserSpaceDispatcher(target: target)
      }
      return UserSpaceDispatcherBuild(dispatcher: automatic, status: automatic.status)
    }
    let composition = try CompatibilityOutputCompositionFactory.make(identity: identity)
    return try buildUserSpaceDispatcher(composition: composition, identity: identity)
  }

  private func buildAutomaticUserSpaceDispatcher(
    target: AutomaticCompatibilityTarget
  ) throws -> any CompatibilityUserSpaceOutputDispatching {
    let composition = try CompatibilityOutputCompositionFactory.make(target: target)
    return try buildUserSpaceDispatcher(composition: composition, identity: target.identity)
      .dispatcher
  }

  func buildUserSpaceDispatcher(
    composition: CompatibilityOutputComposition,
    identity: CompatibilityIdentity
  ) throws -> UserSpaceDispatcherBuild {
    let compatibilityProfile = composition.profile
    let profile = compatibilityProfile.deviceProfile
    let format = composition.format

    let rumbleHandler: UserSpaceOutputDispatcher.RumbleCommandHandler = {
      [weak self] identifier, command in
      guard let self else { return }
      self.feedbackGate.submit(identifier: identifier, command: command)
    }

    let output = try UserSpaceOutputDispatcher(
      profile: profile,
      format: format,
      emitsXboxGuideReport: compatibilityProfile.emitsXboxGuideReport,
      onRumbleCommand: rumbleHandler
    ) { [weak self] identifier in
      _ = await self?.feedbackGate.quiesceAndNeutralize(
        [identifier],
        timeout: self?.compatibilityTransitionTimeouts.feedbackNanoseconds
          ?? CompatibilityTransitionTimeouts.standard.feedbackNanoseconds,
        clock: self?.compatibilityTransitionClock ?? .system,
        resumeWhenComplete: true
      )
    }
    let gated = CompatibilityUserSpaceOutputDispatchingAdapter(
      backend: output,
      deviceManager: deviceManager,
      identity: identity
    ) { [weak self] in await self?.deviceManager.connectedDeviceDescriptions() ?? [] }
    return UserSpaceDispatcherBuild(dispatcher: gated, status: gated.status)
  }

  func initializeCompatibilityBackend() -> Bool {
    if userSpaceEnabled, userSpaceDispatcher != nil { return true }
    do {
      let build = try buildUserSpaceDispatcher(identity: compatibilityIdentity)
      userSpaceLock.withLock {
        userSpaceDispatcher = build.dispatcher
        userSpaceCloseSlot = build.closeSlot
        dispatcher.setBackend(build.dispatcher)
        userSpaceEnabled = true
        userSpaceStatus = build.status
        compatibilityLiveIdentity = compatibilityIdentity
      }
      print("[ApplicationServiceServer] Compatibility virtual gamepad ready")
      return true
    } catch {
      userSpaceLock.withLock {
        dispatcher.setBackend(nil)
        userSpaceDispatcher = nil
        userSpaceEnabled = false
        userSpaceStatus = "error: \(error)"
      }
      print("[ApplicationServiceServer] Compatibility virtual gamepad unavailable: \(error)")
      return false
    }
  }

  func currentUserSpaceStatus() -> String {
    userSpaceLock.withLock {
      guard let dispatcher = userSpaceDispatcher else { return userSpaceStatus }
      let rumble: String
      if dispatcher.lastRumbleStatus == "none" {
        rumble = ""
      } else {
        rumble = ", rumble: \(dispatcher.lastRumbleStatus)"
      }
      let liveStatus = "\(dispatcher.status)\(rumble)"
      return userSpaceStatus.hasPrefix("error:")
        ? "\(userSpaceStatus); live: \(liveStatus)" : liveStatus
    }
  }

  struct UserSpaceStatusSnapshot: Sendable {
    let enabled: Bool
    let status: String
    let requestedIdentity: CompatibilityIdentity
    let liveIdentity: CompatibilityIdentity?
    let retrySnapshot: CompatibilityRetrySnapshot?
  }

  func userSpaceStatusSnapshot() -> UserSpaceStatusSnapshot {
    userSpaceLock.withLock {
      let status: String
      if userSpaceStatus.hasPrefix("error:"), let userSpaceDispatcher {
        status = "\(userSpaceStatus); live: \(userSpaceDispatcher.status)"
      } else if let userSpaceDispatcher, userSpaceDispatcher.lastRumbleStatus != "none" {
        status = "\(userSpaceDispatcher.status), rumble: \(userSpaceDispatcher.lastRumbleStatus)"
      } else if let userSpaceDispatcher {
        status = userSpaceDispatcher.status
      } else {
        status = userSpaceStatus
      }
      return UserSpaceStatusSnapshot(
        enabled: userSpaceEnabled,
        status: status,
        requestedIdentity: compatibilityIdentity,
        liveIdentity: compatibilityLiveIdentity,
        retrySnapshot: compatibilityRetrySnapshot
      )
    }
  }

  func compatibilityTransitionSnapshot() -> CompatibilityTransitionSnapshot {
    userSpaceLock.withLock {
      if userSpaceCloseSlot == nil, let userSpaceDispatcher {
        userSpaceCloseSlot = CompatibilityBackendCloseSlot(userSpaceDispatcher)
      }
      return CompatibilityTransitionSnapshot(
        requestedIdentity: compatibilityIdentity,
        persistedIdentity: persistedCompatibilityIdentity,
        liveIdentity: compatibilityLiveIdentity,
        enabled: userSpaceEnabled,
        dispatcher: userSpaceDispatcher,
        closeSlot: userSpaceCloseSlot
      )
    }
  }

  func isCompatibilityServerStopped() -> Bool {
    userSpaceLock.withLock { compatibilityServerStopped }
  }

  func closeCompatibilityBackend(
    _ backend: (any CompatibilityUserSpaceOutputDispatching)?,
    slot: CompatibilityBackendCloseSlot? = nil,
    timeout: UInt64? = nil,
    error: CompatibilityTransitionError = .candidateCloseTimedOut
  ) async -> Bool {
    guard let backend else { return true }
    let closeSlot = userSpaceLock.withLock { () -> CompatibilityBackendCloseSlot in
      if let slot { return slot }
      if let userSpaceCloseSlot, userSpaceCloseSlot.backend === (backend as AnyObject) {
        return userSpaceCloseSlot
      }
      let slot = CompatibilityBackendCloseSlot(backend)
      if userSpaceDispatcher === backend { userSpaceCloseSlot = slot }
      return slot
    }
    return await closeSlot.close(
      timeout: timeout ?? compatibilityTransitionTimeouts.candidateCloseNanoseconds,
      clock: compatibilityTransitionClock,
      error: error
    )
  }

  static func loadCompatibilityRetrySnapshot(
    defaults: UserDefaults = .standard
  ) -> CompatibilityRetrySnapshot? {
    guard let data = defaults.data(forKey: compatibilityRetrySnapshotDefaultsKey) else {
      return nil
    }
    return try? JSONDecoder().decode(CompatibilityRetrySnapshot.self, from: data)
  }

  static func persistCompatibilityRetrySnapshot(
    _ snapshot: CompatibilityRetrySnapshot?,
    defaults: UserDefaults = .standard
  ) {
    guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
      defaults.removeObject(forKey: compatibilityRetrySnapshotDefaultsKey)
      return
    }
    defaults.set(data, forKey: compatibilityRetrySnapshotDefaultsKey)
  }

}
