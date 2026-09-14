#if canImport(SwiftUI)

  import AppKit
  import Foundation
  import OpenJoystickDriverKit
  import SwiftUI
  struct CaptureAssignmentSheet: View {
    @ObservedObject
    var viewModel: RuntimeViewModel
    let onAdd: (RemappingSource, RemappingDestination) -> Void
    @Environment(\.presentationMode)
    private var presentationMode
    @State
    private var source: RemappingSource = .button(.south)
    @State
    private var destination: RemappingDestination = .keyboard(key: .space, modifiers: [])
    @State
    private var keyboardDestinationCleared = false
    @State
    private var keyboardCaptureActive = false
    @State
    private var selectedRuntimeIdentifier: String?

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        Text(OJDLocalized.string("capture.pressControl", fallback: "Press a controller control"))
          .font(.headline.weight(.semibold))
        Text(
          OJDLocalized.string(
            "capture.chooseControl",
            fallback: "Choose a control below, or listen briefly for the next input."
          )
        ).foregroundColor(Color(NSColor.secondaryLabelColor)).fixedSize(
          horizontal: false,
          vertical: true
        )
        Picker(
          OJDLocalized.string("capture.controllerControl", fallback: "Controller control"),
          selection: sourceBinding
        ) {
          ForEach(SourceOption.options(including: source), id: \.source) { option in
            Text(option.title).tag(option.source)
          }
        }
        touchSourceControls
        if !connectedDevices.isEmpty {
          Picker(
            OJDLocalized.string("common.controller", fallback: "Controller"),
            selection: selectedDeviceBinding
          ) {
            ForEach(connectedDevices, id: \.runtimeIdentifier) { device in
              Text(device.name).tag(device.runtimeIdentifier)
            }
          }
          if let selector = selectedDeviceSelector {
            Button(
              isListening
                ? OJDLocalized.string("capture.listeningButton", fallback: "Listening...")
                : OJDLocalized.string("capture.listen", fallback: "Listen for control")
            ) { beginListening(for: selector) }.disabled(isListening)
          }
        } else {
          Text(
            OJDLocalized.string(
              "capture.connectForLive",
              fallback:
                "Connect a controller to enable live capture. Manual selection is still available."
            )
          ).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        captureStatus
        Picker(
          OJDLocalized.string("common.destination", fallback: "Destination"),
          selection: destinationBinding
        ) {
          ForEach(DestinationOption.options(for: source, including: destination), id: \.destination)
          { option in Text(option.title).tag(option.destination) }
        }.ojdAccessibilityLabel(OJDLocalized.string("common.destination", fallback: "Destination"))
          .ojdAccessibilityValue(destinationAccessibilityValue)
        if case .keyboard = destination {
          KeyboardDestinationCaptureView(
            destination: $destination,
            isCleared: $keyboardDestinationCleared,
            isCapturing: $keyboardCaptureActive
          )
        }
        HStack {
          Spacer()
          Button(OJDLocalized.string("common.cancel", fallback: "Cancel")) { cancelCapture() }
          Button(OJDLocalized.string("common.addAssignment", fallback: "Add assignment")) {
            onAdd(source, destination)
            viewModel.cancelInputCapture()
          }.disabled(!canAddAssignment)
        }
      }.padding(28).frame(width: 470).ojdAccessibilityLabel(
        OJDLocalized.string("capture.title", fallback: "Controller control capture")
      ).background(
        EscapeKeyMonitor(isCapturing: { keyboardCaptureActive }, onEscape: { cancelCapture() })
      ).onAppear { selectInitialDevice() }.onDisappear { stopListening() }.onReceive(
        viewModel.$inputCaptureState
      ) { captureState in
        handleCaptureState(captureState)
        announceCaptureState(captureState)
      }
    }

    @ViewBuilder
    private var touchSourceControls: some View {
      switch source {
      case .touchGrid(let grid):
        VStack(alignment: .leading, spacing: 8) {
          Stepper(
            OJDLocalized.formatted(
              "capture.touchColumns",
              fallback: "Grid columns: %d",
              grid.columns
            ),
            value: touchGridValue(\.columns),
            in: RemappingTouchGridSource.dimensionRange
          )
          Stepper(
            OJDLocalized.formatted("capture.touchRows", fallback: "Grid rows: %d", grid.rows),
            value: touchGridValue(\.rows),
            in: RemappingTouchGridSource.dimensionRange
          )
          Stepper(
            OJDLocalized.formatted(
              "capture.touchColumn",
              fallback: "Cell column: %d",
              grid.column + 1
            ),
            value: touchGridValue(\.column),
            in: 0...max(0, grid.columns - 1)
          )
          Stepper(
            OJDLocalized.formatted("capture.touchRow", fallback: "Cell row: %d", grid.row + 1),
            value: touchGridValue(\.row),
            in: 0...max(0, grid.rows - 1)
          )
        }.padding(.leading, 8)
      case .touchSwipe(let swipe):
        VStack(alignment: .leading, spacing: 5) {
          Text(
            OJDLocalized.formatted(
              "capture.touchSwipeDistance",
              fallback: "Minimum swipe distance: %.0f%%",
              swipe.minimumDistance * 100
            )
          )
          Slider(
            value: Binding(
              get: { swipe.minimumDistance },
              set: { distance in
                source = .touchSwipe(
                  RemappingTouchSwipeSource(
                    surface: swipe.surface,
                    direction: swipe.direction,
                    minimumDistance: distance
                  )
                )
              }
            ),
            in: RemappingTouchSwipeSource.minimumDistanceRange
          )
        }.padding(.leading, 8)
      case .button, .dpad, .axis, .axisDirection, .triggerStage, .motionLean, .touchContact:
        EmptyView()
      }
    }

    private func touchGridValue(_ keyPath: KeyPath<RemappingTouchGridSource, Int>) -> Binding<Int> {
      Binding(
        get: {
          guard case .touchGrid(let grid) = source else { return 0 }
          return grid[keyPath: keyPath]
        },
        set: { value in
          guard case .touchGrid(let grid) = source else { return }
          var columns = grid.columns
          var rows = grid.rows
          var column = grid.column
          var row = grid.row
          switch keyPath {
          case \.columns: columns = value
          case \.rows: rows = value
          case \.column: column = value
          case \.row: row = value
          default: return
          }
          column = min(column, columns - 1)
          row = min(row, rows - 1)
          source = .touchGrid(
            RemappingTouchGridSource(
              surface: grid.surface,
              columns: columns,
              rows: rows,
              column: column,
              row: row
            )
          )
        }
      )
    }

    private var canAddAssignment: Bool {
      if case .keyboard = destination { return !keyboardDestinationCleared }
      return true
    }

    private var isListening: Bool {
      guard let selectedDeviceSelector else { return false }
      if case .listening(let selector) = viewModel.inputCaptureState {
        return selector == selectedDeviceSelector
      }
      return false
    }

    private var destinationBinding: Binding<RemappingDestination> {
      Binding(
        get: { destination },
        set: {
          destination = $0
          keyboardDestinationCleared = false
        }
      )
    }

    private var sourceBinding: Binding<RemappingSource> {
      Binding(
        get: { source },
        set: { newSource in
          source = newSource
          let options = DestinationOption.options(for: newSource, including: destination)
          if !options.contains(where: { $0.destination == destination }),
            let replacement = options.first
          {
            destination = replacement.destination
          }
          keyboardDestinationCleared = false
        }
      )
    }

    private var connectedDevices: [ApplicationServiceDeviceDescription] {
      guard case .available(let status) = viewModel.statusState else { return [] }
      return status.devices
    }

    private var selectedDeviceBinding: Binding<String> {
      Binding(
        get: { selectedRuntimeIdentifier ?? connectedDevices.first?.runtimeIdentifier ?? "" },
        set: {
          if selectedRuntimeIdentifier != $0 { stopListening() }
          selectedRuntimeIdentifier = $0
        }
      )
    }

    private var selectedDeviceSelector: RuntimeDeviceSelector? {
      guard
        let device = connectedDevices.first(where: {
          $0.runtimeIdentifier
            == (selectedRuntimeIdentifier ?? connectedDevices.first?.runtimeIdentifier)
        })
      else { return nil }
      return RuntimeDeviceSelector(device: device)
    }

    private func selectInitialDevice() {
      guard selectedRuntimeIdentifier == nil else { return }
      selectedRuntimeIdentifier = connectedDevices.first?.runtimeIdentifier
    }

    private func cancelCapture() {
      stopListening()
      announce(OJDLocalized.string("capture.canceled", fallback: "Controller capture canceled."))
      presentationMode.wrappedValue.dismiss()
    }

    private func beginListening(for selector: RuntimeDeviceSelector) {
      viewModel.cancelInputCapture()
      Task { @MainActor in await viewModel.listenForInput(for: selector) }
    }

    private func stopListening() { viewModel.cancelInputCapture() }

    private func announce(_ message: String) {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high]
      )
    }

    private func handleCaptureState(_ captureState: RuntimeInputCaptureState) {
      switch captureState {
      case .detected(let selector, _, let detected):
        guard let selectedDeviceSelector, selector == selectedDeviceSelector else { return }
        applyDetectedSource(detected)
      case .received, .unavailable, .error, .idle, .listening: break
      }
    }

    private func applyDetectedSource(_ detected: RemappingSource) {
      source = detected
      let options = DestinationOption.options(for: detected, including: destination)
      if !options.contains(where: { $0.destination == destination }),
        let replacement = options.first
      {
        destination = replacement.destination
      }
      keyboardDestinationCleared = false
    }

    private var destinationAccessibilityValue: String {
      if case .keyboard = destination, keyboardDestinationCleared {
        return OJDLocalized.string("keyboard.noKey", fallback: "No key selected")
      }
      return RuntimePresentation.destinationLabel(destination)
    }

    private var captureStatusAccessibilityValue: String {
      switch viewModel.inputCaptureState {
      case .idle: return OJDLocalized.string("capture.ready", fallback: "Ready to listen.")
      case .listening:
        return OJDLocalized.string(
          "capture.listening",
          fallback: "Listening for a controller control."
        )
      case .received(_, let state):
        if let detected = RuntimePresentation.detectedSource(from: state) {
          return OJDLocalized.formatted(
            "capture.detected",
            fallback: "Detected: %@.",
            RuntimePresentation.sourceLabel(detected)
          )
        }
        return OJDLocalized.string(
          "capture.noSupported",
          fallback: "Input received, but no supported control was identified."
        )
      case .detected(_, _, let detected):
        return OJDLocalized.formatted(
          "capture.detectedWithDestination",
          fallback: "Detected: %@. %@",
          RuntimePresentation.sourceLabel(detected),
          OJDLocalized.string(
            "capture.destinationReady",
            fallback: "Destination is ready for selection."
          )
        )
      case .unavailable(_, let message), .error(_, let message): return message
      }
    }

    private func announceCaptureState(_ captureState: RuntimeInputCaptureState) {
      let message: String
      switch captureState {
      case .idle, .received: return
      case .listening:
        message = OJDLocalized.string(
          "capture.listeningCancel",
          fallback: "Listening for a controller control. Press Escape to cancel."
        )
      case .detected(let selector, _, let detected):
        guard selectedDeviceSelector == selector else { return }
        message = OJDLocalized.formatted(
          "capture.detectedWithDestination",
          fallback: "Detected: %@. %@",
          RuntimePresentation.sourceLabel(detected),
          OJDLocalized.string(
            "capture.destinationReady",
            fallback: "Destination is ready for selection."
          )
        )
      case .unavailable(_, let detail): message = detail
      case .error(_, let detail):
        message = OJDLocalized.formatted("capture.error", fallback: "Capture error. %@", detail)
      }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high]
      )
    }

    @ViewBuilder
    private var captureStatus: some View {
      Group {
        switch viewModel.inputCaptureState {
        case .idle: EmptyView()
        case .listening:
          Text(
            OJDLocalized.string(
              "capture.listeningEllipsis",
              fallback: "Listening for a controller control..."
            )
          )
        case .received(_, let state):
          VStack(alignment: .leading, spacing: 3) {
            if let detected = RuntimePresentation.detectedSource(from: state) {
              Text(
                OJDLocalized.formatted(
                  "capture.detectedNoPeriod",
                  fallback: "Detected: %@",
                  RuntimePresentation.sourceLabel(detected)
                )
              ).font(.subheadline.weight(.semibold))
            } else {
              Text(
                OJDLocalized.string(
                  "capture.noSupported",
                  fallback: "Input received, but no supported control was identified."
                )
              ).font(.subheadline.weight(.semibold))
            }
            Text(
              state.pressedButtons.isEmpty
                ? OJDLocalized.string("capture.noButton", fallback: "No button is currently held.")
                : OJDLocalized.formatted(
                  "capture.buttonsHeld",
                  fallback: "Buttons held: %@",
                  state.pressedButtons.joined(separator: ", ")
                )
            )
          }
        case .detected(_, let state, let detected):
          VStack(alignment: .leading, spacing: 3) {
            Text(
              OJDLocalized.formatted(
                "capture.detectedNoPeriod",
                fallback: "Detected: %@",
                RuntimePresentation.sourceLabel(detected)
              )
            ).font(.subheadline.weight(.semibold))
            Text(
              state.pressedButtons.isEmpty
                ? OJDLocalized.string("capture.noButton", fallback: "No button is currently held.")
                : OJDLocalized.formatted(
                  "capture.buttonsHeld",
                  fallback: "Buttons held: %@",
                  state.pressedButtons.joined(separator: ", ")
                )
            )
          }
        case .unavailable(_, let message), .error(_, let message):
          Text(message).foregroundColor(Color(NSColor.systemRed))
        }
      }.ojdAccessibilityLabel(OJDLocalized.string("capture.status", fallback: "Capture status"))
        .ojdAccessibilityValue(captureStatusAccessibilityValue)
    }
  }

#endif
