import Foundation
import OpenJoystickDriverKit

func runXIDInputChecks() throws {
  let identifier = DeviceIdentifier(vendorID: 0x045E, productID: 0x0202)
  let registry = ParserRegistry()
  require(registry.parserName(for: identifier) == "XID", "Original Xbox pad should select XID")
  require(
    registry.runtimeProfile(for: identifier).protocolVariant == .xid,
    "XID profile should use xid"
  )

  let parser = XIDParser()
  _ = try parser.parse(data: makeXIDReport())
  let analog = try parser.parse(data: makeXIDReport(analogA: 0xFF))
  require(hasEvent(analog, .buttonPressed(.a)), "XID analog A should become a digital press")
  let digital = try parser.parse(data: makeXIDReport(digital: 0x11))
  require(hasEvent(digital, .buttonPressed(.start)), "XID digital start should parse")
  require(hasEvent(digital, .dpadChanged(.north)), "XID digital d-pad north should parse")
}
