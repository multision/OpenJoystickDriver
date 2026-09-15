import Foundation
import Testing

@testable import OpenJoystickDriverKit

extension DS4ParserTests {
  @Test
  func testObservedDS4RightStickYShortfallRemainsVisible() throws {
    let parser = DS4Parser()
    _ = try parser.parse(data: makeDS4Report())

    let events = try parser.parse(data: makeDS4Report(rightStickY: 8))
    let expectedRightStick = ControllerEvent.rightStickChanged(x: 0, y: -120.0 / 128.0)

    #expect(containsEvent(events, expectedRightStick))
  }
  @Test


  func testDeviceInputStateExposesDS4DpadAsHeldButtons() async throws {
    let dispatcher = CapturingOutputDispatcher()
    let pipeline = DevicePipeline(
      identifier: DeviceIdentifier(vendorID: 1356, productID: 2508),
      transport: .hid(locationID: 1),
      parser: DS4Parser(),
      dispatcher: dispatcher
    )
    await pipeline.start()
    await pipeline.feedHIDData(makeDS4Report())

    await pipeline.feedHIDData(makeDS4Report(buttons0: 0x00))
    #expect(await pipeline.inputState().pressedButtons == [Button.dpadUp.rawValue])

    await pipeline.feedHIDData(makeDS4Report(buttons0: 0x03))
    #expect(
      Set(await pipeline.inputState().pressedButtons)
        == Set([Button.dpadRight.rawValue, Button.dpadDown.rawValue])
    )

    await pipeline.feedHIDData(makeDS4Report())
    #expect(await pipeline.inputState().pressedButtons.isEmpty)
  }
  @Test
  func testPipelineSnapshotsBatteryWithoutDispatchingItAsInput() async throws {
    let dispatcher = CapturingOutputDispatcher()
    let pipeline = DevicePipeline(
      identifier: DeviceIdentifier(vendorID: 1356, productID: 2508),
      transport: .hid(locationID: 1),
      parser: DS4Parser(),
      dispatcher: dispatcher
    )
    await pipeline.start()

    await pipeline.feedHIDData(makeDS4Report(status: 0x1B))

    #expect(
      await pipeline.batteryTelemetry()
        == ControllerBatteryTelemetry(percentage: 100, chargingState: .full, cableState: .connected)
    )
    #expect(dispatcher.events.count == 1)
  }
  @Test
  func testRegistryMapsDS4V2IdentityToDS4Parser() {
    let registry = ParserRegistry()
    let identifier = DeviceIdentifier(vendorID: 1356, productID: 2508)
    let profile = registry.runtimeProfile(for: identifier)

    #expect(registry.parserName(for: identifier) == "DS4")
    #expect(profile.protocolVariant == .dualShock4)
  }
}
