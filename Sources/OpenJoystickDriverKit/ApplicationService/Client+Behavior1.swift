import Foundation

extension ApplicationServiceClient {

  /// Connects to the running main app, launching the installed app when needed.
  public func connect(timeoutSeconds: TimeInterval = 5) {
    if waitForLocalServer(until: Date()) { return }
    let timeout = max(0, timeoutSeconds)
    let deadline = Date().addingTimeInterval(timeout)
    switch Self.launchPolicy(
      commandLineArguments: CommandLine.arguments,
      bundlePathExtension: Bundle.main.bundleURL.pathExtension
    ) {
    case .waitForLocalServer: break
    case .spawnBundleExecutable:
      let grace = Date().addingTimeInterval(min(Self.concurrentHostLaunchGraceSeconds, timeout))
      if waitForLocalServer(until: grace) { return }
      spawnMainApplicationExecutable()
    case .unavailable: break
    }
    if waitForLocalServer(until: deadline) { return }
    stateLock.withLock { connected = false }
  }

  public func disconnect() { stateLock.withLock { connected = false } }

  public var isConnected: Bool { stateLock.withLock { connected } }

  public func listDevices() async throws -> [String] {
    try await call("listDevices", LocalServiceRPCEmptyArguments())
  }

  public func getStatus() async throws -> ApplicationServiceStatusPayload {
    let data: Data = try await call("getStatus", LocalServiceRPCEmptyArguments())
    guard let payload = try? JSONDecoder().decode(ApplicationServiceStatusPayload.self, from: data)
    else { throw ApplicationServiceClientError.invalidResponse }
    return payload
  }

  public func requestRequiredAccess() async throws -> PermissionManager.Snapshot {
    try await call("requestRequiredAccess", LocalServiceRPCEmptyArguments())
  }

  public func requestAccess(
    _ requirement: PermissionManager.Requirement
  ) async throws -> PermissionManager.Snapshot {
    try await call("requestAccess", LocalServiceRPCPermissionArguments(requirement: requirement))
  }

  public func deviceInputState(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil
  ) async throws -> DeviceInputState? {
    let data: Data? = try await call(
      "getDeviceInputState",
      LocalServiceRPCDeviceArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier
      )
    )
    guard let data else { return nil }
    return try? JSONDecoder().decode(DeviceInputState.self, from: data)
  }

  public func packetLog(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil
  ) async throws -> [PacketLogEntry] {
    let data: Data = try await call(
      "getPacketLog",
      LocalServiceRPCDeviceArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier
      )
    )
    guard let entries = try? JSONDecoder().decode([PacketLogEntry].self, from: data) else {
      throw ApplicationServiceClientError.invalidResponse
    }
    return entries
  }

  public func sendPhysicalRumble(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    left: UInt8,
    right: UInt8,
    lt: UInt8,
    rt: UInt8,
    durationMs: Int
  ) async throws -> Bool {
    try await call(
      "sendPhysicalRumble",
      LocalServiceRPCRumbleArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        left: Int(left),
        right: Int(right),
        leftTrigger: Int(lt),
        rightTrigger: Int(rt),
        durationMilliseconds: durationMs
      )
    )
  }

  public func setPhysicalPlayerIndicator(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    indicator: PhysicalPlayerIndicator
  ) async throws -> Bool {
    try await call(
      "setPhysicalPlayerIndicator",
      LocalServiceRPCPlayerIndicatorArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        playerIndex: indicator.rawValue
      )
    )
  }

  public func setPhysicalColor(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async throws -> Bool {
    try await call(
      "setPhysicalColor",
      LocalServiceRPCColorArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        red: Int(red),
        green: Int(green),
        blue: Int(blue)
      )
    )
  }

  public func previewPhysicalColor(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    token: UUID,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async throws -> Bool {
    try await call(
      "previewPhysicalColor",
      LocalServiceRPCColorPreviewArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        token: token,
        red: Int(red),
        green: Int(green),
        blue: Int(blue)
      )
    )
  }

  public func releasePhysicalColorPreview(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    token: UUID
  ) async throws -> Bool {
    try await call(
      "releasePhysicalColorPreview",
      LocalServiceRPCColorPreviewReleaseArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        token: token
      )
    )
  }

  public func setPhysicalBrightness(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String? = nil,
    brightness: UInt8
  ) async throws -> Bool {
    try await call(
      "setPhysicalBrightness",
      LocalServiceRPCBrightnessArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier,
        brightness: Int(brightness)
      )
    )
  }

  public func setSuppressOutput(_ suppress: Bool) async throws {
    let _: Bool = try await call("setSuppressOutput", LocalServiceRPCBoolArguments(value: suppress))
  }

  public func getVirtualDeviceDiagnostics() async throws
    -> ApplicationServiceVirtualDeviceDiagnosticsPayload
  {
    let data: Data = try await call("getVirtualDeviceDiagnostics", LocalServiceRPCEmptyArguments())
    guard
      let payload = try? JSONDecoder().decode(
        ApplicationServiceVirtualDeviceDiagnosticsPayload.self,
        from: data
      )
    else { throw ApplicationServiceClientError.invalidResponse }
    return payload
  }

  public func setCompatibilityIdentity(_ raw: String) async throws -> Bool {
    try await call("setCompatibilityIdentity", LocalServiceRPCStringArguments(value: raw))
  }

  public func setCompatibilityIdentityDetailed(
    _ raw: String
  ) async throws -> CompatibilityIdentityTransitionResult {
    let data: Data = try await call(
      "setCompatibilityIdentityDetailed",
      LocalServiceRPCStringArguments(value: raw)
    )
    guard
      let result = try? JSONDecoder().decode(CompatibilityIdentityTransitionResult.self, from: data)
    else { throw ApplicationServiceClientError.invalidResponse }
    return result
  }

  public func suspendController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?
  ) async throws -> ControllerSuspendResult {
    let data: Data = try await call(
      "suspendController",
      LocalServiceRPCDeviceArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier
      )
    )
    guard let result = try? JSONDecoder().decode(ControllerSuspendResult.self, from: data) else {
      throw ApplicationServiceClientError.invalidResponse
    }
    return result
  }

  public func resumeController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?
  ) async throws -> ControllerResumeResult {
    let data: Data = try await call(
      "resumeController",
      LocalServiceRPCDeviceArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier
      )
    )
    guard let result = try? JSONDecoder().decode(ControllerResumeResult.self, from: data) else {
      throw ApplicationServiceClientError.invalidResponse
    }
    return result
  }

  public func disconnectWirelessController(
    vendorID: UInt16,
    productID: UInt16,
    runtimeIdentifier: String?
  ) async throws -> WirelessControllerDisconnectResult {
    let data: Data = try await call(
      "disconnectWirelessController",
      LocalServiceRPCDeviceArguments(
        vendorID: Int(vendorID),
        productID: Int(productID),
        runtimeIdentifier: runtimeIdentifier
      ),
      timeoutSeconds: 5
    )
    guard
      let result = try? JSONDecoder().decode(WirelessControllerDisconnectResult.self, from: data)
    else { throw ApplicationServiceClientError.invalidResponse }
    return result
  }

  public func getCompatibilityIdentity() async throws -> String {
    try await call("getCompatibilityIdentity", LocalServiceRPCEmptyArguments())
  }

  public func runVirtualDeviceSelfTest(
    seconds: Int
  ) async throws -> ApplicationServiceVirtualDeviceSelfTestPayload {
    let clampedSeconds = max(1, min(30, seconds))
    let data: Data = try await call(
      "runVirtualDeviceSelfTest",
      LocalServiceRPCIntArguments(value: clampedSeconds),
      timeoutSeconds: TimeInterval(clampedSeconds) + applicationServiceSelfTestReplyGraceSeconds
    )
    guard
      let payload = try? JSONDecoder().decode(
        ApplicationServiceVirtualDeviceSelfTestPayload.self,
        from: data
      )
    else { throw ApplicationServiceClientError.invalidResponse }
    return payload
  }

  public func resetSettings() async throws -> Bool {
    try await call("resetSettings", LocalServiceRPCEmptyArguments())
  }

  public func getRemappingSnapshot() async throws -> ApplicationServiceRemappingSnapshotPayload {
    try await remappingCall(.getSnapshot, LocalServiceRPCEmptyArguments())
  }

  public func remappingMotionCalibration(
    runtimeIdentifier: String,
    command: RemappingMotionCalibrationCommand? = nil
  ) async throws -> RemappingMotionCalibrationStatus {
    try await remappingCall(
      .motionCalibration,
      ApplicationServiceMotionCalibrationArguments(
        runtimeIdentifier: runtimeIdentifier,
        command: command
      )
    )
  }
}
