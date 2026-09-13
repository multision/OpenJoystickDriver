import CoreHID
import Foundation
import Testing

@testable import OpenJoystickDriverKit

struct CoreHIDAccessBackendTests {
  @available(macOS 15, *)
  @Test
  func ds4SubscribesOnlyToRawReportsAndForwardsOnlyReports() {
    let plan = CoreHIDInputSubscriptionPlan.resolve(
      for: DeviceIdentifier(vendorID: 0x054C, productID: 0x09CC)
    )

    #expect(plan.monitorsRawReports)
    #expect(!plan.subscribesToElement(usagePage: 0x01, usage: 0x30))
    #expect(!plan.subscribesToElement(usagePage: 0xFF00, usage: 1))
    #expect(plan.forwards(.rawReport))
    #expect(!plan.forwards(.elementUpdates))
  }

  @available(macOS 15, *)
  @Test
  func knownAndUnknownGenericHIDDevicesUseOnlySupportedElements() {
    let identifiers = [
      DeviceIdentifier(vendorID: 0x11C1, productID: 0x5600),
      DeviceIdentifier(vendorID: 0xFFFE, productID: 1),
    ]

    for identifier in identifiers {
      let plan = CoreHIDInputSubscriptionPlan.resolve(for: identifier)
      #expect(!plan.monitorsRawReports)
      #expect(plan.subscribesToElement(usagePage: 0x01, usage: 0x30))
      #expect(plan.subscribesToElement(usagePage: 0x09, usage: 1))
      #expect(!plan.subscribesToElement(usagePage: 0x01, usage: 0x36))
      #expect(!plan.subscribesToElement(usagePage: 0x0C, usage: 1))
      #expect(!plan.forwards(.rawReport))
      #expect(plan.forwards(.elementUpdates))
    }
  }

  @available(macOS 15, *)
  @Test
  func reportIdentifiersAreReconstructedOnlyWhenMissing() {
    let reportID = HIDReportID(rawValue: 1)
    #expect(
      CoreHIDInputReport.normalizedBytes(reportID: reportID, data: Data([2, 3])) == [1, 2, 3]
    )
    #expect(
      CoreHIDInputReport.normalizedBytes(reportID: reportID, data: Data([1, 2, 3])) == [1, 2, 3]
    )
    #expect(CoreHIDInputReport.normalizedBytes(reportID: nil, data: Data([2, 3])) == [2, 3])
  }

  @available(macOS 15, *)
  @Test
  func physicalSetReportUsesFiniteTimeoutAndCompletesFailures() async throws {
    struct ExpectedFailure: Error {}
    var receivedTimeout: Duration?

    let result = await CoreHIDPhysicalReportRequest.perform { timeout in
      receivedTimeout = timeout
      throw ExpectedFailure()
    }

    #expect(receivedTimeout == .seconds(2))
    if case .success = result { Issue.record("A failed set-report request unexpectedly succeeded") }
  }
}
