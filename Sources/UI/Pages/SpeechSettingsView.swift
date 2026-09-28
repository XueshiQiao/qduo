import SwiftUI

/// The **Speech** tab of the AI Models page: the readers Speak actions can use,
/// the default one, each provider's API key, and the local audio cache.
struct SpeechSettingsView: View {
    @ObservedObject private var store = SpeechSettingsStore.shared
    @State private var keyDrafts: [String: String] = [:]
    @State private var keyErrors: [String: String] = [:]
    @State private var preview: SpeechPlayback?
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        Form {
            defaultSection
            ForEach(store.readers) { reader in
                ReaderSection(reader: reader, store: store, preview: $preview)
            }
            addSection
            ForEach(SpeechProviders.all, id: \.id) { keySection($0) }
            cacheSection
        }
        .formStyle(.grouped)
        .onAppear { cacheBytes = SpeechCache.shared.size() }
        .onDisappear { SpeechCenter.shared.stop(preview) }
    }

    // MARK: - Default reader

    private var defaultSection: some View {
        Section {
            Picker(selection: Binding(get: { store.defaultReaderID }, set: { store.setDefault($0) })) {
                ForEach(store.allReaders) { Text($0.name).tag($0.id) }
            } label: { iconLabel("speaker.wave.2", .teal, L("speech.default")) }
        } header: {
            Text(L("speech.default.header"))
        } footer: {
            Text(L("speech.default.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addSection: some View {
        Section {
            ForEach(SpeechProviders.all, id: \.id) { provider in
                Button {
                    store.addReader(provider: provider)
                } label: {
                    Label(String(format: L("speech.add"), provider.displayName), systemImage: "plus.circle")
                }
            }
        } footer: {
            Text(L("speech.add.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Keys

    private func keySection(_ provider: SpeechProvider) -> some View {
        Section {
            LabeledContent {
                if store.hasKey(for: provider.id) {
                    HStack(spacing: 8) {
                        Text(L("models.key.saved"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Button(L("models.key.clear")) { store.clearKey(for: provider.id) }
                            .controlSize(.small)
                    }
                } else {
                    Text(L("models.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                }
            } label: {
                iconLabel("key", .teal, String(format: L("models.keyFor"), provider.displayName))
            }
            HStack {
                SecureField(L("models.key.placeholder"), text: Binding(
                    get: { keyDrafts[provider.id] ?? "" }, set: { keyDrafts[provider.id] = $0 }))
                Button(L("models.key.save")) {
                    keyErrors[provider.id] = store.saveKey(keyDrafts[provider.id] ?? "", for: provider.id)
                    if keyErrors[provider.id] == nil { keyDrafts[provider.id] = "" }
                }
                .disabled((keyDrafts[provider.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = keyErrors[provider.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(String(format: L("speech.key.header"), provider.displayName))
        } footer: {
            Text(provider.keyHint).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(String(format: L("speech.cache.usage"),
                                ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file),
                                ByteCountFormatter.string(fromByteCount: SpeechCache.limitBytes, countStyle: .file)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L("speech.cache.clear")) {
                        SpeechCache.shared.clear()
                        cacheBytes = SpeechCache.shared.size()
                    }
                    .controlSize(.small)
                    .disabled(cacheBytes == 0)
                }
            } label: { iconLabel("internaldrive", .teal, L("speech.cache")) }
        } footer: {
            Text(L("speech.cache.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One reader's settings.
private struct ReaderSection: View {
    let reader: SpeechReader
    @ObservedObject var store: SpeechSettingsStore
    @Binding var preview: SpeechPlayback?
    @State private var customVoice = false

    private var provider: SpeechProvider? { SpeechProviders.find(reader.engine) }
    private var voices: [SpeechProvider.Voice] { provider?.voices[reader.model] ?? [] }

    private func set(_ change: (inout SpeechReader) -> Void) {
        var copy = reader
        change(&copy)
        store.update(copy)
    }

    var body: some View {
        Section {
            TextField(L("speech.reader.name"), text: Binding(get: { reader.name }, set: { v in set { $0.name = v } }))

            Picker(L("speech.reader.model"), selection: Binding(get: { reader.model }, set: { model in
                set {
                    $0.model = model
                    let list = provider?.voices[model] ?? []
                    if !list.isEmpty, !list.contains(where: { $0.id == reader.voice }) { $0.voice = list[0].id }
                }
            })) {
                ForEach(provider?.models ?? [reader.model], id: \.self) { Text($0).tag($0) }
            }

            Picker(L("speech.reader.voice"), selection: Binding(
                get: { customVoice || !voices.contains { $0.id == reader.voice } ? "__custom" : reader.voice },
                set: { value in
                    if value == "__custom" { customVoice = true } else { customVoice = false; set { $0.voice = value } }
                })) {
                ForEach(voices) { Text($0.label).tag($0.id) }
                Divider()
                Text(L("speech.reader.voice.custom")).tag("__custom")
            }
            if customVoice || !voices.contains(where: { $0.id == reader.voice }) {
                TextField(L("speech.reader.voice.id"), text: Binding(get: { reader.voice }, set: { v in set { $0.voice = v } }))
                    .font(.system(size: 12, design: .monospaced))
            }

            LabeledContent(L("speech.reader.speed")) {
                HStack {
                    Slider(value: Binding(get: { reader.speed }, set: { v in set { $0.speed = (v * 20).rounded() / 20 } }),
                           in: 0.5...2)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2f×", reader.speed))
                        .font(.system(size: 11, design: .monospaced)).frame(width: 44, alignment: .trailing)
                }
            }

            Picker(L("speech.reader.region"), selection: Binding(get: { reader.region }, set: { v in set { $0.region = v } })) {
                Text(L("speech.reader.region.cn")).tag("cn")
                Text(L("speech.reader.region.intl")).tag("intl")
            }

            HStack {
                Button {
                    preview = SpeechCenter.shared.read(L("speech.preview.sample"), with: reader)
                } label: { Label(L("speech.preview"), systemImage: "play.circle") }
                if let preview, preview.reader.id == reader.id {
                    PreviewStatus(playback: preview)
                }
                Spacer()
                Button(role: .destructive) {
                    store.remove(reader.id)
                } label: { Text(L("speech.reader.remove")) }
            }
        } header: {
            Text("\(reader.name) · \(provider?.displayName ?? reader.engine)")
        }
    }
}

/// What a preview read is doing, next to its button.
private struct PreviewStatus: View {
    @ObservedObject var playback: SpeechPlayback

    var body: some View {
        switch playback.state {
        case .preparing: ProgressView().controlSize(.small)
        case .playing, .paused:
            Button { SpeechCenter.shared.stop(playback) } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .finished:
            EmptyView()
        }
    }
}
