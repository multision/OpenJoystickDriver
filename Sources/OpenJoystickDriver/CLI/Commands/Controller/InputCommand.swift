import Foundation
import OpenJoystickDriverKit

struct InputCommand {
  static let nanosecondsPerSecond: UInt64 = 1_000_000_000
  static let nanosecondsPerMillisecond: UInt64 = 1_000_000

  func run(arguments: [String]) {
    let options = parse(arguments)
    let service = ControllerInputDiagnosticService()
    let failure = withCLIShutdownCleanup(
      { runSync { await service.disconnect() } },
      { runSyncResult { await execute(options, service: service) } }
    )
    runSync { await service.disconnect() }
    if let failure {
      CLIOutput.error(failure)
      exit(1)
    }
  }
}

struct InputCommandFailure: LocalizedError, Sendable {
  let message: String

  init(_ message: String) { self.message = message }

  var errorDescription: String? { message }
}
