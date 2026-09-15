import Foundation
import Testing

@testable import OpenJoystickDriverKit

extension UserSpaceOutputDispatcherLifecycleTests {
  @Test
  func everyAcceptedButtonPreservesHoldReleaseAndLaterInput() async {
    let supported: [(Button, ExpectedButtonOutput)] = [
      (.a, .bit(0)), (.cross, .bit(0)), (.b, .bit(1)), (.circle, .bit(1)), (.x, .bit(2)),
      (.square, .bit(2)), (.y, .bit(3)), (.triangle, .bit(3)), (.leftBumper, .bit(4)),
      (.l1, .bit(4)), (.rightBumper, .bit(5)), (.r1, .bit(5)), (.leftStick, .bit(6)),
      (.rightStick, .bit(7)), (.rightPadClick, .bit(7)), (.start, .bit(8)), (.options, .bit(8)),
      (.back, .bit(9)), (.guide, .bit(10)), (.ps, .bit(10)), (.dpadUp, .bit(11)),
      (.dpadDown, .bit(12)), (.dpadLeft, .bit(13)), (.dpadRight, .bit(14)), (.share, .bit(15)),
      (.l2Digital, .leftTrigger), (.r2Digital, .rightTrigger), (.touchpad, .touchpad),
      (.mute, .mute),
    ]
    let unsupported: [Button] = [
      .leftGrip, .rightGrip, .leftPadClick, .leftSL, .leftSR, .rightSL, .rightSR, .leftFunction,
      .rightFunction, .leftPaddle, .rightPaddle,
    ]
    #expect(
      Set((supported.map(\.0) + unsupported).map(\.rawValue))
        == Set(Button.allCases.map(\.rawValue))
    )

    for (button, output) in supported {
      let backend = UserSpaceDispatcherTestBackend()
      let format = ContinuitySnapshotReportFormat()
      let dispatcher = UserSpaceOutputDispatcher(
        testBackendFactory: { _ in backend },
        format: format
      )
      let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
      var expected = VirtualGamepadState()

      await dispatcher.dispatch(events: [.buttonPressed(button)], from: identifier)
      set(output, pressed: true, in: &expected)
      #expect(backend.publishedReports().last == format.buildInputReport(from: expected))

      await dispatcher.dispatch(events: [.leftStickChanged(x: 0.5, y: -0.25)], from: identifier)
      expected.leftStickX = Int16(0.5 * 32_767)
      expected.leftStickY = Int16(-0.25 * 32_767)
      #expect(backend.publishedReports().last == format.buildInputReport(from: expected))

      await dispatcher.dispatch(events: [.buttonReleased(button)], from: identifier)
      set(output, pressed: false, in: &expected)
      #expect(backend.publishedReports().last == format.buildInputReport(from: expected))

      await dispatcher.dispatch(events: [.rightTriggerChanged(0.75)], from: identifier)
      expected.rightTrigger = Int16(0.75 * 32_767)
      #expect(backend.publishedReports().last == format.buildInputReport(from: expected))
      await dispatcher.close()
    }

    let backend = UserSpaceDispatcherTestBackend()
    let format = ContinuitySnapshotReportFormat()
    let dispatcher = UserSpaceOutputDispatcher(testBackendFactory: { _ in backend }, format: format)
    let identifier = DeviceIdentifier(vendorID: 3, productID: 4)
    let neutral = format.buildInputReport(from: VirtualGamepadState())
    for button in unsupported {
      await dispatcher.dispatch(events: [.buttonPressed(button)], from: identifier)
      #expect(backend.publishedReports().last == neutral, "\(button) must remain unsupported")
    }
    await dispatcher.close()
  }

  @Test
  func dpadSticksAndTriggersPreserveTransitionsAcrossUnrelatedInput() async {
    let dpadCases: [(DpadDirection, GamepadHIDDescriptor.Hat)] = [
      (.north, .north), (.northEast, .northEast), (.east, .east), (.southEast, .southEast),
      (.south, .south), (.southWest, .southWest), (.west, .west), (.northWest, .northWest),
    ]
    for (direction, hat) in dpadCases {
      var expected = VirtualGamepadState()
      await verifyContinuity(
        pressed: .dpadChanged(direction),
        heldWith: .leftStickChanged(x: 0.5, y: -0.25),
        released: .dpadChanged(.neutral),
        later: .rightTriggerChanged(0.75)
      ) { stage in
        switch stage {
        case 0:
          expected.hat = hat
          expected.buttons = GamepadHIDDescriptor.dpadButtonBits(for: hat)
        case 1:
          expected.leftStickX = Int16(0.5 * 32_767)
          expected.leftStickY = Int16(-0.25 * 32_767)
        case 2:
          expected.hat = .neutral
          expected.buttons = 0
        default: expected.rightTrigger = Int16(0.75 * 32_767)
        }
        return expected
      }
    }

    let analogCases:
      [(ControllerEvent, ControllerEvent, (inout VirtualGamepadState, Bool) -> Void)] = [
        (
          .leftStickChanged(x: 0.75, y: -0.5), .leftStickChanged(x: 0, y: 0),
          { state, pressed in
            state.leftStickX = pressed ? Int16(0.75 * 32_767) : 0
            state.leftStickY = pressed ? Int16(-0.5 * 32_767) : 0
          }
        ),
        (
          .rightStickChanged(x: -0.5, y: 0.75), .rightStickChanged(x: 0, y: 0),
          { state, pressed in
            state.rightStickX = pressed ? Int16(-0.5 * 32_767) : 0
            state.rightStickY = pressed ? Int16(0.75 * 32_767) : 0
          }
        ),
        (
          .leftTriggerChanged(0.75), .leftTriggerChanged(0),
          { state, pressed in state.leftTrigger = pressed ? Int16(0.75 * 32_767) : 0 }
        ),
        (
          .rightTriggerChanged(0.75), .rightTriggerChanged(0),
          { state, pressed in state.rightTrigger = pressed ? Int16(0.75 * 32_767) : 0 }
        ),
      ]
    for (pressed, released, update) in analogCases {
      var expected = VirtualGamepadState()
      await verifyContinuity(
        pressed: pressed,
        heldWith: .buttonPressed(.x),
        released: released,
        later: .buttonPressed(.a)
      ) { stage in
        switch stage {
        case 0: update(&expected, true)
        case 1: expected.buttons |= 1 << 2
        case 2: update(&expected, false)
        default: expected.buttons |= 1
        }
        return expected
      }
    }
  }

  @Test
  func compatibilitySuppressionPublishesDeviceWithoutForwardingInput() async {
    let backend = UserSpaceDispatcherTestBackend()
    let creations = LockedCounter()
    let dispatcher = UserSpaceOutputDispatcher { _ in
      _ = creations.next()
      return backend
    }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    await dispatcher.setOutputSuppressed(true)

    await dispatcher.dispatch(events: [.buttonPressed(.a)], from: identifier)

    #expect(creations.current() == 1)
    #expect(backend.publishedReports().isEmpty)
    #expect(backend.counts().close == 0)
    await dispatcher.close()
  }

  @Test
  func compatibilitySuppressionNeutralizesWithoutRetiringDevice() async throws {
    let backend = UserSpaceDispatcherTestBackend()
    let dispatcher = UserSpaceOutputDispatcher { _ in backend }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    await dispatcher.dispatch(events: [.buttonPressed(.a)], from: identifier)

    await dispatcher.setOutputSuppressed(true)

    #expect(
      backend.publishedReports().last
        == OJDGenericGamepadFormat().buildInputReport(from: VirtualGamepadState())
    )
    #expect(backend.counts().close == 0)

    await dispatcher.setOutputSuppressed(false)
    await dispatcher.dispatch(events: [.buttonPressed(.b)], from: identifier)
    var expected = VirtualGamepadState()
    expected.buttons = 1 << GamepadHIDDescriptor.ButtonBit.b.rawValue
    #expect(
      backend.publishedReports().last == OJDGenericGamepadFormat().buildInputReport(from: expected)
    )
    #expect(backend.counts().close == 0)
    await dispatcher.close()
  }

  @Test
  func neutralRetryAfterRetirementDoesNotCreateAnotherDevice() async throws {
    let creations = LockedCounter()
    let dispatcher = UserSpaceOutputDispatcher { _ in
      _ = creations.next()
      return UserSpaceDispatcherTestBackend()
    }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    try await dispatcher.send(.neutral, for: identifier)
    #expect(creations.current() == 0)
    try await dispatcher.send(RemappingGamepadState(buttons: [.south]), for: identifier)
    await dispatcher.controllerDidStop(identifier)
    try await dispatcher.send(.neutral, for: identifier)
    #expect(creations.current() == 1)
    await dispatcher.close()
  }

  @Test
  func remappedReportsAndKeepaliveUseTheirOwnSuppressionGate() async throws {
    let backend = UserSpaceDispatcherTestBackend()
    let dispatcher = UserSpaceOutputDispatcher { _ in backend }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    await dispatcher.setOutputSuppressed(true)
    await dispatcher.dispatch(events: [.buttonPressed(.a)], from: identifier)
    #expect(backend.publishedReports().isEmpty)
    try await dispatcher.send(RemappingGamepadState(buttons: [.north]), for: identifier)
    let pressed = try #require(backend.publishedReports().last)
    let initialCount = backend.counts().send
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    while backend.counts().send == initialCount, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(8))
    }
    #expect(backend.counts().send > initialCount)
    #expect(backend.publishedReports().last == pressed)
    await dispatcher.setRemappingOutputSuppressed(true)
    await #expect(throws: CancellationError.self) {
      try await dispatcher.send(RemappingGamepadState(buttons: [.south]), for: identifier)
    }
    try await dispatcher.send(.neutral, for: identifier)
    #expect(
      backend.publishedReports().last
        == OJDGenericGamepadFormat().buildInputReport(from: VirtualGamepadState())
    )
    await dispatcher.close()
  }

  @Test
  func remappedStatePreservesSmallAxesAndDistinctShareThenReplacesHeldState() async throws {
    let backend = UserSpaceDispatcherTestBackend()
    let dispatcher = UserSpaceOutputDispatcher { _ in backend }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)
    try await dispatcher.send(
      RemappingGamepadState(buttons: [.share], axes: [.leftStickX: 0.01]),
      for: identifier
    )
    var expected = VirtualGamepadState()
    expected.buttons = 1 << 15
    expected.leftStickX = Int16(Float(0.01) * 32_767)
    #expect(
      backend.publishedReports().last == OJDGenericGamepadFormat().buildInputReport(from: expected)
    )
    try await dispatcher.send(RemappingGamepadState(buttons: [.back]), for: identifier)
    expected = VirtualGamepadState()
    expected.buttons = 1 << 9
    #expect(
      backend.publishedReports().last == OJDGenericGamepadFormat().buildInputReport(from: expected)
    )
    await dispatcher.setOutputSuppressed(true)
    try await dispatcher.send(.neutral, for: identifier)
    #expect(
      backend.publishedReports().last
        == OJDGenericGamepadFormat().buildInputReport(from: VirtualGamepadState())
    )
    await dispatcher.close()
  }

  @Test
  func remappingReceivesNativeDeliveryFailure() async {
    let backend = UserSpaceDispatcherTestBackend(failsSend: true)
    let dispatcher = UserSpaceOutputDispatcher { _ in backend }
    await #expect(throws: UserSpaceDispatcherTestBackend.SendFailure.self) {
      try await dispatcher.send(
        RemappingGamepadState(buttons: [.south]),
        for: DeviceIdentifier(vendorID: 1, productID: 2)
      )
    }
    #expect(backend.counts().close == 1)
    await dispatcher.close()
  }

  @Test
  func activationCreatesAndNeutralizesEveryController() async throws {
    let created = LockedBackends()
    let dispatcher = UserSpaceOutputDispatcher { _ in
      let backend = UserSpaceDispatcherTestBackend()
      created.append(backend)
      return backend
    }
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
      DeviceIdentifier(vendorID: 5, productID: 6),
    ]

    try await dispatcher.activate(for: identifiers)

    #expect(created.snapshot().count == identifiers.count)
    #expect(created.snapshot().allSatisfy { $0.counts().send >= 1 })
    await dispatcher.close()
  }

  @Test
  func idleKeepalivePublishesRepeatInterruptReportsAndStateChanges() async throws {
    let backend = UserSpaceDispatcherTestBackend()
    let dispatcher = UserSpaceOutputDispatcher { _ in backend }
    let identifier = DeviceIdentifier(vendorID: 1, productID: 2)

    try await dispatcher.activate(for: [identifier])
    #expect(backend.counts().send >= 1)

    let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    while backend.counts().send < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(8))
    }
    let idleSends = backend.counts().send
    #expect(idleSends >= 2)

    let idle = try #require(backend.publishedReports().last)
    await dispatcher.dispatch(events: [.buttonPressed(.a)], from: identifier)
    #expect(backend.counts().send > idleSends)
    let pressed = try #require(backend.publishedReports().last)
    #expect(pressed != idle)

    await dispatcher.close()
    #expect(backend.counts().close == 1)
  }

  @Test


  func activationSendFailureClosesPartialDevicesForEveryFailurePosition() async {
    let identifiers = [
      DeviceIdentifier(vendorID: 1, productID: 2), DeviceIdentifier(vendorID: 3, productID: 4),
      DeviceIdentifier(vendorID: 5, productID: 6),
    ]
    for failureIndex in identifiers.indices {
      let created = LockedBackends()
      let attempt = LockedCounter()
      let dispatcher = UserSpaceOutputDispatcher { _ in
        let index = attempt.next()

        let backend = UserSpaceDispatcherTestBackend(failsSend: index == failureIndex)
        created.append(backend)
        return backend
      }

      do {
        try await dispatcher.activate(for: identifiers)
        Issue.record("Activation unexpectedly succeeded")
      } catch {}

      #expect(created.snapshot().count == failureIndex + 1)
      #expect(created.snapshot().allSatisfy { $0.counts().close == 1 })
    }
  }

}
