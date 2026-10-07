import SwiftUI
import UniformTypeIdentifiers

/// Add/edit sheet for a single configurable action: title, icon, type, prompt,
/// and an optional per-action model override.
struct ActionEditorView: View {

    @State private var draft: PopBarActionConfig
    @ObservedObject private var llm: LLMService
    @ObservedObject private var speech = SpeechSettingsStore.shared
    /// The system translator's languages, loaded when the editor shows a
    /// `systemTranslate` action (the list comes from an async system call).
    @State private var translateTargets: [SystemTranslator.Target] = []
    /// What is typed in the icon search box. Empty = the curated groups.
    @State private var iconQuery = ""
    /// Why the last picture could not be used, shown under the picture row.
    @State private var iconImageError: String?
    /// Pictures imported while this sheet has been open. All but the one that
    /// is saved are deleted again when it closes, so choosing a few and
    /// cancelling leaves nothing behind in the icons folder.
    @State private var importedPictures: [String] = []
    /// URL names other actions already use (lower case); this one needs its own.
    private let takenURLNames: Set<String>
    /// The action being edited is a group: it may also be given nothing to do.
    private let wasGroup: Bool
    let onSave: (PopBarActionConfig) -> Void
    let onCancel: () -> Void

    init(action: PopBarActionConfig, llm: LLMService, takenURLNames: Set<String> = [],
         onSave: @escaping (PopBarActionConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: action)
        wasGroup = action.isGroup
        self.takenURLNames = takenURLNames
        _llm = ObservedObject(wrappedValue: llm)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("popbar.editor.title"), text: $draft.title)
                    // A group is an action too (issue #16): pointing at it unfolds
                    // what it holds, clicking it does what is chosen here — which
                    // may be nothing. Only a group is offered "nothing": an
                    // ordinary action that did nothing would be a dead button.
                    if wasGroup {
                        Text(L("popbar.editor.group.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker(L(wasGroup ? "popbar.editor.group.click" : "popbar.editor.kind"), selection: $draft.kind) {
                        if wasGroup {
                            Text(L("popbar.editor.group.click.none")).tag(PopBarActionConfig.Kind.group)
                        }
                        Text(L("popbar.editor.kind.ai")).tag(PopBarActionConfig.Kind.ai)
                        Text(L("popbar.editor.kind.copy")).tag(PopBarActionConfig.Kind.copy)
                        Text(L("popbar.editor.kind.webpreview")).tag(PopBarActionConfig.Kind.webPreview)
                        Text(L("popbar.editor.kind.quicklook")).tag(PopBarActionConfig.Kind.quickLook)
                        Text(L("popbar.editor.kind.reveal")).tag(PopBarActionConfig.Kind.revealInFinder)
                        Text(L("popbar.editor.kind.openURL")).tag(PopBarActionConfig.Kind.openURL)
                        Text(L("popbar.editor.kind.speak")).tag(PopBarActionConfig.Kind.speak)
                        Text(L("popbar.editor.kind.transform")).tag(PopBarActionConfig.Kind.transform)
                        Text(L("popbar.editor.kind.shortcut")).tag(PopBarActionConfig.Kind.shortcut)
                        Text(L("popbar.editor.kind.script")).tag(PopBarActionConfig.Kind.script)
                        // Offered on macOS 15+ only — but an action that already
                        // is one keeps its entry, so the picker never shows blank.
                        if SystemTranslator.isAvailable || draft.kind == .systemTranslate {
                            Text(L("popbar.editor.kind.systemTranslate")).tag(PopBarActionConfig.Kind.systemTranslate)
                        }
                        Text(L("popbar.editor.kind.pause")).tag(PopBarActionConfig.Kind.pause)
                        Text(L("popbar.editor.kind.inspect")).tag(PopBarActionConfig.Kind.inspect)
                        Text(L("popbar.editor.kind.settings")).tag(PopBarActionConfig.Kind.settings)
                    }
                    if draft.isPathAction {
                        Text(L("popbar.editor.kind.pathHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                kindSpecificSections

                Section(L("popbar.editor.icon")) {
                    iconSearchField
                    iconGrid
                    iconImageRow
                }

                // A group that only unfolds has nothing for a URL to run.
                if draft.kind != .group { urlSection }

                if draft.kind == .ai {
                    Section(L("popbar.editor.prompt")) {
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                    Section { modelOverrideControls }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("popbar.editor.cancel")) {
                    ActionIconStore.discard(importedPictures)
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("popbar.editor.save")) {
                    let action = saved
                    ActionIconStore.discard(importedPictures.filter { $0 != action.iconImage })
                    onSave(action)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 470, height: 680)
    }

    /// The draft as it will be stored: a transform whose operation was never
    /// touched gets the one its picker was showing.
    private var saved: PopBarActionConfig {
        var action = draft
        if action.kind == .transform, action.op == nil { action.op = TextTransform.uppercase.rawValue }
        // A group given something to do stays a group even while it is empty.
        if wasGroup { action.marksGroup = action.kind == .group ? nil : true }
        return action
    }

    private var isValid: Bool {
        let titleOK = !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
        func filled(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard urlNameProblem == nil else { return false }
        switch draft.kind {
        case .ai:        return titleOK && filled(draft.prompt)
        case .openURL:   return titleOK && filled(draft.url)
        // A new transform shows UPPERCASE in its picker before anything is
        // chosen; saving takes that (see `save`), so nil is valid here.
        case .transform: return titleOK && (draft.op == nil || draft.op.flatMap(TextTransform.init(rawValue:)) != nil)
        case .shortcut:  return titleOK && filled(draft.shortcut)
        case .script:    return titleOK && filled(draft.script)
        case .systemTranslate: return titleOK && filled(draft.targetLanguage)
        default:         return titleOK
        }
    }

    // MARK: - Running it from another app (issue #15)

    /// Why the URL name cannot be saved as it is; nil when it can (or the URL is off).
    private var urlNameProblem: String? {
        guard draft.kind != .group, let name = draft.urlName else { return nil }
        if !ActionURL.isValidName(name) { return L("popbar.editor.url.name.invalid") }
        if takenURLNames.contains(name) { return L("popbar.editor.url.name.taken") }
        return nil
    }

    /// Off for every action until it is turned on here, one action at a time.
    private var urlSection: some View {
        Section {
            Toggle(L("popbar.editor.url.toggle"), isOn: Binding(
                get: { draft.urlName != nil },
                set: { on in
                    draft.urlName = on ? ActionURL.suggestedName(title: draft.title, kind: draft.kind.rawValue,
                                                                 taken: takenURLNames) : nil
                }))
            if let name = draft.urlName {
                TextField(L("popbar.editor.url.name"), text: Binding(
                    get: { name },
                    // Typed straight into the allowed form, so what is shown is
                    // what the URL will carry. Emptied → still on, and invalid
                    // until a name is typed.
                    set: { draft.urlName = ActionURL.sanitized($0) }))
                    .autocorrectionDisabled()
                if let problem = urlNameProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    let example = ActionURL.example(scheme: Brand.urlScheme, name: name, text: "Hello world")
                    HStack {
                        Text(example)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button(L("popbar.editor.url.copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(example, forType: .string)
                        }
                    }
                }
            }
        } header: {
            Text(L("popbar.editor.url.header"))
        } footer: {
            Text(L("popbar.editor.url.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Kind-specific fields

    @ViewBuilder
    private var kindSpecificSections: some View {
        switch draft.kind {
        case .openURL:
            Section {
                TextField(L("popbar.editor.url"), text: optionalText(\.url),
                          prompt: Text(verbatim: "https://www.google.com/search?q={text}"))
                    .font(.system(size: 12, design: .monospaced))
                Picker(L("popbar.editor.openIn"), selection: Binding(
                    get: { draft.openTarget },
                    set: { draft.openIn = $0 == .browser ? nil : $0.rawValue })) {
                    Text(L("popbar.editor.openIn.browser")).tag(OpenURLTarget.browser)
                    Text(L("popbar.editor.openIn.preview")).tag(OpenURLTarget.preview)
                }
            } footer: {
                Text(L("popbar.editor.url.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .speak:
            Section {
                Picker(L("popbar.editor.reader"), selection: Binding(
                    get: { draft.reader ?? "" },
                    set: { draft.reader = $0.isEmpty ? nil : $0 })) {
                    Text(String(format: L("popbar.editor.reader.default"),
                                speech.resolve(nil).name)).tag("")
                    Divider()
                    ForEach(speech.allReaders) { Text($0.name).tag($0.id) }
                    // A reader this action names that no longer exists: keep
                    // the choice visible rather than silently switching it.
                    if let id = draft.reader, !speech.allReaders.contains(where: { $0.id == id }) {
                        Text(L("popbar.editor.reader.missing")).tag(id)
                    }
                }
            } footer: {
                Text(L("popbar.editor.speak.hint"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .settings:
            Section {
                Text(String(format: L("popbar.editor.settings.hint.format"), Brand.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .pause:
            Section {
                Text(String(format: L("popbar.editor.pause.hint.format"), Brand.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .transform:
            Section {
                Picker(L("popbar.editor.op"), selection: Binding(
                    get: { draft.op.flatMap(TextTransform.init(rawValue:)) ?? .uppercase },
                    set: { draft.op = $0.rawValue })) {
                    ForEach(TextTransform.allCases, id: \.self) { op in
                        Text(L("transform.\(op.rawValue)")).tag(op)
                    }
                }
                .onAppear { if draft.op == nil { draft.op = TextTransform.uppercase.rawValue } }
                outputPicker
            }
        case .shortcut:
            Section {
                TextField(L("popbar.editor.shortcut"), text: optionalText(\.shortcut))
                outputPicker
            } footer: {
                Text(L("popbar.editor.shortcut.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .script:
            Section {
                TextEditor(text: optionalText(\.script))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70)
                outputPicker
            } header: {
                Text(L("popbar.editor.script"))
            } footer: {
                Text(L("popbar.editor.script.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .systemTranslate:
            Section {
                Picker(L("popbar.editor.targetLanguage"), selection: Binding(
                    get: { draft.targetLanguage ?? "" },
                    set: { draft.targetLanguage = $0.isEmpty ? nil : $0 })) {
                    Text(L("popbar.editor.targetLanguage.choose")).tag("")
                    Divider()
                    ForEach(translateTargets) { Text($0.name).tag($0.id) }
                    // A language this action names that this system does not
                    // list: keep it visible rather than silently clearing it.
                    // Also while the list is still loading, so the picker
                    // never flashes "Choose" for an action that has one.
                    if let id = draft.targetLanguage,
                       !translateTargets.contains(where: { $0.id == id }) {
                        Text(SystemTranslator.displayName(of: id)).tag(id)
                    }
                }
                .task { if translateTargets.isEmpty { translateTargets = await SystemTranslator.supportedTargets() } }
                outputPicker
            } footer: {
                Text(L(SystemTranslator.isAvailable ? "popbar.editor.systemTranslate.hint"
                                                    : "systemTranslate.error.needsNewerSystem"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ai:
            Section { outputPicker }
        default:
            EmptyView()
        }
    }

    /// Where the produced text goes. Hidden for `count`, which is always a report.
    @ViewBuilder
    private var outputPicker: some View {
        if !(draft.kind == .transform && draft.op == TextTransform.count.rawValue) {
            Picker(L("popbar.editor.output"), selection: Binding(
                get: { draft.outputMode },
                set: { draft.output = $0 == .panel ? nil : $0.rawValue })) {
                ForEach(ActionOutput.allCases, id: \.self) { mode in
                    Text(L("popbar.editor.output.\(mode.rawValue)")).tag(mode)
                }
            }
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<PopBarActionConfig, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    // MARK: - Icon grid

    /// Type any SF Symbol name; the grid below follows every keystroke.
    private var iconSearchField: some View {
        HStack(spacing: 8) {
            // What the action will show: its picture when it has one.
            ActionIconView(draft, size: 15, weight: .regular)
                .frame(width: 24)
            TextField(L("popbar.editor.icon.search"), text: $iconQuery)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if !iconQuery.isEmpty {
                Button { iconQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("popbar.editor.icon.search.clear"))
            }
        }
    }

    /// The curated groups, or — once something is typed — every symbol whose
    /// name starts with or contains it.
    private var iconGrid: some View {
        let found = iconQuery.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SFSymbolCatalog.search(iconQuery)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let found {
                    Text(found.isEmpty ? L("popbar.editor.icon.search.none")
                                       : String(format: L("popbar.editor.icon.search.count"), found.count))
                        .font(.caption).foregroundStyle(.secondary)
                    iconRow(found)
                } else {
                    ForEach(Self.iconGroups, id: \.title) { group in
                        Text(L(group.title)).font(.caption).foregroundStyle(.secondary)
                        iconRow(group.symbols)
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 220)
    }

    /// The user's own picture in place of the symbol.
    private var iconImageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let picture = ActionIconStore.picture(named: draft.iconImage) {
                    Image(nsImage: picture).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
                Text(L(draft.iconImage == nil ? "popbar.editor.icon.image.none" : "popbar.editor.icon.image.set"))
                Spacer()
                if draft.iconImage != nil {
                    Button(L("popbar.editor.icon.image.remove")) {
                        draft.iconImage = nil
                        iconImageError = nil
                    }
                }
                Button(L("popbar.editor.icon.image.choose")) { chooseIconImage() }
            }
            Text(L("popbar.editor.icon.image.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let iconImageError {
                Label(iconImageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseIconImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // As a sheet on the editor's own window when there is one: an
        // app-modal panel run from inside a sheet can leave focus in the wrong
        // window.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { useIconImage(at: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            useIconImage(at: url)
        }
    }

    private func useIconImage(at url: URL) {
        do {
            let name = try ActionIconStore.importPNG(at: url)
            importedPictures.append(name)
            draft.iconImage = name
            iconImageError = nil
        } catch ActionIconStore.ImportError.notPNG {
            iconImageError = L("popbar.editor.icon.image.error.notPNG")
        } catch ActionIconStore.ImportError.cannotWrite {
            iconImageError = L("popbar.editor.icon.image.error.cannotWrite")
        } catch {
            iconImageError = L("popbar.editor.icon.image.error.unreadable")
        }
    }

    private func iconRow(_ symbols: [String]) -> some View {
        LazyVGrid(columns: iconColumns, spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                Button { draft.iconSymbol = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(draft.iconSymbol == symbol ? Color.accentColor.opacity(0.22)
                                                                 : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(draft.iconSymbol == symbol ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
    }

    // MARK: - Model override

    @ViewBuilder
    private var modelOverrideControls: some View {
        Toggle(L("popbar.editor.customModel"), isOn: Binding(
            get: { draft.modelOverride != nil },
            set: { on in
                if on {
                    let p = llm.settings.provider
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                } else {
                    draft.modelOverride = nil
                }
            }))

        if let override = draft.modelOverride {
            Picker(L("popbar.llm.provider"), selection: Binding(
                get: { override.provider },
                set: { p in
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                })) {
                ForEach(LLMConfig.providers, id: \.self) { p in Text(LLMConfig.displayName(p)).tag(p) }
            }

            TextField(L("popbar.llm.model"), text: Binding(
                get: { draft.modelOverride?.model ?? "" },
                set: { draft.modelOverride?.model = $0 }))

            Picker(L("popbar.llm.thinking"), selection: Binding(
                get: { draft.modelOverride?.reasoningEffort ?? "none" },
                set: { draft.modelOverride?.reasoningEffort = $0 })) {
                ForEach(LLMConfig.thinkingOptions(for: override.provider), id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }

            if !llm.isConfigured(forProvider: override.provider) {
                Label(String(format: L("popbar.editor.nokeyWarn"), LLMConfig.displayName(override.provider)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Curated SF Symbols, grouped by what the actions they suit do. Every name
    /// was checked against the system's own availability table: none needs more
    /// than macOS 13.0 (`translate`, the obvious one for translating, needs 14.4
    /// and is left out). The original 48 are all still here, so an icon an action
    /// already uses never disappears from the picker.
    private static let iconGroups: [(title: String, symbols: [String])] = [
        ("icons.ai", ["sparkles", "sparkle", "wand.and.stars", "wand.and.rays", "brain", "brain.head.profile",
                      "lightbulb", "lightbulb.fill", "bolt.fill", "text.badge.checkmark", "checkmark.seal",
                      "pencil", "square.and.pencil", "highlighter", "eraser"]),
        ("icons.chat", ["text.bubble", "quote.bubble", "bubble.left.and.bubble.right", "exclamationmark.bubble",
                        "questionmark.bubble", "questionmark.circle"]),
        ("icons.translate", ["character.bubble", "globe", "globe.asia.australia", "globe.americas",
                             "globe.europe.africa", "character", "character.zh", "character.ja", "a.magnify", "abc",
                             "character.book.closed", "book.closed", "book", "graduationcap"]),
        ("icons.text", ["textformat", "textformat.abc", "textformat.size", "textformat.size.larger",
                        "textformat.size.smaller", "textformat.alt", "bold", "italic", "underline",
                        "strikethrough", "text.quote", "text.alignleft", "text.append", "text.word.spacing",
                        "list.bullet", "list.number", "increase.indent", "arrow.up.arrow.down",
                        "arrow.left.arrow.right", "shuffle"]),
        ("icons.clipboard", ["doc.on.doc", "doc.on.clipboard", "clipboard", "list.clipboard",
                             "arrow.right.doc.on.clipboard", "scissors", "trash", "arrow.2.squarepath",
                             "arrow.uturn.backward", "delete.left"]),
        ("icons.web", ["magnifyingglass", "binoculars", "safari", "safari.fill", "link", "link.badge.plus",
                       "network", "arrow.up.right.square", "arrow.up.forward.app", "play.rectangle", "cart",
                       "map", "mappin.and.ellipse"]),
        ("icons.calc", ["function", "x.squareroot", "sum", "plus.forwardslash.minus", "percent", "equal.circle",
                        "number", "dollarsign.circle", "yensign.circle", "eurosign.circle", "banknote", "ruler",
                        "scalemass", "thermometer.medium", "clock"]),
        ("icons.calendar", ["calendar", "calendar.badge.plus", "calendar.badge.clock", "alarm", "checklist",
                            "checkmark.circle"]),
        ("icons.notes", ["note.text", "note.text.badge.plus", "doc.text", "doc.badge.plus", "doc.append",
                         "bookmark", "bookmark.fill", "star", "star.fill", "flag.fill", "tag", "tag.fill",
                         "paperclip", "archivebox", "tray.and.arrow.down"]),
        ("icons.share", ["square.and.arrow.up", "envelope", "paperplane.fill", "message", "phone", "at",
                         "person.crop.circle.badge.plus", "printer"]),
        ("icons.media", ["pause.circle", "speaker.wave.2.fill", "waveform", "mic.fill", "music.note", "photo", "camera",
                         "text.viewfinder", "viewfinder", "qrcode"]),
        ("icons.dev", ["terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "curlybraces.square",
                       "command", "keyboard", "hammer", "wrench.and.screwdriver", "gearshape",
                       "puzzlepiece.extension", "key", "lock"]),
        ("icons.files", ["eye", "folder", "folder.badge.plus", "doc.text.magnifyingglass", "macwindow",
                         "square.on.square"]),
        ("icons.markers", ["info.circle", "exclamationmark.triangle", "hand.thumbsup"]),
    ]
}
