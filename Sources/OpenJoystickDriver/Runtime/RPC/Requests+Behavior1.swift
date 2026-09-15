import Foundation
import OpenJoystickDriverKit

extension ApplicationServiceServer {
  /// Returns a list of connected device descriptions.
  public func listDevices(reply: @escaping ([String]) -> Void) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let devices = await dm.connectedDeviceDescriptions()
      let strings = devices.map(Self.deviceDescriptionLine)
      callback.call(strings)
    }
  }

  static func deviceDescriptionLine(_ device: ApplicationServiceDeviceDescription) -> String {
    let serialNumber = device.serialNumber ?? "none"
    let quirks = device.quirks.isEmpty ? "none" : device.quirks.joined(separator: ",")
    let backends =
      device.preferredBackends.isEmpty ? "none" : device.preferredBackends.joined(separator: ",")
    let battery = device.battery.map(Self.batteryDescription) ?? "unknown"
    return "\(device.name) (VID:\(device.vendorID)" + " PID:\(device.productID) \(device.parser)"
      + " [\(device.connection)] SN:\(serialNumber))"
      + " protocol=\(device.protocolVariant.rawValue)"
      + " endpoints=in:0x\(String(device.inputEndpoint, radix: 16))"
      + " out:0x\(String(device.outputEndpoint, radix: 16))"
      + " setConfig=\(device.needsSetConfiguration)" + " settleMs=\(device.postHandshakeSettleMs)"
      + " quirks=\(quirks)" + " backends=\(backends)" + " battery=\(battery)"
      + " session=\(device.sessionState.rawValue)"
      + " startup=\(device.startupCommandStatus ?? "not-required")"
  }

  private static func batteryDescription(_ battery: ControllerBatteryTelemetry) -> String {
    let percentage = battery.percentageDescription ?? "unknown"
    return "\(percentage),\(battery.chargingState.rawValue),cable-\(battery.cableState.rawValue)"
  }

  /// Returns the current application service status including input monitoring state and
  /// connected devices.
  public func getStatus(reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    let pm = permissionManager
    Task {
      let permissions = await pm.refreshAccessState()
      let devices = await dm.connectedDeviceDescriptions()
      let userSnapshot = userSpaceStatusSnapshot()
      let payload = ApplicationServiceStatusPayload(
        inputMonitoring: "\(permissions.inputMonitoring)",
        accessibility: "\(permissions.accessibility)",
        connectedDevices: devices,
        userSpaceVirtualDeviceEnabled: userSnapshot.enabled,
        userSpaceVirtualDeviceStatus: userSnapshot.status,
        compatibilityIdentity: userSnapshot.requestedIdentity.rawValue,
        compatibilityLiveIdentity: userSnapshot.liveIdentity?.rawValue,
        compatibilityRetry: userSnapshot.retrySnapshot.map {
          ApplicationServiceCompatibilityRetryPayload(
            requestedIdentity: $0.requestedIdentity.rawValue,
            priorProfileIdentity: $0.priorProfileIdentity.rawValue,
            phase: $0.phase.rawValue
          )
        }
      )
      do {
        let data = try JSONEncoder().encode(payload)
        callback.call(data)
      } catch {
        print("[ApplicationServiceServer] getStatus encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func requestRequiredAccess(reply: @escaping (PermissionManager.Snapshot) -> Void) {
    let callback = SendableReply(call: reply)
    let pm = permissionManager
    Task {
      let snapshot = await pm.requestRequiredAccess()
      callback.call(snapshot)
    }
  }

  public func requestAccess(
    _ requirement: PermissionManager.Requirement,
    reply: @escaping (PermissionManager.Snapshot) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let pm = permissionManager
    Task {
      let snapshot = await pm.requestAccess(requirement)
      callback.call(snapshot)
    }
  }

  /// Returns the current input state for the specified device as encoded JSON data.
  public func getDeviceInputState(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data?) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let state = await dm.inputState(for: identifier, runtimeIdentifier: runtimeIdentifier)
      callback.call(try? JSONEncoder().encode(state))
    }
  }

  /// Returns the recent packet log for the specified device as encoded JSON data.
  public func getPacketLog(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let log = await dm.packetLog(for: identifier, runtimeIdentifier: runtimeIdentifier)
      do {
        let data = try JSONEncoder().encode(log)
        callback.call(data)
      } catch {
        print("[ApplicationServiceServer] getPacketLog encode error: \(error)")
        callback.call(Data())
      }
    }
  }

  public func sendPhysicalRumble(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    left: Int,
    right: Int,
    lt: Int,
    rt: Int,
    durationMs: Int,
    reply: @escaping (Bool) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(vendorID: UInt16(vendorID), productID: UInt16(productID))
      let ok = await dm.sendRumble(
        for: identifier,
        runtimeIdentifier: runtimeIdentifier,
        left: UInt8(clamping: left),
        right: UInt8(clamping: right),
        lt: UInt8(clamping: lt),
        rt: UInt8(clamping: rt),
        durationMs: durationMs
      )
      callback.call(ok)
    }
  }

  public func setPhysicalPlayerIndicator(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    playerIndex: Int,
    reply: @escaping (Bool) -> Void
  ) {

    guard let indicator = PhysicalPlayerIndicator(rawValue: playerIndex) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.sendPlayerIndicator(

          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          indicator: indicator
        )
      )
    }
  }

  public func setPhysicalColor(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    red: Int,
    green: Int,
    blue: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard let red = UInt8(exactly: red), let green = UInt8(exactly: green),
      let blue = UInt8(exactly: blue)
    else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.setPhysicalColor(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          red: red,
          green: green,
          blue: blue
        )
      )
    }
  }

  public func setPhysicalBrightness(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    brightness: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard let brightness = UInt8(exactly: brightness) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.setPhysicalBrightness(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          brightness: brightness
        )
      )
    }
  }

  /// Enables or disables virtual output suppression and reports success.
  public func setSuppressOutput(_ suppress: Bool, reply: @escaping (Bool) -> Void) {
    let callback = SendableReply(call: reply)
    Task {
      do {
        try await remappingRouter.setOutputSuppressed(suppress)
        callback.call(true)
      } catch { callback.call(false) }
    }
  }

  public func setCompatibilityIdentity(_ raw: String, reply: @escaping (Bool) -> Void) {
    guard case .accepted(let id) = CompatibilityIdentity.mutationDecision(for: raw) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    // The RPC bridge is callback-shaped, so this is the single request-scoped task.  The
    // asynchronous transaction itself owns the ordering: close, then publish, then reply.
    Task { [weak self] in
      guard let self else { return }
      callback.call(await self.setCompatibilityIdentityAsync(id))
    }
  }

  public func setCompatibilityIdentityDetailed(_ raw: String, reply: @escaping (Data) -> Void) {
    let callback = SendableReply(call: reply)
    guard case .accepted(let identity) = CompatibilityIdentity.mutationDecision(for: raw) else {
      let result = CompatibilityIdentityTransitionResult(
        requestedIdentity: nil,
        liveIdentity: userSpaceStatusSnapshot().liveIdentity,
        retainedIdentity: userSpaceStatusSnapshot().liveIdentity,
        failure: CompatibilityIdentityTransitionFailure(phase: .validation, cause: .invalidIdentity)
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
      return
    }
    Task { [weak self] in
      guard let self else { return }
      let succeeded = await self.setCompatibilityIdentityAsync(identity)
      let snapshot = self.userSpaceStatusSnapshot()
      let result = CompatibilityIdentityTransitionResult(
        requestedIdentity: identity,
        liveIdentity: snapshot.liveIdentity,
        retainedIdentity: succeeded ? nil : snapshot.liveIdentity,
        failure: succeeded ? nil : self.compatibilityTransitionFailure(from: snapshot)
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  public func suspendController(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      let result = await deviceManager.suspendController(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID),
        runtimeIdentifier: runtimeIdentifier
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }

  public func resumeController(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    reply: @escaping (Data) -> Void
  ) {
    let callback = SendableReply(call: reply)
    Task {
      let result = await deviceManager.resumeController(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID),
        runtimeIdentifier: runtimeIdentifier
      )
      callback.call((try? JSONEncoder().encode(result)) ?? Data())
    }
  }
}
