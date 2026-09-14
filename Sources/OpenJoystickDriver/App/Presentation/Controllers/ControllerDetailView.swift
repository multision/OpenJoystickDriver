#if canImport(SwiftUI)

  import AppKit
  import Foundation
  import OpenJoystickDriverKit
  import SwiftUI
  struct ControllerDetailView: View {
    let device: ApplicationServiceDeviceDescription
    let activeProfile: RuntimeActiveProfileState
    let retry: () -> Void
    @ObservedObject
    var viewModel: RuntimeViewModel
    let openInputTest: @MainActor (ApplicationServiceDeviceDescription) -> Void

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          controllerHeader
          activeProfileRow
          Divider()
          controllerDetails
          Divider()
          inputTestAction
          Divider()
          ControllerIdentityView(viewModel: viewModel)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
      }.ojdAccessibilityLabel(device.name).ojdAccessibilityValue(accessibilityValue)
    }

    private var inputTestAction: some View {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(OJDLocalized.string("inputTest.title", fallback: "Input Test")).font(.headline)
          Text(
            OJDLocalized.string(
              "inputTest.summary",
              fallback: "Test buttons, sticks, triggers, rumble, and controller lighting."
            )
          ).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor)).fixedSize(
            horizontal: false,
            vertical: true
          )
        }
        Spacer(minLength: 12)
        Button(OJDLocalized.string("inputTest.open", fallback: "Open Input Test...")) {
          openInputTest(device)
        }
      }
    }

    private var controllerHeader: some View {
      HStack(alignment: .center, spacing: 10) {
        let presentation = PublishedVirtualIdentity.presentation(
          for: device,
          requested: viewModel.requestedCompatibilityIdentity
        )
        OJDSystemSymbol(
          name: presentation.controllerSymbolName,
          fallback: OJDLocalized.string("common.controller", fallback: "Controller"),
          fallbackSymbolName: presentation.controllerSymbolFallback
        ).font(.title).foregroundColor(presentation.glyphFamily.controllerSymbolColor)
          .ojdAccessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(device.name).font(.headline.weight(.semibold)).lineLimit(1)
          Text(
            "\(reportedValue(device.connection)) · \(publishedProfile.publishedUSBIdentityLabel)"
          ).foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        Spacer(minLength: 0)
      }
    }

    @ViewBuilder
    private var activeProfileRow: some View {
      switch activeProfile {
      case .loading:
        KeyValueRow(
          label: OJDLocalized.string("controllers.activeProfile", fallback: "Active profile"),
          value: OJDLocalized.string("status.checking", fallback: "Checking...")
        )
      case .noProfile:
        KeyValueRow(
          label: OJDLocalized.string("controllers.activeProfile", fallback: "Active profile"),
          value: OJDLocalized.string("common.none", fallback: "None")
        )
      case .profile(let name):
        KeyValueRow(
          label: OJDLocalized.string("controllers.activeProfile", fallback: "Active profile"),
          value: name
        )
      case .unavailable(let message):
        profileFailureRow(
          label: OJDLocalized.string(
            "controllers.profileUnavailable",
            fallback: "Active profile unavailable"
          ),
          message: message
        )
      case .error(let message):
        profileFailureRow(
          label: OJDLocalized.string(
            "controllers.profileLoadError",
            fallback: "Active profile could not be loaded"
          ),
          message: message
        )
      }
    }

    private func profileFailureRow(label: String, message: String) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(OJDLocalized.string("controllers.activeProfile", fallback: "Active profile"))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
          Spacer()
          Text(OJDLocalized.string("common.needsAttention", fallback: "Needs attention"))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        Text(label).font(.caption.weight(.semibold))
        Text(message).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor)).fixedSize(
          horizontal: false,
          vertical: true
        )
        Button(OJDLocalized.string("common.tryAgain", fallback: "Try again"), action: retry)
      }
    }

    private var publishedProfile: VirtualDeviceProfile {
      PublishedVirtualIdentity.profile(
        for: device,
        requested: viewModel.requestedCompatibilityIdentity
      )
    }

    private var controllerDetails: some View {
      VStack(alignment: .leading, spacing: 6) {
        KeyValueRow(
          label: OJDLocalized.string("controllers.publishedAs", fallback: "Published as"),
          value: publishedProfile.publishedUSBIdentityLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("common.protocol", fallback: "Protocol"),
          value: device.protocolVariant.displayLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("common.parser", fallback: "Parser"),
          value: reportedValue(device.parser)
        )
        KeyValueRow(
          label: OJDLocalized.string("common.serialNumber", fallback: "Serial number"),
          value: serialNumberLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("controllers.battery", fallback: "Battery"),
          value: batteryPercentageLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("controllers.chargingState", fallback: "Charging state"),
          value: chargingStateLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("controllers.cableState", fallback: "Cable state"),
          value: cableStateLabel
        )
        KeyValueRow(
          label: OJDLocalized.string("controllers.usbIdentifier", fallback: "USB VID/PID"),
          value: usbIdentifier
        )
        KeyValueRow(
          label: OJDLocalized.string("common.inputEndpoint", fallback: "Input endpoint"),
          value: endpointLabel(device.inputEndpoint)
        )
        KeyValueRow(
          label: OJDLocalized.string("common.outputEndpoint", fallback: "Output endpoint"),
          value: endpointLabel(device.outputEndpoint)
        )
      }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serialNumberLabel: String {
      guard let serialNumber = device.serialNumber else {
        return OJDLocalized.string("controllers.notReported", fallback: "Not reported")
      }
      return reportedValue(serialNumber)
    }

    private var usbIdentifier: String {
      guard device.vendorID != 0 || device.productID != 0 else {
        return OJDLocalized.string("controllers.notReported", fallback: "Not reported")
      }
      return String(format: "%04X:%04X", device.vendorID, device.productID)
    }

    private var batteryPercentageLabel: String {
      guard let percentage = device.battery?.percentageDescription else {
        return OJDLocalized.string("common.unknown", fallback: "Unknown")
      }
      return percentage
    }

    private var chargingStateLabel: String {
      switch device.battery?.chargingState ?? .unknown {
      case .discharging:
        return OJDLocalized.string("controllers.discharging", fallback: "Discharging")
      case .charging: return OJDLocalized.string("controllers.charging", fallback: "Charging")
      case .full: return OJDLocalized.string("controllers.batteryFull", fallback: "Full")
      case .unknown: return OJDLocalized.string("common.unknown", fallback: "Unknown")
      }
    }

    private var cableStateLabel: String {
      switch device.battery?.cableState ?? .unknown {
      case .connected:
        return OJDLocalized.string("settings.controllerConnectedShort", fallback: "Connected")
      case .disconnected:
        return OJDLocalized.string("settings.controllerDisconnectedShort", fallback: "Disconnected")
      case .unknown: return OJDLocalized.string("common.unknown", fallback: "Unknown")
      }
    }

    private func reportedValue(_ value: String) -> String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty
        ? OJDLocalized.string("controllers.notReported", fallback: "Not reported") : trimmed
    }

    private func endpointLabel(_ endpoint: UInt8) -> String {
      endpoint == 0
        ? OJDLocalized.string("controllers.notReported", fallback: "Not reported")
        : String(format: "0x%02X", endpoint)
    }

    private var accessibilityValue: String {
      let details = OJDLocalized.formatted(
        "controllers.accessibilityDetails",
        fallback: "%@. %@. Protocol: %@. Parser: %@. Serial number: %@. "
          + "USB VID/PID: %@. Input endpoint: %@. Output endpoint: %@.",
        reportedValue(device.connection),
        profileAccessibilityValue,
        device.protocolVariant.displayLabel,
        reportedValue(device.parser),
        serialNumberLabel,
        usbIdentifier,
        endpointLabel(device.inputEndpoint),
        endpointLabel(device.outputEndpoint)
      )
      let battery = OJDLocalized.formatted(
        "controllers.batteryAccessibilityDetails",
        fallback: "Battery: %@. Charging state: %@. Cable state: %@.",
        batteryPercentageLabel,
        chargingStateLabel,
        cableStateLabel
      )
      return "\(details) \(battery)"
    }

    private var profileAccessibilityValue: String {
      switch activeProfile {
      case .loading:
        return OJDLocalized.string(
          "controllers.profileCheckingSentence",
          fallback: "Active profile is being checked."
        )
      case .noProfile:
        return OJDLocalized.string(
          "controllers.noActiveProfileSentence",
          fallback: "No active profile."
        )
      case .profile(let name):
        return OJDLocalized.formatted(
          "controllers.activeProfileSentence",
          fallback: "Active profile: %@.",
          name
        )
      case .unavailable(let message):
        return OJDLocalized.formatted(
          "controllers.profileUnavailableSentence",
          fallback: "Active profile unavailable: %@",
          message
        )
      case .error(let message):
        return OJDLocalized.formatted(
          "controllers.profileErrorSentence",
          fallback: "Active profile error: %@",
          message
        )
      }
    }
  }

#endif
