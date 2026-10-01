import Foundation
import CoreGraphics

/// How the popup presents its action row. The trigger/LLM core is identical for
/// both — only the UI and window placement differ (capsule = horizontal bar above
/// the selection; wheel = a ring centered on the cursor).
enum PopBarStyle: String, CaseIterable, Hashable {
    case capsule
    case wheel
    case liquidGlass
    /// The 3D glass ring (ray-marched with Metal) that leans toward the pointer.
    case donut
    /// Ring-based styles (wheel, liquid glass, donut): centered on the cursor, only
    /// the ring hit-tests. The shell treats them the same for placement /
    /// hit-testing; they differ only in their SwiftUI skin.
    var isWheel: Bool { self == .wheel || self == .liquidGlass || self == .donut }
}

/// The popup's own persistence. App-wide prefs live in `Preferences`.
enum PopBarPreferences {

    // Paths into the config file. These ARE the setting names the user sees when
    // they open it, so they are grouped and spelled for reading, not for storage.
    private enum P {
        static let autoExpandHeight   = "popup.autoExpandHeight"
        static let resultFontSize     = "popup.resultFontSize"
        static let readingHighlight   = "popup.readingHighlight"
        static let style              = "popup.style"
        static let enabled            = "popup.enabled"
        static let hotKeyEnabled      = "popup.hotKeyEnabled"
        static let hotKey             = "popup.hotKey"
        static let simulateCopy       = "popup.simulateCopy"
        static let excludedApps       = "popup.excludedApps"
        static let terminalApps       = "popup.terminalApps"
        static let ignoreAddressBars  = "popup.ignoreAddressBars"
        static let wheelOuterRadius   = "wheel.outerRadius"
        static let wheelInnerRadius   = "wheel.innerRadius"
        static let wheelShowIcons     = "wheel.showIcons"
        static let wheelShowLabels    = "wheel.showLabels"
        static let wheelAutoHideOnExit = "wheel.autoHideOnExit"
        static let wheelDonutDividers = "wheel.donutDividers"
        static let wheelSubSeam       = "wheel.subSeam"
        static let wheelSubThickness  = "wheel.subThickness"
        static let previewFallback    = "webPreview.fallbackToSearch"
        static let previewEngine      = "webPreview.searchEngine"
        static let ocrEnabled         = "ocr.enabled"
        static let ocrAutoCopy        = "ocr.autoCopy"
        static let ocrHotKey          = "ocr.hotKey"
    }

    private static var config: ConfigStore { .shared }

    /// Allowed range + default for the result Markdown's base font size (issue #14).
    /// The user found the old ~12pt body too small, so the default is a touch larger.
    static let resultFontSizeRange: ClosedRange<Double> = 11...20
    static let resultFontSizeDefault: Double = 13

    /// Wheel geometry knobs (apply to both the wheel + liquid-glass styles). Defaults
    /// match the locked design; inner is kept at least `wheelMinThickness` below outer.
    static let wheelOuterRadiusRange: ClosedRange<Double> = 90...170
    static let wheelInnerRadiusRange: ClosedRange<Double> = 28...140
    static let wheelMinThickness: Double = 26
    static let wheelOuterRadiusDefault: Double = 114
    static let wheelInnerRadiusDefault: Double = 54
    /// Submenu ring (second level) geometry. Defaults locked with the user against
    /// `docs/popbar-wheel-submenu-mockup.html`.
    static let wheelSubSeamRange: ClosedRange<Double> = 0...20
    static let wheelSubThicknessRange: ClosedRange<Double> = 34...72
    static let wheelSubSeamDefault: Double = 6
    static let wheelSubThicknessDefault: Double = 52


    /// Whether the result panel auto-grows its HEIGHT to fit the content (up to a
    /// max, then scrolls). Opt-out: defaults to ON, so the result fits its content
    /// out of the box. Width is always fixed.
    static var autoExpandHeight: Bool {
        get { config.bool(P.autoExpandHeight, default: true) }
        set { config.set(P.autoExpandHeight, newValue) }
    }

    /// Which presentation the popup uses. A missing or unrecognized value falls
    /// back to the default, Liquid Glass, rather than refusing to start — this is
    /// a hand-editable file, and a typo in one setting must not take the popup
    /// down with it. (Every seeded file writes the style out, so only a
    /// hand-trimmed file ever reaches this fallback.)
    static var style: PopBarStyle {
        get { PopBarStyle(rawValue: config.string(P.style, default: "")) ?? .liquidGlass }
        set { config.set(P.style, newValue.rawValue) }
    }

    /// Base font size for the result Markdown. Clamped to the allowed range on
    /// BOTH read and write: the write clamps what the UI produces, the read clamps
    /// what a person typed into the file.
    static var resultFontSize: Double {
        get { clamped(config.double(P.resultFontSize, default: resultFontSizeDefault), resultFontSizeRange) }
        set { config.set(P.resultFontSize, clamped(newValue, resultFontSizeRange)) }
    }

    /// How the reading window marks the word being spoken. Unknown values in the
    /// file fall back to the pill.
    static var readingHighlight: ReadingHighlightStyle {
        get { ReadingHighlightStyle(rawValue: config.string(P.readingHighlight, default: ReadingHighlightStyle.pill.rawValue)) ?? .pill }
        set { config.set(P.readingHighlight, newValue.rawValue) }
    }

    // MARK: - Wheel geometry / content (wheel + liquid-glass styles)

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static var wheelOuterRadius: Double {
        get { clamped(config.double(P.wheelOuterRadius, default: wheelOuterRadiusDefault), wheelOuterRadiusRange) }
        set { config.set(P.wheelOuterRadius, clamped(newValue, wheelOuterRadiusRange)) }
    }
    static var wheelInnerRadius: Double {
        get { clamped(config.double(P.wheelInnerRadius, default: wheelInnerRadiusDefault), wheelInnerRadiusRange) }
        set { config.set(P.wheelInnerRadius, clamped(newValue, wheelInnerRadiusRange)) }
    }
    static var wheelShowIcons: Bool {
        get { config.bool(P.wheelShowIcons, default: true) }
        set { config.set(P.wheelShowIcons, newValue) }
    }
    static var wheelShowLabels: Bool {
        get { config.bool(P.wheelShowLabels, default: true) }
        set { config.set(P.wheelShowLabels, newValue) }
    }
    /// Auto-hide the ring when the pointer moves outside it. Opt-out; default ON.
    /// The capsule style ignores this.
    static var wheelAutoHideOnExit: Bool {
        get { config.bool(P.wheelAutoHideOnExit, default: true) }
        set { config.set(P.wheelAutoHideOnExit, newValue) }
    }

    /// Whether the 3D style carves a groove between neighbouring slices. Default on.
    static var wheelDonutDividers: Bool {
        get { config.bool(P.wheelDonutDividers, default: true) }
        set { config.set(P.wheelDonutDividers, newValue) }
    }

    /// Gap between the main ring and the submenu ring.
    static var wheelSubSeam: Double {
        get { clamped(config.double(P.wheelSubSeam, default: wheelSubSeamDefault), wheelSubSeamRange) }
        set { config.set(P.wheelSubSeam, clamped(newValue, wheelSubSeamRange)) }
    }
    /// Band width of the submenu ring.
    static var wheelSubThickness: Double {
        get { clamped(config.double(P.wheelSubThickness, default: wheelSubThicknessDefault), wheelSubThicknessRange) }
        set { config.set(P.wheelSubThickness, clamped(newValue, wheelSubThicknessRange)) }
    }

    // MARK: - Web preview (link fallback)

    /// When the "web preview" action finds no link in the selection, search the web
    /// for the selected text instead. Opt-out; default ON.
    static var previewFallbackToSearch: Bool {
        get { config.bool(P.previewFallback, default: true) }
        set { config.set(P.previewFallback, newValue) }
    }

    /// Which engine the no-link fallback search uses. Anything unrecognized → Bing
    /// (which works both inside and outside mainland China).
    static var previewSearchEngine: PreviewSearchEngine {
        get { PreviewSearchEngine(rawValue: config.string(P.previewEngine, default: "")) ?? .bing }
        set { config.set(P.previewEngine, newValue.rawValue) }
    }

    /// A `WheelLayout` built from the current settings. Inner is clamped to stay at
    /// least `wheelMinThickness` below outer, so the ring is always valid no matter
    /// what the file says.
    static var wheelLayout: WheelLayout {
        let outer = wheelOuterRadius
        let inner = min(wheelInnerRadius, outer - wheelMinThickness)
        return WheelLayout(outerRadius: CGFloat(outer), innerRadius: CGFloat(inner),
                           showIcons: wheelShowIcons, showLabels: wheelShowLabels,
                           submenuSeam: CGFloat(wheelSubSeam),
                           submenuThickness: CGFloat(wheelSubThickness))
    }

    // MARK: - Paused

    /// Whether selecting text opens the popup at all. Default ON; OFF is "paused"
    /// from the menu bar or the settings sidebar. Persisted, so a pause survives a
    /// relaunch — it was switched off by hand and should not switch itself back on.
    /// The screenshot-OCR hotkey is not affected: it is pressed on purpose.
    static var popupEnabled: Bool {
        get { config.bool(P.enabled, default: true) }
        set { config.set(P.enabled, newValue) }
    }

    // MARK: - Popup hotkey (issue #4)

    /// Whether the popup hotkey is registered. Opt-in; default OFF.
    ///
    /// Independent of the pause: pausing stops the popup opening BY ITSELF when
    /// text is selected; the hotkey opens it on purpose, paused or not, and in
    /// excluded apps and address bars too. Paused + hotkey is "only when I ask".
    /// The whole design is in `docs/popup-hotkey.html`.
    static var popupHotKeyEnabled: Bool {
        get { config.bool(P.hotKeyEnabled, default: false) }
        set { config.set(P.hotKeyEnabled, newValue) }
    }

    /// The popup hotkey, written the way it is spoken (`"opt+x"`). Nil until the
    /// user records one: there is no built-in default, because any combo picked
    /// for everyone is some other app's shortcut for someone, and a hotkey that
    /// silently does nothing is worse than one that asks to be set.
    static var popupHotKey: KeyCombo? {
        get { KeyCombo(configString: config.string(P.hotKey, default: "")) }
        set { config.set(P.hotKey, newValue?.configString ?? "") }
    }

    // MARK: - Where the popup reads

    /// Whether the last way of reading a selection — pressing ⌘C for the user and
    /// reading the clipboard — may be used. Opt-out; default ON, because browsers
    /// and Electron apps are only readable this way. Off, the popup reads only what
    /// an app hands over without a key press.
    static var simulateCopy: Bool {
        get { config.bool(P.simulateCopy, default: true) }
        set { config.set(P.simulateCopy, newValue) }
    }

    /// Selecting in a browser's address bar does not open the popup (issue #6).
    static var ignoreAddressBars: Bool {
        get { config.bool(P.ignoreAddressBars, default: true) }
        set { config.set(P.ignoreAddressBars, newValue) }
    }

    /// The ignore rules in force now (built in; see `SelectionIgnoreRules`).
    /// Main thread (reads the config).
    static var activeIgnoreRules: [SelectionIgnoreRules.Rule] {
        SelectionIgnoreRules.enabled(in: ["ignoreAddressBars": ignoreAddressBars])
    }

    /// Bundle IDs of apps where selecting never opens the popup. The screenshot-OCR
    /// hotkey still works there: it is pressed on purpose.
    static var excludedApps: [String] {
        get { config.stringArray(P.excludedApps) }
        set { config.set(P.excludedApps, newValue) }
    }

    /// Terminals in which a program running inside may make the selection and
    /// copy it by itself (herdr, tmux with mouse mode, vim — issue #8). In these
    /// apps a clipboard write during the selecting drag is taken as the selection,
    /// whatever the app itself reports (see `CopyOnSelectStrategy`).
    ///
    /// Not in the file yet → the built-in list is written into it, and from then
    /// on the file is what counts: a terminal the user removed stays removed.
    static var terminalApps: [String] {
        get {
            guard config.value(P.terminalApps) != nil else {
                config.set(P.terminalApps, defaultTerminalApps)
                return defaultTerminalApps
            }
            return config.stringArray(P.terminalApps)
        }
        set { config.set(P.terminalApps, newValue) }
    }

    /// Attaché is the author's own app. Ghostty, Terminal, iTerm2 and OTTY are
    /// installed on the development Mac; the other bundle IDs are the vendors'
    /// published ones, not checked here.
    static let defaultTerminalApps = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.appmakes.otty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "me.xueshi.attache",
    ]

    // MARK: - Screenshot OCR

    /// Whether the screenshot-OCR hotkey is registered. Opt-in; default OFF.
    static var screenOCREnabled: Bool {
        get { config.bool(P.ocrEnabled, default: false) }
        set { config.set(P.ocrEnabled, newValue) }
    }

    /// Also copy the recognized text to the clipboard. Opt-out; default ON.
    static var screenOCRAutoCopy: Bool {
        get { config.bool(P.ocrAutoCopy, default: true) }
        set { config.set(P.ocrAutoCopy, newValue) }
    }

    /// The hotkey that starts a screenshot-OCR capture, written the way it is
    /// spoken: `"shift+cmd+s"`. Anything unparseable falls back to ⌘⇧S rather than
    /// leaving the feature silently unbound.
    static var screenOCRHotKey: KeyCombo {
        get { KeyCombo(configString: config.string(P.ocrHotKey, default: "")) ?? .defaultScreenOCR }
        set { config.set(P.ocrHotKey, newValue.configString) }
    }
}

/// The engines the no-link fallback search can use. Brand names are shown verbatim
/// (not localized). `bing` is the default.
enum PreviewSearchEngine: String, CaseIterable, Hashable {
    case bing, google, duckduckgo

    var displayName: String {
        switch self {
        case .bing:       return "Bing"
        case .google:     return "Google"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// Query-URL prefix; the percent-encoded query is appended.
    var template: String {
        switch self {
        case .bing:       return "https://www.bing.com/search?q="
        case .google:     return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        }
    }
}

/// Builds a search URL for the current engine from selected text.
enum PreviewSearch {
    static func searchURL(for text: String) -> URL? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Encode with only unreserved characters allowed, so query sub-delimiters in
        // the SELECTED TEXT (`&`, `+`, `#`, `=`, …) are percent-escaped as data rather
        // than restructuring the search URL — e.g. "C++ & Swift" stays a single query
        // instead of splitting into extra parameters / spaces (`.urlQueryAllowed`
        // leaves those characters intact, which would change the query).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: PopBarPreferences.previewSearchEngine.template + encoded)
    }
}

/// The reading window's spoken-word mark. Both are drawn behind the text, so the
/// words themselves never change or move.
enum ReadingHighlightStyle: String, CaseIterable {
    /// A soft rounded pill a little wider than the word.
    case pill
    /// A highlighter stroke across the lower half of the word.
    case marker
    /// A solid accent-colour pill with the word in white.
    case solid
    /// Karaoke: text not yet read is faded, read text is normal, and the word
    /// being spoken is in the accent colour.
    case karaoke
}
