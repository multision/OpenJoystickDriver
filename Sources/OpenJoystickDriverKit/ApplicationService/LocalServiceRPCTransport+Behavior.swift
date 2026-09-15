import Darwin
import Foundation

extension LocalServiceRPCClient {
  final class CallState: @unchecked Sendable {
    private let lock = NSLock()
    var descriptor: Int32?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ descriptor: Int32) -> Bool {
      lock.withLock {
        guard !cancelled else { return false }
        self.descriptor = descriptor
        return true
      }
    }

    func cancel() {
      let descriptor = lock.withLock { () -> Int32? in
        cancelled = true
        let descriptor = self.descriptor
        self.descriptor = nil
        return descriptor
      }
      guard let descriptor else { return }
      shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }

    func close(_ descriptor: Int32) {
      let shouldClose = lock.withLock { () -> Bool in
        guard self.descriptor == descriptor else { return false }
        self.descriptor = nil
        return true
      }
      guard shouldClose else { return }
      Darwin.close(descriptor)
    }
  }

  public static func isAvailable() -> Bool { serverProcessIdentifier() != nil }

  public static func serverProcessIdentifier() -> Int32? {
    serverProcessIdentifier(socketPath: LocalServiceRPCTransport.defaultSocketPath)
  }

  static func serverProcessIdentifier(socketPath: String) -> Int32? {
    guard
      let descriptor = try? LocalServiceRPCTransport.openConnectedSocket(
        timeoutSeconds: 0.2,
        socketPath: socketPath
      )
    else { return nil }
    defer { Darwin.close(descriptor) }
    var processIdentifier: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &processIdentifier, &size) == 0,
      processIdentifier > 0
    else { return nil }
    return processIdentifier
  }

  static func call<Arguments: Encodable & Sendable, Value: Decodable & Sendable>(
    method: String,
    arguments: Arguments,
    timeoutSeconds: TimeInterval,
    socketPath: String = LocalServiceRPCTransport.defaultSocketPath,
    as type: Value.Type = Value.self
  ) async throws -> Value {
    let state = CallState()
    return try await withTaskCancellationHandler {
      do {
        return try await Task.detached(priority: .userInitiated) {
          guard !state.isCancelled else { throw CancellationError() }
          let descriptor: Int32
          do {
            descriptor = try LocalServiceRPCTransport.openConnectedSocket(
              timeoutSeconds: timeoutSeconds,
              socketPath: socketPath
            )
          } catch {
            if state.isCancelled { throw CancellationError() }
            throw error
          }
          guard state.install(descriptor) else {
            Darwin.close(descriptor)
            throw CancellationError()
          }
          do {
            let request = LocalServiceRPCRequest(
              method: method,
              arguments: try JSONEncoder().encode(arguments)
            )
            do {
              try LocalServiceRPCTransport.sendFrame(
                try JSONEncoder().encode(request),
                to: descriptor
              )
            } catch LocalServiceRPCError.connectionFailed(let code)
              where code == EPIPE || code == ECONNRESET
            { throw LocalServiceRPCError.peerRejected }
            let responseData = try LocalServiceRPCTransport.receiveFrame(
              from: descriptor,
              closedBeforeFrameError: .peerRejected
            )
            let response = try JSONDecoder().decode(
              LocalServiceRPCResponse.self,
              from: responseData
            )
            if response.errorCode == "peerRejected" { throw LocalServiceRPCError.peerRejected }
            if let error = response.error { throw LocalServiceRPCError.remote(error) }
            guard let result = response.result else { throw LocalServiceRPCError.invalidFrame }
            let value = try JSONDecoder().decode(type, from: result)
            state.close(descriptor)
            try Task.checkCancellation()
            guard !state.isCancelled else { throw CancellationError() }
            return value
          } catch {
            state.close(descriptor)
            if state.isCancelled { throw CancellationError() }
            throw error
          }
        }.value
      } catch {
        if state.isCancelled || Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      state.cancel()
    }
  }
}
