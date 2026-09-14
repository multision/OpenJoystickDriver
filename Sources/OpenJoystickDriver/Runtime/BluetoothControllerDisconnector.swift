import Foundation
import IOBluetooth
import OpenJoystickDriverKit

final class BluetoothControllerDisconnector: WirelessControllerDisconnecting, @unchecked Sendable {
  private let closeConnection: @Sendable (String) -> IOReturn

  init(
    closeConnection: @escaping @Sendable (String) -> IOReturn = { address in
      IOBluetoothDevice(addressString: address)?.closeConnection() ?? kIOReturnNotFound
    }
  ) { self.closeConnection = closeConnection }

  func disconnect(
    address: String,
    timeoutNanoseconds: UInt64
  ) async -> WirelessControllerDisconnectOutcome {
    let outcomes = AsyncStream<WirelessControllerDisconnectOutcome> { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let result = self.closeConnection(address)
        continuation.yield(result == kIOReturnSuccess ? .disconnected : .failed)
        continuation.finish()
      }
      Task {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        continuation.yield(.timedOut)
        continuation.finish()
      }
    }
    for await outcome in outcomes { return outcome }
    return .failed
  }
}
