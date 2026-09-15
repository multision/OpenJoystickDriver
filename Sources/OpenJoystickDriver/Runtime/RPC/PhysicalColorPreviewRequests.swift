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
    guard let red = UInt8(exactly: red), let green = UInt8(exactly: green),
      let blue = UInt8(exactly: blue)
    else {
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
          red: red,
          green: green,
          blue: blue
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
