import Foundation
import Testing

@testable import OpenJoystickDriver

struct BrowserEngineDetectorTests {
  @Test
  func detectsBlinkGeckoAndWebKitFromBundleStructure() throws {
    let blink = try BrowserBundleFixture(fingerprint: .blink)
    let gecko = try BrowserBundleFixture(fingerprint: .gecko)
    let webkit = try BrowserBundleFixture(fingerprint: .webkit)
    defer {
      blink.remove()
      gecko.remove()
      webkit.remove()
    }
    let detector = BrowserEngineDetector()

    #expect(detector.detect(bundleURL: blink.url) == .blink)
    #expect(detector.detect(bundleURL: gecko.url) == .gecko)
    #expect(detector.detect(bundleURL: webkit.url) == .webkit)
  }

  @Test
  func rejectsAmbiguousAndNonBrowserBundles() throws {
    let ambiguous = try BrowserBundleFixture(fingerprint: .blink)
    let unknownBrowser = try BrowserBundleFixture(fingerprint: .none)
    let nonBrowser = try BrowserBundleFixture(fingerprint: .gecko, browserRole: false)
    defer {
      ambiguous.remove()
      unknownBrowser.remove()
      nonBrowser.remove()
    }
    try ambiguous.install(.gecko)
    let detector = BrowserEngineDetector()

    #expect(detector.detect(bundleURL: ambiguous.url) == .unknown)
    #expect(detector.detect(bundleURL: unknownBrowser.url) == .unknown)
    #expect(detector.detect(bundleURL: nonBrowser.url) == nil)
  }

  @Test
  func namesAndBundleIdentifiersDoNotAffectClassification() throws {
    let renamedBlink = try BrowserBundleFixture(
      fingerprint: .blink,
      identifier: "org.mozilla.firefox",
      displayName: "Safari"
    )
    let rebrandedGecko = try BrowserBundleFixture(
      fingerprint: .gecko,
      identifier: "com.google.Chrome",
      displayName: "Unrelated Browser"
    )
    defer {
      renamedBlink.remove()
      rebrandedGecko.remove()
    }
    let detector = BrowserEngineDetector()

    #expect(detector.detect(bundleURL: renamedBlink.url) == .blink)
    #expect(detector.detect(bundleURL: rebrandedGecko.url) == .gecko)
  }

  @Test
  func cacheInvalidatesWithBundleVersionAndResourceMetadata() throws {
    let fixture = try BrowserBundleFixture(fingerprint: .blink)
    defer { fixture.remove() }
    let detector = BrowserEngineDetector()
    #expect(detector.detect(bundleURL: fixture.url) == .blink)

    try fixture.remove(.blink)
    try fixture.install(.gecko)
    try fixture.writeInfo(version: "2")

    #expect(detector.detect(bundleURL: fixture.url) == .gecko)
  }

  @Test
  func detectsBundledSDLFromMachOLoadCommandsWithoutAnApplicationAllowlist() throws {
    let fixture = try BrowserBundleFixture(
      fingerprint: .linkedLibrary("@rpath/SDL3.framework/Versions/A/SDL3"),
      browserRole: false,
      identifier: "example.renamed.application",
      displayName: "Anything"
    )
    let historicalIdentityWithoutSDL = try BrowserBundleFixture(
      fingerprint: .linkedLibrary("@rpath/Unrelated.framework/Unrelated"),
      browserRole: false,
      identifier: "com.valvesoftware.Steam",
      displayName: "Steam"
    )
    defer {
      fixture.remove()
      historicalIdentityWithoutSDL.remove()
    }

    #expect(BundledSDLDetector().detect(bundleURL: fixture.url))
    #expect(!BundledSDLDetector().detect(bundleURL: historicalIdentityWithoutSDL.url))
    #expect(BrowserEngineDetector().detect(bundleURL: fixture.url) == nil)
  }

  @Test
  func detectsBundledSDLInFrameworksAndPluginsAndInvalidatesTheCache() throws {
    let fixture = try BrowserBundleFixture(fingerprint: .none, browserRole: false)
    defer { fixture.remove() }
    let detector = BundledSDLDetector()
    #expect(!detector.detect(bundleURL: fixture.url))

    try fixture.installLinkedLibrary(
      "@rpath/SDL2.framework/Versions/A/SDL2",
      at: "Contents/Frameworks/Game.framework/Versions/A/Game"
    )
    #expect(detector.detect(bundleURL: fixture.url))

    try fixture.removeItem(at: "Contents/Frameworks")
    #expect(!detector.detect(bundleURL: fixture.url))
    try fixture.installLinkedLibrary(
      "@rpath/libSDL3.dylib",
      at: "Contents/PlugIns/Input.plugin/Input"
    )
    #expect(detector.detect(bundleURL: fixture.url))
  }
}

private final class BrowserBundleFixture {
  enum Fingerprint {
    case blink
    case gecko
    case webkit
    case linkedLibrary(String)
    case none
  }

  let url: URL
  private let identifier: String
  private let displayName: String
  private let browserRole: Bool

  init(
    fingerprint: Fingerprint,
    browserRole: Bool = true,
    identifier: String = "example.fixture",
    displayName: String = "Fixture"
  ) throws {
    self.identifier = identifier
    self.displayName = displayName
    self.browserRole = browserRole
    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("app")
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("Contents/Resources"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("Contents/MacOS"),
      withIntermediateDirectories: true
    )
    try writeInfo(version: "1")
    try install(fingerprint)
  }

  func writeInfo(version: String) throws {
    var info: [String: Any] = [
      "CFBundleExecutable": "FixtureExecutable", "CFBundleIdentifier": identifier,
      "CFBundleDisplayName": displayName, "CFBundleVersion": version,
    ]
    if browserRole { info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["http", "https"]]] }
    let data = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .binary,
      options: 0
    )
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
  }

  func install(_ fingerprint: Fingerprint) throws {
    let resources = url.appendingPathComponent("Contents/Resources")
    let executable = url.appendingPathComponent("Contents/MacOS/FixtureExecutable")
    switch fingerprint {
    case .blink:
      for name in ["icudtl.dat", "resources.pak", "v8_context_snapshot.arm64.bin"] {
        try Data([1]).write(to: resources.appendingPathComponent(name))
      }
    case .gecko:
      try Data([1]).write(to: resources.appendingPathComponent("XUL"))
      try Data([1]).write(to: resources.appendingPathComponent("omni.ja"))
      try "[App]\nName=Fixture\n[Gecko]\nMinVersion=1\n".write(
        to: resources.appendingPathComponent("application.ini"),
        atomically: true,
        encoding: .utf8
      )
    case .webkit:
      try Self.machO(linkedLibrary: "/System/Library/Frameworks/WebKit.framework/WebKit").write(
        to: executable
      )
    case .linkedLibrary(let path): try Self.machO(linkedLibrary: path).write(to: executable)
    case .none: break
    }
  }

  func remove(_ fingerprint: Fingerprint) throws {
    let resources = url.appendingPathComponent("Contents/Resources")
    switch fingerprint {
    case .blink:
      for name in ["icudtl.dat", "resources.pak", "v8_context_snapshot.arm64.bin"] {
        try? FileManager.default.removeItem(at: resources.appendingPathComponent(name))
      }
    case .gecko:
      for name in ["XUL", "omni.ja", "application.ini"] {
        try? FileManager.default.removeItem(at: resources.appendingPathComponent(name))
      }
    case .webkit, .linkedLibrary:
      try? FileManager.default.removeItem(
        at: url.appendingPathComponent("Contents/MacOS/FixtureExecutable")
      )
    case .none: break
    }
  }

  func installLinkedLibrary(_ library: String, at relativePath: String) throws {
    let destination = url.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Self.machO(linkedLibrary: library).write(to: destination)
  }

  func removeItem(at relativePath: String) throws {
    try FileManager.default.removeItem(at: url.appendingPathComponent(relativePath))
  }

  func remove() { try? FileManager.default.removeItem(at: url) }

  private static func machO(linkedLibrary path: String) -> Data {
    let name = Array(path.utf8) + [0]
    let commandSize = (24 + name.count + 7) & ~7
    var bytes = [UInt8](repeating: 0, count: 32 + commandSize)
    write(0xFEED_FACF, to: &bytes, at: 0)
    write(1, to: &bytes, at: 16)
    write(UInt32(commandSize), to: &bytes, at: 20)
    write(0x0C, to: &bytes, at: 32)
    write(UInt32(commandSize), to: &bytes, at: 36)
    write(24, to: &bytes, at: 40)
    bytes.replaceSubrange(56..<(56 + name.count), with: name)
    return Data(bytes)
  }

  private static func write(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
  }
}
