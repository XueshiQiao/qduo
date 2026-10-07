import Foundation

/// Running an action from another app through a URL (issue #15):
///
///     qduo://run/<name>?text=<the text, percent-encoded>
///
/// Any app can open such a URL, and so can a link on a web page. So nothing is
/// callable until the user turns it on for one action and gives that action a
/// name (`PopBarActionConfig.urlName`); the URL can reach that action and no
/// other. There is no switch that opens them all.
enum ActionURL {

    struct Request: Equatable {
        /// The action's `urlName`, lower-cased.
        let name: String
        let text: String
    }

    /// The one command there is.
    static let command = "run"

    /// Longer text than this is refused rather than cut: a caller that sent half
    /// a document and got back a translation of some of it would not know.
    static let maxTextLength = 200_000

    /// `<scheme>://run/<name>?text=…` → the request. nil for anything else:
    /// another scheme, another command, no name, a name that could not be one.
    /// `text` may be absent or empty here; the caller says so to the user.
    static func parse(_ url: URL, scheme: String) -> Request? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme.lowercased(),
              parts.host?.lowercased() == command else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 1 else { return nil }
        let name = path[0].lowercased()
        guard isValidName(name) else { return nil }
        let text = parts.queryItems?.first { $0.name == "text" }?.value ?? ""
        return Request(name: name, text: text)
    }

    /// A name is what gets typed into another app's settings, so it is kept to
    /// what never needs escaping in a URL: lower-case letters, digits, "-" and
    /// "_", starting with a letter or digit, at most 40 characters.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 40 else { return false }
        func plain(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return plain(first) && name.unicodeScalars.allSatisfy { plain($0) || $0 == "-" || $0 == "_" }
    }

    /// What is typed, turned into a name as far as it can be: lower case, spaces
    /// to "-", everything else that is not allowed dropped.
    static func sanitized(_ raw: String) -> String {
        var out = ""
        for scalar in raw.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == " " {
                if !out.isEmpty, !out.hasSuffix("-") { out += "-" }
            }
        }
        while out.hasPrefix("-") || out.hasPrefix("_") { out.removeFirst() }
        return String(out.prefix(40))
    }

    /// A name to start from when the user turns the URL on for an action: from
    /// its title when the title has anything a name can use ("Ask ChatGPT" →
    /// "ask-chatgpt"), else from what it does ("翻译", an AI action → "ai"), with
    /// a number added when another action already has it.
    static func suggestedName(title: String, kind: String, taken: Set<String>) -> String {
        var base = sanitized(title)
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty { base = sanitized(kind) }
        if base.isEmpty { base = "action" }
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The names already given out, lower-cased, leaving out one action (the one
    /// being edited, which may keep its own).
    static func takenNames(in list: [PopBarActionConfig], except id: String? = nil) -> Set<String> {
        var names = Set<String>()
        for action in list.flatMap({ [$0] + $0.children }) where action.id != id {
            if let name = action.urlName?.lowercased(), !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// The action a name stands for: top level or inside a group. A group that
    /// only unfolds has nothing to run, and an action from a newer build cannot
    /// be run here.
    static func action(named name: String, in list: [PopBarActionConfig]) -> PopBarActionConfig? {
        let wanted = name.lowercased()
        return list.flatMap { [$0] + $0.children }.first {
            $0.urlName?.lowercased() == wanted && $0.kind != .group && !$0.isUnsupported
        }
    }

    /// The URL another app would open, for showing in the editor.
    static func example(scheme: String, name: String, text: String) -> String {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = command
        parts.path = "/" + name
        parts.queryItems = [URLQueryItem(name: "text", value: text)]
        return parts.string ?? "\(scheme)://\(command)/\(name)?text="
    }
}
