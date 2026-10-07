# Known issues

Problems we know about and chose not to fix yet, with what we found and the options
we have. Add new ones at the top; when one is fixed, delete its entry (git keeps it).

---

## Text selected in Chromium browsers and Electron apps loses its paragraph breaks

**Found:** 2026-09-30 · **Status:** fixed for Chrome on 2026-10-07; open for the others

**What you see:** select several paragraphs or a list on a web page and run an
action (e.g. Speak). The text arrives as one run, paragraphs glued together:

```
…isn't available here.If you didn't know either, here's how:1. Download and install…Mac App Store.2. Connect your iPhone…
```

Pressing ⌘C on the same selection gives the text with its line breaks.

**Why:** we read the selection through the Accessibility API
(`AccessibilityStrategy`: `kAXSelectedTextAttribute`, then `AXStringForTextMarkerRange`).
Chromium builds all of these answers with `AXRange::GetText()`, whose paragraph-break
option defaults to off (`ui/accessibility/ax_range.h`), so `"A<div>B</div>C"` comes
back as `"ABC"`. `AXAttributedStringForTextMarkerRange` is the same. Every app that
reads Chromium through Accessibility has this. Measured on a real selection in
Chrome: 727 characters, 0 line breaks, from both attributes. Safari keeps them.

**What is done:** apps on the `popup.copyFirstApps` list (Settings › Advanced;
default: Chrome only) are read with a simulated ⌘C once Accessibility has found a
selection (`CopyFirstStrategy`). Other Chromium browsers (Edge, Arc, Brave) and
Electron apps still lose the breaks until the user adds them to that list; they
were not added by default because none was checked.

**What that costs, in listed apps:** the clipboard is written and put back on every
selection. A clipboard manager can record Chrome's write if it looks before the
restore, and we can't mark it transient because Chrome writes it, not us. A page
that changes what a copy gives (adds "Read more at…", or blocks copying) changes or
delays what the popup reads; the log line `same apart from whitespace` from
`PopBar.CopyFirst` shows how often the two reads differ.

**The other option, not taken:**

| Option | How | Pros | Cons |
|---|---|---|---|
| **AppleScript + page JavaScript** (what Easydict does) | For browsers, ask the browser for the selection over AppleScript and run `window.getSelection().toString()` in the active tab. Chrome: `tell application id "com.google.Chrome" to tell active tab of front window to execute javascript "window.getSelection().toString();"`. Safari has the same through `do JavaScript`. Fall back to Accessibility when it fails. | Paragraph breaks come back; the clipboard is not touched; no browser extension needed | Chrome needs **View → Developer → Allow JavaScript from Apple Events** turned on by the user (off by default, no prompt). macOS asks once for Automation permission ("QDuo wants to control Google Chrome"), so the app needs `NSAppleEventsUsageDescription` (and the Apple Events entitlement if sandboxed). Only browsers with an AppleScript dictionary. List numbers ("1.", "2.") are dropped: `getSelection()` returns list items without their markers (checked in headless Chrome 154). Easydict uses a 0.2 s timeout. |

Not an option: rebuilding paragraphs from Chrome's Accessibility paragraph markers
(`AXNextParagraphEndTextMarkerForTextMarker`). It only works for one app's internals,
not as a general fix.

**References:**
- Easydict: `Easydict/Swift/Utility/EventMonitor/Workflow/SelectionWorkflow.swift`
  (strategy order; `preferAppleScriptAPI` is on by default) and
  `AppleScriptTask+Browser.swift` (the scripts). Introduced in
  https://github.com/tisfeng/Easydict/pull/976.
- PopClip's changelog, 2023.7: "Added a work-around for a Chromium bug that could
  cause PopClip to not see the newlines in the text selection". Its method is not
  public. https://www.popclip.app/changelog
- The reading window shows the text exactly as it arrives, so it shows this issue
  as is. Before 2026-09-30 it put every sentence on its own line, which hid it.
