import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct ReceiptTimeTests {
  @Test
  func hidAndUSBParsingDeliverReceiptTimeToTheProtocolHook() async throws {
    let (calls, continuation) = AsyncStream<ReceiptTimeParser.Call>.makeStream()
    var iterator = calls.makeAsyncIterator()
    let parser = ReceiptTimeParser(continuation: continuation)
    let pipeline = DevicePipeline(
      identifier: DeviceIdentifier(vendorID: 1, productID: 2),
      transport: .hid(locationID: 77),
      parser: parser,
      dispatcher: LoggingOutputDispatcher()
    )
    await pipeline.start()
    let before = DispatchTime.now().uptimeNanoseconds
    await pipeline.feedHIDData(Data([1]))
    let after = DispatchTime.now().uptimeNanoseconds
    guard case .timed(let observed) = await iterator.next() else {
      Issue.record("Expected a timestamped HID parse")
      return
    }
    #expect((before...after).contains(observed))
    _ = try await pipeline.parseEvents(from: [2], receivedAtNanoseconds: 123)
    #expect(await iterator.next() == .timed(123))
    await pipeline.stop()
  }
}

private final class ReceiptTimeParser: InputParser {
  enum Call: Equatable, Sendable { case timed(UInt64), untimed }

  private let continuation: AsyncStream<Call>.Continuation

  init(continuation: AsyncStream<Call>.Continuation) { self.continuation = continuation }

  func parse(data: Data) throws -> [ControllerEvent] {
    continuation.yield(.untimed)
    return []
  }
  func parse(data: Data, receivedAtNanoseconds: UInt64) throws -> [ControllerEvent] {
    continuation.yield(.timed(receivedAtNanoseconds))
    return []
  }
}
