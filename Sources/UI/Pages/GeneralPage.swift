import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// The General page: the Accessibility permission, the app-level settings
/// (launch at login, language), how the selection is read and where it is not,
/// and the config / log files.
///
/// There is no global on/off switch, by design. Reading the selection IS the app;
/// a switch for it would only be a slower way to quit. Per-app exclusion covers
/// the real need — "not in this app".
///
/// The Accessibility block appears only while the permission is missing — it is
/// the one thing standing between a fresh install and a working popup, so it goes
/// at the top and disappears the moment it stops being true.
struct GeneralPage: View {

    @ObservedObject private var store: PopBarStore
    private let openOnboarding: () -> Void

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var languageCode: String? = Preferences.languageOverride
    /// Set when the recorded popup hotkey could not be registered (another app,
    /// or the screenshot-OCR hotkey, has it), so the field can say so.
    @State private var popupHotKeyError = false

    /// The Accessibility grant happens in System Settings, in another process — the
    /// app is never told. Polling is the only way to notice, and two seconds is
    /// fast enough to feel immediate without being busy work.
    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let systemTag = "__system__"
    private static let log = FileLog("GeneralPage")

    init(store: PopBarStore, openOnboarding: @escaping () -> Void = {}) {
        _store = ObservedObject(wrappedValue: store)
        self.openOnboarding = openOnboarding
    }

    var body: some View {
        Form {
            if !store.isTrusted { permissionSection }
            appSection
            popupHotKeySection
            readingSection
            excludedAppsSection
            terminalAppsSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.general"))
        .onAppear {
            store.refreshTrust()
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
        .onReceive(trustPoll) { _ in store.refreshTrust() }
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
                    HotKeyRecorderField(combo: store.popupHotKey) { combo in
                        popupHotKeyError = !store.setPopupHotKey(combo)
                    }
                } label: {
                    iconLabel("command", .purple, L("popbar.ocr.hotkey.label"))
                }
                if store.popupHotKey == nil {
                    Text(L("popbar.hotkey.notSet"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if popupHotKeyError || !store.popupHotKeyRegistered {
                    Text(L("popbar.ocr.hotkey.occupied"))
                        .font(.caption).foregroundStyle(.orange)
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
                    iconLabel("command", .blue, L("popbar.simulateCopy.title"))
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

    // MARK: - Excluded apps

    private var excludedAppsSection: some View {
        Section {
            if store.excludedApps.isEmpty {
                Text(L("popbar.excluded.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.excludedApps, id: \.self) { id in
                ExcludedAppRow(bundleID: id) { store.includeApp(id) }
            }
            addAppMenu(skipping: store.excludedApps) { store.excludeApp($0) }
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
                ExcludedAppRow(bundleID: id) { store.removeTerminalApp(id) }
            }
            addAppMenu(skipping: store.terminalApps) { store.addTerminalApp($0) }
        } header: {
            Text(L("popbar.terminals.header"))
        } footer: {
            Text(L("popbar.terminals.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Add App…": the running apps not on the list yet, then a file chooser.
    private func addAppMenu(skipping listed: [String], add: @escaping (String) -> Void) -> some View {
        Menu(L("popbar.excluded.add")) {
            let running = Self.runningApps(excluding: listed)
            ForEach(running, id: \.bundleID) { app in
                Button {
                    add(app.bundleID)
                } label: {
                    // Menus drop a Label's icon unless the style asks for it.
                    Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        .labelStyle(.titleAndIcon)
                }
            }
            if !running.isEmpty { Divider() }
            Button(L("popbar.excluded.choose")) { chooseApp(add) }
        }
        .fixedSize()
    }

    private struct RunningApp {
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    /// Apps with a Dock presence, alphabetised — the ones a person selects text in.
    private static func runningApps(excluding excluded: [String]) -> [RunningApp] {
        var seen = Set(excluded)
        seen.insert(Bundle.main.bundleIdentifier ?? "")
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return RunningApp(bundleID: id, name: app.localizedName ?? id,
                                  icon: Self.menuIcon(app.icon))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func menuIcon(_ image: NSImage?) -> NSImage {
        let icon = (image ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// For an app that is not running right now.
    private func chooseApp(_ add: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }

    // MARK: - Accessibility permission

    private var permissionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("popbar.perm.title")).fontWeight(.medium)
                    Text(L("popbar.perm.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(L("popbar.perm.grant")) { store.requestPermission() }
                Button(L("popbar.perm.open")) { store.openAccessibilitySettings() }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text(L("popbar.perm.header"))
        }
    }

    // MARK: - App

    private var appSection: some View {
        Section {
            // The onboarding guide opens by itself once, on a new install. This is
            // the way back to it — always here, finished or not.
            LabeledContent {
                Button(L("onboarding.settings.open")) { openOnboarding() }
            } label: {
                iconLabel("hand.wave.fill", .orange, L("onboarding.settings.title"))
            }
            Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                iconLabel("power", .green, L("Launch at Login"))
            }
            Picker(selection: Binding(
                get: { languageCode ?? Self.systemTag },
                set: { setLanguage($0 == Self.systemTag ? nil : $0) }
            )) {
                Text(L("language.followSystem")).tag(Self.systemTag)
                ForEach(LocalizationOverride.supportedCodes, id: \.self) { code in
                    Text(LocalizationOverride.nativeName(for: code)).tag(code)
                }
            } label: {
                iconLabel("globe", .cyan, L("Language"))
            }
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
        } header: {
            Text(L("Diagnostics"))
        }
    }

    // MARK: - Actions

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Self.log.error("Failed to toggle launch at login: \(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setLanguage(_ code: String?) {
        languageCode = code
        Preferences.setLanguageOverride(code)
    }
}

/// One app on a list (excluded apps, terminals): its icon and name when it is
/// installed, the bare bundle ID when it is not (a hand-edited config, an app
/// since deleted, a default terminal never installed) — still removable either way.
private struct ExcludedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = appURL(for: bundleID)
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                  ?? NSWorkspace.shared.icon(for: .application))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                if url != nil {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("popbar.excluded.remove"), action: remove)
                .buttonStyle(.borderless)
        }
    }
}

/// Where the app with this bundle ID is: the copy Launch Services knows about,
/// or else a running copy. An app run straight from a build folder (a
/// development build, say) is often not registered, so only the running app
/// can say where it is.
private func appURL(for bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
}
