import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

struct StatusConsumptionTests {
  @Test
  func cliTextConsumesTheSameTypedErrorAndPermissionSemantics() {
    let payload = ApplicationServiceStatusPayload(
      inputMonitoring: "unknown",
      accessibility: "denied",
      connectedDevices: [],
      userSpaceVirtualDeviceEnabled: false,
      userSpaceVirtualDeviceStatus: "error: creation failed",
      compatibilityIdentity: CompatibilityIdentity.sdl2_3.rawValue
    )
    let snapshot = RuntimeStatusSnapshot(payload: payload)

    let lines = RuntimeStatusText.payloadLines(snapshot)

    #expect(lines.contains("  Input Monitoring : [UNKNOWN] unknown"))
    #expect(lines.contains("  Accessibility    : [DENIED] denied"))
    #expect(lines.contains("  backend   : error"))
    #expect(lines.contains("  status    : error: creation failed"))
    #expect(lines.contains("  identity  : sdl2-3"))
  }

  @Test
  func directModeRetainsLocallyObservedPermissionTruth() {
    let permissions = StatusPermissions(inputMonitoring: .granted, accessibility: .denied)
    let lines = RuntimeStatusText.directModeLines(permissions)

    #expect(lines.contains("  Input Monitoring : [OK] granted"))
    #expect(lines.contains("  Accessibility    : [DENIED] denied"))
    #expect(lines.contains("  Overall          : [ACTION] blocked"))
    #expect(!lines.contains { $0.contains("[UNAVAILABLE]") })
  }

  @Test
  func controllerStatusIncludesBatteryTelemetry() {
    let device = ApplicationServiceDeviceDescription(
      name: "DualShock 4",
      vendorID: 0x054C,
      productID: 0x09CC,
      parser: "DS4",
      connection: "USB",
      serialNumber: nil,
      battery: ControllerBatteryTelemetry(
        percentage: 100,
        chargingState: .full,
        cableState: .connected
      )
    )
    let payload = ApplicationServiceStatusPayload(
      inputMonitoring: "granted",
      accessibility: "granted",
      connectedDevices: [device]
    )

    let lines = RuntimeStatusText.payloadLines(RuntimeStatusSnapshot(payload: payload))

    #expect(lines.contains("    battery=100% status=full cable=connected"))
    #expect(
      ApplicationServiceServer.deviceDescriptionLine(device).contains(
        "battery=100%,full,cable-connected"
      )
    )
  }

  @Test
  func batteryDescriptionsDistinguishRangesExactValuesAndUnknownValues() {
    let range = controller(
      battery: ControllerBatteryTelemetry(
        percentage: 95,
        percentageRange: 90...99,
        chargingState: .charging,
        cableState: .connected
      )
    )
    let exact = controller(
      battery: ControllerBatteryTelemetry(
        percentage: 100,
        chargingState: .full,
        cableState: .connected
      )
    )
    let unknown = controller(
      battery: ControllerBatteryTelemetry(
        percentage: nil,
        chargingState: .unknown,
        cableState: .disconnected
      )
    )

    #expect(ApplicationServiceServer.deviceDescriptionLine(range).contains("battery=90–99%"))
    #expect(ApplicationServiceServer.deviceDescriptionLine(exact).contains("battery=100%"))
    #expect(ApplicationServiceServer.deviceDescriptionLine(unknown).contains("battery=unknown"))
  }

  private func controller(
    battery: ControllerBatteryTelemetry
  ) -> ApplicationServiceDeviceDescription {
    ApplicationServiceDeviceDescription(
      name: "DualShock 4",
      vendorID: 0x054C,
      productID: 0x09CC,
      parser: "DS4",
      connection: "USB",
      serialNumber: nil,
      battery: battery
    )
  }
}
