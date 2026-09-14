import Foundation
import IOKit
import Testing

@testable import OpenJoystickDriver

struct BluetoothControllerDisconnectorTests {
  @Test
  func successfulCloseReturnsThePlatformResult() async {
    let disconnector = BluetoothControllerDisconnector { address in
      address == "AA:BB:CC:DD:EE:FF" ? kIOReturnSuccess : kIOReturnNotFound
    }

    let result = await disconnector.disconnect(
      address: "AA:BB:CC:DD:EE:FF",
      timeoutNanoseconds: 1_000_000_000
    )

    #expect(result == .disconnected)
  }

  @Test
  func timeoutReturnsBeforeALateCloseCompletes() async {
    let disconnector = BluetoothControllerDisconnector { _ in
      Thread.sleep(forTimeInterval: 0.2)
      return kIOReturnSuccess
    }
    let startedAt = DispatchTime.now().uptimeNanoseconds

    let result = await disconnector.disconnect(
      address: "AA:BB:CC:DD:EE:FF",
      timeoutNanoseconds: 10_000_000
    )

    #expect(result == .timedOut)
    #expect(DispatchTime.now().uptimeNanoseconds - startedAt < 150_000_000)
    try? await Task.sleep(nanoseconds: 220_000_000)
  }
}
