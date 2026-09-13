#if canImport(SwiftUI)

  import AppKit
  import OpenJoystickDriverKit
  import SwiftUI

  // SF Symbol via NSImage(systemSymbolName:), else fallback text.
  struct OJDSystemSymbol: View {
    let name: String
    let fallback: String
    let fallbackSymbolName: String?

    init(name: String, fallback: String, fallbackSymbolName: String? = nil) {
      self.name = name
      self.fallback = fallback
      self.fallbackSymbolName = fallbackSymbolName
    }

    var body: some View {
      if #available(macOS 11.0, *) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
          Image(nsImage: image)
        } else if let fallbackSymbolName,
          let image = NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: nil)
        {
          Image(nsImage: image)
        } else {
          Text(fallback).font(.caption)
        }
      } else {
        Text(fallback).font(.caption)
      }
    }
  }

  struct OJDListGlyphSlot<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
      content.font(.system(size: 15, weight: .medium)).frame(
        width: 28,
        height: 28,
        alignment: .center
      ).ojdAccessibilityHidden(true)
    }
  }

  extension View {
    @ViewBuilder
    func ojdAccessibilityLabel(_ label: String) -> some View {
      if #available(macOS 11.0, *) {
        accessibilityLabel(Text(label))
      } else {
        accessibility(label: Text(label))
      }
    }

    @ViewBuilder
    func ojdAccessibilityValue(_ value: String) -> some View {
      if #available(macOS 11.0, *) {
        accessibilityValue(Text(value))
      } else {
        accessibility(value: Text(value))
      }
    }

    @ViewBuilder
    func ojdAccessibilityHidden(_ hidden: Bool) -> some View {
      if #available(macOS 11.0, *) {
        accessibilityHidden(hidden)
      } else {
        accessibility(hidden: hidden)
      }
    }

    @ViewBuilder
    func ojdAccessibilitySelection(_ selected: Bool) -> some View {
      let value = OJDLocalized.string(
        selected ? "common.selected" : "common.notSelected",
        fallback: selected ? "Selected" : "Not selected"
      )
      if #available(macOS 11.0, *) {
        accessibilityValue(Text(value)).accessibilityAddTraits(selected ? .isSelected : [])
      } else {
        accessibility(value: Text(value)).accessibility(addTraits: selected ? .isSelected : [])
      }
    }
  }

  struct SettingsSidebar: View {
    @ObservedObject
    var navigation: SettingsNavigationModel
    let panes: [SettingsPane]

    var body: some View {
      List(selection: selection) {
        ForEach(panes) { pane in
          HStack(spacing: 8) {
            OJDSystemSymbol(name: pane.symbolName, fallback: pane.title).frame(width: 18)
              .ojdAccessibilityHidden(true)
            Text(pane.title)
            Spacer(minLength: 0)
          }.padding(.vertical, 3).tag(pane)
        }
      }.listStyle(SidebarListStyle()).frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
        .ojdAccessibilityLabel(
          OJDLocalized.string("settings.navigation", fallback: "Settings navigation")
        )
    }

    private var selection: Binding<SettingsPane?> {
      Binding(
        get: { navigation.selectedPane },
        set: { pane in if let pane { navigation.requestPane(pane) } }
      )
    }
  }

#endif
