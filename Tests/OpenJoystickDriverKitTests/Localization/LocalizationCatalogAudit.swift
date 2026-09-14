import Foundation

@testable import OpenJoystickDriverKit

enum LocalizationCatalogAudit {
  static func keys(for localization: String) -> Set<String> {
    var result = stringsData(for: localization).map { Set(parseStrings($0).keys) } ?? []
    result.formUnion(stringsDictionary(for: localization).keys)
    return result
  }

  static func placeholderSignatures(for localization: String) -> [String: [String]] {
    var result =
      stringsData(for: localization).map {
        parseStrings($0).mapValues { placeholderSignature(in: $0) }
      } ?? [:]
    for (key, value) in stringsDictionary(for: localization) {
      var strings: [String] = []
      collectPluralStrings(value, into: &strings)
      result[key] = strings.flatMap { placeholderSignature(in: $0) }.sorted()
    }
    return result
  }

  static func pluralCategories(for localization: String) -> [String: Set<String>] {
    stringsDictionary(for: localization).mapValues(collectPluralCategories)
  }

  private static func resourceData(for localization: String, extension: String) -> Data? {
    guard
      let path = Localization.moduleBundle.path(
        forResource: "Localizable",
        ofType: `extension`,
        inDirectory: "\(localization).lproj"
      )
    else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: path))
  }

  private static func stringsData(for localization: String) -> Data? {
    resourceData(for: localization, extension: "strings")
  }

  private static func stringsDictionary(for localization: String) -> [String: Any] {
    guard let data = resourceData(for: localization, extension: "stringsdict"),
      let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = value as? [String: Any]
    else { return [:] }
    return dictionary
  }

  private static func parseStrings(_ data: Data) -> [String: String] {
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    let pattern = #""((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var result: [String: String] = [:]
    expression.enumerateMatches(in: text, range: range) { match, _, _ in
      guard let match, let keyRange = Range(match.range(at: 1), in: text),
        let valueRange = Range(match.range(at: 2), in: text)
      else { return }
      result[String(text[keyRange])] = String(text[valueRange])
    }
    return result
  }

  private static func collectPluralStrings(_ value: Any, into strings: inout [String]) {
    if let string = value as? String {
      strings.append(string)
      return
    }
    guard let dictionary = value as? [String: Any] else { return }
    for (key, child) in dictionary where !key.hasPrefix("NSString") {
      collectPluralStrings(child, into: &strings)
    }
  }

  private static func collectPluralCategories(_ value: Any) -> Set<String> {
    guard let dictionary = value as? [String: Any] else { return [] }
    if dictionary["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" {
      return Set(dictionary.keys.filter { !$0.hasPrefix("NSString") })
    }
    return dictionary.values.reduce(into: Set<String>()) { result, child in
      result.formUnion(collectPluralCategories(child))
    }
  }

  private static func placeholderSignature(in value: String) -> [String] {
    let pattern = #"%(?:[0-9]+\$)?[-+0-9.#]*[@a-zA-Z]"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      Range(match.range, in: value).map { String(value[$0]) }
    }
  }
}
