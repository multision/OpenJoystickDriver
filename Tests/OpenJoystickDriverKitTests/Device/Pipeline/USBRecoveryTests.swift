import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct USBPipelineRecoveryTests {
  private let identifier = DeviceIdentifier(vendorID: 0x3537, productID: 0x1010, locationID: 7)
  private let device = USBTransportDevice(
    route: .ioUSBHost,
    serviceID: 1,
    vendorID: 0x3537,
    productID: 0x1010,
    locationID: 7
  )

  @Test
  func disconnectedReadClosesOnceAndReopensOneSession() async {
    let first = RecoveryUSBSession(readError: .disconnected)
    let second = RecoveryUSBSession(readError: .timeout)
    let provider = RecoveryUSBProvider(sessions: [first, second])
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .usb(device: device),
      parser: RecoveryInputParser(),
      dispatcher: RecoveryOutputDispatcher(),
      usbTransportProvider: provider,
      usbRecoveryPolicy: USBPipelineRecoveryPolicy(
        openRetryDelays: [1],
        reconnectBaseDelayNanoseconds: 1_000_000,
        reconnectMaximumDelayNanoseconds: 1_000_000,
        accessContentionDelayNanoseconds: 1_000_000
      )
    )

    let start = Task { await pipeline.start() }
    #expect(await waitUntil { await provider.openCount == 2 })
    #expect(await first.closeCount == 1)

    await pipeline.stop()
    await start.value
    #expect(await first.closeCount == 1)
    #expect(await second.closeCount == 1)
  }

  @Test
  func invalidatedSessionRejectsLateRumble() async {
    let session = RecoveryUSBSession(readError: .timeout)
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .usb(device: device),
      parser: RecoveryRumbleParser(),
      dispatcher: RecoveryOutputDispatcher()
    )
    await pipeline.setUSBHandleForTesting(session)

    await pipeline.invalidateUSBHandle(session)

    #expect(!(await pipeline.sendRumble(left: 1, right: 2, lt: 3, rt: 4)))
    #expect(await session.writeCount == 0)
    #expect(await session.closeCount == 1)
  }

  @Test
  func shutdownNeutralizesAllUSBMotorsWithOneCombinedReport() async {
    let session = RecoveryUSBSession(readError: .timeout)
    let parser = RecoveryRumbleParser()
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .usb(device: device),
      parser: parser,
      dispatcher: RecoveryOutputDispatcher()
    )
    await pipeline.setUSBHandleForTesting(session)
    let manager = DeviceManager(dispatcher: RecoveryOutputDispatcher())

    await manager.neutralizePhysicalOutputs(for: identifier, pipeline: pipeline)

    #expect(await session.writes == [[0, 0, 0, 0]])
  }

  @Test
  func physicalRemovalDiscardsOwnershipWithoutWritingToAbsentDevice() async {
    let session = RecoveryUSBSession(readError: .timeout)
    let pipeline = DevicePipeline(
      identifier: identifier,
      transport: .usb(device: device),
      parser: RecoveryRumbleParser(),
      dispatcher: RecoveryOutputDispatcher()
    )
    await pipeline.setUSBHandleForTesting(session)
    let manager = DeviceManager(dispatcher: RecoveryOutputDispatcher())
    let owner = UUID()
    _ = await manager.setPhysicalOutputForTesting(
      .rumble(motor: .leftMain, intensity: 1),
      owner: owner,
      identifier: identifier
    )

    await manager.discardPhysicalOutputs(for: identifier)

    #expect(await session.writeCount == 0)
    #expect(await manager.mappingClaimCountForTesting == 0)
  }

  private func waitUntil(condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
  }
}

private class RecoveryInputParser: InputParser {
  func parse(data: Data) throws -> [ControllerEvent] { [] }
}

private final class RecoveryRumbleParser: RecoveryInputParser, PhysicalRumbleOutput {
  var physicalRumbleMotors: [PhysicalRumbleMotor] {
    [.leftMain, .rightMain, .leftTrigger, .rightTrigger]
  }

  func physicalRumblePacket(
    left: UInt8,
    right: UInt8,
    lt: UInt8,
    rt: UInt8
  ) -> PhysicalUSBOutputPacket {
    PhysicalUSBOutputPacket(endpoint: 2, bytes: [left, right, lt, rt], timeoutMilliseconds: 2_000)
  }
}

private actor RecoveryUSBProvider: USBTransportProvider {
  private var sessions: [RecoveryUSBSession]
  private(set) var openCount = 0

  init(sessions: [RecoveryUSBSession]) { self.sessions = sessions }
  func devices() -> [USBTransportDevice] { [] }

  func open(
    _ device: USBTransportDevice,
    options: USBTransportOpenOptions
  ) -> any USBTransportSession {
    openCount += 1
    return sessions.removeFirst()
  }
}

private actor RecoveryUSBSession: USBTransportSession {
  let readError: USBTransportError
  private(set) var closeCount = 0
  private(set) var writes: [[UInt8]] = []
  var writeCount: Int { writes.count }
  var inputOwnership: HIDInputOwnership { closeCount == 0 ? .exclusive : .unknown }

  init(readError: USBTransportError) { self.readError = readError }

  func writeInterruptPacket(endpoint: UInt8, data: [UInt8], timeout: UInt32) throws -> Int {
    guard closeCount == 0 else { throw USBTransportError.disconnected }
    writes.append(data)
    return data.count
  }

  func readInterruptPacket(endpoint: UInt8, length: Int, timeout: UInt32) throws -> [UInt8] {
    throw readError
  }

  func close() {
    guard closeCount == 0 else { return }
    closeCount = 1
  }
}

private final class RecoveryOutputDispatcher: OutputDispatcher, ControllerInputOwnershipListener,
  @unchecked Sendable
{
  var suppressOutput = false
  func dispatch(events: [ControllerEvent], from identifier: DeviceIdentifier) {}
  func controllerInputOwnershipChanged(
    _ ownership: HIDInputOwnership,
    for identifier: DeviceIdentifier
  ) {}
}

extension DevicePipeline {
  func setUSBHandleForTesting(_ handle: any USBTransportSession) { usbHandle = handle }
}

extension DeviceManager {
  func setPhysicalOutputForTesting(
    _ output: RemappingPhysicalOutput,
    owner: UUID,
    identifier: DeviceIdentifier
  ) -> PhysicalOutputChannel {
    physicalOutputOwnership.setMapping(output, active: true, owner: owner, for: identifier)
  }

  var mappingClaimCountForTesting: Int { physicalOutputOwnership.mappingClaimCount }
}
