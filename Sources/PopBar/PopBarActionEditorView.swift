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
    /// The symbol-search window is open (`SymbolSearchView`).
    @State private var showSymbolSearch = false
    /// The picture window, and whether a file is being dragged over its drop area.
    @State private var showImagePicker = false
    @State private var imageDropTargeted = false
    /// Why the last picture could not be used, shown in the picture window.
    @State private var iconImageError: String?
    /// Pictures imported while this sheet has been open. All but the one that
    /// is saved are deleted again when it closes, so choosing a few and
    /// cancelling leaves nothing behind in the icons folder.
    @State private var importedPictures: [String] = []
    /// URL names other actions already use (lower case); this one needs its own.
    private let takenURLNames: Set<String>
    /// The action being edited was a group when the sheet opened. Given another
    /// kind, it stays one (see `saved`).
    private let wasGroup: Bool
    /// "Group" is offered as a kind: the action is at the top level, or new.
    private let canBeGroup: Bool
    let onSave: (PopBarActionConfig) -> Void
    let onCancel: () -> Void

    init(action: PopBarActionConfig, llm: LLMService, takenURLNames: Set<String> = [], canBeGroup: Bool = true,
         onSave: @escaping (PopBarActionConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: action)
        wasGroup = action.isGroup
        self.canBeGroup = canBeGroup
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
                    // A group is one of the kinds (issue #16), chosen in the same
                    // picker as every other: "Group" only holds actions; any
                    // other kind on an action that holds some is a group that
                    // also runs when clicked. Not offered to an action that is
                    // INSIDE a group — two levels, never three.
                    Picker(L("popbar.editor.kind"), selection: $draft.kind) {
                        if canBeGroup || draft.kind == .group {
                            Text(L("popbar.editor.kind.group")).tag(PopBarActionConfig.Kind.group)
                            Divider()
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
                    if draft.kind == .group {
                        Text(L("popbar.editor.group.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(L("popbar.editor.icon")) { iconGrid }

                kindSpecificSections

                if draft.kind == .ai {
                    Section(L("popbar.editor.prompt")) {
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                    Section { modelOverrideControls }
                }

                // Always the last thing on the page, whatever is above it: few
                // people need it. A group that only holds actions has nothing
                // for a URL to run.
                if draft.kind != .group { urlSection }
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

    /// The curated groups, led by the two ways to something else: any SF Symbol
    /// by name, or a picture. Each opens its own small window; an icon chosen
    /// there takes the first tile, where it shows as the one in use.
    private var iconGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.iconGroups.enumerated()), id: \.element.title) { index, group in
                    Text(L(group.title)).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: iconColumns, spacing: 6) {
                        if index == 0 { leadingTiles }
                        ForEach(group.symbols, id: \.self) { symbolTile($0) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 220)
    }

    /// The symbol in use is one of the curated ones (and no picture hides it).
    private var usesCuratedSymbol: Bool {
        draft.iconImage == nil && Self.iconGroups.contains { $0.symbols.contains(draft.iconSymbol) }
    }

    @ViewBuilder
    private var leadingTiles: some View {
        // What is in use, when it is not one of the tiles below.
        if !usesCuratedSymbol {
            iconTile(selected: true, help: draft.iconImage == nil ? draft.iconSymbol : L("popbar.editor.icon.image")) {
                ActionIconView(draft, size: 15, weight: .regular)
            } action: {}
        }
        iconTile(selected: false, dashed: true, help: L("popbar.editor.icon.search.title")) {
            Image(systemName: "magnifyingglass").font(.system(size: 13))
        } action: { showSymbolSearch = true }
        .popover(isPresented: $showSymbolSearch, arrowEdge: .bottom) {
            SymbolSearchView(onUse: { useSymbol($0); showSymbolSearch = false },
                             onCancel: { showSymbolSearch = false })
        }
        iconTile(selected: false, dashed: true, help: L("popbar.editor.icon.image")) {
            Image(systemName: "photo.badge.plus").font(.system(size: 13))
        } action: {
            iconImageError = nil
            showImagePicker = true
        }
        .popover(isPresented: $showImagePicker, arrowEdge: .bottom) { imagePicker }
    }

    /// One tile of the grid. A curated symbol, or one of the leading three.
    private func iconTile<Content: View>(selected: Bool, dashed: Bool = false, help: String,
                                         @ViewBuilder content: @escaping () -> Content,
                                         action: @escaping () -> Void) -> some View {
        EditorIconTile(selected: selected, dashed: dashed, help: help, action: action, content: content)
    }

    private func symbolTile(_ symbol: String) -> some View {
        iconTile(selected: draft.iconImage == nil && draft.iconSymbol == symbol, help: symbol) {
            Image(systemName: symbol).font(.system(size: 15))
        } action: { useSymbol(symbol) }
    }

    /// Choosing a symbol means the picture, if there was one, is no longer used.
    private func useSymbol(_ symbol: String) {
        draft.iconSymbol = symbol
        draft.iconImage = nil
    }

    // MARK: A picture of the user's own

    /// The small window behind the picture tile. What a picture has to be is
    /// said here, where one is chosen, and nowhere else.
    private var imagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("popbar.editor.icon.image")).font(.system(size: 12.5, weight: .semibold))
            VStack(spacing: 6) {
                if let picture = ActionIconStore.picture(named: draft.iconImage) {
                    Image(nsImage: picture).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "photo.badge.plus").font(.system(size: 22)).foregroundStyle(.secondary)
                }
                Text(L("popbar.editor.icon.image.drop")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L("popbar.editor.icon.image.choose")) { chooseIconImage() }
                    if draft.iconImage != nil {
                        Button(L("popbar.editor.icon.image.remove")) {
                            draft.iconImage = nil
                            showImagePicker = false
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(imageDropTargeted ? Color.accentColor : Color.secondary.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .onDrop(of: [.fileURL], isTargeted: $imageDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                // Asked for as the file-URL type by name: a file dragged from
                // Finder arrives as that, as data or as a URL.
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return }
                    DispatchQueue.main.async { useIconImage(at: url) }
                }
                return true
            }
            Text(L("popbar.editor.icon.image.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let iconImageError {
                Label(iconImageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private func chooseIconImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // App-modal, on purpose: this is asked from a popover, whose own window
        // goes away the moment anything else takes the focus — a sheet attached
        // to it would go with it.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useIconImage(at: url)
        // The panel taking the focus can have closed the popover. A picture
        // that could not be used has its reason shown there, so bring it back.
        if iconImageError != nil {
            DispatchQueue.main.async { showImagePicker = true }
        }
    }

    private func useIconImage(at url: URL) {
        do {
            let name = try ActionIconStore.importPNG(at: url)
            importedPictures.append(name)
            draft.iconImage = name
            iconImageError = nil
            showImagePicker = false
        } catch ActionIconStore.ImportError.notPNG {
            iconImageError = L("popbar.editor.icon.image.error.notPNG")
        } catch ActionIconStore.ImportError.cannotWrite {
            iconImageError = L("popbar.editor.icon.image.error.cannotWrite")
        } catch {
            iconImageError = L("popbar.editor.icon.image.error.unreadable")
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

/// One tile of the editor's icon grids: a symbol to choose, or (dashed) a way
/// to something else.
private struct EditorIconTile<Content: View>: View {
    let selected: Bool
    var dashed = false
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 32, height: 30)
                .foregroundStyle(dashed ? Color.secondary : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.22)
                                       : (dashed ? Color.clear : Color.primary.opacity(0.05)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : (dashed ? Color.secondary.opacity(0.6) : .clear),
                                      style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The small window behind the magnifying-glass tile: type any part of a
/// symbol's name, the matches follow every keystroke.
///
/// Its own view, with its own state: a popover is a window of its own, and
/// focus set from the sheet that opened it does not reach in.
private struct SymbolSearchView: View {
    let onUse: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var pick: String?
    @FocusState private var focused: Bool

    var body: some View {
        let found = SFSymbolCatalog.search(query)
        let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            Text(L("popbar.editor.icon.search.title")).font(.system(size: 12.5, weight: .semibold))
            TextField(L("popbar.editor.icon.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                // Return uses what is picked, or the first match. Handled here
                // and not by a default button: this window must never pass a
                // Return on to the sheet's Save.
                .onSubmit { if let symbol = pick ?? found.first { onUse(symbol) } }
            Text(!typed ? L("popbar.editor.icon.search.hint")
                        : (found.isEmpty ? L("popbar.editor.icon.search.none")
                                         : String(format: L("popbar.editor.icon.search.count"), found.count)))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(found, id: \.self) { symbol in
                        EditorIconTile(selected: pick == symbol, help: symbol, action: { pick = symbol }) {
                            Image(systemName: symbol).font(.system(size: 15))
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 150)
            Divider()
            HStack(spacing: 8) {
                Text(pick ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("popbar.editor.cancel"), action: onCancel)
                Button(L("popbar.editor.icon.search.use")) { if let pick { onUse(pick) } }
                    .disabled(pick == nil)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { focused = true }
        // A pick that is no longer among the matches would be used unseen.
        .onChange(of: query) { _ in
            if let current = pick, !SFSymbolCatalog.search(query).contains(current) { pick = nil }
        }
    }
}
