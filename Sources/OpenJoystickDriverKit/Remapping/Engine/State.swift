import Foundation

let remappingStateNanosecondsPerMillisecond: Double = 1_000_000

struct RemappingEngineState {
  var devices: [DeviceIdentifier: RemappingDeviceState] = [:]
  var keyReferences: [RemappingKeyboardKey: Int] = [:]
  var modifierReferences: [RemappingKeyModifier: Int] = [:]
  var mouseButtonReferences: [RemappingMouseButton: Int] = [:]
}
