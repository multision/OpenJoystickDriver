import Testing

@testable import OpenJoystickDriverKit

private actor PhysicalHIDOutputOrderRecorder {
  private var values: [Int] = []
  private var firstValueWaiters: [CheckedContinuation<Void, Never>] = []

  func append(_ value: Int) {
    values.append(value)
    if value == 1 {
      for waiter in firstValueWaiters { waiter.resume() }
      firstValueWaiters.removeAll()
    }
  }

  func waitForFirstValue() async {
    if values.contains(1) { return }
    await withCheckedContinuation { firstValueWaiters.append($0) }
  }

  func snapshot() -> [Int] { values }
}

struct PhysicalHIDOutputSerialQueueTests {
  @Test
  func commandsCompleteInSubmissionOrderWithoutInterleaving() async {
    let queue = PhysicalHIDOutputSerialQueue()
    let recorder = PhysicalHIDOutputOrderRecorder()

    let first = Task {
      await queue.perform {
        await recorder.append(1)
        await Task.yield()
        await recorder.append(2)
        return true
      }
    }
    await recorder.waitForFirstValue()
    let second = Task {
      await queue.perform {
        await recorder.append(3)
        return true
      }
    }

    #expect(await first.value)
    #expect(await second.value)
    #expect(await recorder.snapshot() == [1, 2, 3])
  }
}
