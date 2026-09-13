#if canImport(AppKit) && canImport(SwiftUI)

  import AppKit
  import Combine
  import OpenJoystickDriverKit
  import SwiftUI

  enum SettingsWindowSizingPolicy {
    static let defaultContentSize = NSSize(width: 960, height: 640)
    static let minimumContentSize = NSSize(width: 720, height: 480)

    static func fittingContentSize(_ current: NSSize) -> NSSize {
      NSSize(
        width: max(current.width, minimumContentSize.width),
        height: max(current.height, minimumContentSize.height)
      )
    }
  }

  @MainActor
  final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier(
      "OpenJoystickDriver.SettingsToolbar"
    )
    private static let sidebarIdentifier = NSToolbarItem.Identifier(
      "OpenJoystickDriver.SettingsSidebar"
    )

    private let navigation: SettingsNavigationModel
    private let notificationPermission: NotificationPermissionModel
    private let preferences: SettingsPreferencesModel
    private let console: ConsoleViewModel
    private let developerTools: DeveloperToolsViewModel
    private var developerToolsObservation: AnyCancellable?

    init(
      viewModel: RuntimeViewModel,
      restartApplication: @escaping @MainActor () -> Void,
      openInputTest: @escaping @MainActor (ApplicationServiceDeviceDescription) -> Void,
      persistence: any SettingsPanePersistence = UserDefaultsSettingsPanePersistence()
    ) {
      notificationPermission = NotificationPermissionModel()
      preferences = SettingsPreferencesModel()
      navigation = SettingsNavigationModel(
        persistence: persistence,
        developerToolsEnabled: preferences.developerToolsEnabled
      )
      console = ConsoleViewModel()
      developerTools = DeveloperToolsViewModel(gateway: viewModel.gateway)
      let rootView = SettingsRootView(
        navigation: navigation,
        viewModel: viewModel,
        notificationPermission: notificationPermission,
        preferences: preferences,
        console: console,
        developerTools: developerTools,
        restartApplication: restartApplication,
        openInputTest: openInputTest
      )
      let host = NSHostingView(rootView: rootView)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: SettingsWindowSizingPolicy.defaultContentSize),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.contentMinSize = SettingsWindowSizingPolicy.minimumContentSize
      window.hidesOnDeactivate = false
      let autosaveName = "SettingsWindowGeometry"
      let restoredFrame = window.setFrameUsingName(autosaveName)
      window.setFrameAutosaveName(autosaveName)
      window.title = OJDLocalized.string("app.name", fallback: "OpenJoystickDriver")
      window.isReleasedWhenClosed = false
      window.contentView = host
      let restoredContentSize = window.contentView?.bounds.size ?? .zero
      window.setContentSize(SettingsWindowSizingPolicy.fittingContentSize(restoredContentSize))
      if !restoredFrame { window.center() }
      WindowFramePolicy.clamp(window)
      super.init(window: window)
      window.delegate = self
      configureToolbar(for: window)
      developerToolsObservation = preferences.$developerToolsEnabled.dropFirst().sink {
        [weak self] enabled in
        guard let self else { return }
        self.navigation.setDeveloperToolsEnabled(enabled)
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(pane: SettingsPane?) {
      if let pane { navigation.requestPane(pane) }
      window?.toolbar?.isVisible = true
      if let window { WindowFramePolicy.clamp(window) }
      window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      // Hiding, rather than releasing, preserves the selected pane and the user's window geometry.
      sender.orderOut(nil)
      return false
    }

    private func configureToolbar(for window: NSWindow) {
      let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
      toolbar.delegate = self
      toolbar.allowsUserCustomization = false
      toolbar.autosavesConfiguration = false
      toolbar.displayMode = .iconAndLabel
      window.toolbar = toolbar
      toolbar.isVisible = true
    }

    @objc
    private func performToggleSidebar(_ sender: Any?) {
      NSApplication.shared.sendAction(
        #selector(NSSplitViewController.toggleSidebar(_:)),
        to: nil,
        from: sender
      )
    }
  }

  extension SettingsWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      [Self.sidebarIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      [Self.sidebarIdentifier]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func toolbar(
      _ toolbar: NSToolbar,
      itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
      willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
      guard itemIdentifier == Self.sidebarIdentifier else { return nil }
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.target = self
      item.action = #selector(performToggleSidebar(_:))
      item.label = OJDLocalized.string("settings.navigation", fallback: "Settings navigation")
      item.paletteLabel = item.label
      item.toolTip = item.label
      if #available(macOS 11.0, *) {
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
      }
      return item
    }
  }

#endif
