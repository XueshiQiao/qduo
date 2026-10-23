import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The two sheets behind Advanced → Backup (issue #22). The work itself is in
// `BackupExporter` and `BackupImporter`; these only collect the choices and say
// what happened.

/// What one part is called on screen, the same in both sheets.
private func partTitle(_ part: BackupManifest.Part) -> String {
    switch part {
    case .config:  return L("backup.part.config")
    case .icons:   return L("backup.part.icons")
    case .keys:    return L("backup.part.keys")
    case .history: return L("backup.part.history")
    }
}

private func partSymbol(_ part: BackupManifest.Part) -> (String, Color) {
    switch part {
    case .config:  return ("doc.badge.gearshape", .indigo)
    case .icons:   return ("photo", .orange)
    case .keys:    return ("key.fill", .yellow)
    case .history: return ("clock.arrow.circlepath", .teal)
    }
}

/// Lines up whatever sits under a row (the password boxes) with the row's text,
/// not with its checkbox.
private extension HorizontalAlignment {
    enum PartText: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.leading] }
    }
    static let partText = HorizontalAlignment(PartText.self)
}

/// One checkbox row: checkbox, icon tile, title with its count, and a line under
/// it, all centred on one line. `extra` (the password boxes) goes underneath,
/// lined up with the text. The checkbox is a bare control so it stays centred
/// on the tile; a Toggle with this label puts it level with the first line.
private struct PartToggle<Extra: View>: View {
    let part: BackupManifest.Part
    let detail: String?
    let note: String?
    @Binding var isOn: Bool
    @ViewBuilder var extra: Extra

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .partText, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Toggle(partTitle(part), isOn: $isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                let (symbol, color) = partSymbol(part)
                IconTile(symbol: symbol, color: color)
                    .onTapGesture { if isEnabled { isOn.toggle() } }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // The checkbox already carries this name for VoiceOver.
                        Text(partTitle(part)).accessibilityHidden(true)
                        if let detail { Text(detail).foregroundStyle(.secondary) }
                    }
                    if let note {
                        Text(note)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { isOn.toggle() } }
                .alignmentGuide(.partText) { $0[.leading] }
            }
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The backup password box. It shows what is typed, in plain text: a backup
/// password is typed once and has to be typed again, maybe on another Mac,
/// so seeing it matters more than hiding it from someone looking over a
/// shoulder. Monospaced, so l and 1, O and 0 can be told apart. It has a border
/// and a prompt: a grouped Form otherwise draws a bare, right-aligned field.
private struct PasswordField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    /// Put the cursor in this box when it first appears.
    var focusOnAppear = false

    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
            .focused($focused)
            .onAppear {
                guard focusOnAppear else { return }
                DispatchQueue.main.async { focused = true }
            }
            .background(TypeAsIsGuard())
    }

    /// Whatever is typed or pasted goes in unchanged. Text Replacement (System
    /// Settings → Keyboard) is on in a plain text field, and smart quotes,
    /// dashes and paste spacing follow the person's settings, so each could
    /// turn the password into something other than what was typed.
    static func typeAsIs(_ editor: NSTextView?) {
        guard let editor else { return }
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
    }
}

/// Keeps the sheet's field editor typing as-is. The editor is shared by the
/// window and only exists while a box is being edited, and the window may not
/// be key when the box gets focus (another app in front), so it is checked on
/// every update of this view's own window rather than once on focus.
private struct TypeAsIsGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class GuardView: NSView {
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak window] _ in
                    guard let editor = window?.firstResponder as? NSTextView,
                          editor.isFieldEditor, editor.isAutomaticTextReplacementEnabled
                            || editor.isAutomaticQuoteSubstitutionEnabled || editor.isAutomaticDashSubstitutionEnabled
                            || editor.smartInsertDeleteEnabled else { return }
                    PasswordField.typeAsIs(editor)
                }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// Why the main button is greyed out, shown beside it.
private struct BlockedReason: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "key.fill")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A sentence for the person, never an enum case name. The app's own failures
/// get their own wording; a system error (disk full, no permission) brings its
/// own localized description.
private func readable(_ error: Error) -> String {
    switch error {
    case BackupImporter.Failure.notABackup:    return String(format: L("backup.import.notBackup"), Brand.name)
    case BackupImporter.Failure.newerFormat:   return String(format: L("backup.import.newer"), Brand.name)
    case BackupImporter.Failure.tooLarge, BackupFiles.Failure.tooLarge:
        return L("backup.import.tooLarge")
    case BackupImporter.Failure.wrongPassword: return L("backup.password.wrong")
    case BackupImporter.Failure.siblingRunning(let name):
        return String(format: L("backup.import.sibling"), name)
    case BackupImporter.Failure.historyFailed: return L("backup.import.historyFailed")
    case BackupImporter.Failure.partiallyRestored: return L("backup.import.partial")
    case is BackupImporter.Failure, is BackupExporter.Failure, is HistoryStore.BackupError,
         is BackupFiles.Failure, is BackupArchive.Failure, is BackupCrypto.Failure, is KeychainError:
        return L("backup.error.generic")
    default:
        return (error as NSError).localizedDescription
    }
}

/// After settings, icons or keys were written there is no going back to the
/// running app: its memory still holds the old settings and saving them is
/// switched off. An app-modal alert with one button, so neither closing the
/// sheet nor closing the settings window leaves the app in that state.
@MainActor
private func relaunchAfterRestore(message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = String(format: L("backup.import.relaunch.info"), Brand.name)
    alert.addButton(withTitle: L("backup.import.relaunch"))
    _ = alert.runModal()
    AppRelaunch.relaunch(arguments: ["--settings", "--page", "advanced"])
}

// MARK: - Export

struct BackupExportSheet: View {
    let onClose: () -> Void

    @State private var chosen = Set(BackupManifest.Part.allCases)
    @State private var password = ""
    @State private var iconCount = 0
    @State private var keyCount = 0
    @State private var historyCount: Int?
    @State private var historySize: Int64 = 0
    @State private var working = false
    @State private var errorText: String?
    @State private var savedTo: URL?

    /// Nothing can be changed while the file is being written, or once it is.
    private var locked: Bool { working || savedTo != nil }
    private var canExport: Bool {
        !chosen.isEmpty && !working && (!chosen.contains(.keys) || hasPassword)
    }
    /// Spaces alone do not count: they cannot be seen in the box.
    private var hasPassword: Bool { !password.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    toggle(.config, detail: nil, note: L("backup.part.config.note"))
                    toggle(.icons, detail: String(format: L("backup.count.icons"), iconCount), note: nil)
                    toggle(.keys, detail: String(format: L("backup.count.keys"), keyCount),
                           note: L("backup.part.keys.note")) {
                        if chosen.contains(.keys) {
                            VStack(alignment: .leading, spacing: 6) {
                                PasswordField(title: L("backup.password"),
                                              prompt: L("backup.password.export.prompt"), text: $password,
                                              focusOnAppear: true)
                            }
                        }
                    }
                    toggle(.history,
                           detail: historyCount.map { String(format: L("backup.count.history"), $0, sizeText(historySize)) },
                           note: L("backup.part.history.note"))
                } header: {
                    Text(L("backup.export.title"))
                } footer: {
                    Text(L("backup.export.footer"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let savedTo {
                    Section {
                        Label(String(format: L("backup.export.done"), savedTo.lastPathComponent),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button(L("backup.export.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([savedTo])
                        }
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if working { ProgressView().controlSize(.small) }
                if !locked && chosen.contains(.keys) && !hasPassword {
                    BlockedReason(text: L("backup.export.needsPassword"))
                }
                Spacer()
                Button(savedTo == nil ? L("backup.cancel") : L("backup.done")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                if savedTo == nil {
                    Button(L("backup.export.button")) { chooseDestination() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canExport)
                }
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .interactiveDismissDisabled(working)
        .task { await loadCounts() }
    }

    private func toggle(_ part: BackupManifest.Part, detail: String?, note: String?) -> some View {
        toggle(part, detail: detail, note: note) { EmptyView() }
    }

    private func toggle<Extra: View>(_ part: BackupManifest.Part, detail: String?, note: String?,
                                     @ViewBuilder extra: () -> Extra) -> some View {
        PartToggle(part: part, detail: detail, note: note, isOn: Binding(
            get: { chosen.contains(part) },
            set: { on in
                if on { chosen.insert(part) } else { chosen.remove(part) }
                errorText = nil
            }), extra: extra)
        .disabled(locked)
    }

    /// Off the main thread: the icon count reads every picture, and the key
    /// count is a synchronous keychain query.
    private func loadCounts() async {
        let (icons, keys) = await Task.detached(priority: .userInitiated) {
            (BackupExporter.readableIcons().count,
             (try? KeychainStore(service: Brand.keychainService).allItems().count) ?? 0)
        }.value
        iconCount = icons
        keyCount = keys
        historyCount = await HistoryStore.shared.recordCount()
        historySize = await HistoryStore.shared.diskSize()
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = BackupExporter.suggestedFileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    private func export(to url: URL) {
        working = true
        errorText = nil
        let parts = chosen
        let secret = chosen.contains(.keys) ? password : nil
        Task {
            do {
                _ = try await BackupExporter.export(parts: parts, password: secret, to: url)
                savedTo = url
            } catch {
                errorText = String(format: L("backup.export.failed"), readable(error))
            }
            working = false
        }
    }
}

// MARK: - Import

struct BackupImportSheet: View {
    let zip: URL
    let onClose: () -> Void

    @State private var inspection: BackupInspection?
    @State private var chosen = Set<BackupManifest.Part>()
    @State private var password = ""
    @State private var working = true
    @State private var errorText: String?
    @State private var wrongPassword = false
    /// Set once something was applied. Settings, icons or keys mean a restart.
    @State private var finished: BackupImporter.ApplyResult?

    private var canRestore: Bool {
        inspection != nil && finished == nil && !working && !chosen.isEmpty
            && (!chosen.contains(.keys) || !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let inspection {
                    partsSection(inspection)
                }
                if let finished {
                    Section {
                        Label(finished.needsRelaunch
                              ? String(format: L("backup.import.done"), Brand.name)
                              : L("backup.import.historyDone"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if working { ProgressView().controlSize(.small) }
                if inspection != nil && finished == nil && !working
                    && chosen.contains(.keys) && password.isEmpty {
                    BlockedReason(text: L("backup.import.needsPassword"))
                }
                Spacer()
                if let finished {
                    // After settings, icons or keys there is no going back to the
                    // running app: its memory still holds the old settings and
                    // writing them is switched off. The only way out is a restart.
                    if finished.needsRelaunch {
                        Button(L("backup.import.relaunch")) {
                            inspection?.cleanup()
                            AppRelaunch.relaunch(arguments: ["--settings", "--page", "advanced"])
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("backup.done")) { close() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(L("backup.cancel")) { close() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    Button(L("backup.import.restore")) { restore() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRestore)
                }
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .interactiveDismissDisabled(finished?.needsRelaunch == true || working)
        .task { await inspect() }
    }

    @ViewBuilder
    private func partsSection(_ inspection: BackupInspection) -> some View {
        let manifest = inspection.manifest
        Section {
            if manifest.parts.config != nil {
                toggle(.config, detail: nil, note: L("backup.import.config.replace"))
            }
            if let icons = manifest.parts.icons {
                toggle(.icons, detail: String(format: L("backup.count.icons"), icons.count),
                       note: L("backup.import.icons.note"))
            }
            if let keys = manifest.parts.keys {
                toggle(.keys, detail: String(format: L("backup.count.keys"), keys.count),
                       note: inspection.localKeyTitles.isEmpty ? nil
                           : String(format: L("backup.import.keys.overwrite"),
                                    inspection.localKeyTitles.joined(separator: ", "))) {
                    if chosen.contains(.keys) {
                        VStack(alignment: .leading, spacing: 6) {
                            PasswordField(title: L("backup.password"),
                                          prompt: L("backup.password.import.prompt"), text: $password,
                                          focusOnAppear: true)
                                .onChange(of: password) { _ in wrongPassword = false }
                            if wrongPassword {
                                Text(L("backup.password.wrong"))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if let history = manifest.parts.history {
                toggle(.history, detail: String(format: L("backup.count.historyRecords"), history.records),
                       note: L("backup.import.history.merge"))
            }
        } header: {
            Text(String(format: L("backup.import.from"), manifest.app.version,
                        Self.dateText(manifest.exportedAt)))
        } footer: {
            Text(L("backup.import.scripts"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle(_ part: BackupManifest.Part, detail: String?, note: String?) -> some View {
        toggle(part, detail: detail, note: note) { EmptyView() }
    }

    private func toggle<Extra: View>(_ part: BackupManifest.Part, detail: String?, note: String?,
                                     @ViewBuilder extra: () -> Extra) -> some View {
        PartToggle(part: part, detail: detail, note: note, isOn: Binding(
            get: { chosen.contains(part) },
            set: { on in
                if on { chosen.insert(part) } else { chosen.remove(part) }
                errorText = nil
            }), extra: extra)
        .disabled(finished != nil || working)
    }

    private static func dateText(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func inspect() async {
        do {
            let found = try await BackupImporter.inspect(zip)
            inspection = found
            chosen = found.manifest.availableParts
        } catch {
            errorText = readable(error)
        }
        working = false
    }

    private func restore() {
        guard let inspection else { return }
        working = true
        errorText = nil
        wrongPassword = false
        let parts = chosen
        let secret = chosen.contains(.keys) ? password : nil
        Task {
            do {
                let result = try await BackupImporter.apply(inspection, parts: parts, password: secret)
                finished = result
                if result.needsRelaunch {
                    inspection.cleanup()
                    relaunchAfterRestore(message: String(format: L("backup.import.done"), Brand.name))
                }
            } catch BackupImporter.Failure.wrongPassword {
                wrongPassword = true
            } catch BackupImporter.Failure.partiallyRestored {
                inspection.cleanup()
                relaunchAfterRestore(message: L("backup.import.partial"))
            } catch {
                errorText = readable(error)
            }
            working = false
        }
    }

    private func close() {
        inspection?.cleanup()
        onClose()
    }
}
