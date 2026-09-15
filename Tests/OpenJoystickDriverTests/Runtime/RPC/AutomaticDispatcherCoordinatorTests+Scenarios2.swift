import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension AutomaticDispatcherCoordinatorTests {
  @Test(.timeLimit(.minutes(1)))
  func consumerRevisionsReplaceGenericWithGeckoAndWebKitAndRejectStaleActivation() async throws {
    let coordinator = AutomaticDispatcherCoordinator()
    let generic = InstallationBackend(stage: .none, gate: InstallationGate())
    let gecko = InstallationBackend(stage: .none, gate: InstallationGate())
    let webkit = InstallationBackend(stage: .none, gate: InstallationGate())
    let geckoTarget = AutomaticCompatibilityTarget(
      identity: .appleGameController,
      reportVariant: .geckoXboxOneS
    )
    let factory: AutomaticDispatcherCoordinator.Factory = { target in
      if target == .genericHID { return generic }
      return target == geckoTarget ? gecko : webkit
    }
    let initial = await coordinator.leaseForDispatch(
      controller: identifier,
      consumer: .unknown,
      identity: .genericHID,
      isEligible: { _, _ in true },
      factory: factory
    )
    try #require(initial != nil)
    await initial?.release()

    await coordinator.replaceForConsumer(
      .geckoGamepad,
      revision: 1,
      descriptions: [description],
      isEligible: { _, _ in true },
      identityProvider: { _, _ in geckoTarget },
      factory: factory
    )
    #expect(generic.counts().closes == 1)
    let installedGecko = await coordinator.installedTargets()
    #expect(installedGecko[identifier] == geckoTarget)

    await coordinator.replaceForConsumer(
      .webkitGamepad,
      revision: 2,
      descriptions: [description],
      isEligible: { _, _ in true },
      identityProvider: { _, _ in .appleGameController },
      factory: factory
    )
    #expect(gecko.counts().closes == 1)
    let installedWebKit = await coordinator.installedTargets()
    #expect(installedWebKit[identifier] == .appleGameController)

    await coordinator.replaceForConsumer(
      .geckoGamepad,
      revision: 1,
      descriptions: [description],
      isEligible: { _, _ in true },
      identityProvider: { _, _ in geckoTarget },
      factory: factory
    )
    let installedAfterStaleActivation = await coordinator.installedTargets()
    #expect(installedAfterStaleActivation[identifier] == .appleGameController)
    #expect(webkit.counts() == (1, 0))
    await coordinator.close()
    #expect(webkit.counts().closes == 1)
  }
}
