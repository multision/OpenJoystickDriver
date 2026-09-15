import Foundation

extension ApplicationServiceClient {

  public func pairRemappingJoyCons(
    leftRuntimeIdentifier: String,
    rightRuntimeIdentifier: String,
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .pairJoyCons,
      ApplicationServiceJoyConPairArguments(
        leftRuntimeIdentifier: leftRuntimeIdentifier,
        rightRuntimeIdentifier: rightRuntimeIdentifier,
        profileID: profileID
      )
    )
  }

  public func unpairRemappingJoyCons(
    sessionID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .unpairJoyCons,
      ApplicationServiceJoyConUnpairArguments(sessionID: sessionID)
    )
  }

  public func getRemappingProfile(id: UUID) async throws -> RemappingProfile {
    try await remappingCall(
      .getProfile,
      ApplicationServiceRemappingProfileIDArguments(profileID: id)
    )
  }

  public func createRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .createProfile,
      ApplicationServiceRemappingProfileArguments(profile: profile)
    )
  }

  public func updateRemappingProfile(
    _ profile: RemappingProfile,
    expectedCurrent: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .updateProfile,
      ApplicationServiceRemappingProfileUpdateArguments(
        profile: profile,
        expectedCurrent: expectedCurrent
      )
    )
  }

  public func importRemappingProfile(
    _ profile: RemappingProfile
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .importProfile,
      ApplicationServiceRemappingProfileArguments(profile: profile)
    )
  }

  public func deleteRemappingProfile(
    id: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .deleteProfile,
      ApplicationServiceRemappingProfileIDArguments(profileID: id)
    )
  }

  public func deleteDamagedRemappingProfile(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .deleteDamagedProfile,
      ApplicationServiceRemappingProfileIssueArguments(issueID: issueID)
    )
  }

  public func resetRemappingProfileLibrary(
    issueID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .resetProfileLibrary,
      ApplicationServiceRemappingProfileIssueArguments(issueID: issueID)
    )
  }

  public func activateRemappingProfile(
    id: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .activateProfile,
      ApplicationServiceRemappingProfileIDArguments(profileID: id)
    )
  }

  public func deactivateRemappingProfile(
    vendorID: UInt16,
    productID: UInt16
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .deactivateProfile,
      ApplicationServiceRemappingModelArguments(vendorID: vendorID, productID: productID)
    )
  }

  public func deactivateRemappingProfile(
    profileID: UUID
  ) async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(
      .deactivateProfileByID,
      ApplicationServiceRemappingProfileIDArguments(profileID: profileID)
    )
  }

  public func getRemappingPostEventAccess() async throws -> RemappingPostEventAccessState {
    try await remappingCall(.getPostEventAccess, LocalServiceRPCEmptyArguments())
  }

  public func requestRemappingPostEventAccess() async throws -> RemappingPostEventAccessState {
    try await remappingCall(.requestPostEventAccess, LocalServiceRPCEmptyArguments())
  }

  func remappingCall<Arguments: Encodable & Sendable, Value: Decodable & Sendable>(
    _ method: ApplicationServiceRemappingRPCMethod,
    _ arguments: Arguments
  ) async throws -> Value {
    do { return try await call(method.rawValue, arguments) } catch LocalServiceRPCError.remote(
      let description
    ) {
      guard let error = ApplicationServiceRemappingRPCError(rpcDescription: description) else {
        throw LocalServiceRPCError.remote(description)
      }
      throw error
    }
  }

  func call<Arguments: Encodable & Sendable, Value: Decodable & Sendable>(
    _ method: String,
    _ arguments: Arguments,
    timeoutSeconds: TimeInterval = applicationServiceDefaultReplyTimeoutSeconds
  ) async throws -> Value {
    guard stateLock.withLock({ connected }) else {
      throw ApplicationServiceClientError.notConnected
    }
    do {
      return try await LocalServiceRPCClient.call(
        method: method,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds,
        socketPath: socketPath
      )
    } catch LocalServiceRPCError.timeout { throw ApplicationServiceClientError.timeout }
  }

  func waitForLocalServer(until deadline: Date) -> Bool {
    while true {
      if LocalServiceRPCClient.serverProcessIdentifier(socketPath: socketPath) != nil {
        stateLock.withLock { connected = true }
        return true
      }
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  func spawnMainApplicationExecutable() {
    guard let executable = Bundle.main.executableURL else { return }
    let process = Process()
    process.executableURL = executable
    process.arguments = []
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
      FileHandle.standardError.write(
        Data(
          "[ApplicationServiceClient] Could not launch main app: ".appending(
            "\(error.localizedDescription)\n"
          ).utf8
        )
      )
    }
  }
}
