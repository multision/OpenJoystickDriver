import AppKit
import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

private final class ConsumerCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var value: CompatibilityConsumerFamily?

  func set(_ value: CompatibilityConsumerFamily) { lock.withLock { self.value = value } }
  func get() -> CompatibilityConsumerFamily? { lock.withLock { value } }
}

private final class RoutingConsumer: @unchecked Sendable {
  var value = CompatibilityConsumerFamily.unknown
}

private final class RoutingBackend: CompatibilityUserSpaceOutputDispatching, @unchecked Sendable {
  var suppressOutput = false
  var status: String { "probe" }
  var lastRumbleStatus: String { "none" }
  func activate(for identifiers: [DeviceIdentifier]) {}
  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {}
  func close() {}
}

struct CompatibilityConsumerRoutingTests {
  @Test
  @MainActor
  func activationUsesTheApplicationCarriedByTheNotification() {
    let center = NotificationCenter()
    let activatedURL = URL(fileURLWithPath: "/Applications/Activated.app")
    let staleForegroundURL = URL(fileURLWithPath: "/Applications/Stale.app")
    let received = ConsumerCapture()
    let token = CompatibilityConsumerRouting.observe(
      notificationCenter: center,
      activatedBundleURL: { $0.object as? URL },
      consumerResolver: { url in url == activatedURL ? .geckoGamepad : .webkitGamepad },
      { received.set($0) }
    )
    defer { center.removeObserver(token) }

    center.post(
      name: NSWorkspace.didActivateApplicationNotification,
      object: activatedURL,
      userInfo: ["foreground": staleForegroundURL]
    )

    #expect(received.get() == .geckoGamepad)
  }

  @Test
  func automaticDiagnosticsExposeConsumerVariantAndVirtualIdentity() async throws {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let description = ApplicationServiceDeviceDescription(
      name: "probe",
      vendorID: identifier.vendorID,
      productID: identifier.productID,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne,
      runtimeIdentifier: identifier.runtimeIdentifier
    )
    let consumer = RoutingConsumer()
    let descriptionsProvider: @Sendable () async -> [ApplicationServiceDeviceDescription] = {
      [description]
    }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { consumer.value },
      builder: { _ in RoutingBackend() },
      observeConsumerChanges: false,
      descriptionsProvider: descriptionsProvider
    )

    try await dispatcher.activate(for: [identifier])
    consumer.value = .geckoGamepad
    await dispatcher.refreshForCurrentConsumer()
    #expect(
      dispatcher.status == "automatic, consumer: geckoGamepad, targets: gecko-xbox-one-s 045E:02E0"
    )

    consumer.value = .webkitGamepad
    await dispatcher.refreshForCurrentConsumer()
    #expect(dispatcher.status == "automatic, consumer: webkitGamepad, targets: canonical 045E:0B13")
    await dispatcher.close()
  }
}
