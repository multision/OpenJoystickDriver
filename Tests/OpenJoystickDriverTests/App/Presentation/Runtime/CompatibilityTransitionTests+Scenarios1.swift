import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension CompatibilityTransitionTests {
  func transitionServer(
    factory: CompatibilityTransitionFactory,
    identifiers: [DeviceIdentifier],
    priorIdentity: CompatibilityIdentity = .genericHID,
    timeouts: CompatibilityTransitionTimeouts = .standard,
    clock: CompatibilityTransitionClock = .system,
    identifierProvider: (@Sendable () async -> [DeviceIdentifier])? = nil
  ) -> (ApplicationServiceServer, CompatibilityTransitionProbe) {
    let compatibilityDispatcher = CompatibilityOutputDispatcher()
    let profileLibrary = RemappingProfileLibrary()
    let postEventAccess = CoreGraphicsPostEventAccess()
    let remappingEngine = RemappingEventEngine(
      sink: CoreGraphicsSystemInputSink(access: postEventAccess)
    )
    let remappingRouter = RemappingOutputRouter(
      library: profileLibrary,
      engine: remappingEngine,
      compatibility: compatibilityDispatcher,
      foregroundApplication: WorkspaceRemappingForegroundApplication(),
      postEventAccess: postEventAccess
    )
    let server = ApplicationServiceServer(
      deviceManager: DeviceManager(dispatcher: remappingRouter),
      permissionManager: PermissionManager(),
      dispatcher: compatibilityDispatcher,
      remappingProfileLibrary: profileLibrary,
      remappingRouter: remappingRouter,
      postEventAccess: postEventAccess,
      userSpaceDispatcherBuilder: { try factory.make($0) },
      connectedIdentifierProvider: identifierProvider ?? { identifiers },
      compatibilityTransitionTimeouts: timeouts,
      compatibilityTransitionClock: clock,
      initializeCompatibilityBackend: false
    )
    let old = CompatibilityTransitionProbe(identity: priorIdentity)
    server.userSpaceLock.withLock {
      server.compatibilityIdentity = priorIdentity
      server.persistedCompatibilityIdentity = priorIdentity
      server.userSpaceDispatcher = old
      server.userSpaceEnabled = true
      server.userSpaceStatus = old.status
      server.compatibilityLiveIdentity = priorIdentity
      compatibilityDispatcher.setBackend(old)
    }
    return (server, old)
  }

  func requestIdentity(
    _ server: ApplicationServiceServer,
    _ identity: CompatibilityIdentity
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      server.setCompatibilityIdentity(identity.rawValue) { continuation.resume(returning: $0) }
    }
  }

  @Test
  func noncooperativeFeedbackIsQuarantinedBeforeNeutralization() async {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let stalledWrite = CompatibilityTransitionGate()
    let probe = CompatibilityFeedbackProbe()
    let feedbackGate = CompatibilityFeedbackGate { _, command in
      await probe.append(command)
      if command.left > 0 { await stalledWrite.wait() }
    }

    feedbackGate.submit(identifier: identifier, command: VirtualRumbleCommand(left: 1, right: 0))
    while await probe.count() < 1 { await Task.yield() }

    let started = DispatchTime.now().uptimeNanoseconds
    #expect(await feedbackGate.quiesceAndNeutralize([identifier], timeout: 20_000_000))
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    #expect(elapsed < 100_000_000)
    #expect(await probe.values().last == VirtualRumbleCommand(left: 0, right: 0, durationMs: 0))

    await stalledWrite.open()
  }

  @Test


  func stageFailurePreservesLiveBackendAndPersistence() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let prior = defaults.object(forKey: key)
    defaults.set(CompatibilityIdentity.genericHID.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    let factory = CompatibilityTransitionFactory()
    factory.buildFailures = [.appleGameController]

    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 0)
    #expect(server.userSpaceDispatcher === old)
    #expect(server.userSpaceEnabled)
    #expect(server.compatibilityIdentity == .genericHID)
    #expect(server.compatibilityRetrySnapshot?.detail?.contains("BuildFailure") == true)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.genericHID.rawValue)
  }

  @Test


  func successfulTransitionActivatesBeforeCommitAndClosesOldOnce() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let prior = defaults.object(forKey: key)
    defaults.set(CompatibilityIdentity.genericHID.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)

    let factory = CompatibilityTransitionFactory()
    let (server, old) = transitionServer(factory: factory, identifiers: [identifier])

    #expect(await requestIdentity(server, .appleGameController))
    let candidate = factory.values().first
    #expect(candidate?.activationValues == [[identifier]])
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceDispatcher === candidate)
    #expect(server.compatibilityIdentity == .appleGameController)

    #expect(defaults.string(forKey: key) == CompatibilityIdentity.appleGameController.rawValue)
  }

  @Test
  func failedPriorRestorationActivatesGenericFallbackWithoutPersistingIt() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let prior = defaults.object(forKey: key)
    defaults.set(CompatibilityIdentity.sdl2_3.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    let factory = CompatibilityTransitionFactory()
    factory.activationFailures = [.appleGameController, .sdl2_3]
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)],
      priorIdentity: .sdl2_3
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 1)
    #expect(factory.values().map(\.identity) == [.appleGameController, .sdl2_3, .genericHID])
    #expect(factory.values().dropLast().allSatisfy { $0.closeCountValue == 1 })
    #expect(server.userSpaceDispatcher === factory.values().last)
    #expect(server.compatibilityLiveIdentity == .genericHID)
    #expect(server.compatibilityIdentity == .sdl2_3)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.sdl2_3.rawValue)
    #expect(
      server.compatibilityRetrySnapshot
        == CompatibilityRetrySnapshot(
          requestedIdentity: .appleGameController,
          priorProfileIdentity: .sdl2_3,
          phase: .rollbackActivation
        )
    )
  }

  @Test
  func candidateFailureRollsBackOneCoherentPriorBackend() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let prior = defaults.object(forKey: key)
    defaults.set(CompatibilityIdentity.genericHID.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    let factory = CompatibilityTransitionFactory()
    factory.activationFailures = [.appleGameController]
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    let probes = factory.values()
    #expect(probes.count == 2)
    #expect(probes[0].closeCountValue == 1)
    #expect(probes[1].closeCountValue == 0)
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceDispatcher === probes[1])
    #expect(server.userSpaceEnabled)
    #expect(server.compatibilityIdentity == .genericHID)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.genericHID.rawValue)
  }

  @Test


  func rollbackFailureLeavesOutputUnavailableWithoutAStaleBackend() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let retryKey = ApplicationServiceServer.compatibilityRetrySnapshotDefaultsKey
    let prior = defaults.object(forKey: key)
    let priorRetry = defaults.object(forKey: retryKey)
    defaults.set(CompatibilityIdentity.genericHID.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
      if let priorRetry {
        defaults.set(priorRetry, forKey: retryKey)
      } else {
        defaults.removeObject(forKey: retryKey)
      }
    }

    let factory = CompatibilityTransitionFactory()

    factory.activationFailures = [.appleGameController, .genericHID]
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(factory.values().allSatisfy { $0.closeCountValue == 1 })
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceDispatcher == nil)
    #expect(server.userSpaceEnabled == false)
    #expect(server.currentUserSpaceStatus().hasPrefix("error:"))
    #expect(server.compatibilityIdentity == .genericHID)
    #expect(defaults.string(forKey: key) == CompatibilityIdentity.genericHID.rawValue)
    #expect(
      server.compatibilityRetrySnapshot
        == CompatibilityRetrySnapshot(
          requestedIdentity: .appleGameController,
          priorProfileIdentity: .genericHID,
          phase: .rollbackActivation
        )
    )
  }

  @Test


  func persistedRetrySnapshotLoadsAfterRestartAndSameIntentCanRetry() async {
    let defaults = UserDefaults.standard
    let identityKey = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let retryKey = ApplicationServiceServer.compatibilityRetrySnapshotDefaultsKey
    let priorIdentity = defaults.object(forKey: identityKey)
    let priorRetry = defaults.object(forKey: retryKey)
    defer {
      if let priorIdentity {
        defaults.set(priorIdentity, forKey: identityKey)
      } else {
        defaults.removeObject(forKey: identityKey)
      }
      if let priorRetry {
        defaults.set(priorRetry, forKey: retryKey)
      } else {
        defaults.removeObject(forKey: retryKey)
      }
    }

    let snapshot = CompatibilityRetrySnapshot(

      requestedIdentity: .appleGameController,
      priorProfileIdentity: .genericHID,
      phase: .rollbackActivation
    )
    defaults.set(CompatibilityIdentity.appleGameController.rawValue, forKey: identityKey)
    ApplicationServiceServer.persistCompatibilityRetrySnapshot(snapshot, defaults: defaults)

    let factory = CompatibilityTransitionFactory()
    let (server, placeholder) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )
    #expect(server.compatibilityRetrySnapshot == snapshot)
    server.userSpaceLock.withLock {
      server.dispatcher.setBackend(nil)
      server.userSpaceDispatcher = nil
      server.userSpaceCloseSlot = nil
      server.userSpaceEnabled = false
      server.compatibilityIdentity = .appleGameController
      server.persistedCompatibilityIdentity = .appleGameController
      server.compatibilityLiveIdentity = nil
    }
    await placeholder.close()

    #expect(await requestIdentity(server, .appleGameController))
    #expect(server.compatibilityIdentity == .appleGameController)
    #expect(server.compatibilityLiveIdentity == .appleGameController)
    #expect(server.compatibilityRetrySnapshot == nil)
    #expect(defaults.object(forKey: retryKey) == nil)
  }

  @Test
  func zeroControllerActivationUsesTheRemainingZeroDeviceBudget() async {
    let activationGate = CompatibilityTransitionGate()
    let factory = CompatibilityTransitionFactory()
    factory.firstActivationGate = activationGate
    let (server, old) = transitionServer(
      factory: factory,

      identifiers: [],
      timeouts: CompatibilityTransitionTimeouts(
        stageNanoseconds: 100_000_000,
        perControllerNanoseconds: 100_000_000,
        totalNanoseconds: 100_000_000,
        zeroControllerActivationNanoseconds: 100_000_000,
        feedbackNanoseconds: 100_000_000,
        candidateCloseNanoseconds: 100_000_000,
        rollbackStageNanoseconds: 100_000_000,
        rollbackActivationTotalNanoseconds: 100_000_000,
        zeroDeviceNanoseconds: 5_000_000
      )
    )

    let started = DispatchTime.now().uptimeNanoseconds
    #expect(await requestIdentity(server, .appleGameController) == false)
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    #expect(old.closeCountValue == 1)
    #expect(elapsed < 50_000_000)
    #expect(factory.values().count == 1)
    #expect(factory.values().first?.activationValues == [[]])
    #expect(server.userSpaceDispatcher == nil)
    #expect(server.compatibilityLiveIdentity == nil)
    await activationGate.open()
  }

  @Test
  func zeroControllerActivationCommitsAnIdleBackendForFutureHotPlug() async {
    let factory = CompatibilityTransitionFactory()
    let (server, old) = transitionServer(factory: factory, identifiers: [])

    #expect(await requestIdentity(server, .appleGameController))
    #expect(old.closeCountValue == 1)
    #expect(factory.values().count == 1)
    #expect(factory.values().first?.activationValues == [[]])
    #expect(server.userSpaceDispatcher === factory.values().first)
    #expect(server.compatibilityLiveIdentity == .appleGameController)
  }

}
