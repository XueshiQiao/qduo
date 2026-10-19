import Foundation

/// Which names are allowed inside a backup zip. One bad name refuses the whole
/// file: a backup is a known shape, and a zip that also carries something else
/// is not one.
///
/// Allowed, under a single root folder `R`:
///
///     R/   R/manifest.json   R/config.json   R/keys.enc   R/history.sqlite
///     R/icons/   R/icons/<name>.png
///
/// `<name>.png` matches `^[A-Za-z0-9_-][A-Za-z0-9._-]*\.png$`, so it cannot
/// start with a dot. `..`, a leading `/`, a NUL and a backslash are refused
/// wherever they sit — those are the ways a name points outside the folder
/// `ditto` is about to extract into.
enum BackupEntryRules {

    private static let fileNames: Set<String> = ["manifest.json", "config.json", "keys.enc", "history.sqlite"]
    private static let iconPattern = #"^[A-Za-z0-9_-][A-Za-z0-9._-]*\.png$"#

    static func isIconFileName(_ name: String) -> Bool {
        name.range(of: iconPattern, options: .regularExpression) != nil
    }

    static func isAcceptable(entryName: String) -> Bool {
        if entryName.isEmpty || entryName.hasPrefix("/") || entryName.contains("\\") || entryName.contains("\u{0}") {
            return false
        }
        let directory = entryName.hasSuffix("/")
        let body = directory ? String(entryName.dropLast()) : entryName
        if body.isEmpty { return false }
        // Keep empty pieces (`R//x`) so they can be rejected below. `..` and `.`
        // as their own piece are the traversal, not a name that merely contains dots.
        let parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return false }
        switch parts.count {
        case 1:
            // The root folder. Some zips store it with a trailing slash and some
            // without. A loose file at the top (`manifest.json`) has a dot in
            // its name and is not a folder, so it does not get in this way.
            if directory { return true }
            return !parts[0].contains(".")
        case 2:
            if parts[1] == "icons" { return true }
            return !directory && fileNames.contains(parts[1])
        case 3:
            return !directory && parts[1] == "icons" && isIconFileName(parts[2])
        default:
            return false
        }
    }

    /// The single root folder, or nil when the list is empty, contains a name
    /// that is not acceptable, or names more than one root.
    static func rootDirectory(of entries: [String]) -> String? {
        guard !entries.isEmpty else { return nil }
        var root: String?
        for entry in entries {
            guard isAcceptable(entryName: entry) else { return nil }
            let body = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard let first = body.split(separator: "/").first, !first.isEmpty else { return nil }
            let name = String(first)
            if let root, root != name { return nil }
            root = name
        }
        return root
    }
}
