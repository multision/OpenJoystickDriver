import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension CompatibilityTests {
  @Test


  func repeatedForegroundRefreshesKeepLatestBackend() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    let box = AutomaticConsumerBox()
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { box.value },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    await dispatcher.dispatch(events: [], from: id)
    box.value = .appleGameController
    for _ in 0..<3 { await dispatcher.refreshForCurrentConsumer() }

    #expect(probe.snapshot().0 == 1)
    await dispatcher.close()
  }

  @Test


  func unchangedForegroundRefreshPreservesVirtualDevice() async {
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
    for _ in 0..<3 { await dispatcher.refreshForCurrentConsumer() }

    #expect(probe.snapshot().0 == 1)
    #expect(probe.snapshot().2[0].counts().1 == 0)
    await dispatcher.close()
  }

  @Test
  func consumerChangeDoesNotDropCurrentDispatch() async {
    let id = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let probe = ConcurrentFactoryProbe()
    let box = AutomaticConsumerBox()
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { box.value },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(id)])
    )
    await dispatcher.dispatch(events: [], from: id)
    box.value = .appleGameController
    await dispatcher.refreshForCurrentConsumer()
    await dispatcher.dispatch(events: [], from: id)
    #expect(probe.snapshot().2.map { $0.counts().0 } == [2])
    await dispatcher.close()
  }

  @Test
  func unrelatedControllerStopLeavesOtherControllerUsable() async {
    let first = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let second = DeviceIdentifier(vendorID: 0x3537, productID: 0x1011)
    let probe = ConcurrentFactoryProbe()
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: DeviceManager(dispatcher: LoggingOutputDispatcher()),
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: { .sdlHIDAPI },
      builder: { _ in probe.make() },
      observeConsumerChanges: false,
      descriptionsProvider: provider([description(first), description(second)])
    )
    await dispatcher.dispatch(events: [], from: second)
    await dispatcher.controllerDidStop(first)
    await dispatcher.dispatch(events: [], from: second)
    #expect(probe.snapshot().2.first?.counts().0 == 2)
    await dispatcher.close()
  }

  @Test
  func automaticDispatcherRefreshesOnConsumerChangeWithoutInput() async {
    let manager = DeviceManager(dispatcher: LoggingOutputDispatcher())
    let identifier = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010)
    let description = ApplicationServiceDeviceDescription(
      name: "GameSir",
      vendorID: identifier.vendorID,
      productID: identifier.productID,
      parser: "GIP",
      connection: "USB",
      serialNumber: nil,
      protocolVariant: .xboxOne,
      runtimeIdentifier: identifier.runtimeIdentifier
    )
    let box = AutomaticConsumerBox()
    let builder: AutomaticDispatcherCoordinator.Factory = { _ in
      let backend = AutomaticBackendProbe()
      box.created.append(backend)
      return backend
    }
    let consumerProvider: @Sendable () -> CompatibilityConsumerFamily = { box.value }
    let descriptionsProvider: @Sendable () async -> [ApplicationServiceDeviceDescription] = {
      [description]
    }
    let dispatcher = AutomaticUserSpaceOutputDispatcher(
      deviceManager: manager,
      ownershipProvider: { _ in .exclusiveRawUSB },
      consumerProvider: consumerProvider,
      builder: builder,
      observeConsumerChanges: false,
      descriptionsProvider: descriptionsProvider
    )
    await dispatcher.dispatch(events: [], from: identifier)
    box.value = .appleGameController
    await dispatcher.refreshForCurrentConsumer()
    box.value = .unknown
    await dispatcher.refreshForCurrentConsumer()
    #expect(box.created.count == 1)
    await dispatcher.controllerDidStop(identifier)
    #expect(box.created.last?.closed == true)
    await dispatcher.close()
  }

  @Test
  func coalescingStressRunsTwentyFiveExplicitIterations() async {
    for _ in 0..<25 {
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
      await dispatcher.close()
      #expect(probe.snapshot().2[0].counts().1 == 1)
    }
  }

  @Test
  func rejectedCompatibilityIdentityDoesNotPublishRequestedValue() async {
    let gateway = GatewayStub(setIdentityResult: false)
    let viewModel = await MainActor.run { RuntimeViewModel(gateway: gateway) }

    await viewModel.setCompatibilityIdentity(.appleGameController)

    let state = await MainActor.run { viewModel.compatibilityState }
    guard case .available(.sdl2_3) = state else {
      Issue.record("Expected a rejected identity to retain the live identity")
      return
    }
    #expect(await MainActor.run { viewModel.compatibilityError } != nil)
    #expect(await gateway.selectedIdentity == .sdl2_3)
  }

  @Test
  func resettingCompatibilityIdentityUsesTheScopedMutation() async {
    let gateway = GatewayStub()
    let viewModel = await MainActor.run { RuntimeViewModel(gateway: gateway) }

    await viewModel.resetCompatibilityIdentity()

    #expect(await gateway.selectedIdentity == .automatic)
    #expect(await gateway.setIdentityCallCount == 1)
  }

  @Test
  func compatibilitySuccessDoesNotInheritAnUnrelatedRuntimeError() async {
    let gateway = GatewayStub(statusShouldFail: true)
    let viewModel = await MainActor.run { RuntimeViewModel(gateway: gateway) }

    await viewModel.refresh()

    let state = await MainActor.run { (viewModel.compatibilityState, viewModel.compatibilityError) }
    guard case .available = state.0 else {
      Issue.record("Expected compatibility identity loading to succeed")
      return
    }
    #expect(state.1 == nil)
    #expect(await MainActor.run { viewModel.lastError } != nil)
  }

  @Test
  func newerCompatibilitySelectionWinsOverAnOlderIdentityRead() async {
    let gateway = GatewayStub(compatibilityReadDelayNanoseconds: 100_000_000)
    let viewModel = await MainActor.run { RuntimeViewModel(gateway: gateway) }
    let read = Task { @MainActor in await viewModel.loadCompatibilityIdentity() }
    try? await Task.sleep(nanoseconds: 10_000_000)

    await viewModel.setCompatibilityIdentity(.appleGameController)
    await read.value

    let state = await MainActor.run { viewModel.compatibilityState }
    guard case .available(let identity) = state else {
      Issue.record("Expected the newer compatibility selection to remain authoritative")
      return
    }
    #expect(identity == .appleGameController)
  }

  @Test
  func compatibilitySelectionUpdatesTheStatusSummary() async {
    let gateway = GatewayStub()
    let viewModel = await MainActor.run { RuntimeViewModel(gateway: gateway) }

    await viewModel.refresh()
    await viewModel.setCompatibilityIdentity(.appleGameController)

    let state = await MainActor.run { viewModel.statusState }
    guard case .available(let status) = state else {
      Issue.record("Expected the status summary to remain available")
      return
    }
    #expect(status.compatibilityIdentity == .appleGameController)
  }

  @Test
  func rpcRejectsUnknownIdentityWithoutChangingRuntimeOrPersistence() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let priorRawValue = defaults.object(forKey: key)

    defaults.set(CompatibilityIdentity.appleGameController.rawValue, forKey: key)
    defer {
      if let priorRawValue {
        defaults.set(priorRawValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }

    let permissionManager = PermissionManager()
    let dispatcher = CompatibilityOutputDispatcher()
    let profileLibrary = RemappingProfileLibrary()
    let postEventAccess = CoreGraphicsPostEventAccess()
    let remappingEngine = RemappingEventEngine(
      sink: CoreGraphicsSystemInputSink(access: postEventAccess)
    )
    let remappingRouter = RemappingOutputRouter(
      library: profileLibrary,
      engine: remappingEngine,
      compatibility: dispatcher,
      foregroundApplication: WorkspaceRemappingForegroundApplication(),
      postEventAccess: postEventAccess
    )
    let deviceManager = DeviceManager(dispatcher: remappingRouter)

    let server = ApplicationServiceServer(
      deviceManager: deviceManager,
      permissionManager: permissionManager,
      dispatcher: dispatcher,
      remappingProfileLibrary: profileLibrary,
      remappingRouter: remappingRouter,
      postEventAccess: postEventAccess
    )
    let priorRuntimeIdentity = server.compatibilityIdentity
    let priorRuntimeEnabled = server.userSpaceEnabled
    let priorRuntimeStatus = server.currentUserSpaceStatus()

    let accepted = await withCheckedContinuation { continuation in
      server.setCompatibilityIdentity("xone-hid") { result in continuation.resume(returning: result)
      }
    }

    #expect(accepted == false)
    #expect(server.compatibilityIdentity == priorRuntimeIdentity)
    #expect(server.userSpaceEnabled == priorRuntimeEnabled)
    #expect(server.currentUserSpaceStatus() == priorRuntimeStatus)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.appleGameController.rawValue)
  }

  @Test
  func serverInitSanitizesUnknownPersistedIdentityToAutomatic() {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let priorRawValue = defaults.object(forKey: key)
    defaults.set("xone-hid", forKey: key)
    defer {
      if let priorRawValue {
        defaults.set(priorRawValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }

    let permissionManager = PermissionManager()
    let dispatcher = CompatibilityOutputDispatcher()
    let profileLibrary = RemappingProfileLibrary()
    let postEventAccess = CoreGraphicsPostEventAccess()
    let remappingEngine = RemappingEventEngine(
      sink: CoreGraphicsSystemInputSink(access: postEventAccess)
    )
    let remappingRouter = RemappingOutputRouter(
      library: profileLibrary,
      engine: remappingEngine,
      compatibility: dispatcher,
      foregroundApplication: WorkspaceRemappingForegroundApplication(),
      postEventAccess: postEventAccess
    )
    let server = ApplicationServiceServer(
      deviceManager: DeviceManager(dispatcher: remappingRouter),
      permissionManager: permissionManager,
      dispatcher: dispatcher,
      remappingProfileLibrary: profileLibrary,
      remappingRouter: remappingRouter,
      postEventAccess: postEventAccess,
      initializeCompatibilityBackend: false
    )

    #expect(server.compatibilityIdentity == .automatic)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.automatic.rawValue)
  }

}
