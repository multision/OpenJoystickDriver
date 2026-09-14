import Foundation
import Testing

@testable import OpenJoystickDriverKit

private final class ControllerSessionOutputProbe: OutputDispatcher, ControllerLifecycleListener,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedSuppression = false
  private var batches: [[ControllerEvent]] = []
  private var stopped: [DeviceIdentifier] = []

  var suppressOutput: Bool {
    get { lock.withLock { storedSuppression } }
    set { lock.withLock { storedSuppression = newValue } }
  }

  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {
    lock.withLock { batches.append(events) }
  }

  func controllerDidStop(_ identifier: DeviceIdentifier) {
    lock.withLock { stopped.append(identifier) }
  }

  func snapshot() -> (batches: [[ControllerEvent]], stopped: [DeviceIdentifier]) {
    lock.withLock { (batches, stopped) }
  }
}

struct ControllerSessionTests {
  @Test
  func suspensionNeutralizesHeldInputAndIgnoresReportsUntilResume() async {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 1),
      parser: DS4Parser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x28))

    #expect(await pipeline.suspendControllerSession())
    #expect(await pipeline.controllerSessionState() == .suspended)
    #expect(await pipeline.inputState().isEffectivelyNeutral)
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x48))
    #expect(await pipeline.inputState().isEffectivelyNeutral)

    let suspended = output.snapshot()
    #expect(suspended.stopped == [identifier])
    #expect(suspended.batches.flatMap { $0 }.contains(.buttonReleased(.cross)))

    #expect(await pipeline.resumeControllerSession())
    #expect(await pipeline.controllerSessionState() == .active)
    await pipeline.stop()
  }

  @Test
  func ds4LivenessLossNeutralizesAndRequiresFreshNeutralReport() async throws {
    let identifier = DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    let output = ControllerSessionOutputProbe()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .hid(locationID: 2),
      parser: DS4Parser(),
      dispatcher: output
    )
    await pipeline.start()
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x28))
    try await Task.sleep(nanoseconds: 1_050_000_000)
    await pipeline.feedHIDData(ds4USBReport(buttons: 0x48))
    #expect(output.snapshot().batches.flatMap { $0 }.contains(.buttonReleased(.cross)))

    await pipeline.feedHIDData(ds4USBReport(buttons: 0x08))
    #expect(await pipeline.inputState().isEffectivelyNeutral)
    await pipeline.stop()
  }

  private func ds4USBReport(buttons: UInt8) -> Data {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 1
    report[1] = 128
    report[2] = 128
    report[3] = 128
    report[4] = 128
    report[5] = buttons
    return Data(report)
  }
}
