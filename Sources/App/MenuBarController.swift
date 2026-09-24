import Cocoa
import Combine

/// The status-bar item and its menu.
///
/// This app has no Dock icon, so the status item is its ONLY entry point: the menu
/// has to carry everything you cannot otherwise reach, Quit included. A left-click
/// therefore opens the menu directly — there is nowhere else to put it.
final class MenuBarController: NSObject {

    private static let log = FileLog("MenuBar")

    /// The app icon's ring and arc without the tile, drawn by
    /// scripts/make-menubar-icon.py. The catalogue marks it as a template, so the
    /// system tints it for light, dark and highlighted menu bars.
    private static let iconName = "MenuBarIcon"

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateController: UpdateController
    private lazy var mainWindowController = MainWindowController(appState: appState)
    private lazy var onboardingWindowController = OnboardingWindowController(appState: appState)

    private var storeObserver: AnyCancellable?

    private enum Tag: Int { case finishSetup = 100, ocr = 200, update = 600 }

    init(appState: AppState, updateController: UpdateController) {
        self.appState = appState
        self.updateController = updateController
        super.init()
        setupStatusItem()
        appState.showOnboarding = { [weak self] in self?.showOnboarding(reason: .manual) }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // A missing image would leave an invisible slot — and the status item is
            // the app's only entry point — so fall back to a system symbol.
            let image = NSImage(named: Self.iconName) ?? {
                Self.log.error("\(Self.iconName) missing from the asset catalogue")
                return NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            }()
            image?.isTemplate = true
            image?.accessibilityDescription = Brand.name
            button.image = image
        }
        // Attached permanently: with no Dock icon there is no second gesture to
        // reserve, so every click should show the menu.
        statusItem.menu = buildMenu()

        // The icon dims when the app cannot work — i.e. Accessibility has not been
        // granted. It is a warning, not a switch: there is nothing to turn on.
        storeObserver = appState.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = !appState.store.isTrusted
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "\(Brand.name) v\(Brand.version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Only while the app cannot work (Accessibility missing): back into the
        // onboarding guide. Hidden otherwise — see `menuWillOpen`.
        let finishItem = NSMenuItem(title: L("menu.finishSetup"),
                                    action: #selector(openOnboarding(_:)), keyEquivalent: "")
        finishItem.target = self
        finishItem.tag = Tag.finishSetup.rawValue
        if #available(macOS 14.4, *) { finishItem.subtitle = L("menu.finishSetup.subtitle") }
        finishItem.isHidden = appState.store.isTrusted
        menu.addItem(finishItem)

        let ocrItem = NSMenuItem(title: L("menu.captureText"),
                                 action: #selector(captureText(_:)), keyEquivalent: "")
        ocrItem.target = self
        ocrItem.tag = Tag.ocr.rawValue
        menu.addItem(ocrItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("menu.settings"),
                                      action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L("Check for Updates…"),
                                    action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = Tag.update.rawValue
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let feedbackItem = NSMenuItem(title: L("Feedback…"),
                                      action: #selector(openFeedback(_:)), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        let moreAppsItem = NSMenuItem(title: L("More Apps by Author…"),
                                      action: #selector(openAuthorWebsite(_:)), keyEquivalent: "")
        moreAppsItem.target = self
        menu.addItem(moreAppsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(format: L("menu.quit.format"), Brand.name),
                                  action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    /// Open the settings window (used by the menu and by the first-run path).
    func showMainWindow() {
        mainWindowController.show()
    }

    /// Open the onboarding guide (first launch, relaunch, Settings, the menu).
    func showOnboarding(reason: OnboardingOpenReason) {
        onboardingWindowController.show(reason: reason)
    }

    // MARK: - Actions

    @objc private func openOnboarding(_ sender: NSMenuItem) {
        showOnboarding(reason: .manual)
    }

    @objc private func captureText(_ sender: NSMenuItem) {
        appState.controller.triggerScreenOCR()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        showMainWindow()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updateController.checkForUpdates(sender)
    }

    @objc private func openFeedback(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Brand.feedbackURL)
    }

    @objc private func openAuthorWebsite(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Brand.authorWebsiteURL)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    /// State is read when the menu opens, not when it was built — otherwise the
    /// checkmark shows whatever was true the last time something rebuilt the menu.
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: Tag.ocr.rawValue) {
            // Greyed out rather than hidden: an absent row reads as a missing
            // feature, a greyed one as a switch you have not turned on yet.
            item.isEnabled = appState.store.screenOCREnabled
        }
        if let item = menu.item(withTag: Tag.update.rawValue) {
            item.isEnabled = updateController.canCheckForUpdates
        }
        appState.store.refreshTrust()
        menu.item(withTag: Tag.finishSetup.rawValue)?.isHidden = appState.store.isTrusted
    }
}
