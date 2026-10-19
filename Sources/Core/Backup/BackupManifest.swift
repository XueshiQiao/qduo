import Foundation

/// What one backup contains. Written as `manifest.json` at the top of the zip's
/// single folder. A backup made by a newer build has a higher `format`; this
/// build refuses to import that rather than guessing.
struct BackupManifest: Codable, Equatable {

    static let format = 1

    /// The pieces a person can tick. The file only records the ones that were
    /// actually exported — see `Parts`.
    enum Part: String, CaseIterable, Codable {
        case config, icons, keys, history
    }

    struct AppInfo: Codable, Equatable {
        var version: String
        var build: String
        var bundleID: String
    }

    struct ConfigPart: Codable, Equatable { var file: String }
    struct IconsPart: Codable, Equatable { var dir: String; var count: Int }
    struct KeysPart: Codable, Equatable { var file: String; var encrypted: Bool; var count: Int }
    struct HistoryPart: Codable, Equatable { var file: String; var records: Int }

    /// Absent parts are left out of the JSON. An optional with no value encodes
    /// as a missing key, which is what "this backup does not contain icons" means.
    struct Parts: Codable, Equatable {
        var config: ConfigPart? = nil
        var icons: IconsPart? = nil
        var keys: KeysPart? = nil
        var history: HistoryPart? = nil
    }

    var format: Int
    var app: AppInfo
    /// ISO 8601, UTC. Part of the key that seals `keys.enc`, so that file cannot
    /// be moved into a different backup and still open.
    var exportedAt: String
    var parts: Parts

    var availableParts: Set<Part> {
        var set = Set<Part>()
        if parts.config != nil { set.insert(.config) }
        if parts.icons != nil { set.insert(.icons) }
        if parts.keys != nil { set.insert(.keys) }
        if parts.history != nil { set.insert(.history) }
        return set
    }

    var isNewerThanThisBuild: Bool { format > Self.format }

    /// The extra authenticated data for `keys.enc`: the format number and the
    /// timestamp, in that order, separated by a byte that neither one contains.
    static func keysAAD(format: Int, exportedAt: String) -> Data {
        var data = Data()
        data.append(contentsOf: String(format).utf8)
        data.append(0)
        data.append(contentsOf: exportedAt.utf8)
        return data
    }

    var keysAAD: Data { Self.keysAAD(format: format, exportedAt: exportedAt) }

    static func exportedAtString(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
