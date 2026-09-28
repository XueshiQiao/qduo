import Foundation

enum Bench {

    struct Text { let id: String; let text: String }

    static func run(configPath: String, only: Set<String>?, texts textFilter: Set<String>?,
                    repeatOverride: Int?) async {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            fail("no config at \(configPath) — run `speech-bench init` first")
        }
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { fail("config is not valid JSON: \(error)") }

        let repeats = max(1, repeatOverride ?? root[path: "repeat"]?.doubleValue.map { Int($0) } ?? 3)
        let budget = root[path: "bufferBudgetMs"]?.doubleValue ?? 300
        let texts: [Text] = (root[path: "texts"]?.arrayValue ?? []).compactMap { item in
            guard let id = item[path: "id"]?.stringValue, let text = item[path: "text"]?.stringValue,
                  textFilter?.contains(id) ?? true else { return nil }
            return Text(id: id, text: text)
        }
        guard !texts.isEmpty else { fail("no texts selected") }

        let providers = (root[path: "providers"]?.objectValue ?? [:])
            .filter { id, value in
                if let only { return only.contains(id) }
                return value[path: "enabled"]?.boolValue ?? false
            }
            .sorted { $0.key < $1.key }
        guard !providers.isEmpty else { fail("no provider enabled — set \"enabled\": true in \(configPath)") }

        let outDir = outputDirectory(root)
        print("results → \(outDir.path)\n")

        var all: [TTSRunMetrics] = []
        for (id, value) in providers {
            // An entry may name its engine, so one provider can be measured
            // twice with different models ("elevenlabs-v3": {"engine": "elevenlabs", …}).
            let settings = TTSSettings(value.objectValue ?? [:])
            let engineId = settings.string("engine", id)
            if TTSEngineRegistry.paused.contains(engineId) { print("⏸ \(id) is paused, skipped\n"); continue }
            guard let make = TTSEngineRegistry.all[engineId] else { print("⚠︎ unknown engine \(engineId) for \(id), skipped"); continue }
            let engine = make(settings)
            let label = settings.string("label", id)
            var skip = false
            print("━━ \(label)  [\(type(of: engine).descriptor.transport), marks: \(type(of: engine).descriptor.marks.rawValue)]")
            for text in texts where !skip {
                for attempt in 1...repeats {
                    // Attempt 1 opens a fresh connection (what the first read
                    // after launch costs); later attempts reuse it.
                    if attempt == 1 { TTSNetwork.resetSession() }
                    let m = await measure(engine: engine, provider: id, text: text, attempt: attempt,
                                          budget: budget, saveTo: attempt == 1 ? outDir : nil)
                    all.append(m)
                    print(line(m))
                    // A config or auth error will not fix itself: stop this provider.
                    if let error = m.error, attempt == 1 {
                        skip = error.hasPrefix("missing setting") || error.contains("HTTP 401") || error.contains("HTTP 403")
                        break
                    }
                }
            }
            print("")
        }

        let summary = Summary.render(all, budget: budget)
        print(summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: outDir.appendingPathComponent("runs.json"))
        try? Data(summary.utf8).write(to: outDir.appendingPathComponent("summary.txt"))
    }

    static func measure(engine: TTSEngine, provider: String, text: Text, attempt: Int,
                        budget: Double, saveTo dir: URL?) async -> TTSRunMetrics {
        let start = DispatchTime.now()
        let stream: TTSStream
        do { stream = try engine.synthesize(TTSRequest(text: text.text)) }
        catch {
            var m = TTSRunMetrics(); m.provider = provider; m.textId = text.id; m.attempt = attempt
            m.error = error.localizedDescription
            return m
        }
        var recorder = TTSRunRecorder(format: stream.format, start: start)
        await recorder.drain(stream)
        let m = recorder.metrics(provider: provider, textId: text.id, text: text.text,
                                 attempt: attempt, bufferBudgetMs: budget)
        if let dir {
            let base = dir.appendingPathComponent("\(provider)-\(text.id)")
            try? recorder.wav().write(to: base.appendingPathExtension("wav"))
            try? MarksDump.render(text: text.text, recorder: recorder)
                .write(to: base.appendingPathExtension("marks.txt"), atomically: true, encoding: .utf8)
            if !recorder.notes.isEmpty {
                try? recorder.notes.joined(separator: "\n")
                    .write(to: base.appendingPathExtension("notes.txt"), atomically: true, encoding: .utf8)
            }
        }
        return m
    }

    static func outputDirectory(_ root: JSONValue) -> URL {
        let configured = root[path: "outputDir"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = configured.isEmpty
            ? FileManager.default.currentDirectoryPath + "/build/speech-bench-results"
            : (configured as NSString).expandingTildeInPath
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = URL(fileURLWithPath: base).appendingPathComponent(stamp.string(from: Date()))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func line(_ m: TTSRunMetrics) -> String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%5.0f", $0) } ?? "    —" }
        if let error = m.error { return "  \(m.textId) #\(m.attempt)  ✗ \(error)" }
        let keeps = m.keepsUpWithRealTime == true ? "✓" : "✗"
        let cov = m.markCoverage.map { String(format: "%3.0f%%", $0 * 100) } ?? "  —"
        return "  \(m.textId.padding(toLength: 10, withPad: " ", startingAt: 0)) #\(m.attempt)"
            + "  conn\(ms(m.connectedMs))  1st-audio\(ms(m.firstAudioMs))  1st-mark\(ms(m.firstMarkMs))"
            + "  no-stall-start\(ms(m.noStallStartMs))  total\(ms(m.totalMs))"
            + String(format: "  audio %4.1fs  RTF %.2f", m.audioSec, m.rtf ?? 0)
            + "  realtime \(keeps)  marks \(cov) late \(m.marksLate)"
            + (m.reusedConnection == true ? "  (warm)" : "")
    }
}

/// A human-readable listing of every mark: when it arrived, when it plays,
/// what the provider said, and what it was matched to in the text. The way to
/// eyeball whether highlighting would land on the right word.
enum MarksDump {
    static func render(text: String, recorder: TTSRunRecorder) -> String {
        let ns = text as NSString
        var out = "arrive_ms  play_s  end_s   provider-word  →  matched-text\n"
        for a in recorder.marks {
            let m = a.mark
            let matched = m.location.map { ns.substring(with: NSRange(location: $0, length: m.length)) } ?? "✗ NOT FOUND"
            out += String(format: "%8.0f  %6.2f  %6.2f   ", a.arrivalMs,
                          recorder.format.seconds(frames: m.startFrame), recorder.format.seconds(frames: m.endFrame))
            out += "\(m.spoken)  →  \(matched)\n"
        }
        return out
    }
}
