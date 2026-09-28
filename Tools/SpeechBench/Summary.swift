import Foundation

/// One table row per provider × text, over all attempts. Pass/fail thresholds
/// live here and are documented in README.md — change both together.
enum Summary {
    static let firstSoundGoodMs = 800.0
    static let firstSoundOkMs = 1500.0
    static let coverageNeeded = 0.9

    static func render(_ runs: [TTSRunMetrics], budget: Double) -> String {
        var out = "SUMMARY (median of successful attempts; cold = attempt 1 on a fresh connection)\n"
        out += "buffer budget \(Int(budget)) ms · first sound ✓ ≤ \(Int(firstSoundGoodMs)) ms, △ ≤ \(Int(firstSoundOkMs)) ms"
        out += " · highlight ✓ needs ≥ \(Int(coverageNeeded * 100))% coverage and no late marks\n\n"
        let header = ["provider", "text", "ok", "cold 1st-sound", "warm 1st-sound", "conn", "RTF", "stream RTF",
                      "realtime", "highlight", "verdict"]
        var rows: [[String]] = []
        let groups = Dictionary(grouping: runs) { "\($0.provider)\u{1}\($0.textId)" }
        for key in groups.keys.sorted() {
            let group = groups[key]!.sorted { $0.attempt < $1.attempt }
            let ok = group.filter { $0.error == nil && $0.firstAudioMs != nil }
            let first = group[0]
            guard !ok.isEmpty else {
                rows.append([first.provider, first.textId, "0/\(group.count)", "—", "—", "—", "—", "—", "—", "—",
                             "✗ \(first.error ?? "no audio")".prefix(60).description])
                continue
            }
            let cold = ok.first { $0.attempt == 1 }?.effectiveFirstSoundMs
            let warmRuns = ok.filter { $0.attempt > 1 }
            let warm = median((warmRuns.isEmpty ? ok : warmRuns).compactMap(\.effectiveFirstSoundMs))
            let conn = median(ok.compactMap(\.connectedMs))
            let rtf = median(ok.compactMap(\.rtf))
            let srtf = median(ok.compactMap(\.streamingRtf))
            let realtime = ok.allSatisfy { $0.keepsUpWithRealTime == true }
            let coverage = median(ok.compactMap(\.markCoverage))
            let late = ok.map(\.marksLate).max() ?? 0
            let worstLate = ok.compactMap(\.worstMarkLateMs).max() ?? 0
            let highlightOK = (coverage ?? 0) >= coverageNeeded && late == 0
            let highlight = coverage.map { String(format: "%.0f%%", $0 * 100) + (late > 0 ? String(format: " late×%d ≤%.0fms", late, worstLate) : "") } ?? "none"

            var verdict: [String] = []
            if !highlightOK { verdict.append("✗ highlight") }
            if !realtime { verdict.append("✗ realtime") }
            if let warm {
                verdict.append(warm <= firstSoundGoodMs ? "✓ fast" : warm <= firstSoundOkMs ? "△ slowish" : "✗ slow")
            }
            rows.append([first.provider, first.textId, "\(ok.count)/\(group.count)", ms(cold), ms(warm), ms(conn),
                         f2(rtf), f2(srtf), realtime ? "✓" : "✗", highlight, verdict.joined(separator: " ")])
        }
        out += table(header: header, rows: rows)
        return out
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    static func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "—" }
    static func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }

    static func table(header: [String], rows: [[String]]) -> String {
        func width(_ s: String) -> Int { s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) } }
        var widths = header.map(width)
        for row in rows { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], width(cell)) } }
        func render(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in c + String(repeating: " ", count: widths[i] - width(c)) }
                .joined(separator: "  ")
        }
        return ([render(header), widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")]
                + rows.map(render)).joined(separator: "\n") + "\n"
    }
}
