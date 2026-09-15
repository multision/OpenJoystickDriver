import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

extension CompatibilityTests {
  @Test
  func rpcAcceptsCurrentIdentityWithoutReplacingTheLiveBackend() async {
    let permissionManager = PermissionManager()

    let compatibilityDispatcher = CompatibilityOutputDispatcher()
    let profileLibrary = RemappingProfileLibrary()
    let postEventAccess = CoreGraphicsPostEventAccess()
    let remappingEngine = RemappingEventEngine(
      sink: CoreGraphicsSystemInputSink(access: postEventAccess)
    )
    let remappingRouter = RemappingOutputRouter(
      library: profileLibrary,
      engine: remappingEngine,
      compatibility: compatibilityDispatcher,
      foregroundApplication: WorkspaceRemappingForegroundApplication(),
      postEventAccess: postEventAccess
    )
    let server = ApplicationServiceServer(
      deviceManager: DeviceManager(dispatcher: remappingRouter),
      permissionManager: permissionManager,

      dispatcher: compatibilityDispatcher,
      remappingProfileLibrary: profileLibrary,
      remappingRouter: remappingRouter,
      postEventAccess: postEventAccess
    )
    let backend = AutomaticBackendProbe()
    server.userSpaceLock.withLock {
      server.compatibilityIdentity = .appleGameController
      server.userSpaceDispatcher = backend
      server.userSpaceEnabled = true
      server.compatibilityLiveIdentity = .appleGameController
      compatibilityDispatcher.setBackend(backend)
    }

    let accepted = await withCheckedContinuation { continuation in
      server.setCompatibilityIdentity(CompatibilityIdentity.appleGameController.rawValue) {
        continuation.resume(returning: $0)
      }
    }

    #expect(accepted)
    #expect(server.userSpaceDispatcher === backend)
    #expect(!backend.closed)
    backend.close()
  }
}
