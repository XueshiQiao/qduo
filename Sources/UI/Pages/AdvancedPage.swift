import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Advanced page: the settings most people never touch — the popup hotkey
/// (off by default), how the selection is read and where it is not (excluded
/// apps, terminals), and the config / log files.
///
/// Everything here is either opt-in or a workaround for one app. Keeping it off
/// the General page keeps that page to what a new user actually decides: the
/// app's own settings and what the popup looks like.
struct AdvancedPage: View {

    @ObservedObject private var store: PopBarStore

    #if DEBUG
    @AppStorage(DebugReadViaBadge.enabledKey) private var showReadViaBadge = true
    #endif
    /// Set when the recorded popup hotkey could not be registered (another app,
    /// or the screenshot-OCR hotkey, has it), so the field can say so.
    @State private var popupHotKeyError = false
    @State private var showExport = false
    /// The backup chosen in the open panel; the import sheet is up while set.
    @State private var importing: BackupFile?

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            popupHotKeySection
            readingSection
            copyFirstAppsSection
            excludedAppsSection
            terminalAppsSection
            backupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.advanced"))
        .sheet(isPresented: $showExport) {
            BackupExportSheet { showExport = false }
        }
        .sheet(item: $importing) { file in
            BackupImportSheet(zip: file.url) { importing = nil }
        }
    }

    // MARK: - Backup (issue #22)

    /// The config file alone is not the user's setup: the icon pictures sit in a
    /// folder beside it, the API keys in the Keychain and the history in its own
    /// database. A backup carries all four.
    private var backupSection: some View {
        Section {
            LabeledContent {
                Button(L("backup.export.button")) { showExport = true }
            } label: {
                iconLabel("square.and.arrow.up", .blue, L("backup.export.title"))
            }
            LabeledContent {
                Button(L("backup.import.button")) { chooseBackup() }
            } label: {
                iconLabel("square.and.arrow.down", .green, L("backup.import.title"))
            }
        } header: {
            Text(L("backup.header"))
        } footer: {
            Text(String(format: L("backup.footer"), Brand.name))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = BackupFile(url: url)
    }

    // MARK: - Popup hotkey (issue #4)

    /// Independent of the pause, on purpose: the pause is about the popup opening
    /// by itself, the hotkey about opening it when asked. Paused + hotkey is the
    /// "only when I press it" mode. See `docs/popup-hotkey.html`.
    private var popupHotKeySection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.popupHotKeyEnabled },
                                 set: { popupHotKeyError = !store.setPopupHotKeyEnabled($0) })) {
                featureLabel("keyboard", .purple,
                             L("popbar.hotkey.enable.title"), L("popbar.hotkey.enable.subtitle"))
            }
            if store.popupHotKeyEnabled {
                LabeledContent {
                    HotKeyRecorderField(hotKey: store.popupHotKey) { trigger in
                        popupHotKeyError = !store.setPopupHotKey(trigger)
                    }
                } label: {
                    iconLabel("command", .purple, L("popbar.ocr.hotkey.label"))
                }
                Text(L("popbar.hotkey.doubleTap.caption"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A rejected shortcut is reported first: with none recorded yet, the
                // "record one" hint would otherwise hide that the try failed.
                if store.popupHotKey == nil && !popupHotKeyError {
                    Text(L("popbar.hotkey.notSet"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if popupHotKeyError || !store.popupHotKeyRegistered {
                    Text(L("popbar.ocr.hotkey.occupied"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .doubleTap = store.popupHotKey {
                    Text(L("popbar.hotkey.doubleTap.note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(L("popbar.hotkey.header"))
        } footer: {
            Text(String(format: L("popbar.hotkey.footer"), Brand.name))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - How the selection is read

    private var readingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.simulateCopy }, set: { store.setSimulateCopy($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    iconLabel("command", .blue, String(format: L("popbar.simulateCopy.title"), Brand.name))
                    Text(L("popbar.simulateCopy.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { store.ignoreAddressBars }, set: { store.setIgnoreAddressBars($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    iconLabel("link", .blue, L("popbar.ignoreAddressBars.title"))
                    Text(L("popbar.ignoreAddressBars.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(L("popbar.reading.header"))
        }
    }

    // MARK: - Apps read with ⌘C first

    private var copyFirstAppsSection: some View {
        Section {
            // Only the installed ones, as with the terminals below.
            let installed = store.copyFirstApps.filter { appURL(for: $0) != nil }
            if installed.isEmpty {
                Text(L(store.copyFirstApps.isEmpty ? "popbar.copyFirst.none" : "popbar.copyFirst.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(installed, id: \.self) { id in
                AppListRow(bundleID: id) { store.removeCopyFirstApp(id) }
            }
            AddAppMenu(skipping: store.copyFirstApps) { store.addCopyFirstApp($0) }
        } header: {
            Text(L("popbar.copyFirst.header"))
        } footer: {
            Text(L("popbar.copyFirst.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!store.simulateCopy)
    }

    // MARK: - Excluded apps

    private var excludedAppsSection: some View {
        Section {
            if store.excludedApps.isEmpty {
                Text(L("popbar.excluded.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.excludedApps, id: \.self) { id in
                AppListRow(bundleID: id) { store.includeApp(id) }
            }
            AddAppMenu(skipping: store.excludedApps) { store.excludeApp($0) }
        } header: {
            Text(L("popbar.excluded.header"))
        } footer: {
            Text(L("popbar.excluded.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Terminals

    private var terminalAppsSection: some View {
        Section {
            // Only the installed ones: the built-in list names terminals most
            // people don't have. The others stay in the config file untouched.
            let installed = store.terminalApps.filter { appURL(for: $0) != nil }
            if installed.isEmpty {
                Text(L("popbar.terminals.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(installed, id: \.self) { id in
                AppListRow(bundleID: id) { store.removeTerminalApp(id) }
            }
            AddAppMenu(skipping: store.terminalApps) { store.addTerminalApp($0) }
        } header: {
            Text(L("popbar.terminals.header"))
        } footer: {
            Text(L("popbar.terminals.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            // Nothing else in the app mentions that this file exists, and it is
            // the one place every setting actually lives — so it needs a door.
            LabeledContent {
                Button(L("diagnostics.revealConfig")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.shared.fileURL])
                }
            } label: {
                iconLabel("doc.badge.gearshape", .indigo, L("diagnostics.config.title"))
            }
            Text(String(format: L("diagnostics.config.subtitle"), ConfigStore.shared.fileURL.path))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent {
                Button(L("diagnostics.revealLog")) {
                    NSWorkspace.shared.activateFileViewerSelecting([FileLog.url])
                }
            } label: {
                iconLabel("doc.text", Color(nsColor: .systemGray), L("diagnostics.log.title"))
            }
            Text(String(format: L("diagnostics.log.subtitle"), Brand.name, FileLog.url.path))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if DEBUG
            // Debug builds only: the AX / Clipboard / ⌘C label under the popup.
            Toggle(isOn: $showReadViaBadge) {
                iconLabel("tag", .orange, L("diagnostics.readViaBadge"))
            }
            #endif
        } header: {
            Text(L("Diagnostics"))
        }
    }
}

/// A chosen backup file, as the import sheet's item.
private struct BackupFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
