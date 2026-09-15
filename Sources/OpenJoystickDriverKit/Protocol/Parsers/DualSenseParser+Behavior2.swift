import Foundation

extension DualSenseParser {

  func diffButtons(prev: UInt8, curr: UInt8, mapping: [(UInt8, Button)]) -> [ControllerEvent] {
    var events: [ControllerEvent] = []
    for (mask, button) in mapping {
      let wasPressed = (prev & mask) != 0
      let isPressed = (curr & mask) != 0
      if wasPressed != isPressed {
        events.append(isPressed ? .buttonPressed(button) : .buttonReleased(button))
      }
    }
    return events
  }

}
