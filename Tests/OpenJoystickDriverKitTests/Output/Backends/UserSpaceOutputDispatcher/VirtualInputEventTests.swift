import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct VirtualInputEventTests {
  private func apply(_ events: [ControllerEvent], to state: inout VirtualGamepadState) {
    let dispatcher = UserSpaceOutputDispatcher { _ in
      throw UserSpaceOutputDispatcher.CreationError.createFailed
    }
    for event in events {
      dispatcher.applyEvent(
        event,
        stickTransfer: .init(deadzone: 0, rescalesDeadzone: false),
        state: &state
      )
    }
  }

  @Test(arguments: [false, true])
  func ds4USBAndBluetoothFixturesReachVirtualReports(bluetooth: Bool) throws {
    let parser = DS4Parser(prefersBluetooth: bluetooth)
    var packet = [UInt8](repeating: 0, count: bluetooth ? 78 : 64)
    let base = bluetooth ? 3 : 1
    packet[0] = bluetooth ? 0x11 : 0x01
    if bluetooth {
      packet[1] = 0xC0
      packet[2] = 0
    }
    packet[base] = 255
    packet[base + 1] = 0
    packet[base + 2] = 0
    packet[base + 3] = 255
    packet[base + 4] = 0x28
    packet[base + 5] = 0x01
    packet[base + 6] = 0x01
    packet[base + 7] = 255
    packet[base + 8] = 128
    packet[base + 12] = 1
    packet[base + 18] = 2
    packet[base + 29] = bluetooth ? 0x19 : 0x09

    let events = try parser.parse(data: Data(packet))
    var state = VirtualGamepadState()
    apply(events, to: &state)
    let virtualReport = DualShock4USBHIDReportFormat().buildInputReport(from: state)

    #expect(events.contains(.buttonPressed(.cross)))
    #expect(events.contains(.buttonPressed(.l1)))
    #expect(events.contains(.buttonPressed(.ps)))
    #expect(
      events.contains {
        if case .motionSample = $0 { return true }
        return false
      }
    )
    #expect(state.leftStickX > 32_000)
    #expect(state.leftStickY == -Int16.max)
    #expect(state.rightStickX == -Int16.max)
    #expect(state.rightStickY > 32_000)
    #expect(virtualReport[5] & 0xF0 == 0x20)
    #expect(virtualReport[6] & 0x01 == 0x01)
    #expect(virtualReport[7] & 0x01 == 0x01)
    #expect(virtualReport[8] == 255)
    #expect(virtualReport[9] == 127)
    #expect(
      parser.batteryTelemetry
        == ControllerBatteryTelemetry(
          percentage: 95,
          percentageRange: 90...99,
          chargingState: bluetooth ? .charging : .discharging,
          cableState: bluetooth ? .connected : .disconnected
        )
    )
  }

  @Test
  func nintendoDigitalTriggersSurviveParserAndVirtualOutput() throws {
    let parser = SwitchProParser()
    var packet: [UInt8] = [0x30, 0, 0x91, 0, 0, 0, 0, 8, 128, 0, 8, 128]
    var state = VirtualGamepadState()
    apply(try parser.parse(data: Data(packet)), to: &state)
    packet[3] = 0x80
    packet[5] = 0x80
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(state.leftTriggerPressed)
    #expect(state.rightTriggerPressed)
    let nintendo = SwitchProUSBHIDReportFormat().buildInputReport(from: state)
    #expect(nintendo[3] & 0x80 == 0x80)
    #expect(nintendo[5] & 0x80 == 0x80)
    let sony = DualSenseUSBHIDReportFormat().buildInputReport(from: state)
    #expect(sony[5] == 255)
    #expect(sony[6] == 255)
    let xbox = Xbox360MacHIDReportFormat().buildInputReport(from: state)
    #expect(xbox[4] == 255)
    #expect(xbox[5] == 255)
    packet[3] = 0
    packet[5] = 0
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(state.leftTriggerPressed == false)
    #expect(state.rightTriggerPressed == false)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[5...6] == [0, 0])
    #expect(Xbox360MacHIDReportFormat().buildInputReport(from: state)[4...5] == [0, 0])
  }

  @Test
  func sonyTouchpadAndMuteSurviveParserPressAndRelease() throws {
    let parser = DualSenseParser()
    var packet = [UInt8](repeating: 0, count: 64)
    packet[0] = 1
    for index in 1...4 { packet[index] = 128 }
    packet[8] = 8
    var state = VirtualGamepadState()
    apply(try parser.parse(data: Data(packet)), to: &state)
    packet[10] = 0x06
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(state.touchpadPressed)
    #expect(state.mutePressed)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[10] == 0x06)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[33] == 0x80)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[37] == 0x80)
    #expect(DualShock4USBHIDReportFormat().buildInputReport(from: state)[7] == 0x02)
    #expect(DualShock4USBHIDReportFormat().buildInputReport(from: state)[35] == 0x80)
    #expect(DualShock4USBHIDReportFormat().buildInputReport(from: state)[39] == 0x80)
    packet[10] = 0
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(state.touchpadPressed == false)
    #expect(state.mutePressed == false)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[10] == 0)
    #expect(DualShock4USBHIDReportFormat().buildInputReport(from: state)[7] == 0)
  }

  @Test
  func digitalTriggerTransitionsDoNotReplaceAnalogPressure() {
    var state = VirtualGamepadState()
    apply([.leftTriggerChanged(0.5), .buttonPressed(.l2Digital)], to: &state)
    #expect(state.leftTrigger == 16_383)
    #expect(state.effectiveLeftTrigger == 16_383)
    apply([.buttonReleased(.l2Digital)], to: &state)
    #expect(state.effectiveLeftTrigger == 16_383)
    apply([.leftTriggerChanged(0)], to: &state)
    #expect(state.effectiveLeftTrigger == 0)
  }

  @Test
  func xidSoutheastSurvivesParserToReport() throws {
    var packet = [UInt8](repeating: 0, count: 20)
    packet[1] = 20
    packet[2] = 10
    var state = VirtualGamepadState()
    let parser = XIDParser()
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[8] & 0x0F == 3)
    packet[2] = 0
    apply(try parser.parse(data: Data(packet)), to: &state)
    #expect(DualSenseUSBHIDReportFormat().buildInputReport(from: state)[8] & 0x0F == 8)
  }
}
