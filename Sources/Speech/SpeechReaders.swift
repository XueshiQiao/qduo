import Foundation
import SwiftUI

/// A voice the user set up to read text aloud: one provider, model, voice and
/// speed, under a name the user chose ("Qwen 女声", "Japanese"). Speak actions
/// pick a reader by `id`; the macOS system voice is always available as the
/// reader `SpeechReader.systemID` and is not stored.
///
/// Only providers that meet all three hard requirements (streaming, first sound
/// ≤ 800 ms, word timings in real time) are offered — see
/// design/cloud-tts/provider-decisions.html.
struct SpeechReader: Identifiable, Equatable {
    static let systemID = "system"

    var id: String
    var name: String
    /// A `TTSEngineRegistry` id, e.g. "qwen-audio".
    var engine: String
    var model: String
    var voice: String
    /// Playback speed as a multiplier, 1.0 = normal.
    var speed: Double
    /// "cn" (mainland endpoint) or "intl" (international endpoint).
    var region: String

    var isSystem: Bool { id == Self.systemID }

    static func system() -> SpeechReader {
        SpeechReader(id: systemID, name: L("speech.reader.system"), engine: "system", model: "", voice: "",
                     speed: 1, region: "")
    }

    /// Settings handed to the engine adapter, with the provider's API key.
    func engineSettings(apiKey: String) -> TTSSettings {
        TTSSettings([
            "apiKey": .string(apiKey), "model": .string(model), "voice": .string(voice),
            "speed": .number(speed), "region": .string(region),
        ])
    }

    /// What decides whether two reads sound the same — the cache key's reader half.
    var cacheIdentity: String { [engine, model, voice, String(format: "%.2f", speed), region].joined(separator: "|") }

    // MARK: - Config file

    init(id: String, name: String, engine: String, model: String, voice: String, speed: Double, region: String) {
        self.id = id; self.name = name; self.engine = engine; self.model = model
        self.voice = voice; self.speed = speed; self.region = region
    }

    /// From one entry of `speech.readers`. Unknown keys are kept in `extra` so a
    /// hand-edited or newer file loses nothing when the app writes it back.
    init?(json: JSONValue) {
        guard let o = json.objectValue, let id = o["id"]?.stringValue, !id.isEmpty, id != Self.systemID,
              let engine = o["engine"]?.stringValue, SpeechProviders.find(engine) != nil else { return nil }
        let provider = SpeechProviders.find(engine)!
        self.id = id
        self.name = o["name"]?.stringValue ?? provider.displayName
        self.engine = engine
        self.model = o["model"]?.stringValue ?? provider.defaultModel
        self.voice = o["voice"]?.stringValue ?? provider.defaultVoice
        self.speed = min(2, max(0.5, o["speed"]?.doubleValue ?? 1))
        self.region = o["region"]?.stringValue ?? "cn"
        self.extra = o.filter { !Self.ownKeys.contains($0.key) }
    }

    private static let ownKeys: Set<String> = ["id", "name", "engine", "model", "voice", "speed", "region"]
    private var extra: [String: JSONValue] = [:]

    var json: JSONValue {
        var o = extra
        o["id"] = .string(id); o["name"] = .string(name); o["engine"] = .string(engine)
        o["model"] = .string(model); o["voice"] = .string(voice); o["speed"] = .number(speed)
        o["region"] = .string(region)
        return .object(o)
    }
}

/// The providers a reader can use, with what the settings page offers for each.
struct SpeechProvider {
    struct Voice: Identifiable { let id: String; let label: String }
    let id: String
    let displayName: String
    let models: [String]
    let defaultModel: String
    let voices: [String: [Voice]]   // by model
    let defaultVoice: String
    let keyHint: String
}

enum SpeechProviders {
    /// Qwen-Audio voices from the official list (Model Studio › Qwen-Audio-TTS
    /// voice list, 2026-09-28). All speak Mandarin and English unless noted.
    static let qwenAudio = SpeechProvider(
        id: "qwen-audio",
        displayName: "Qwen-Audio (Alibaba)",
        models: ["qwen-audio-3.0-tts-flash", "qwen-audio-3.0-tts-plus"],
        defaultModel: "qwen-audio-3.0-tts-flash",
        voices: [
            "qwen-audio-3.0-tts-flash": [
                .init(id: "longanhuan_v3.6", label: "龙安欢 · 女"),
                .init(id: "longanfengyue", label: "龙安风月 · 女 · 自然亲切"),
                .init(id: "longanxiaoxin", label: "龙安小欣 · 女 · 活泼"),
                .init(id: "longanlingxi", label: "龙安灵犀 · 女 · 甜美"),
                .init(id: "longanyuanfei", label: "龙安元妃 · 女 · 端庄"),
                .init(id: "longchuanshu_v3.6", label: "龙川叔 · 男 · 川味"),
                .init(id: "longhuohuo_v3.6", label: "龙火火 · 男孩"),
                .init(id: "longjielidou_v3.6", label: "龙杰力豆 · 男童"),
                .init(id: "longpaopao_v3.6", label: "龙泡泡 · 女童"),
                .init(id: "loongjohn", label: "John · Male · US (English only)"),
                .init(id: "loongeva_v3.6", label: "Eva · Female · US (English only)"),
                .init(id: "loongmary", label: "Mary · Female · UK (English only)"),
            ],
            "qwen-audio-3.0-tts-plus": [
                .init(id: "longanlingxin", label: "龙安灵心 · 女 · 温暖"),
                .init(id: "longanlufeng", label: "龙安路风 · 男 · 阳光"),
            ],
        ],
        defaultVoice: "longanhuan_v3.6",
        keyHint: L("speech.key.hint.qwen"))

    static let all = [qwenAudio]

    static func find(_ id: String) -> SpeechProvider? { all.first { $0.id == id } }
}

/// Keychain storage for reader API keys: ONE key per provider (account
/// `tts-key-<provider>`), shared by every reader of that provider and kept
/// apart from the LLM keys. Never written to the config file.
struct SpeechKeyStore {
    private static let keychain = KeychainStore(service: Brand.keychainService)
    private static let log = FileLog("Speech.Keys")
    private static func account(_ provider: String) -> String { "tts-key-\(provider)" }

    func key(for provider: String) -> String { Self.keychain.get(Self.account(provider)) ?? "" }

    @discardableResult
    func save(_ key: String, for provider: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.account(provider))
            Self.log.info("API key saved for \(provider)")
            return nil
        } catch {
            Self.log.error("keychain save failed for \(provider): \(error)")
            return "\(error)"
        }
    }

    func clear(for provider: String) {
        Self.keychain.remove(Self.account(provider))
        Self.log.info("API key cleared for \(provider)")
    }
}

/// The readers the user set up, the default reader, and the provider keys —
/// the single source of truth behind the Speech tab and every Speak action.
/// Main thread only.
final class SpeechSettingsStore: ObservableObject {
    static let shared = SpeechSettingsStore()

    private enum P {
        static let readers = "speech.readers"
        static let defaultReader = "speech.defaultReader"
    }
    private let keys = SpeechKeyStore()
    private var config: ConfigStore { .shared }

    @Published private(set) var readers: [SpeechReader] = []
    @Published private(set) var defaultReaderID = SpeechReader.systemID
    @Published private(set) var keyedProviders: Set<String> = []

    private init() {
        readers = (ConfigStore.shared.value(P.readers)?.arrayValue ?? []).compactMap(SpeechReader.init(json:))
        let stored = ConfigStore.shared.string(P.defaultReader, default: SpeechReader.systemID)
        defaultReaderID = readers.contains { $0.id == stored } ? stored : SpeechReader.systemID
        refreshKeys()
    }

    /// The system voice first, then the user's readers.
    var allReaders: [SpeechReader] { [SpeechReader.system()] + readers }

    /// The reader an action asked for, else the default, else the system voice.
    /// An action naming a reader that was deleted falls back to the default.
    func resolve(_ id: String?) -> SpeechReader {
        let wanted = id ?? defaultReaderID
        return allReaders.first { $0.id == wanted }
            ?? allReaders.first { $0.id == defaultReaderID }
            ?? SpeechReader.system()
    }

    func name(of id: String?) -> String? {
        guard let id else { return nil }
        return allReaders.first { $0.id == id }?.name
    }

    // MARK: - Editing

    @discardableResult
    func addReader(provider: SpeechProvider) -> SpeechReader {
        let count = readers.filter { $0.engine == provider.id }.count
        let reader = SpeechReader(id: UUID().uuidString, name: count == 0 ? "Qwen" : "Qwen \(count + 1)",
                                  engine: provider.id, model: provider.defaultModel, voice: provider.defaultVoice,
                                  speed: 1, region: "cn")
        readers.append(reader)
        persist()
        return reader
    }

    func update(_ reader: SpeechReader) {
        guard let i = readers.firstIndex(where: { $0.id == reader.id }) else { return }
        readers[i] = reader
        persist()
    }

    func remove(_ id: String) {
        readers.removeAll { $0.id == id }
        if defaultReaderID == id { defaultReaderID = SpeechReader.systemID }
        persist()
    }

    func setDefault(_ id: String) {
        defaultReaderID = allReaders.contains { $0.id == id } ? id : SpeechReader.systemID
        persist()
    }

    private func persist() {
        config.set(P.readers, .array(readers.map(\.json)))
        config.set(P.defaultReader, .string(defaultReaderID))
    }

    // MARK: - Keys

    func apiKey(for provider: String) -> String { keys.key(for: provider) }
    func hasKey(for provider: String) -> Bool { keyedProviders.contains(provider) }

    func saveKey(_ key: String, for provider: String) -> String? {
        let error = keys.save(key, for: provider)
        refreshKeys()
        return error
    }

    func clearKey(for provider: String) {
        keys.clear(for: provider)
        refreshKeys()
    }

    private func refreshKeys() {
        keyedProviders = Set(SpeechProviders.all.map(\.id).filter { !keys.key(for: $0).isEmpty })
    }
}
