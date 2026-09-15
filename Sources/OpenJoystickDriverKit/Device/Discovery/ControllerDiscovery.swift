import Foundation

func controllerDisplayName(productName: String?, vendorID: UInt16, productID: UInt16) -> String {
  if let productName {
    let value = productName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty { return value }
  }
  return String(format: "Controller %04x:%04x", vendorID, productID)
}

let usbDetectionPollNanoseconds: UInt64 = 500_000_000
let devicePermissionWatchNanoseconds: UInt64 = 1_000_000_000
let deviceDiscoveryNanosecondsPerMillisecond: UInt64 = 1_000_000
let maxRumbleDurationMs = 5_000
let usbVendorSpecificClass: UInt8 = 0xFF

struct RumbleStopTokenRegistry {
  private var generations: [DeviceIdentifier: UInt64] = [:]

  mutating func replace(for identifier: DeviceIdentifier) -> UInt64 {
    let generation = (generations[identifier] ?? 0) &+ 1
    generations[identifier] = generation
    return generation
  }

  func isCurrent(_ generation: UInt64, for identifier: DeviceIdentifier) -> Bool {
    generations[identifier] == generation
  }

  mutating func remove(_ identifier: DeviceIdentifier) {
    generations.removeValue(forKey: identifier)
  }

  mutating func removeAll() { generations.removeAll() }
}

actor PhysicalHIDOutputSerialQueue {
  private var tail: Task<Bool, Never>?
  private var generation: UInt64 = 0

  func perform(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
    let previous = tail
    generation &+= 1
    let currentGeneration = generation
    let task = Task {
      if let previous { _ = await previous.value }
      guard !Task.isCancelled else { return false }
      return await operation()
    }
    tail = task
    let result = await task.value
    if generation == currentGeneration { tail = nil }
    return result
  }
}

/// Manages device detection and pipeline lifecycle for all
/// connected controllers.
/// Uses dual detection: an Apple USB transport provider for raw interfaces and
/// the OS-generation HID wrapper for HID-class controllers.
public actor DeviceManager {

  let parserRegistry: ParserRegistry
  let dispatcher: any OutputDispatcher
  let permissionManager: PermissionManager
  let hidManager: HIDManager
  let usbTransportProvider: (any USBTransportProvider)?
  let wirelessControllerDisconnector: (any WirelessControllerDisconnecting)?
  var pipelines: [DeviceIdentifier: DevicePipeline] = [:]
  var deviceInfos: [DeviceIdentifier: DeviceInfo] = [:]
  var detectionTasks: [Task<Void, Never>] = []
  var hidDetectionTask: Task<Void, Never>?
  var hidInitializationTasks: [UInt32: Task<Void, Never>] = [:]
  var hidPeriodicOutputTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
  var hidOutputQueues: [DeviceIdentifier: PhysicalHIDOutputSerialQueue] = [:]
  var permissionWatchTask: Task<Void, Never>?
  var externalOutputAllowed = true
  var lastPhysicalHIDOutputNanoseconds: [DeviceIdentifier: UInt64] = [:]
  var rumbleStopTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
  var rumbleStopTokens = RumbleStopTokenRegistry()
  var physicalOutputOwnership = PhysicalOutputOwnership()

  /// Creates a manager that sends all output to `dispatcher`.
  ///
  /// - Parameters:
  ///   - dispatcher: Output dispatcher for sending HID reports.
  ///   - virtualProfile: Virtual device profile for self-exclusion filtering.
  ///   - usbTransportProvider: Native raw-USB transport provider, or nil to disable raw USB
  ///     discovery.
  public init(
    dispatcher: any OutputDispatcher,
    virtualProfile: VirtualDeviceProfile = .default,
    usbTransportProvider: (any USBTransportProvider)? = nil,
    wirelessControllerDisconnector: (any WirelessControllerDisconnecting)? = nil
  ) {
    self.dispatcher = dispatcher
    self.usbTransportProvider = usbTransportProvider
    self.wirelessControllerDisconnector = wirelessControllerDisconnector
    let registry = ParserRegistry()
    self.parserRegistry = registry
    self.permissionManager = PermissionManager()
    self.hidManager = HIDManager(
      virtualProfile: virtualProfile,
      additionalProfileIdentifiers: registry.hidProfileIdentifiers()
    )
  }
}
