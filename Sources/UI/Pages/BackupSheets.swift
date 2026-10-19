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

/// One checkbox row: icon tile, title with its count, and a line under it.
private struct PartToggle: View {
    let part: BackupManifest.Part
    let detail: String?
    let note: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            let (symbol, color) = partSymbol(part)
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(partTitle(part))
                        if let detail { Text(detail).foregroundStyle(.secondary) }
                    }
                    if let note {
                        Text(note)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
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
    @State private var confirm = ""
    @State private var iconCount = 0
    @State private var keyCount = 0
    @State private var historyCount: Int?
    @State private var historySize: Int64 = 0
    @State private var working = false
    @State private var errorText: String?
    @State private var savedTo: URL?

    private var passwordsMatch: Bool { password == confirm }
    /// Nothing can be changed while the file is being written, or once it is.
    private var locked: Bool { working || savedTo != nil }
    private var canExport: Bool {
        !chosen.isEmpty && !working && (!chosen.contains(.keys) || (!password.isEmpty && passwordsMatch))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    toggle(.config, detail: nil, note: L("backup.part.config.note"))
                    toggle(.icons, detail: String(format: L("backup.count.icons"), iconCount), note: nil)
                    toggle(.keys, detail: String(format: L("backup.count.keys"), keyCount),
                           note: L("backup.part.keys.note"))
                    if chosen.contains(.keys) {
                        SecureField(L("backup.password"), text: $password)
                            .disabled(locked)
                        SecureField(L("backup.password.confirm"), text: $confirm)
                            .disabled(locked)
                        if !confirm.isEmpty && !passwordsMatch {
                            Text(L("backup.password.mismatch"))
                                .font(.caption).foregroundStyle(.orange)
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
        PartToggle(part: part, detail: detail, note: note, isOn: Binding(
            get: { chosen.contains(part) },
            set: { on in
                if on { chosen.insert(part) } else { chosen.remove(part) }
                errorText = nil
            }))
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
                                    inspection.localKeyTitles.joined(separator: ", ")))
                if chosen.contains(.keys) {
                    SecureField(L("backup.password"), text: $password)
                        .onChange(of: password) { _ in wrongPassword = false }
                        .disabled(finished != nil || working)
                    if wrongPassword {
                        Text(L("backup.password.wrong"))
                            .font(.caption).foregroundStyle(.orange)
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
        PartToggle(part: part, detail: detail, note: note, isOn: Binding(
            get: { chosen.contains(part) },
            set: { on in
                if on { chosen.insert(part) } else { chosen.remove(part) }
                errorText = nil
            }))
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
