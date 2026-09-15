import Foundation
import IOKit.hid
import Testing

@testable import OpenJoystickDriverKit

extension VirtualControllerBackendTests {
  @Test
  func testUserSpaceSDLIdentityAdvertisesXbox360HIDAPIReportSizes() {
    let format = Xbox360MacHIDReportFormat()
    let properties = UserSpaceOutputDispatcher.deviceProperties(
      profile: .xbox360Wired,
      format: format,
      identifier: DeviceIdentifier(vendorID: 13623, productID: 4112)
    )

    let inputSize = properties[kIOHIDMaxInputReportSizeKey as String] as? Int
    let outputSize = properties[kIOHIDMaxOutputReportSizeKey as String] as? Int
    #expect(inputSize == format.inputReportPayloadSize)
    #expect(outputSize == format.outputReportPayloadSize)
  }

  @available(macOS 15, *)
  @Test
  func testCoreHIDPropertiesPreserveDescriptorAndIdentity() {
    let format = Xbox360MacHIDReportFormat()
    let properties = UserSpaceOutputDispatcher.virtualDeviceProperties(
      profile: .xbox360Wired,
      format: format,
      identifier: DeviceIdentifier(vendorID: 13623, productID: 4112)
    )

    #expect(properties.descriptor == Data(format.descriptor))
    #expect(properties.vendorID == UInt32(VirtualDeviceProfile.xbox360Wired.vendorID))
    #expect(properties.productID == UInt32(VirtualDeviceProfile.xbox360Wired.productID))
    #expect(properties.versionNumber == UInt64(VirtualDeviceProfile.xbox360Wired.versionNumber))
    #expect(properties.versionNumber != 0)
  }

  @Test
  func testUserSpaceDispatcherFailsFastWithoutVirtualDeviceEntitlement() throws {
    guard !UserSpaceOutputDispatcher.hasRequiredVirtualDeviceEntitlement else { return }

    do {
      _ = try UserSpaceOutputDispatcher()
      Issue.record("UserSpaceOutputDispatcher should require the virtual HID entitlement")
    } catch UserSpaceOutputDispatcher.CreationError.missingEntitlement(let entitlement) {
      #expect(entitlement == UserSpaceOutputDispatcher.requiredVirtualDeviceEntitlement)
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test
  func testXbox360FormatDefaultsToJoystickPrimaryUsage() {
    #expect(
      UserSpaceOutputDispatcher.defaultPrimaryUsage(for: Xbox360MacHIDReportFormat())
        == kHIDUsage_GD_Joystick
    )
  }

  @Test
  func testXbox360GamePadFormatDefaultsToGamePadPrimaryUsage() {
    #expect(
      UserSpaceOutputDispatcher.defaultPrimaryUsage(
        for: Xbox360MacHIDReportFormat(topLevelUsage: UInt8(kHIDUsage_GD_GamePad))
      ) == kHIDUsage_GD_GamePad
    )
  }

  @Test
  func testXboxOneCompatibilityFormatDeclaresRumbleOutputSize() throws {
    let format = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor,
      outputReportID: VirtualRumbleOutputReportParser.xboxOneReportID,
      outputReportPayloadSize: VirtualRumbleOutputReportParser.xboxOneReportPayloadSize
    )

    #expect(format.inputReportID == 1)
    #expect(format.outputReportID == VirtualRumbleOutputReportParser.xboxOneReportID)
    #expect(
      format.outputReportPayloadSize == VirtualRumbleOutputReportParser.xboxOneReportPayloadSize
    )
  }

  @Test
  func testXboxGIPCompatibilityFormatAdvertisesFullOutputSize() throws {
    let format = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor,
      outputReportID: VirtualRumbleOutputReportParser.xboxGIPReportID,
      outputReportPayloadSize: VirtualRumbleOutputReportParser
        .xboxGIPReportPayloadSizeWithoutReportID
    )
    let properties = UserSpaceOutputDispatcher.deviceProperties(
      profile: .xboxOneS,
      format: format,
      identifier: DeviceIdentifier(vendorID: 13623, productID: 4112)
    )

    let outputSize = properties[kIOHIDMaxOutputReportSizeKey as String] as? Int
    #expect(outputSize == 13)
  }

  @Test
  func testCompatibilityFormatsReturnFullyNeutralReportsAfterRelease() throws {
    let generic = OJDGenericGamepadFormat().buildInputReport(from: VirtualGamepadState())
    let apple = Xbox360MacHIDReportFormat(topLevelUsage: UInt8(kHIDUsage_GD_GamePad))
      .buildInputReport(from: VirtualGamepadState())
    let x360 = Xbox360MacHIDReportFormat().buildInputReport(from: VirtualGamepadState())
    let xone = try HIDDescriptorReportFormat(
      descriptor: XboxOneBluetoothHIDDescriptor.seriesDescriptor
    ).buildInputReport(from: VirtualGamepadState())

    #expect(generic == [UInt8](repeating: 0, count: generic.count))
    #expect(Array(apple.dropFirst(2)) == [UInt8](repeating: 0, count: apple.count - 2))
    #expect(Array(x360.dropFirst(2)) == [UInt8](repeating: 0, count: x360.count - 2))
    #expect(xone[0] == 1)
    #expect(Array(xone[1...8]) == [0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80])
    #expect(xone[14] == 0x00)
    #expect(xone[16] == 0x00)
    #expect(xone.count == 17)
  }

  @Test
  func userSpaceCreationErrorsDistinguishPermissionFromEntitlementAndCreation() {
    let errors: [UserSpaceOutputDispatcher.CreationError] = [
      .inputMonitoringDenied, .accessibilityDenied, .createFailed, .missingEntitlement("test"),
      .provisioningProfileExcludesHost,
    ]
    for error in errors {
      switch error {
      case .inputMonitoringDenied, .accessibilityDenied, .createFailed, .missingEntitlement,
        .provisioningProfileExcludesHost:
        break
      }
    }
  }

  @Test
  func mapsCoreHIDNilCreateToAccessibilityDeniedWhenPostEventNotGranted() {
    for accessibility: PermissionManager.AccessState in [.denied, .unknown] {
      let error = UserSpaceOutputDispatcher.mappedCoreHIDCreationFailure(
        provisioning: .includesHost,
        accessibility: accessibility
      )
      guard case .accessibilityDenied = error else {
        Issue.record("expected accessibilityDenied for accessibility \(accessibility)")
        return
      }
    }
  }

  @Test
  func mapsCoreHIDNilCreateToCreateFailedWhenAccessibilityGranted() {
    for provisioning: VirtualHIDProvisioningHost.Authorization in [
      .includesHost, .unrestricted, .unavailable,
    ] {
      let error = UserSpaceOutputDispatcher.mappedCoreHIDCreationFailure(
        provisioning: provisioning,
        accessibility: .granted
      )
      guard case .createFailed = error else {
        Issue.record("expected createFailed for provisioning \(provisioning)")
        return
      }
    }
  }

  @Test
  func mapsCoreHIDNilCreateToProvisioningExcludeBeforeAccessibility() {
    let error = UserSpaceOutputDispatcher.mappedCoreHIDCreationFailure(
      provisioning: .excludesHost,
      accessibility: .denied
    )
    guard case .provisioningProfileExcludesHost = error else {
      Issue.record("expected provisioningProfileExcludesHost")
      return
    }
  }

}
