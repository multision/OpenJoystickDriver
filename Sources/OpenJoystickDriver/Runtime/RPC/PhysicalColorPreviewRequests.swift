import Foundation
import OpenJoystickDriverKit

extension ApplicationServiceServer {
  public func previewPhysicalColor(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    token: UUID,
    red: Int,
    green: Int,
    blue: Int,
    reply: @escaping (Bool) -> Void
  ) {
    guard [red, green, blue].allSatisfy({ (0...255).contains($0) }) else {
      reply(false)
      return
    }
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.previewPhysicalColor(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          token: token,
          red: UInt8(red),
          green: UInt8(green),
          blue: UInt8(blue)
        )
      )
    }
  }

  public func releasePhysicalColorPreview(
    vendorID: Int,
    productID: Int,
    runtimeIdentifier: String?,
    token: UUID,
    reply: @escaping (Bool) -> Void
  ) {
    let callback = SendableReply(call: reply)
    let dm = deviceManager
    Task {
      let identifier = DeviceIdentifier(
        vendorID: UInt16(clamping: vendorID),
        productID: UInt16(clamping: productID)
      )
      callback.call(
        await dm.releasePhysicalColorPreview(
          for: identifier,
          runtimeIdentifier: runtimeIdentifier,
          token: token
        )
      )
    }
  }
}
