import Foundation
import IOKit
import Testing

@testable import OpenJoystickDriver

struct BluetoothControllerDisconnectorTests {
  @Test
  func successfulCloseReturnsThePlatformResult() async {
    let disconnector = BluetoothControllerDisconnector { address, _ in
      .init(
        status: address == "AA:BB:CC:DD:EE:FF" ? kIOReturnSuccess : kIOReturnNotFound,
        isConnected: false
      )
    }

    let result = await disconnector.disconnect(
      address: "AA:BB:CC:DD:EE:FF",
      timeoutNanoseconds: 1_000_000_000
    )

    #expect(result == .disconnected)
  }

  @Test
  func timeoutReturnsBeforeALateCloseCompletes() async {
    let disconnector = BluetoothControllerDisconnector { _, _ in
      Thread.sleep(forTimeInterval: 0.2)
      return .init(status: kIOReturnSuccess, isConnected: false)
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

  @Test
  func closeSuccessRequiresDisconnectedConfirmation() async {
    let disconnector = BluetoothControllerDisconnector { _, _ in
      .init(status: kIOReturnSuccess, isConnected: true)
    }

    let result = await disconnector.disconnect(
      address: "AA:BB:CC:DD:EE:FF",
      timeoutNanoseconds: 1_000_000_000
    )

    #expect(result == .stillConnected)
  }

  @Test
  func closeFailureRetainsIOReturn() async {
    let disconnector = BluetoothControllerDisconnector { _, _ in
      .init(status: kIOReturnNotPermitted, isConnected: true)
    }

    let result = await disconnector.disconnect(
      address: "AA:BB:CC:DD:EE:FF",
      timeoutNanoseconds: 1_000_000_000
    )

    #expect(result == .failed(kIOReturnNotPermitted))
  }
}
