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
  public typealias RumbleCommandHandler = @Sendable (DeviceIdentifier, VirtualRumbleCommand) -> Void

  public enum CreationError: Error, CustomStringConvertible, Sendable {
    case createFailed
    case inputMonitoringDenied
    case accessibilityDenied
    case missingEntitlement(String)
    case provisioningProfileExcludesHost

    public var description: String {
      switch self {
      case .createFailed: return "Failed to create virtual HID device"
      case .inputMonitoringDenied: return "Input Monitoring denied for IOKit virtual device"
      case .accessibilityDenied: return "Accessibility denied for IOKit virtual device"
      case .missingEntitlement(let entitlement): return "Missing entitlement: \(entitlement)"
      case .provisioningProfileExcludesHost:
        return "Development provisioning profile does not include this Mac"
      }
    }
  }

  protocol VirtualDeviceBackend: AnyObject, Sendable {
    func send(_ report: [UInt8]) async throws
    func close()
  }

  internal final class LifecycleState: @unchecked Sendable {
    internal let lock = NSLock()
    internal var closed = false

    var isOpen: Bool { lock.withLock { !closed } }

    func close() -> Bool {
      lock.withLock {
        guard !closed else { return false }
        closed = true
        return true
      }
    }
  }

  internal struct IOKitReportError: Error, Sendable { let code: IOReturn }

  /// Interrupt IN for IOKit clients (`hid_read`). GetReport is a separate control path.
  static func publishIOKitInputReport(_ device: IOHIDUserDevice, report: [UInt8]) throws {
    let result = report.withUnsafeBytes { pointer -> IOReturn in
      guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
      return IOHIDUserDeviceHandleReportWithTimeStamp(
        device,
        mach_absolute_time(),
        base.assumingMemoryBound(to: UInt8.self),
        pointer.count
      )
    }
    guard result == kIOReturnSuccess else { throw IOKitReportError(code: result) }
  }

  @available(macOS, introduced: 10.15, obsoleted: 15.0)
  internal final class IOHIDBackend: VirtualDeviceBackend, @unchecked Sendable {
    internal var device: IOHIDUserDevice?
    let queue: DispatchQueue
    internal let lock = NSLock()
    internal var isClosed = false

    init(device: IOHIDUserDevice, queue: DispatchQueue) {
      self.device = device
      self.queue = queue
    }

    deinit { close() }

    func send(_ report: [UInt8]) throws {
      guard let device = lock.withLock({ isClosed ? nil : device }) else {
        throw CancellationError()
      }
      try UserSpaceOutputDispatcher.publishIOKitInputReport(device, report: report)
    }

    func close() {
      let device = lock.withLock { () -> IOHIDUserDevice? in
        guard !isClosed else { return nil }
        isClosed = true
        defer { self.device = nil }
        return self.device
      }
      if let device { IOHIDUserDeviceCancel(device) }
    }
  }

  @available(macOS 15, *)
  internal final class CoreHIDBackend: VirtualDeviceBackend, @unchecked Sendable {
    internal var device: HIDVirtualDevice?
    internal var delegateOwner: CoreHIDDelegate?
    internal let lock = NSLock()
    internal var isClosed = false

    init(device: HIDVirtualDevice, delegate: CoreHIDDelegate) {
      self.device = device
      delegateOwner = delegate
    }

    func send(_ report: [UInt8]) async throws {
      guard let device = lock.withLock({ isClosed ? nil : device }) else {
        throw CancellationError()
      }
      // CoreHID GetReport is the delegate. HIDAPI `hid_read` is IOKit interrupt IN
      // via HandleReport. dispatchInputReport alone can leave that queue idle.
      if #available(macOS 26, *), let userDevice = device.hidDevice {
        try UserSpaceOutputDispatcher.publishIOKitInputReport(userDevice, report: report)
      }
      try await device.dispatchInputReport(data: Data(report), timestamp: SuspendingClock.now)
    }

    func close() {
      let device = lock.withLock { () -> HIDVirtualDevice? in
        guard !isClosed else { return nil }
        isClosed = true
        delegateOwner = nil
        defer { self.device = nil }
        return self.device
      }
      if #available(macOS 26, *), let userDevice = device?.hidDevice {
        IOHIDUserDeviceCancel(userDevice)
      }
    }
  }

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

  public var suppressOutput: Bool {
    get { registryLock.withLock { _suppressOutput } }
    set { registryLock.withLock { _suppressOutput = newValue } }
  }

  public var status: String { registryLock.withLock { _status } }
  public func setOutputSuppressed(_ suppressed: Bool) async {
    let suppression: (entries: [Entry], shouldNeutralize: Bool) = registryLock.withLock {
      let changed = !_suppressOutput && suppressed
      _suppressOutput = suppressed
      return (Array(entries.values), changed)
    }
    for entry in suppression.entries {
      _ = try? await entry.sender.submit {
        suppression.shouldNeutralize && !entry.inputReportState.isRemapped
          ? [entry.inputReportState.reset()] : []
      }.value()
    }
  }
  public func setRemappingOutputSuppressed(_ suppressed: Bool) async {
    let senders = registryLock.withLock {
      remappingOutputSuppressed = suppressed
      return entries.values.map(\.sender)
    }
    for sender in senders { _ = try? await sender.submit { [] }.value() }
  }

  public var lastRumbleStatus: String { registryLock.withLock { _lastRumbleStatus } }

  static let requiredVirtualDeviceEntitlement = "com.apple.developer.hid.virtual.device"
  static var hasRequiredVirtualDeviceEntitlement: Bool {
    hasEntitlement(requiredVirtualDeviceEntitlement)
  }

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

  public func close() async { await beginClose().value }

  /// Creates and neutrally activates one virtual device for each supplied controller.
  public func activate(for identifiers: [DeviceIdentifier]) async throws {
    guard lifecycle.isOpen else { throw CancellationError() }
    var seen = Set<DeviceIdentifier>()
    let identifiers = identifiers.filter { seen.insert($0).inserted }
    do {
      for identifier in identifiers {
        let entry = try await entry(for: identifier)
        guard lifecycle.isOpen else { throw CancellationError() }
        try await entry.sender.submit { [entry] in [entry.inputReportState.currentReport()] }
          .value()
        startInputReportKeepalive(entry)
      }
      registryLock.withLock { recomputeStatusLocked() }
    } catch {
      await close()
      throw error
    }
  }

  public func activate(controller identifier: DeviceIdentifier) async throws {
    guard lifecycle.isOpen else { throw CancellationError() }
    do {
      let entry = try await entry(for: identifier)
      guard lifecycle.isOpen else { throw CancellationError() }
      try await entry.sender.submit { [entry] in [entry.inputReportState.currentReport()] }.value()
      startInputReportKeepalive(entry)
      registryLock.withLock { recomputeStatusLocked() }
    } catch {
      await close()
      throw error
    }
  }

  @discardableResult
  func beginClose() -> Task<Void, Never> {
    registryLock.withLock {
      if let shutdownTask { return shutdownTask }
      _ = lifecycle.close()
      let resources = Array(entries.values)
      let identifiers = Set(entries.keys).union(creationTasks.keys)
      let tasks = Array(creationTasks.values)
      entries.removeAll()
      for identifier in identifiers { lifecycleGenerations[identifier, default: 0] &+= 1 }
      creationTasks.removeAll()
      creationRetryPolicies.removeAll()
      _status = "off"
      tasks.forEach { $0.cancel() }
      let drains = resources.map { $0.beginClose() }
      let shutdown = Task {
        for drain in drains { await drain.value }
        for task in tasks { if let entry = try? await task.value { await entry.close() } }
      }
      shutdownTask = shutdown
      return shutdown
    }
  }

  internal func startInputReportKeepalive(_ entry: Entry) {
    entry.startInputReportKeepalive(
      isActive: { [weak self, weak entry] in
        guard let self, let entry else { return false }
        return self.lifecycle.isOpen
          && !self.isOutputSuppressed(remapped: entry.inputReportState.isRemapped)
      },
      onFailure: { [weak self, weak entry] error in
        guard let self, let entry else { return }
        let removed = self.registryLock.withLock { () -> Entry? in
          guard let identifier = self.entries.first(where: { $0.value === entry })?.key else {
            return nil
          }
          self._status = "error: keepalive failed: \(error)"
          return self.entries.removeValue(forKey: identifier)
        }
        _ = removed?.beginClose()
      }
    )
  }

  public func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) async {
    try? await deliver(events: events, from: identifier, remappedState: nil, motionUpdate: nil)
  }

  public func dispatchReportingFailure(
    events: [ControllerEvent],
    from identifier: DeviceIdentifier
  ) async throws {
    try await deliver(events: events, from: identifier, remappedState: nil, motionUpdate: nil)
  }

  public func send(_ state: RemappingGamepadState, for identifier: DeviceIdentifier) async throws {
    if state == .neutral, !lifecycle.isOpen {
      await close()
      return
    }
    try await deliver(events: [], from: identifier, remappedState: state, motionUpdate: nil)
  }

  public func send(
    _ motion: RemappingVirtualMotionState?,
    for identifier: DeviceIdentifier
  ) async throws {
    try await deliver(events: [], from: identifier, remappedState: nil, motionUpdate: .some(motion))
  }

  internal func isOutputSuppressed(remapped: Bool) -> Bool {
    registryLock.withLock { remapped ? remappingOutputSuppressed : _suppressOutput }
  }

  internal func deliver(
    events: [ControllerEvent],
    from identifier: DeviceIdentifier,
    remappedState: RemappingGamepadState?,
    motionUpdate: RemappingVirtualMotionState??
  ) async throws {
    let neutralizing = remappedState == .neutral || motionUpdate == .some(nil)
    let remapped = remappedState != nil || motionUpdate != nil
    let outputSuppressed = isOutputSuppressed(remapped: remapped)
    guard lifecycle.isOpen, !outputSuppressed || neutralizing || !remapped else {
      throw CancellationError()
    }
    let activeEntry: Entry
    do {
      if neutralizing {
        guard let existing = registryLock.withLock({ entries[identifier] }) else { return }
        activeEntry = existing
      } else {
        activeEntry = try await entry(for: identifier)
      }
    } catch {
      registryLock.withLock { if lifecycle.isOpen { _status = "error: \(error)" } }
      throw error
    }
    guard lifecycle.isOpen else { throw CancellationError() }
    if outputSuppressed && !neutralizing { return }
    let stickTransfer =
      remappedState == nil
      ? Self.stickTransfer(for: identifier) : StickTransfer(deadzone: 0, rescalesDeadzone: false)
    let isActive: @Sendable () -> Bool = { [self] in
      lifecycle.isOpen && (!isOutputSuppressed(remapped: remapped) || neutralizing)
    }
    do {
      try await activeEntry.sender.submit(whileActive: isActive, requireActive: true) {
        [self, activeEntry] in
        guard isActive() else { throw CancellationError() }
        let primaryReport: [UInt8]?
        if let motionUpdate {
          guard motionUpdate == nil || activeEntry.inputReportState.supportsMotion else {
            throw RemappingEventEngineError.sinkUnavailable
          }
          primaryReport = activeEntry.inputReportState.updateMotion(motionUpdate)
        } else {
          primaryReport = activeEntry.inputReportState.update(remapped: remapped) { state in
            if let remappedState {
              let motion = state.motion
              let motionSamples = state.motionSamples
              let motionTimestamp = state.motionTimestampNanoseconds
              state = VirtualGamepadState()
              state.motion = motion
              state.motionSamples = motionSamples
              state.motionTimestampNanoseconds = motionTimestamp
              for event in remappedState.events(since: .neutral) {
                applyEvent(event, stickTransfer: stickTransfer, state: &state)
              }
            } else {
              for event in events { applyEvent(event, stickTransfer: stickTransfer, state: &state) }
            }
          }
        }
        var reports = primaryReport.map { [$0] } ?? []
        if emitsXboxGuideReport {
          if let remappedState {
            reports.append([0x02, remappedState.buttons.contains(.guide) ? 0x01 : 0x00])
          } else {
            reports += events.compactMap { xboxGuideReport(for: $0) }
          }
        }
        return reports
      }.value()
      startInputReportKeepalive(activeEntry)
      registryLock.withLock { recomputeStatusLocked() }
    } catch {
      let removed = registryLock.withLock { () -> Entry? in
        guard entries[identifier] === activeEntry else { return nil }
        _status = "error: \(error)"
        return entries.removeValue(forKey: identifier)
      }
      await removed?.close()
      throw error
    }
  }

  internal func entry(for identifier: DeviceIdentifier) async throws -> Entry {
    let result: (task: Task<Entry, Error>, generation: UInt64) = try registryLock.withLock {
      guard lifecycle.isOpen else { throw CancellationError() }
      let generation = lifecycleGenerations[identifier, default: 0]
      if let entry = entries[identifier] { return (Task { entry }, generation) }
      if let task = creationTasks[identifier] { return (task, generation) }

      let now = DispatchTime.now().uptimeNanoseconds
      let retryPolicy = creationRetryPolicies[identifier] ?? UserSpaceDeviceCreationRetryPolicy()
      guard retryPolicy.permitsAttempt(at: now) else { throw CreationError.createFailed }

      let task = Task { try await self.createEntry(for: identifier) }
      creationTasks[identifier] = task
      return (task, generation)
    }
    let (task, generation) = result

    do {
      let entry = try await task.value
      let installed = registryLock.withLock { () -> Bool in
        guard lifecycle.isOpen, lifecycleGenerations[identifier, default: 0] == generation else {
          return false
        }
        creationTasks.removeValue(forKey: identifier)
        creationRetryPolicies.removeValue(forKey: identifier)
        entries[identifier] = entry
        recomputeStatusLocked()
        return true
      }
      guard installed else {
        await entry.close()
        throw CancellationError()
      }
      return entry
    } catch {
      registryLock.withLock {
        guard lifecycleGenerations[identifier, default: 0] == generation else { return }
        creationTasks.removeValue(forKey: identifier)
        var policy = creationRetryPolicies[identifier] ?? UserSpaceDeviceCreationRetryPolicy()
        policy.recordFailure(at: DispatchTime.now().uptimeNanoseconds)
        creationRetryPolicies[identifier] = policy
      }
      throw error
    }
  }

  internal func recomputeStatusLocked() {
    _status = entries.isEmpty ? "off" : "on (devices=\(entries.count))"
  }
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
