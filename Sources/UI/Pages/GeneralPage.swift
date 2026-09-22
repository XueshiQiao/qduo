import SwiftUI
import AppKit
import ServiceManagement

/// The General page: the master switch and its two failure modes, plus the
/// app-level settings that have nowhere better to live (launch at login,
/// language, the log file).
///
/// The Accessibility block appears only while the permission is missing — it is
/// the one thing standing between a fresh install and a working popup, so it goes
/// at the top and disappears the moment it stops being true.
struct GeneralPage: View {

    @ObservedObject private var store: PopBarStore

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var languageCode: String? = Preferences.languageOverride

    /// The Accessibility grant happens in System Settings, in another process — the
    /// app is never told. Polling is the only way to notice, and two seconds is
    /// fast enough to feel immediate without being busy work.
    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let systemTag = "__system__"
    private static let log = FileLog("GeneralPage")

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            statusSection
            if !store.isTrusted { permissionSection }
            appSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.general"))
        .onAppear {
            store.refreshTrust()
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
        .onReceive(trustPoll) { _ in store.refreshTrust() }
        // Editing the config file by hand is a supported way to change these, so
        // the controls have to follow it rather than showing a stale reading.
        .onReceive(NotificationCenter.default.publisher(for: .configReloadedFromDisk)) { _ in
            languageCode = Preferences.languageOverride
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })) {
                featureLabel("text.bubble.fill", .indigo,
                             L("popbar.enable.title"), L("popbar.enable.subtitle"))
            }
            LabeledContent {
                HStack(spacing: 6) {
                    StatusDot(active: running)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(running ? .green : .orange)
                }
            } label: {
                iconLabel("dot.radiowaves.left.and.right", running ? .green : .gray,
                          L("popbar.status.title"))
            }
        }
    }

    private var running: Bool { store.isEnabled && store.isTrusted }

    private var statusText: String {
        if !store.isTrusted { return L("popbar.status.needsPermission") }
        return store.isEnabled ? L("popbar.status.on") : L("popbar.status.off")
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
