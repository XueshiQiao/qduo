import AppKit
import ApplicationServices

/// For the apps on the user's ⌘C-first list (`PopBarPreferences.copyFirstApps`):
/// read the selection through Accessibility as usual, then take the TEXT from a
/// ⌘C instead.
///
/// Why: some apps hand over a selection that is readable but lossy. Chrome's
/// accessibility text of a web page drops the line breaks between paragraphs, so
/// several paragraphs arrive as one; what Chrome puts on the clipboard for ⌘C
/// keeps them. (Safari's accessibility text keeps them, so it is not listed.)
///
/// The Accessibility read still comes first, and decides whether ⌘C is pressed
/// at all:
///  - it read nothing → return nil and let the ordinary chain run, exactly as
///    for an app that is not listed. No ⌘C is sent on its account, so a drag
///    that selected no text cannot make the app beep.
///  - it read text → press ⌘C. If text lands on the clipboard, that text is the
///    result, with the element Accessibility read from attached, so Replace and
///    the link tiers work as they do on the Accessibility path. If nothing
///    lands, the Accessibility text is the result.
///
/// Limited to a list on purpose. A ⌘C on every selection costs time (the app
/// copies asynchronously) and a clipboard manager may record the copied text if
/// it looks at the clipboard before it is put back; neither is worth paying in
/// apps whose accessibility text is already right.
final class CopyFirstStrategy: SelectionStrategy {

    /// Results carry the id of the read that produced their text.
    let id = SelectionStrategyID.clipboardCopy
    private static let log = FileLog("PopBar.CopyFirst")

    private let accessibility: SelectionStrategy
    private let copy: (SelectionContext) async throws -> SelectionResult?

    init(accessibility: SelectionStrategy,
         copy: @escaping (SelectionContext) async throws -> SelectionResult?) {
        self.accessibility = accessibility
        self.copy = copy
    }

    func canHandle(_ context: SelectionContext) -> Bool {
        context.prefersSimulatedCopy && context.allowsSimulatedCopy
    }

    func selectedText(_ context: SelectionContext) async throws -> SelectionResult? {
        guard let direct = try await accessibility.selectedText(context),
              !direct.text.isBlankSelection else { return nil }

        let copied: SelectionResult?
        do {
            copied = try await copy(context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            copied = nil
        }
        guard var result = copied, !result.text.isBlankSelection else {
            Self.log.debug("⌘C brought nothing — using the \(direct.text.count) char(s) read directly")
            return direct
        }
        result.sourceElement = direct.sourceElement
        result.bounds = direct.bounds
        if result.focusedElement == nil { result.focusedElement = direct.focusedElement }
        Self.log.debug("⌘C text used: \(result.text.count) char(s), read directly: \(direct.text.count)")
        return result
    }
}
