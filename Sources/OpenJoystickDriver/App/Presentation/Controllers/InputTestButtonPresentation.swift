#if canImport(SwiftUI)

  import OpenJoystickDriverKit

  enum InputTestButtonPresentation {
    static let standardButtons: Set<Button> = [
      .a, .b, .x, .y, .cross, .circle, .square, .triangle, .leftBumper, .rightBumper, .l1, .r1,
      .l2Digital, .r2Digital, .back, .share, .guide, .ps, .start, .options, .leftStick, .rightStick,
      .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
    ]

    static let coreDiagnosticButtons: Set<Button> = [
      .a, .b, .x, .y, .cross, .circle, .square, .triangle, .leftBumper, .rightBumper, .l1, .r1,
      .l2Digital, .r2Digital, .back, .guide, .ps, .start, .leftStick, .rightStick, .dpadUp,
      .dpadDown, .dpadLeft, .dpadRight,
    ]

    static func isPressed(_ buttons: [Button], in state: DeviceInputState) -> Bool {
      isPressed(buttons, in: Set(state.pressedButtons))
    }

    static func isPressed(_ buttons: [Button], in pressedButtons: Set<String>) -> Bool {
      buttons.contains { pressedButtons.contains($0.rawValue) }
    }

    static func additionalButtons(in state: DeviceInputState) -> [String] {
      let known = Set(standardButtons.map(\.rawValue))
      return state.pressedButtons.filter { !known.contains($0) }.sorted()
    }

    static func localizedTitle(for rawName: String) -> String {
      guard let button = Button(rawValue: rawName) else { return rawName }
      switch button {
      case .leftFunction: return RuntimePresentation.sourceLabel(.button(.leftFunction))
      case .rightFunction: return RuntimePresentation.sourceLabel(.button(.rightFunction))
      case .leftPaddle: return RuntimePresentation.sourceLabel(.button(.leftPaddle))
      case .rightPaddle: return RuntimePresentation.sourceLabel(.button(.rightPaddle))
      case .leftSL: return RuntimePresentation.sourceLabel(.button(.leftSL))
      case .leftSR: return RuntimePresentation.sourceLabel(.button(.leftSR))
      case .rightSL: return RuntimePresentation.sourceLabel(.button(.rightSL))
      case .rightSR: return RuntimePresentation.sourceLabel(.button(.rightSR))
      case .leftGrip: return RuntimePresentation.sourceLabel(.button(.leftGrip))
      case .rightGrip: return RuntimePresentation.sourceLabel(.button(.rightGrip))
      case .leftPadClick: return RuntimePresentation.sourceLabel(.button(.leftPadClick))
      case .rightPadClick: return RuntimePresentation.sourceLabel(.button(.rightPadClick))
      case .mute: return OJDLocalized.string("mapping.mute", fallback: "Mute")
      case .touchpad:
        return OJDLocalized.string("mapping.touchpadClick", fallback: "Touchpad click")
      default: return button.displayName
      }
    }
  }

#endif
