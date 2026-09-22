import SwiftUI

/// The settings window's sidebar: a fixed list of pages.
///
/// This replaces the plug-in tool registry the code was extracted from. That
/// registry existed so a multi-tool app could grow tabs without the shell knowing
/// about them; this app is one tool, so the indirection bought nothing and the
/// pages are simply named here. Order in `allCases` is order in the sidebar, and
/// `Block` decides where the separators fall.
enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
    case general
    case actions
    case appearance
    case ocr
    case models
    case about

    var id: String { rawValue }

    /// Which sidebar block the row sits in. Blocks are separated by a gap with no
    /// header, the way System Settings separates its groups.
    enum Block: Int, CaseIterable { case popup, app }

    var block: Block {
        switch self {
        case .general, .actions, .appearance, .ocr: return .popup
        case .models, .about:                       return .app
        }
    }

    var title: String {
        switch self {
        case .general:    return L("page.general")
        case .actions:    return L("page.actions")
        case .appearance: return L("page.appearance")
        case .ocr:        return L("page.ocr")
        case .models:     return L("page.models")
        case .about:      return L("page.about")
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .actions:    return "list.bullet.rectangle.fill"
        case .appearance: return "circle.hexagongrid.fill"
        case .ocr:        return "viewfinder"
        case .models:     return "brain.head.profile"
        case .about:      return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general:    return Color(nsColor: .systemGray)
        case .actions:    return .indigo
        case .appearance: return .purple
        case .ocr:        return .teal
        case .models:     return .blue
        case .about:      return .pink
        }
    }

    /// Stable id stem for accessibility identifiers — never localized.
    var axID: String { "page_\(rawValue)" }

    static func block(_ block: Block) -> [SettingsPage] {
        allCases.filter { $0.block == block }
    }
}
