import Foundation
import IOKit.hid
import Testing

@testable import OpenJoystickDriverKit

struct VirtualControllerBackendTests {}

extension Array where Element: Equatable {
  func containsSequence(_ sequence: [Element]) -> Bool {
    guard !sequence.isEmpty, sequence.count <= count else { return false }
    return indices.dropLast(sequence.count - 1).contains { index in
      self[index..<(index + sequence.count)].elementsEqual(sequence)
    }
  }

}
