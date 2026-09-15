import Foundation

/// Checks whether USB startup can continue after an Xbox 360 ring LED rejection.
public func isIgnorableUSBStartupOutputError(
  parser: any InputParser,
  packet: [UInt8],
  error: USBTransportError
) -> Bool {
  guard parser is Xbox360Parser, packet == [0x01, 0x03, 0x06] else { return false }
  switch error {
  case .inputOutput, .notFound, .notSupported: return true
  default: return false
  }
}

extension DevicePipeline {}
