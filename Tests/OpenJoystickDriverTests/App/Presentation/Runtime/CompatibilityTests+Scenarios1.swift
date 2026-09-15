import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension CompatibilityTests {
  func provider(
    _ values: [ApplicationServiceDeviceDescription]
  ) -> @Sendable () async -> [ApplicationServiceDeviceDescription] { { values } }

  func description(_ id: DeviceIdentifier) -> ApplicationServiceDeviceDescription {
    ApplicationServiceDeviceDescription(
      name: "probe",
      vendorID: id.vendorID,
      productID: id.productID,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne,
      runtimeIdentifier: id.runtimeIdentifier
    )
  }

  @Test
  func automaticConsumerChangesWithSameEffectiveIdentityDoNotRebuild() async {
    let identifier = DeviceIdentifier(vendorID: 0x057E, productID: 0x2009)
    let probe = ConcurrentFactoryProbe()
    let box = AutomaticConsumerBox()
    let description = ApplicationServiceDeviceDescription(
      name: "Switch",
      vendorID: identifier.vendorID,
      productID: identifier.productID,
      parser: "SwitchPro",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .switchPro,
      runtimeIdentifier: identifier.runtimeIdentifier
    )
    let descriptionsProvider: @Sendable () -> [ApplicationServiceDeviceDescription] = {
      [description]
    }

    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { box.value },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: descriptionsProvider

    )

    await dispatcher.dispatch(events: [], from: identifier)
    box.value = .appleGameController
    await dispatcher.refreshForCurrentConsumer()

    #expect(probe.snapshot().0 == 1)
    #expect(probe.snapshot().2.first?.counts().1 == 0)
    await dispatcher.close()
  }

  @Test


  func automaticActivationBuildsOneCoherentChildPerController() async throws {
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
    ]
    let created = AutomaticConsumerBox()
    let descriptions = identifiers.map { description($0) }
    let descriptionsProvider: @Sendable () -> [ApplicationServiceDeviceDescription] = {
      descriptions
    }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in
        let backend = AutomaticBackendProbe()

        created.created.append(backend)
        return backend
      },
      observeConsumerChanges: false,
      descriptionsProvider: descriptionsProvider
    )

    try await dispatcher.activate(for: identifiers)
    #expect(created.created.count == identifiers.count)
    #expect(created.created.map(\.activations) == identifiers.map { [[$0]] })
    await dispatcher.dispatch(events: [], from: identifiers[0])
    await dispatcher.close()
    #expect(created.created.allSatisfy { $0.closed })
  }

  @Test
  func automaticActivationFailureClosesTheEntireChildSet() async {
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
    ]
    let created = AutomaticConsumerBox()
    let descriptions = identifiers.map { description($0) }
    let descriptionsProvider: @Sendable () -> [ApplicationServiceDeviceDescription] = {
      descriptions
    }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in
        let backend = AutomaticBackendProbe(failsActivation: created.created.count == 1)
        created.created.append(backend)
        return backend
      },
      observeConsumerChanges: false,
      descriptionsProvider: descriptionsProvider
    )

    do {
      try await dispatcher.activate(for: identifiers)
      Issue.record("Activation unexpectedly succeeded")
    } catch {}
    #expect(created.created.count == identifiers.count)
    #expect(created.created.allSatisfy { $0.closed })
    await dispatcher.close()
  }

  @Test


  func automaticEffectiveIdentityChangeReplacesChildren() async throws {
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
    ]
    let created = AutomaticConsumerBox()
    let box = AutomaticConsumerBox()
    let descriptions = identifiers.map { description($0) }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { box.value },
      builder: { _ in
        let backend = AutomaticBackendProbe()
        created.created.append(backend)
        return backend
      },
      observeConsumerChanges: false,
      descriptionsProvider: { descriptions },
      identityProvider: { _, consumer in consumer == .sdlHIDAPI ? .genericHID : .appleGameController
      }
    )

    try await dispatcher.activate(for: identifiers)

    box.value = .appleGameController
    await dispatcher.refreshForCurrentConsumer()

    #expect(created.created.count == 4)
    #expect(created.created.prefix(2).allSatisfy { $0.closed })
    #expect(created.created.suffix(2).allSatisfy { !$0.closed })
    await dispatcher.close()
  }

  @Test
  func repeatedConsumerRefreshKeepsCurrentChildren() async throws {
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
    ]
    let created = AutomaticConsumerBox()
    let box = AutomaticConsumerBox()
    let descriptions = identifiers.map { description($0) }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { box.value },
      builder: { _ in
        let backend = AutomaticBackendProbe()
        created.created.append(backend)
        return backend
      },
      observeConsumerChanges: false,
      descriptionsProvider: { descriptions },
      identityProvider: { _, consumer in consumer == .sdlHIDAPI ? .genericHID : .appleGameController
      }
    )

    try await dispatcher.activate(for: identifiers)
    let original = created.created
    box.value = .appleGameController
    await dispatcher.refreshForCurrentConsumer()
    await dispatcher.refreshForCurrentConsumer()

    #expect(created.created.count == 4)
    #expect(original.allSatisfy { $0.closed })
    #expect(created.created.suffix(2).allSatisfy { !$0.closed })
    await dispatcher.close()
  }

  @Test


  func concurrentFirstDispatchCoalescesAndKeepsBothEvents() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    probe.gate = DispatchSemaphore(value: 0)
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    let first = Task { await dispatcher.dispatch(events: [], from: id) }
    await probe.waitForEntered()
    let second = Task { await dispatcher.dispatch(events: [], from: id) }

    #expect(probe.snapshot().0 == 0)
    probe.gate?.signal()
    await first.value
    await second.value
    #expect(probe.snapshot().0 == 1)
    #expect(probe.snapshot().2[0].counts().0 == 2)
    #expect(probe.snapshot().2[0].counts().1 == 0)
    await dispatcher.close()
    #expect(probe.snapshot().2[0].counts().1 == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func differentControllersBuildIndependently() async {
    let first = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let second = DeviceIdentifier(vendorID: 0x3537, productID: 0x1011)
    let probe = ConcurrentFactoryProbe()
    probe.gate = DispatchSemaphore(value: 0)
    let dispatcher = AutomaticUserSpaceOutputDispatcher(

      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(first), description(second)])
    )
    let firstTask = Task { await dispatcher.dispatch(events: [], from: first) }

    let secondTask = Task { await dispatcher.dispatch(events: [], from: second) }
    await probe.waitForEntered()
    await probe.waitForEntered()
    #expect(probe.snapshot().1 == 2)
    probe.gate?.signal()
    probe.gate?.signal()
    await firstTask.value
    await secondTask.value
    #expect(probe.snapshot().0 == 2)
    await dispatcher.close()
  }

  @Test


  func stopDuringBuildDoesNotResurrect() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    probe.gate = DispatchSemaphore(value: 0)
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    let task = Task { await dispatcher.dispatch(events: [], from: id) }
    await probe.waitForEntered()
    let stop = Task { await dispatcher.controllerDidStop(id) }

    #expect(probe.snapshot().2.isEmpty)
    probe.gate?.signal()
    await stop.value
    await task.value
    let counts = probe.snapshot().2.first?.counts()
    #expect(counts?.0 == 0)
    #expect(counts?.1 == 1)
    await dispatcher.close()
  }

  @Test
  func closeDuringBuildClosesExactlyOnce() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    probe.gate = DispatchSemaphore(value: 0)
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    let task = Task { await dispatcher.dispatch(events: [], from: id) }
    await probe.waitForEntered()
    let close = Task { await dispatcher.close() }
    #expect(probe.snapshot().2.isEmpty)
    probe.gate?.signal()
    await close.value
    await task.value
    #expect(probe.snapshot().2.first?.counts().1 == 1)
  }

  @Test
  func retiredLeaseClosesAfterReleaseOnlyOnce() async {
    let backend = ConcurrentBackendProbe()
    let slot = AutomaticBackendSlot(backend)
    let lease = slot.acquire()
    let retirement = Task { await slot.retireAndWait() }
    #expect(backend.counts().1 == 0)
    await lease?.release()
    _ = await retirement.value
    #expect(backend.counts().1 == 1)
  }

  @Test


  func suppressionRetiresPublicationThenRecreatesAndResumesOutput() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    await dispatcher.dispatch(events: [], from: id)
    #expect(probe.snapshot().0 == 1)
    #expect(probe.snapshot().2.first?.counts().0 == 1)

    await dispatcher.setOutputSuppressed(true)
    #expect(probe.snapshot().2.first?.counts().1 == 1)
    await dispatcher.dispatch(events: [], from: id)
    #expect(probe.snapshot().0 == 1)

    await dispatcher.setOutputSuppressed(false)
    #expect(probe.snapshot().0 == 2)
    #expect(probe.snapshot().2[1].counts().0 == 0)
    await dispatcher.dispatch(events: [], from: id)
    #expect(probe.snapshot().2[1].counts().0 == 1)

    await dispatcher.close()
    #expect(probe.snapshot().2[1].counts().1 == 1)
  }

}
