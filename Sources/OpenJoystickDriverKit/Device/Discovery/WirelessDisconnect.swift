import Foundation

public enum WirelessControllerDisconnectOutcome: Sendable, Equatable {
  case disconnected
  case failed
  case timedOut
}

public protocol WirelessControllerDisconnecting: Sendable {
  func disconnect(
    address: String,
    timeoutNanoseconds: UInt64
  ) async -> WirelessControllerDisconnectOutcome
}
