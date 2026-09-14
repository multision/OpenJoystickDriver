#if canImport(AppKit)

  import Foundation
  import OpenJoystickDriverKit

  @MainActor
  final class MenuBarViewModel {
    let runtime: RuntimeViewModel
    private var liveRefreshInFlight = false

    init(runtime: RuntimeViewModel) { self.runtime = runtime }

    var devices: [ApplicationServiceDeviceDescription] {
      guard case .available(let status) = runtime.statusState else { return [] }
      return status.devices
    }

    var needsPermissionAttention: Bool {
      guard case .available(let status) = runtime.statusState else { return false }
      let needsPostEventAccess =
        status.requiresPostEventAccess == true && status.postEventAccess != .granted
      return !status.permissions.isReady || needsPostEventAccess
    }

    func refresh() async {
      await runtime.refreshSystemExtensionSetup()
      await runtime.refresh()
    }

    func refreshLiveStatus() async -> Bool? {
      guard !liveRefreshInFlight else { return nil }
      liveRefreshInFlight = true
      defer { liveRefreshInFlight = false }
      return await runtime.refreshLiveStatus()
    }
  }

#endif
