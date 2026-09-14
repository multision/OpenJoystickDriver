import Foundation
import Testing

@testable import OpenJoystickDriverKit

@Suite("Build identity")
struct BuildIdentityTests {
  @Test
  func JSONUsesTypedLowerCamelFields() throws {
    let identity = BuildIdentity(
      semanticVersion: "0.5.0-beta.4",
      appBundleVersion: "1.4.89",
      sourceCommit: String(repeating: "a", count: 40),
      sourceState: .clean
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
    )

    #expect(object["semanticVersion"] as? String == "0.5.0-beta.4")
    #expect(object["appBundleVersion"] as? String == "1.4.89")
    #expect(object["sourceState"] as? String == "clean")
  }

  @Test
  func statusJSONExposesBuildIdentityAtTheTopLevel() throws {
    let identity = BuildIdentity(
      semanticVersion: "0.5.0-beta.4",
      appBundleVersion: "1.4.89",
      sourceCommit: String(repeating: "b", count: 40),
      sourceState: .clean
    )
    let status = ApplicationServiceStatusPayload(
      buildIdentity: identity,
      inputMonitoring: "granted",
      accessibility: "granted",
      connectedDevices: []
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
    )

    let encodedIdentity = try #require(object["buildIdentity"] as? [String: Any])
    #expect(encodedIdentity["sourceCommit"] as? String == identity.sourceCommit)
  }
}
