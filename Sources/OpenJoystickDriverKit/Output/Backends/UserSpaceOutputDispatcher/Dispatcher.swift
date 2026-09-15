import CoreHID
import Darwin
import Foundation
import IOKit
import IOKit.hid
import Security

/// Publishes one virtual gamepad for each connected physical controller.
///
/// macOS 15 and later use CoreHID. macOS 10.15 through 14 use the earlier
/// IOKit user-space HID API because CoreHID is unavailable there. Neither path
/// runs in the USB DriverKit extension.
public final class UserSpaceOutputDispatcher: CompatibilityUserSpaceOutputDispatching,
  CompatibilityUserSpaceOutputControllerActivating, RemappingGamepadSink,
  RemappingGamepadOutputControlling, @unchecked Sendable
{

  internal let profile: VirtualDeviceProfile
  internal let format: any VirtualGamepadReportFormat
  internal let primaryUsage: Int
  let emitsXboxGuideReport: Bool
  internal let productNameOverride: String?
  internal let onRumbleCommand: RumbleCommandHandler?
  internal let onControllerDidStop: (@Sendable (DeviceIdentifier) async -> Void)?
  internal let lifecycle = LifecycleState()
  internal let testBackendFactory:
    (@Sendable (DeviceIdentifier) async throws -> any VirtualDeviceBackend)?
  internal let registryLock = NSLock()
  internal var entries: [DeviceIdentifier: Entry] = [:]
  internal var creationTasks: [DeviceIdentifier: Task<Entry, Error>] = [:]
  internal var creationRetryPolicies: [DeviceIdentifier: UserSpaceDeviceCreationRetryPolicy] = [:]
  internal var lifecycleGenerations: [DeviceIdentifier: UInt64] = [:]
  internal var shutdownTask: Task<Void, Never>?
  internal var _suppressOutput = false
  internal var remappingOutputSuppressed = false
  internal var _status = "off"
  internal var _lastRumbleStatus = "none"

  static let requiredVirtualDeviceEntitlement = "com.apple.developer.hid.virtual.device"
  @preconcurrency
  public init(
    profile: VirtualDeviceProfile = .default,
    format: any VirtualGamepadReportFormat = OJDGenericGamepadFormat(),
    emitsXboxGuideReport: Bool = false,
    productNameOverride: String? = nil,
    onRumbleCommand: RumbleCommandHandler? = nil,
    onControllerDidStop: (@Sendable (DeviceIdentifier) async -> Void)? = nil
  ) throws {
    self.profile = profile
    self.format = format
    self.primaryUsage = Self.defaultPrimaryUsage(for: format)
    self.emitsXboxGuideReport = emitsXboxGuideReport
    self.productNameOverride = productNameOverride
    self.onRumbleCommand = onRumbleCommand
    self.onControllerDidStop = onControllerDidStop
    self.testBackendFactory = nil

    guard Self.hasRequiredVirtualDeviceEntitlement else {
      throw CreationError.missingEntitlement(Self.requiredVirtualDeviceEntitlement)
    }
  }

  init(
    testBackendFactory:
      @escaping @Sendable (DeviceIdentifier) async throws -> any VirtualDeviceBackend,
    format: any VirtualGamepadReportFormat = OJDGenericGamepadFormat(),
    onControllerDidStop: (@Sendable (DeviceIdentifier) async -> Void)? = nil
  ) {
    profile = .default
    self.format = format
    primaryUsage = Self.defaultPrimaryUsage(for: format)
    emitsXboxGuideReport = false
    productNameOverride = nil
    onRumbleCommand = nil
    self.onControllerDidStop = onControllerDidStop
    self.testBackendFactory = testBackendFactory
  }

  deinit { beginClose() }
}

extension UserSpaceOutputDispatcher: ControllerLifecycleListener {
  public func controllerDidStop(_ identifier: DeviceIdentifier) async {
    let resources = registryLock.withLock { () -> (Entry?, Task<Entry, Error>?) in
      lifecycleGenerations[identifier, default: 0] &+= 1
      let creationTask = creationTasks.removeValue(forKey: identifier)
      creationRetryPolicies.removeValue(forKey: identifier)
      let removed = entries.removeValue(forKey: identifier)
      recomputeStatusLocked()
      return (removed, creationTask)
    }
    await resources.0?.close()
    resources.1?.cancel()
    if let creationTask = resources.1, let entry = try? await creationTask.value {
      await entry.close()
    }
    await onControllerDidStop?(identifier)
  }
}
