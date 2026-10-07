import AppKit

/// The fallback: when the Accessibility API can't read the selection (browsers
/// that hide their tree, Electron before it's enabled, custom text views), copy
/// it the way a human would — synthesize ⌘C and read the clipboard — but do it
/// non-destructively by backing up and restoring the clipboard around the copy.
///
/// Correctness hinges on two things, both lifted from the mature reference
/// implementations:
///  - **changeCount polling**: don't read after a fixed sleep (the target app
///    copies asynchronously); poll `NSPasteboard.changeCount` until it actually
///    advances, then read. Avoids grabbing stale/old clipboard text.
///  - **full backup/restore**: snapshot every item and type, restore after, so
///    the user's clipboard is untouched.
final class ClipboardCopyStrategy: SelectionStrategy {

    let id = SelectionStrategyID.clipboardCopy
    private static let log = FileLog("PopBar.Clipboard")

    /// Poll cadence and ceiling for confirming the copy landed.
    private let pollInterval: TimeInterval = 0.005   // 5ms
    private let pollTimeout: TimeInterval = 0.4       // 400ms

    /// Off when the user turned the ⌘C fallback off in Settings.
    func canHandle(_ context: SelectionContext) -> Bool { context.allowsSimulatedCopy }

    func selectedText(_ context: SelectionContext) async throws -> SelectionResult? {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionDenied }

        // issue #15 — gate the synthetic ⌘C on a plausible TEXT selection. The
        // drag gesture fires on ANY drag (a Finder icon, a list row, a window),
        // and posting ⌘C with nothing copyable makes the frontmost app play the
        // system "funk" beep. Ask AX first; if there's clearly no text selection,
        // skip the copy silently (no beep). See AXSelectionProbe for the policy
        // and the AX-opaque (Electron) tradeoff.
        let decision = await MainActor.run { AXSelectionProbe.shouldAttemptCopy() }
        var via = "ax"
        var attempt = decision.shouldCopy
        if !attempt, let pid = context.pid,
           !AXSelectionProbe.isNonTextSelectionRole(decision.role) {
            // AX saw no selection — but it can be AX-OPAQUE: some apps render selectable
            // text as `AXStaticText` (or expose no focused element) and report a 0-length
            // range even with a live selection (e.g. WeChat chat bubbles). The app's own
            // Copy command is the authoritative signal — it's enabled iff something
            // copyable is selected — so consult it as a second chance. A non-selectable
            // label drag leaves Copy DISABLED, so we still skip and never beep (issue #15).
            //
            // We DON'T take this chance when the focus is a table/list/outline row or cell
            // (`isNonTextSelectionRole`): those enable Copy for a row/cell selection that
            // isn't text, so a drag over a table/sidebar/spreadsheet would otherwise
            // false-trigger. File copies are additionally rejected below by the file-URL
            // check after the copy lands.
            let copyEnabled = await MainActor.run { AXSelectionProbe.copyMenuItemEnabled(forPID: pid) }
            if copyEnabled == true {
                attempt = true
                via = "copy-menu-enabled"
            }
        }
        guard attempt else {
            Self.log.debug("skip ⌘C — no selection (role=\(decision.role) selRangeLen=\(decision.rangeLength), Copy menu not enabled)")
            return nil
        }
        Self.log.debug("send ⌘C — via \(via) (role=\(decision.role) selRangeLen=\(decision.rangeLength))")
        return try await copyAndRead(context)
    }

    /// Press ⌘C, read what lands on the clipboard, put the clipboard back.
    /// No check that anything is selected: the caller has already established
    /// that (the gate in `selectedText`, or `CopyFirstStrategy` having read the
    /// selection through Accessibility).
    ///
    /// Once the ⌘C is sent, the wait for the app's copy and the restore run to
    /// the end even if this read is cancelled (a newer trigger took over): the
    /// app copies asynchronously, and a restore done before its write lands
    /// would be overwritten by it, leaving the selection on the user's
    /// clipboard. For the same reason one copy finishes before the next starts —
    /// otherwise the next one could back up the previous one's copied text as if
    /// it were the user's.
    func copyAndRead(_ context: SelectionContext) async throws -> SelectionResult? {
        try Task.checkCancellation()
        let abandoned = Abandoned()
        let result = await withTaskCancellationHandler {
            let task = await MainActor.run { () -> Task<SelectionResult?, Never> in
                let previous = inFlight
                let task = Task.detached { [self] () -> SelectionResult? in
                    _ = await previous?.value
                    // Given up while waiting its turn: no ⌘C on its account.
                    if abandoned.isSet { return nil }
                    return await performCopy(context)
                }
                inFlight = task
                return task
            }
            return await task.value
        } onCancel: {
            abandoned.set()
        }
        try Task.checkCancellation()
        return result
    }

    /// The copy still running or waiting, if any. Main thread only.
    private var inFlight: Task<SelectionResult?, Never>?

    /// Set when the read that asked for a copy was cancelled.
    private final class Abandoned: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Runs outside the read's own task, so a cancellation cannot stop it half-way.
    private func performCopy(_ context: SelectionContext) async -> SelectionResult? {
        let backup = await MainActor.run { Pasteboard.backup() }
        let initialChangeCount = await MainActor.run { NSPasteboard.general.changeCount }

        await MainActor.run { KeySender.copy() }

        var captured: String?
        var clipboardChanged = false
        let start = Date()
        while Date().timeIntervalSince(start) < pollTimeout {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            let (changeCount, string, isFileCopy) = await MainActor.run { () -> (Int, String?, Bool) in
                let pb = NSPasteboard.general
                return (pb.changeCount, pb.string(forType: .string), pb.types?.contains(.fileURL) ?? false)
            }
            if changeCount != initialChangeCount {
                clipboardChanged = true
                // The Copy command also enables on NON-text selections — files in
                // Finder, list / sidebar rows — which the `copy-menu-enabled` second
                // chance can't tell apart from text up front. Those land a FILE URL on
                // the pasteboard; reject them so a non-text drag never pops PopBar with a
                // filename/path (that's the false-trigger class the AX gate guards — the
                // second chance must not reopen it). A real text selection never carries
                // a file URL.
                if isFileCopy { break }
                // Clipboard advanced. Accept a non-empty string; a changed-but-empty
                // clipboard means another manager raced us — keep waiting briefly.
                if let string, !string.isEmpty { captured = string; break }
            }
        }

        // Before restoring, grab the rich pasteboard (+ focused element) for
        // LinkResolver — the copied HTML/RTF carries the anchor's href, and it's gone
        // once we restore the user's original clipboard.
        var capturedHTML: Data?
        var capturedRTF: Data?
        var capturedElement: AXUIElement?
        if context.resolvesLinks, captured != nil {
            (capturedHTML, capturedRTF, capturedElement) = await MainActor.run { () -> (Data?, Data?, AXUIElement?) in
                let pb = NSPasteboard.general
                return (pb.data(forType: .html), pb.data(forType: .rtf), AXSelectionProbe.focusedElement())
            }
        }

        // Restore whenever the clipboard changed, whether or not we captured
        // anything. Unchanged (the app ignored the ⌘C) → it still holds the
        // user's content, and writing it back would only be one more change for
        // a clipboard manager to look at.
        if clipboardChanged {
            await MainActor.run { _ = Pasteboard.restore(backup) }
        }

        guard let text = captured else {
            Self.log.debug("clipboard copy did not land within \(Int(self.pollTimeout * 1000))ms")
            return nil
        }
        var result = SelectionResult(text: text, via: id, bounds: nil)
        result.focusedElement = capturedElement
        result.htmlData = capturedHTML
        result.rtfData = capturedRTF
        return result
    }
}
