import Darwin
import Foundation
import OpenJoystickDriverKit
import OpenJoystickDriverUSB

@MainActor
final class ApplicationServiceRuntime {
  private let permissionManager: PermissionManager
  private let dispatcher: CompatibilityOutputDispatcher
  private let remappingRouter: RemappingOutputRouter
  private let manager: DeviceManager
  private let applicationServiceServer: ApplicationServiceServer
  private var started = false
  private var shutdownSignalSources: [DispatchSourceSignal] = []
  private var shutdownSignalHandler: (@MainActor @Sendable () -> Void)?

  init() {
    let permissionManager = PermissionManager()
    let dispatcher = CompatibilityOutputDispatcher()
    let remappingProfileLibrary = RemappingProfileLibrary()
    let postEventAccess = CoreGraphicsPostEventAccess()
    let physicalOutputBridge = RemappingPhysicalOutputBridge()
    let remappingEngine = RemappingEventEngine(
      sink: CoreGraphicsSystemInputSink(access: postEventAccess),
      gamepadSink: dispatcher,
      physicalOutputSink: physicalOutputBridge
    )
    let remappingRouter = RemappingOutputRouter(
      library: remappingProfileLibrary,
      engine: remappingEngine,
      compatibility: dispatcher,
      foregroundApplication: WorkspaceRemappingForegroundApplication(),
      postEventAccess: postEventAccess
    )
    let manager = DeviceManager(
      dispatcher: remappingRouter,
      usbTransportProvider: OpenJoystickDriverUSBTransportProvider(),
      wirelessControllerDisconnector: BluetoothControllerDisconnector()
    )
    physicalOutputBridge.attach(manager)
    let applicationServiceServer = ApplicationServiceServer(
      deviceManager: manager,
      permissionManager: permissionManager,
      dispatcher: dispatcher,
      remappingProfileLibrary: remappingProfileLibrary,
      remappingRouter: remappingRouter,
      postEventAccess: postEventAccess,
      initializeCompatibilityBackend: false
    )

    self.permissionManager = permissionManager
    self.dispatcher = dispatcher
    self.remappingRouter = remappingRouter
    self.manager = manager
    self.applicationServiceServer = applicationServiceServer
  }

  func start() throws {
    guard !started else { return }
    started = true

    setbuf(stdout, nil)
    serviceLog("[Service] Starting main-app service runtime")
    setupGracefulShutdown()
    do { try applicationServiceServer.start() } catch {
      cancelGracefulShutdown()
      started = false
      throw error
    }
    Task { await permissionManager.startPolling() }
    remappingRouter.startTicker()
    Task {
      await manager.start()
      _ = await applicationServiceServer.activateCompatibilityBackendForCurrentDevices()
    }
  }

  /// Replaces `stop()` + `exit(0)` on SIGTERM/SIGINT.
  ///
  /// The menu-bar host uses this so AppKit can remove the status item before the
  /// process exits. Install the handler before `start()`.
  func handleShutdownSignal(_ handler: @escaping @MainActor @Sendable () -> Void) {
    shutdownSignalHandler = handler
  }

  func stop() async {
    guard started else { return }
    started = false

    cancelGracefulShutdown()
    await applicationServiceServer.stop()
    await manager.stop()
    do { try await remappingRouter.shutdown() } catch {
      serviceError("[Service] Remapping shutdown failed: \(error.localizedDescription)")
    }
    await permissionManager.stopPolling()
    serviceLog("[Service] Stopped")
  }

  private func serviceLog(_ message: String) { print(message) }

  private func serviceError(_ message: String) { fputs("\(message)\n", stderr) }

  private func setupGracefulShutdown() {
    guard shutdownSignalSources.isEmpty else { return }
    shutdownSignalSources = [SIGTERM, SIGINT].map { signalNumber in
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          if let shutdownSignalHandler = self.shutdownSignalHandler {
            shutdownSignalHandler()
            return
          }
          self.serviceLog("[Service] Signal \(signalNumber) - stopping...")
          await self.stop()
          exit(0)
        }
      }
      signal(signalNumber, SIG_IGN)
      source.resume()
      return source
    }
  }

  private func cancelGracefulShutdown() {
    let sources = shutdownSignalSources
    shutdownSignalSources.removeAll()
    for source in sources { source.cancel() }
  }
}
