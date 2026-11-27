import Foundation

/// Checks a config document against `ConfigSchema` — the same schema the app
/// writes beside the config file for editors.
///
/// Only the keywords that schema uses are understood: `type`, `enum`,
/// `minimum`, `maximum`, `pattern`, `required`, `properties`, `items` and a
/// local `$ref` into `#/definitions/`. That is deliberate. Checking against the
/// schema itself, rather than a second hand-written list of keys and values,
/// means a setting added to the schema is checked the day it is added, and the
/// two can never disagree about what is allowed.
///
/// The schema says `additionalProperties: true` everywhere, because the app
/// keeps keys it does not know. A key that is not in the schema is still
/// reported — as `unknownKey` — because the usual reason for one is a typo
/// (`hotkey` for `hotKey`), which the app would keep and silently ignore.
struct SchemaCheck {

    struct Finding: Equatable {
        enum Kind: Equatable {
            /// The value breaks the schema: wrong type, not an allowed value,
            /// out of range, missing a required key.
            case violation
            /// A key the schema does not describe. The app keeps it and does
            /// nothing with it.
            case unknownKey
        }
        let kind: Kind
        /// Where it is, written the way a person would point at it:
        /// `popup.hotKey`, `actions[2].children[0].kind`.
        let path: String
        let message: String
    }

    private let root: [String: Any]

    init?(schemaJSON: String = ConfigSchema.json) {
        guard let data = schemaJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        root = object
    }

    func check(_ document: JSONValue) -> [Finding] {
        var findings: [Finding] = []
        check(document, against: root, path: "", into: &findings)
        return findings
    }

    // MARK: - Walking

    private func resolve(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/definitions/") else { return schema }
        let name = String(ref.dropFirst("#/definitions/".count))
        let definitions = root["definitions"] as? [String: Any]
        return (definitions?[name] as? [String: Any]) ?? [:]
    }

    private func check(_ value: JSONValue, against rawSchema: [String: Any], path: String,
                       into findings: inout [Finding]) {
        let schema = resolve(rawSchema)
        let shown = path.isEmpty ? "(the top level)" : path

        if let types = Self.types(schema["type"]), !types.contains(where: { Self.value(value, is: $0) }) {
            findings.append(Finding(kind: .violation, path: shown,
                                    message: "should be \(types.joined(separator: " or ")), found \(Self.describe(value))"))
            return   // nothing else about a value of the wrong type is worth saying
        }

        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { Self.equal(value, $0) }) {
            let list = allowed.map(Self.literal).joined(separator: ", ")
            findings.append(Finding(kind: .violation, path: shown,
                                    message: "\(Self.describe(value)) is not one of the allowed values: \(list)"))
        }

        if case .number(let n) = value {
            if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, n < minimum {
                findings.append(Finding(kind: .violation, path: shown,
                                        message: "\(Self.number(n)) is below the minimum \(Self.number(minimum))"))
            }
            if let maximum = (schema["maximum"] as? NSNumber)?.doubleValue, n > maximum {
                findings.append(Finding(kind: .violation, path: shown,
                                        message: "\(Self.number(n)) is above the maximum \(Self.number(maximum))"))
            }
        }

        if case .string(let s) = value, let pattern = schema["pattern"] as? String,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
            findings.append(Finding(kind: .violation, path: shown,
                                    message: "\"\(s)\" does not have the allowed form (\(pattern))"))
        }

        if case .object(let object) = value {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for name in (schema["required"] as? [String] ?? []) where object[name] == nil {
                findings.append(Finding(kind: .violation, path: shown, message: "is missing the required key \"\(name)\""))
            }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let childSchema = properties[key] as? [String: Any] {
                    check(child, against: childSchema, path: childPath, into: &findings)
                } else if !properties.isEmpty {
                    var message = "is not a key the app knows; it is kept but does nothing"
                    if let close = Self.closest(to: key, in: Array(properties.keys)) {
                        message += " (did you mean \"\(close)\"?)"
                    }
                    findings.append(Finding(kind: .unknownKey, path: childPath, message: message))
                }
            }
        }

        if case .array(let items) = value, let itemSchema = schema["items"] as? [String: Any] {
            for (i, item) in items.enumerated() {
                check(item, against: itemSchema, path: "\(path)[\(i)]", into: &findings)
            }
        }
    }

    // MARK: - Helpers

    private static func types(_ raw: Any?) -> [String]? {
        if let one = raw as? String { return [one] }
        return raw as? [String]
    }

    private static func value(_ value: JSONValue, is type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n == n.rounded() && n.isFinite
        default:
            return false
        }
    }

    private static func equal(_ value: JSONValue, _ literal: Any) -> Bool {
        switch value {
        case .null:            return literal is NSNull
        case .string(let s):   return (literal as? String) == s
        case .bool(let b):     return (literal as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue == b } ?? false
        case .number(let n):   return (literal as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == n } ?? false
        default:               return false
        }
    }

    private static func literal(_ any: Any) -> String {
        if any is NSNull { return "null" }
        if let s = any as? String { return "\"\(s)\"" }
        return "\(any)"
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null:            return "null"
        case .bool(let b):     return b ? "true" : "false"
        case .number(let n):   return number(n)
        case .string(let s):   return "\"\(s)\""
        case .array:           return "an array"
        case .object:          return "an object"
        }
    }

    private static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    /// The known key a typo most likely meant: same letters ignoring case, or
    /// at most two edits away.
    static func closest(to key: String, in candidates: [String]) -> String? {
        if let same = candidates.first(where: { $0.lowercased() == key.lowercased() }) { return same }
        let scored = candidates.map { ($0, editDistance($0.lowercased(), key.lowercased())) }
            .filter { $0.1 <= 2 }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return scored.first?.0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
