import Foundation

/// One ordered stream for event reports, keepalives, and host-protocol replies.
/// Closing rejects queued work and detaches the backend before draining the current send.
final class UserSpaceReportSender: @unchecked Sendable {
  private let lock = NSLock()
  private var backend: (any UserSpaceOutputDispatcher.VirtualDeviceBackend)?
  private var tail: Task<Void, Error>?
  private var closeTask: Task<Void, Never>?
  private var closed = false

  func attach(_ backend: any UserSpaceOutputDispatcher.VirtualDeviceBackend) {
    let rejected = lock.withLock {
      guard !closed, self.backend == nil else { return true }
      self.backend = backend
      return false
    }
    if rejected { backend.close() }
  }

  /// Builds reports only after preceding work finishes, so an idle report cannot replay old state.
  func submit(
    whileActive: @escaping @Sendable () -> Bool = { true },
    requireActive: Bool = false,
    _ reports: @escaping @Sendable () throws -> [[UInt8]]
  ) -> Task<Void, Error> {
    lock.withLock {
      guard !closed else { return Task { throw CancellationError() } }
      let previous = tail
      let task = Task { [self] in
        if let previous {
          await withTaskCancellationHandler {
            _ = await previous.result
          } onCancel: {
            previous.cancel()
          }
        }
        try Task.checkCancellation()
        let backend = try lock.withLock {
          guard !closed, let backend = self.backend else { throw CancellationError() }
          return backend
        }
        let values = try reports()
        for report in values {
          guard !lock.withLock({ closed }) else { throw CancellationError() }
          guard whileActive() else {
            if requireActive { throw CancellationError() }
            return
          }
          try await backend.send(report)
        }
      }
      tail = task
      return task
    }
  }

  @discardableResult
  func beginClose() -> Task<Void, Never> {
    let result = lock.withLock {
      () -> (Task<Void, Never>, (any UserSpaceOutputDispatcher.VirtualDeviceBackend)?) in
      if let closeTask { return (closeTask, nil) }
      closed = true
      let pending = tail
      pending?.cancel()
      let backend = backend
      self.backend = nil
      tail = nil
      let task = Task { if let pending { _ = await pending.result } }
      closeTask = task
      return (task, backend)
    }
    result.1?.close()
    return result.0
  }
}
