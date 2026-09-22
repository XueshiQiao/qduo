import Cocoa
import SwiftUI

// MARK: - MainWindowController
//
// Hosts the SwiftUI settings UI in a single window with a native sidebar.
// Closing hides the window rather than terminating: this is a menu-bar app, and
// the popup has to keep working after you close the settings.
final class MainWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let root = MainView().environmentObject(appState)
        let hosting = NSHostingController(rootView: root)

        window = NSWindow(contentViewController: hosting)
        window.title = Brand.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 860, height: 600))
        // Keyed off the bundle id rather than the name, so the remembered position
        // survives a rename.
        window.setFrameAutosaveName("\(Brand.baseID).main")
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        // ORDER MATTERS on macOS 14+ (cooperative activation): order the window
        // front FIRST, then activate the app. The other way round routinely leaves
        // the window BEHIND the previously-frontmost app, because the system defers
        // the activation while the order-front has already run.
        //
        // Deliberately NOT `orderFrontRegardless`: that fronts the window without
        // keying it (only the ACTIVE app can own a key window), which breaks text
        // field focus app-wide — keystrokes leak to the previously-active app.
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileLog("MainWindow").debug("window shown — windowNumber=\(self.window.windowNumber)")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}

// MARK: - Root view

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selection) {
                ForEach(SettingsPage.Block.allCases, id: \.rawValue) { block in
                    Section {
                        ForEach(SettingsPage.block(block)) { page in
                            row(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Pin the sidebar to a FIXED width (min == max). Without this, dragging
            // the window narrow makes the split view squeeze the sidebar and clip
            // the labels — only the detail area may resize.
            .navigationSplitViewColumnWidth(212)
            .safeAreaInset(edge: .top, spacing: 0) { brand }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(store: appState.store) }
        } detail: {
            detail
                .accessibilityIdentifier(appState.selection.axID)
                .environment(\.defaultMinListRowHeight, 34)
                .scrollContentBackground(.hidden)
                .auroraBackground()
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: toggleSidebar) { Image(systemName: "sidebar.leading") }
                            .help(L("nav.toggleSidebar"))
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 540)
        // Re-key the whole tree on an in-app language change so every label
        // re-reads. `selection` lives on the store, so it survives the rebuild.
        .id(appState.languageRevision)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .general:    GeneralPage(store: appState.store)
        case .actions:    ActionsPage(actions: appState.actions, llm: appState.llm)
        case .appearance: AppearancePage(store: appState.store)
        case .ocr:        OCRPage(store: appState.store)
        case .models:     ModelsPage(settings: appState.llm.settings)
        case .about:      AboutPage()
        }
    }

    private func row(_ page: SettingsPage) -> some View {
        HStack(spacing: 9) {
            SidebarIcon(symbol: page.symbol, color: page.color)
            Text(page.title)
        }
        .padding(.vertical, 2)
        .tag(page)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.\(page.axID)")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable().frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name).font(.system(size: 14, weight: .bold))
                Text(verbatim: "v\(Brand.version)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}

/// Live "is the popup actually working right now" line, shown under the sidebar
/// on every page — it can be off for two different reasons (switched off, or not
/// granted Accessibility) and the difference is the whole story.
///
/// Its own view because it observes the popup's store, which the root view does
/// not: without that, the line would keep whatever it said when the window opened.
private struct StatusFooter: View {
    @ObservedObject var store: PopBarStore

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(active: store.isEnabled && store.isTrusted)
            Text(text)
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var text: String {
        if !store.isTrusted { return L("popbar.status.needsPermission") }
        return store.isEnabled ? L("popbar.status.on") : L("popbar.status.off")
    }
}
