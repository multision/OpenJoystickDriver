import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension CompatibilityTransitionTests {
  @Test
  func noncooperativeCandidateCloseCannotOverrunRollbackBudget() async {
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
    let closeGate = CompatibilityTransitionGate()
    let factory = CompatibilityTransitionFactory()
    factory.activationFailures = [.appleGameController]
    factory.closeGates[.appleGameController] = closeGate
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)],
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

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 1)
    #expect(factory.values().count == 1)
    #expect(server.userSpaceDispatcher == nil)
    await closeGate.open()
    while factory.values().first?.closeCountValue == 0 { await Task.yield() }
    #expect(factory.values().first?.closeCountValue == 1)
  }

  @Test
  func rapidIdentityRequestsSerializeAndCommitLastRequest() async {
    let defaults = UserDefaults.standard
    let key = ApplicationServiceServer.compatibilityIdentityDefaultsKey
    let prior = defaults.object(forKey: key)
    defaults.set(CompatibilityIdentity.genericHID.rawValue, forKey: key)
    defer {
      if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    let gate = CompatibilityTransitionGate()
    let factory = CompatibilityTransitionFactory()
    factory.firstActivationGate = gate
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )

    let first = Task { await requestIdentity(server, .appleGameController) }
    await factory.waitForCount(1)
    let second = Task { await requestIdentity(server, .sdl2_3) }
    while await server.compatibilityTransitionCoordinator.submissionCount() < 2 {
      await Task.yield()
    }
    let third = Task { await requestIdentity(server, .xbox360HID) }
    await gate.open()

    #expect(await first.value)
    #expect(await second.value)
    #expect(await third.value)
    #expect(server.compatibilityIdentity == .xbox360HID)
    #expect(server.userSpaceEnabled)
    #expect(old.closeCountValue == 1)
    #expect(factory.values().count == 3)
    #expect(factory.values().dropLast().allSatisfy { $0.closeCountValue == 1 })
    #expect(factory.values().last?.closeCountValue == 0)
  }

  @Test
  func zeroActivationDeadlineFailsDeterministicallyBeforeCommit() async {
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
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)],
      timeouts: CompatibilityTransitionTimeouts(
        stageNanoseconds: 2_000_000_000,
        perControllerNanoseconds: 0,
        totalNanoseconds: 0
      )
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 1)
    #expect(factory.values().allSatisfy { $0.closeCountValue == 1 })
    #expect(factory.values().allSatisfy { $0.activationValues.isEmpty })
    #expect(server.userSpaceDispatcher == nil)
    #expect(server.userSpaceEnabled == false)
  }

  @Test
  func currentIdentityIsARealNoOp() async {
    let factory = CompatibilityTransitionFactory()
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [DeviceIdentifier(vendorID: 1, productID: 2)]
    )

    #expect(await requestIdentity(server, .genericHID))
    #expect(factory.values().isEmpty)
    #expect(old.closeCountValue == 0)
    #expect(server.userSpaceDispatcher === old)
  }

  @Test


  func hangingActivationTimesOutAndCannotReplaceSuccessfulRollbackLate() async {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let gate = CompatibilityTransitionGate()
    let factory = CompatibilityTransitionFactory()
    factory.firstActivationGate = gate
    let (server, old) = transitionServer(
      factory: factory,
      identifiers: [identifier],

      timeouts: CompatibilityTransitionTimeouts(
        stageNanoseconds: 100_000_000,
        perControllerNanoseconds: 5_000_000,
        totalNanoseconds: 5_000_000,
        zeroControllerActivationNanoseconds: 5_000_000,
        feedbackNanoseconds: 100_000_000,
        candidateCloseNanoseconds: 100_000_000,
        rollbackStageNanoseconds: 100_000_000,
        rollbackActivationTotalNanoseconds: 100_000_000,
        zeroDeviceNanoseconds: 200_000_000
      )
    )

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 1)
    let rollback = factory.values().last
    #expect(factory.values().count == 2)
    #expect(server.userSpaceDispatcher === rollback)
    #expect(server.userSpaceEnabled)
    #expect(server.compatibilityTransitionSnapshot().liveIdentity == .genericHID)

    await gate.open()
    await Task.yield()
    #expect(server.userSpaceDispatcher === rollback)
    #expect(factory.values().first?.closeCountValue == 1)
  }

  @Test
  func startupActivationUsesTransactionAndNeutralActivation() async {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let factory = CompatibilityTransitionFactory()
    let (server, old) = transitionServer(factory: factory, identifiers: [identifier])

    #expect(await server.activateCompatibilityBackendForCurrentDevices())
    let candidate = factory.values().first
    #expect(candidate?.activationValues == [[identifier]])
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceDispatcher === candidate)
    #expect(server.userSpaceEnabled)
  }

  @Test
  func removalDuringBreakBeforeMakeCannotCommitGhostIdentifiers() async {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let snapshots = IdentifierSnapshotBox([[identifier], []])
    let factory = CompatibilityTransitionFactory()
    let (server, old) = transitionServer(factory: factory, identifiers: [identifier]) {
      snapshots.next()
    }

    #expect(await requestIdentity(server, .appleGameController) == false)
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceEnabled)
    #expect(server.compatibilityIdentity == .genericHID)
    #expect(factory.values().count == 2)
    #expect(factory.values().allSatisfy { $0.closeCountValue <= 1 })
  }

  @Test
  func shutdownCancelsTransitionAndPreventsPostShutdownCommit() async {
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    let gate = CompatibilityTransitionGate()
    let factory = CompatibilityTransitionFactory()
    factory.firstActivationGate = gate
    let (server, old) = transitionServer(factory: factory, identifiers: [identifier])
    let request = Task { await requestIdentity(server, .appleGameController) }
    await factory.waitForCount(1)

    let stop = Task { await server.stop() }
    while !server.isCompatibilityServerStopped() { await Task.yield() }
    await gate.open()
    await stop.value
    #expect(await request.value == false)
    #expect(old.closeCountValue == 1)
    #expect(server.userSpaceDispatcher == nil)
    #expect(server.userSpaceEnabled == false)
    #expect(server.userSpaceStatus == "off")
    #expect(server.compatibilityLiveIdentity == nil)
  }
}
