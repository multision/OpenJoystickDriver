import Foundation
import OpenJoystickDriverKit

/// Owns installation requests until activation, retirement, and suppression have completed.
actor AutomaticDispatcherCoordinator {

  var entries: [DeviceIdentifier: Entry] = [:]
  var closed = false
  var closeFinished = false
  var closeWaiters: [CheckedContinuation<Void, Never>] = []
  var foreground: UInt64 = 0
  var consumerRevision: UInt64 = 0
  var consumer: CompatibilityConsumerFamily = .unknown
  var remappingSuppressed = false
  var suppressed = false
  var suppressionRevision: UInt64 = 0
  let recoveryDelayNanoseconds: UInt64

  init(recoveryDelayNanoseconds: UInt64 = 5_000_000_000) {
    self.recoveryDelayNanoseconds = recoveryDelayNanoseconds
  }
}
