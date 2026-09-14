import Testing

@testable import OpenJoystickDriverKit

private enum CompatibilitySpecialControl: CaseIterable {
  case share
  case touchpad
  case mute
}

struct UserSpaceInputReportStateTests {
  @Test
  func currentInputReportTracksChangesForHostGetReportRequests() throws {
    let format = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor
    )
    let state = UserSpaceInputReportState(format: format)
    let neutral = state.currentReport()

    let active = state.update {
      $0.buttons = 1 << GamepadHIDDescriptor.ButtonBit.a.rawValue
      $0.leftStickX = 32_767
      $0.leftTrigger = 16_384
    }

    #expect(active != neutral)
    #expect(state.currentReport() == active)

    let released = state.update { $0 = VirtualGamepadState() }
    #expect(released == neutral)
    #expect(state.currentReport() == neutral)
  }

  @Test
  func seriesIdleReportMatchesInterruptGetReportLayout() throws {
    let format = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor,
      buttonUsageMap: XboxOneBluetoothHIDDescriptor.buttonUsageMap,
      digitalUsageMap: XboxOneBluetoothHIDDescriptor.seriesDigitalUsageMap
    )
    let report = UserSpaceInputReportState(format: format).currentReport()
    #expect(report.count == 17)
    #expect(report[0] == 1)
    #expect(Array(report[1...8]) == [0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80])
  }

  @Test
  func genericCompatibilityTriggersReturnToTheirExactPreActuationReport() {
    let format = OJDGenericGamepadFormat()
    let firstSession = UserSpaceInputReportState(format: format)
    let neutral = firstSession.currentReport()

    let actuated = firstSession.update {
      $0.leftTrigger = 32_767
      $0.rightTrigger = 32_767
    }
    let released = firstSession.update {
      $0.leftTrigger = 0
      $0.rightTrigger = 0
    }
    let recreatedSession = UserSpaceInputReportState(format: format)

    #expect(actuated != neutral)
    #expect(released == neutral)
    #expect(recreatedSession.currentReport() == neutral)
    #expect((neutral[0] & 0xC0) == 0)
  }

  @Test
  func appleCompatibilityTracksShareSeparatelyFromView() throws {
    let format = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor,
      buttonUsageMap: XboxOneBluetoothHIDDescriptor.buttonUsageMap,
      digitalUsageMap: XboxOneBluetoothHIDDescriptor.seriesDigitalUsageMap
    )
    let state = UserSpaceInputReportState(format: format)
    let neutral = state.currentReport()

    let share = state.update { $0.buttons = 1 << GamepadHIDDescriptor.ButtonBit.share.rawValue }
    let view = state.update { $0.buttons = 1 << GamepadHIDDescriptor.ButtonBit.back.rawValue }

    #expect(share[14] == 0)
    #expect(share[16] == 1)
    #expect(view[14] == 0x40)
    #expect(view[16] == 0)
    #expect(state.update { $0 = VirtualGamepadState() } == neutral)
  }

  @Test
  func everyCompatibilityFormatPreservesCompoundStateAcrossUpdatesAndRelease() throws {
    let identities: [CompatibilityIdentity] = [
      .automatic, .genericHID, .sdl2_3, .appleGameController, .xbox360HID, .dualShock4, .dualSense,
      .switchPro,
    ]
    for identity in identities {
      let format = try CompatibilityOutputCompositionFactory.make(identity: identity).format
      let reportState = UserSpaceInputReportState(format: format)
      let neutral = reportState.currentReport()
      var expected = compoundState()

      let active = reportState.update { $0 = expected }
      #expect(active == format.buildInputReport(from: expected), "\(identity)")
      #expect(active != neutral, "\(identity)")

      expected.rightStickX = 12_345
      let updated = reportState.update { $0.rightStickX = expected.rightStickX }
      #expect(updated == format.buildInputReport(from: expected), "\(identity)")

      let released = reportState.update { $0 = VirtualGamepadState() }
      #expect(released == neutral, "\(identity)")
    }
  }

  @Test
  func compatibilityFormatsExplicitlyClassifySpecialControlSupport() throws {
    let supported: [CompatibilityIdentity: Set<CompatibilitySpecialControl>] = [
      .automatic: [.share], .genericHID: [.share], .sdl2_3: [], .appleGameController: [.share],
      .xbox360HID: [], .dualShock4: [.share, .touchpad], .dualSense: [.share, .touchpad, .mute],
      .switchPro: [.share],
    ]
    #expect(Set(supported.keys) == Set(CompatibilityIdentity.allCases))

    for (identity, supportedControls) in supported {
      let format = try CompatibilityOutputCompositionFactory.make(identity: identity).format
      let neutral = format.buildInputReport(from: VirtualGamepadState())
      for control in CompatibilitySpecialControl.allCases {
        var state = VirtualGamepadState()
        switch control {
        case .share: state.buttons = 1 << GamepadHIDDescriptor.ButtonBit.share.rawValue
        case .touchpad: state.touchpadPressed = true
        case .mute: state.mutePressed = true
        }
        #expect(
          (format.buildInputReport(from: state) != neutral) == supportedControls.contains(control),
          "\(identity) \(control)"
        )
      }
    }
  }

  private func compoundState() -> VirtualGamepadState {
    VirtualGamepadState(
      buttons: UInt32.max,
      leftStickX: 24_000,
      leftStickY: -20_000,
      rightStickX: -16_000,
      rightStickY: 8_000,
      leftTrigger: 24_000,
      rightTrigger: 12_000,
      leftTriggerPressed: true,
      rightTriggerPressed: true,
      touchpadPressed: true,
      mutePressed: true,
      hat: .southWest
    )
  }
}
