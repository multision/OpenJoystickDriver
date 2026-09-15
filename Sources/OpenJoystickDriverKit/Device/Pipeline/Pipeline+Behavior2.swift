import Foundation

extension DevicePipeline {

  func invalidateUSBHandle(_ handle: any USBTransportSession) async {
    guard let current = usbHandle, ObjectIdentifier(current) == ObjectIdentifier(handle) else {
      return
    }
    usbHandle = nil
    await handle.close()
    (parser as? any InputParserSessionLifecycle)?.resetProtocolState()
  }

}
