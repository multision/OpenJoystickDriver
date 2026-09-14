import Foundation
import OpenJoystickDriverKit

enum RuntimePresentation {
  static func permissionLabel(_ state: RuntimePermissionState) -> String {
    switch state {
    case .granted: return OJDLocalized.string("status.allowed", fallback: "Allowed")
    case .denied: return OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
    case .unknown: return OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
    case .unavailable: return OJDLocalized.string("common.unavailable", fallback: "Unavailable")
    }
  }

  static func readinessLabel(_ readiness: RuntimeReadiness) -> String {
    switch readiness {
    case .ready: return OJDLocalized.string("status.ready", fallback: "Ready")
    case .needsAttention:
      return OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
    case .noController:
      return OJDLocalized.string("status.connectController", fallback: "Connect a controller")
    }
  }

  static func postEventAccessLabel(_ state: RemappingPostEventAccessState?) -> String {
    switch state {
    case .granted: return OJDLocalized.string("status.allowed", fallback: "Allowed")
    case .notAuthorized:
      return OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
    case nil: return OJDLocalized.string("status.checking", fallback: "Checking")
    }
  }

  static func deviceCountLabel(_ count: Int) -> String {
    OJDLocalized.plural(
      "status.controllerConnected",
      count: count,
      fallback: "%d controllers connected"
    )
  }

  static func profileLabel(_ profile: RemappingProfile) -> String { profile.name }

  static func profileScopeLabel(_ scope: RemappingApplicationScope) -> String {
    switch scope {
    case .global: return OJDLocalized.string("mapping.allApps", fallback: "All apps")
    case .application: return OJDLocalized.string("mapping.specificApp", fallback: "A specific app")
    }
  }

  static func compatibilityLabel(_ identity: CompatibilityIdentity) -> String {
    switch identity {
    case .automatic: return OJDLocalized.string("mapping.automatic", fallback: "Automatic")
    case .genericHID:
      return OJDLocalized.string("compatibility.genericHID", fallback: "Generic HID")
    case .sdl2_3: return OJDLocalized.string("compatibility.sdl2_3", fallback: "SDL2/3")
    case .appleGameController:
      return OJDLocalized.string(
        "compatibility.appleGameController",
        fallback: "Apple GameController"
      )
    case .xbox360HID:
      return OJDLocalized.string("compatibility.xbox360HID", fallback: "Xbox 360 HID")
    case .dualShock4: return OJDLocalized.string("controller.dualShock4", fallback: "DualShock 4")
    case .dualSense: return OJDLocalized.string("controller.dualSense", fallback: "DualSense")
    case .switchPro: return OJDLocalized.string("controller.switchPro", fallback: "Switch Pro")
    }
  }

  static func sourceLabel(_ source: RemappingSource) -> String {
    switch source {
    case .button(let button): return buttonLabel(button)
    case .dpad(let direction):
      return OJDLocalized.formatted(
        "mapping.dpadDirection",
        fallback: "D-pad %@",
        humanized(direction.rawValue)
      )
    case .axis(let axis): return axisLabel(axis)
    case .axisDirection(let axis, let direction):
      return OJDLocalized.formatted(
        "mapping.axisDirection",
        fallback: "%@ %@",
        axisLabel(axis),
        humanized(direction.rawValue)
      )
    case .triggerStage(let trigger, let stage):
      return OJDLocalized.formatted(
        "mapping.triggerStage",
        fallback: "%@ trigger %@ pull",
        humanized(trigger.rawValue),
        humanized(stage.rawValue)
      )
    case .motionLean(let direction):
      return OJDLocalized.formatted(
        "mapping.motionLean",
        fallback: "Motion lean %@",
        humanized(direction.rawValue)
      )
    case .touchContact(let surface):
      return OJDLocalized.formatted(
        "mapping.touchContact",
        fallback: "%@ touch",
        touchSurfaceLabel(surface)
      )
    case .touchGrid(let grid):
      return OJDLocalized.formatted(
        "mapping.touchGridCell",
        fallback: "%@ grid %d×%d cell %d,%d",
        touchSurfaceLabel(grid.surface),
        grid.columns,
        grid.rows,
        grid.column + 1,
        grid.row + 1
      )
    case .touchSwipe(let swipe):
      return OJDLocalized.formatted(
        "mapping.touchSwipe",
        fallback: "%@ swipe %@",
        touchSurfaceLabel(swipe.surface),
        humanized(swipe.direction.rawValue)
      )
    }
  }

  private static func touchSurfaceLabel(_ surface: RemappingTouchSurface) -> String {
    switch surface {
    case .primary: OJDLocalized.string("mapping.touchSurfacePrimary", fallback: "Primary surface")
    case .left: OJDLocalized.string("mapping.touchSurfaceLeft", fallback: "Left surface")
    case .right: OJDLocalized.string("mapping.touchSurfaceRight", fallback: "Right surface")
    }
  }

  static func destinationLabel(_ destination: RemappingDestination) -> String {
    switch destination {
    case .gamepadAxis(let axis): return axisLabel(axis)
    case .gamepadDpad(let direction): return sourceLabel(.dpad(direction))
    case .gamepadButton(let button): return buttonLabel(button)
    case .keyboard(let key, let modifiers):
      let modifierLabel = modifiers.sorted { $0.rawValue < $1.rawValue }.map(Self.modifierLabel)
        .joined(separator: " + ")
      let keyLabel = keyboardKeyLabel(key)
      return modifierLabel.isEmpty ? keyLabel : "\(modifierLabel) + \(keyLabel)"
    case .mouseButton(let button):
      return OJDLocalized.formatted(
        "mapping.mouseButton",
        fallback: "Mouse %@ button",
        humanized(button.rawValue)
      )
    case .mouseMovement(let axis):
      return OJDLocalized.formatted(
        "mapping.pointerMovement",
        fallback: "Pointer %@ movement",
        humanized(axis.rawValue)
      )
    case .scroll(let axis):
      return OJDLocalized.formatted(
        "mapping.scroll",
        fallback: "Scroll %@",
        humanized(axis.rawValue)
      )
    case .physical(let output): return physicalOutputLabel(output)
    }
  }

  static func physicalOutputLabel(_ output: RemappingPhysicalOutput) -> String {
    switch output {
    case .rumble(let motor, let intensity):
      return OJDLocalized.formatted(
        "mapping.physicalRumble",
        fallback: "%@ rumble (%@%%)",
        humanized(motor.rawValue),
        String(Int((intensity * 100).rounded()))
      )
    case .playerIndicator(let indicator):
      return OJDLocalized.formatted(
        "mapping.physicalPlayerIndicator",
        fallback: "Player indicator %@",
        indicator == .off
          ? OJDLocalized.string("common.disabled", fallback: "Disabled")
          : String(indicator.rawValue)
      )
    case .color(let red, let green, let blue):
      return OJDLocalized.formatted(
        "mapping.physicalColor",
        fallback: "Controller color %@",
        String(format: "#%02X%02X%02X", red, green, blue)
      )
    case .brightness(let intensity):
      return OJDLocalized.formatted(
        "mapping.physicalBrightness",
        fallback: "Controller brightness (%@%%)",
        String(Int((intensity * 100).rounded()))
      )
    case .adaptiveTrigger(let trigger, let effect):
      return OJDLocalized.formatted(
        "mapping.physicalAdaptiveTrigger",
        fallback: "%@ adaptive trigger: %@",
        humanized(trigger.rawValue),
        humanized(effect.kind.rawValue)
      )
    }
  }

  static func detectedSource(from state: DeviceInputState) -> RemappingSource? {
    if let sample = state.touchSamples.first(where: { $0.contacts.contains(where: \.isActive) }) {
      return .touchContact(RemappingTouchSurface(sample.surface))
    }
    let pressed = Set(state.pressedButtons.map(normalizedInputName))
    var buttons: [(Set<String>, RemappingButton)] = []
    buttons.append((Set(["leftfunction"]), .leftFunction))
    buttons.append((Set(["rightfunction"]), .rightFunction))
    buttons.append((Set(["leftpaddle"]), .leftPaddle))
    buttons.append((Set(["rightpaddle"]), .rightPaddle))
    buttons.append((Set(["leftsl"]), .leftSL))
    buttons.append((Set(["leftsr"]), .leftSR))
    buttons.append((Set(["rightsl"]), .rightSL))
    buttons.append((Set(["rightsr"]), .rightSR))
    buttons.append((Set(["leftgrip"]), .leftGrip))
    buttons.append((Set(["rightgrip"]), .rightGrip))
    buttons.append((Set(["leftpadclick"]), .leftPadClick))
    buttons.append((Set(["rightpadclick"]), .rightPadClick))
    buttons.append((Set(["a", "cross", "south", "buttona", "buttoncross"]), .south))
    buttons.append((Set(["b", "circle", "east", "buttonb", "buttoncircle"]), .east))
    buttons.append((Set(["x", "square", "west", "buttonx", "buttonsquare"]), .west))
    buttons.append((Set(["y", "triangle", "north", "buttony", "buttontriangle"]), .north))
    buttons.append((Set(["lb", "l1", "leftshoulder", "leftbumper"]), .leftShoulder))
    buttons.append((Set(["rb", "r1", "rightshoulder", "rightbumper"]), .rightShoulder))
    buttons.append((Set(["ls", "l3", "leftstick", "leftstickclick"]), .leftStick))
    buttons.append((Set(["rs", "r3", "rightstick", "rightstickclick"]), .rightStick))
    buttons.append((Set(["start", "menu"]), .start))
    buttons.append((Set(["back", "select", "view"]), .back))
    // Guide/Home/logo is reserved for the operating system and is intentionally excluded from
    // automatic capture, just like the manual SourceOption catalog.
    buttons.append((Set(["share", "create"]), .share))
    buttons.append((Set(["options", "pause"]), .options))
    buttons.append((Set(["touchpad", "touchpadclick"]), .touchpad))
    buttons.append((Set(["mute", "micmute", "microphonemute"]), .mute))
    buttons.append((Set(["l2digital", "lefttriggerclick"]), .leftTriggerClick))
    buttons.append((Set(["r2digital", "righttriggerclick"]), .rightTriggerClick))
    for (aliases, button) in buttons where !pressed.isDisjoint(with: aliases) {
      return .button(button)
    }

    var dpad: [(Set<String>, RemappingDpadDirection)] = []
    dpad.append((Set(["dpadup", "hatup", "up"]), .up))
    dpad.append((Set(["dpaddown", "hatdown", "down"]), .down))
    dpad.append((Set(["dpadleft", "hatleft", "left"]), .left))
    dpad.append((Set(["dpadright", "hatright", "right"]), .right))
    for (aliases, direction) in dpad where !pressed.isDisjoint(with: aliases) {
      return .dpad(direction)
    }

    var axes: [(Double, RemappingAxis)] = []
    axes.append((Double(state.leftStickX), .leftStickX))
    axes.append((Double(state.leftStickY), .leftStickY))
    axes.append((Double(state.rightStickX), .rightStickX))
    axes.append((Double(state.rightStickY), .rightStickY))
    axes.append((Double(state.leftTrigger), .leftTrigger))
    axes.append((Double(state.rightTrigger), .rightTrigger))
    for (value, axis) in axes {
      guard value.isFinite, abs(value) >= 0.5 else { continue }
      let direction: RemappingAxisDirection = value < 0 ? .negative : .positive
      return .axisDirection(axis, direction)
    }
    return nil
  }

  static func detectedTransition(
    from previous: DeviceInputState,
    to current: DeviceInputState
  ) -> RemappingSource? {
    let previousTouches = Set(
      previous.touchSamples.compactMap { sample in
        sample.contacts.contains(where: \.isActive) ? RemappingTouchSurface(sample.surface) : nil
      }
    )
    let currentTouches = Set(
      current.touchSamples.compactMap { sample in
        sample.contacts.contains(where: \.isActive) ? RemappingTouchSurface(sample.surface) : nil
      }
    )
    if let surface = RemappingTouchSurface.allCases.first(where: {
      currentTouches.contains($0) && !previousTouches.contains($0)
    }) {
      return .touchContact(surface)
    }
    let previousButtons = Set(previous.pressedButtons.map(normalizedInputName))
    let currentButtons = Set(current.pressedButtons.map(normalizedInputName))
    let newlyPressed = currentButtons.subtracting(previousButtons)
    if !newlyPressed.isEmpty {
      var newlyPressedState = current
      newlyPressedState.pressedButtons = Array(newlyPressed)
      if let source = detectedSource(from: newlyPressedState) { return source }
    }

    var axes: [(Float, Float, RemappingAxis)] = []
    axes.append((previous.leftStickX, current.leftStickX, .leftStickX))
    axes.append((previous.leftStickY, current.leftStickY, .leftStickY))
    axes.append((previous.rightStickX, current.rightStickX, .rightStickX))
    axes.append((previous.rightStickY, current.rightStickY, .rightStickY))
    axes.append((previous.leftTrigger, current.leftTrigger, .leftTrigger))
    axes.append((previous.rightTrigger, current.rightTrigger, .rightTrigger))
    for (previousValue, currentValue, axis) in axes {
      guard currentValue.isFinite, previousValue.isFinite else { continue }
      let crossedActivation = abs(currentValue) >= 0.5 && abs(previousValue) < 0.5
      let changedDirection =
        abs(currentValue) >= 0.5 && abs(previousValue) >= 0.5
        && (previousValue < 0) != (currentValue < 0)
      guard crossedActivation || changedDirection else { continue }
      let direction: RemappingAxisDirection = currentValue < 0 ? .negative : .positive
      return .axisDirection(axis, direction)
    }

    // A source becoming unrecognized or disappearing is a release, not a new assignment.  Only
    // newly pressed aliases and axis activation/direction transitions above count as input.
    return nil
  }

}
