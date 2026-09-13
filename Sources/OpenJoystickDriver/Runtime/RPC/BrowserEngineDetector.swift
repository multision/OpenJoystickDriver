import Foundation

enum BrowserEngine: Sendable {
  case blink
  case gecko
  case webkit
  case unknown
}

final class BrowserEngineDetector: @unchecked Sendable {
  private struct FileMetadata: Equatable {
    let modificationDate: Date?
    let size: UInt64?
  }

  private struct CacheKey: Equatable {
    let bundleVersion: String?
    let shortVersion: String?
    let info: FileMetadata
    let executable: FileMetadata
    let resources: FileMetadata
    let frameworks: FileMetadata
  }

  private struct CacheEntry {
    let key: CacheKey
    let engine: BrowserEngine?
  }

  private let fileManager: FileManager
  private let lock = NSLock()
  private var cache: [URL: CacheEntry] = [:]

  init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  func detect(bundleURL: URL) -> BrowserEngine? {
    let bundleURL = bundleURL.standardizedFileURL
    guard let info = information(at: bundleURL), isBrowser(info: info) else { return nil }
    let executableURL = executableURL(bundleURL: bundleURL, info: info)
    let key = cacheKey(bundleURL: bundleURL, info: info, executableURL: executableURL)
    if let cached = lock.withLock({ cache[bundleURL] }), cached.key == key { return cached.engine }

    let engine = inspect(bundleURL: bundleURL, executableURL: executableURL)
    lock.withLock { cache[bundleURL] = CacheEntry(key: key, engine: engine) }
    return engine
  }

  private func information(at bundleURL: URL) -> [String: Any]? {
    let url = bundleURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: url),
      let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let info = value as? [String: Any]
    else { return nil }
    return info
  }

  private func isBrowser(info: [String: Any]) -> Bool {
    let schemes =
      (info["CFBundleURLTypes"] as? [[String: Any]])?.flatMap {
        $0["CFBundleURLSchemes"] as? [String] ?? []
      }.map { $0.lowercased() } ?? []
    if schemes.contains("http") && schemes.contains("https") { return true }

    guard let types = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
    let webContentTypes: Set<String> = ["public.html", "public.xhtml", "public.url"]
    return types.contains { type in
      guard let role = type["CFBundleTypeRole"] as? String, role == "Viewer" || role == "Editor",
        let contentTypes = type["LSItemContentTypes"] as? [String]
      else { return false }
      return !webContentTypes.isDisjoint(with: contentTypes)
    }
  }

  private func executableURL(bundleURL: URL, info: [String: Any]) -> URL? {
    guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else {
      return nil
    }
    return bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
  }

  private func cacheKey(bundleURL: URL, info: [String: Any], executableURL: URL?) -> CacheKey {
    CacheKey(
      bundleVersion: info["CFBundleVersion"] as? String,
      shortVersion: info["CFBundleShortVersionString"] as? String,
      info: metadata(bundleURL.appendingPathComponent("Contents/Info.plist")),
      executable: metadata(executableURL),
      resources: metadata(bundleURL.appendingPathComponent("Contents/Resources")),
      frameworks: metadata(bundleURL.appendingPathComponent("Contents/Frameworks"))
    )
  }

  private func metadata(_ url: URL?) -> FileMetadata {
    guard let url,
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return FileMetadata(modificationDate: nil, size: nil) }
    return FileMetadata(
      modificationDate: values.contentModificationDate,
      size: values.fileSize.map(UInt64.init)
    )
  }

  private func inspect(bundleURL: URL, executableURL: URL?) -> BrowserEngine? {
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    guard
      let enumerator = fileManager.enumerator(
        at: contentsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }

    var hasICUData = false
    var hasResourcesPak = false
    var hasV8Snapshot = false
    var hasXUL = false
    var hasOmni = false
    var hasGeckoSection = false
    for case let url as URL in enumerator {
      switch url.lastPathComponent {
      case "icudtl.dat": hasICUData = true
      case "resources.pak": hasResourcesPak = true
      case "v8_context_snapshot.bin", "snapshot_blob.bin": hasV8Snapshot = true
      case "XUL": hasXUL = true
      case "omni.ja": hasOmni = true
      case "application.ini":
        if let contents = try? String(contentsOf: url, encoding: .utf8),
          contents.split(whereSeparator: \Character.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[Gecko]"
          })
        {
          hasGeckoSection = true
        }
      default:
        if url.lastPathComponent.hasPrefix("v8_context_snapshot.") && url.pathExtension == "bin" {
          hasV8Snapshot = true
        }
      }
    }

    var matches: [BrowserEngine] = []
    if hasICUData && hasResourcesPak && hasV8Snapshot { matches.append(.blink) }
    if hasXUL && hasOmni && hasGeckoSection { matches.append(.gecko) }
    if let executableURL, executableLinksWebKit(executableURL) { matches.append(.webkit) }
    return matches.count == 1 ? matches[0] : .unknown
  }

  private func executableLinksWebKit(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    return MachOLoadCommands.linkedLibraryPaths(in: data).contains {
      $0.contains("/WebKit.framework/") || $0.contains("/Safari.framework/")
    }
  }
}

enum MachOLoadCommands {
  private static let loadDylibCommands: Set<UInt32> = [0x0C, 0x8000_0018, 0x8000_001F, 0x8000_0023]

  static func linkedLibraryPaths(in data: Data) -> [String] {
    let bytes = [UInt8](data)
    guard bytes.count >= 4 else { return [] }
    let magic = readUInt32(bytes, at: 0, endian: .big)
    switch magic {
    case 0xCAFE_BABE: return fatPaths(bytes, is64: false, endian: .big)
    case 0xCAFE_BABF: return fatPaths(bytes, is64: true, endian: .big)
    case 0xBEBA_FECA: return fatPaths(bytes, is64: false, endian: .little)
    case 0xBFBA_FECA: return fatPaths(bytes, is64: true, endian: .little)
    default: return thinPaths(bytes, offset: 0)
    }
  }

  private enum Endian { case little, big }

  private static func fatPaths(_ bytes: [UInt8], is64: Bool, endian: Endian) -> [String] {
    guard let count = readUInt32(bytes, at: 4, endian: endian) else { return [] }
    let stride = is64 ? 32 : 20
    var paths: [String] = []
    for index in 0..<Int(count) {
      let arch = 8 + index * stride
      let sliceOffset: UInt64?
      if is64 {
        sliceOffset = readUInt64(bytes, at: arch + 8, endian: endian)
      } else {
        sliceOffset = readUInt32(bytes, at: arch + 8, endian: endian).map(UInt64.init)
      }
      guard let sliceOffset, let offset = Int(exactly: sliceOffset), offset < bytes.count else {
        continue
      }
      paths.append(contentsOf: thinPaths(bytes, offset: offset))
    }
    return paths
  }

  private static func thinPaths(_ bytes: [UInt8], offset: Int) -> [String] {
    guard let littleMagic = readUInt32(bytes, at: offset, endian: .little) else { return [] }
    let endian: Endian
    let headerSize: Int
    switch littleMagic {
    case 0xFEED_FACE:
      endian = .little
      headerSize = 28
    case 0xFEED_FACF:
      endian = .little
      headerSize = 32
    case 0xCEFA_EDFE:
      endian = .big
      headerSize = 28
    case 0xCFFA_EDFE:
      endian = .big
      headerSize = 32
    default: return []
    }
    guard let commandCount = readUInt32(bytes, at: offset + 16, endian: endian) else { return [] }
    var commandOffset = offset + headerSize
    var paths: [String] = []
    for _ in 0..<Int(commandCount) {
      guard let command = readUInt32(bytes, at: commandOffset, endian: endian),
        let commandSize = readUInt32(bytes, at: commandOffset + 4, endian: endian),
        commandSize >= 8, let next = Int(exactly: UInt64(commandOffset) + UInt64(commandSize)),
        next <= bytes.count
      else { break }
      if loadDylibCommands.contains(command),
        let nameOffset = readUInt32(bytes, at: commandOffset + 8, endian: endian),
        let nameStart = Int(exactly: UInt64(commandOffset) + UInt64(nameOffset)), nameStart < next,
        let end = bytes[nameStart..<next].firstIndex(of: 0),
        let path = String(bytes: bytes[nameStart..<end], encoding: .utf8)
      {
        paths.append(path)
      }
      commandOffset = next
    }
    return paths
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int, endian: Endian) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    let values = bytes[offset..<(offset + 4)].map(UInt32.init)
    switch endian {
    case .little: return values[0] | values[1] << 8 | values[2] << 16 | values[3] << 24
    case .big: return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3]
    }
  }

  private static func readUInt64(_ bytes: [UInt8], at offset: Int, endian: Endian) -> UInt64? {
    guard offset >= 0, offset + 8 <= bytes.count else { return nil }
    var result: UInt64 = 0
    for index in 0..<8 {
      let shift = endian == .little ? index * 8 : (7 - index) * 8
      result |= UInt64(bytes[offset + index]) << shift
    }
    return result
  }
}

final class BundledSDLDetector: @unchecked Sendable {
  private struct CacheKey: Equatable {
    let executables: Date?
    let frameworks: Date?
    let plugins: Date?
  }

  private struct CacheEntry {
    let key: CacheKey
    let usesSDL: Bool
  }

  private let fileManager: FileManager
  private let lock = NSLock()
  private var cache: [URL: CacheEntry] = [:]

  init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  func detect(bundleURL: URL) -> Bool {
    let bundleURL = bundleURL.standardizedFileURL
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    let roots = ["MacOS", "Frameworks", "PlugIns"].map(contentsURL.appendingPathComponent)
    let key = CacheKey(
      executables: modificationDate(roots[0]),
      frameworks: modificationDate(roots[1]),
      plugins: modificationDate(roots[2])
    )
    if let cached = lock.withLock({ cache[bundleURL] }), cached.key == key { return cached.usesSDL }

    let usesSDL = roots.contains(where: inspect)
    lock.withLock { cache[bundleURL] = CacheEntry(key: key, usesSDL: usesSDL) }
    return usesSDL
  }

  private func modificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  private func inspect(_ macOSURL: URL) -> Bool {
    guard
      let enumerator = fileManager.enumerator(
        at: macOSURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return false }
    for case let url as URL in enumerator {
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
      if MachOLoadCommands.linkedLibraryPaths(in: data).contains(where: Self.isSDLPath) {
        return true
      }
    }
    return false
  }

  private static func isSDLPath(_ path: String) -> Bool {
    let component = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    return component == "sdl2" || component == "sdl3" || component.hasPrefix("libsdl2.")
      || component.hasPrefix("libsdl3.")
  }
}
