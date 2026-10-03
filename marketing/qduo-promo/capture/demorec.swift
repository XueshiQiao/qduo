// demorec — records the real QDuo popup for the promo film.
//
// One process does three things, so their clocks agree:
//   1. shows a small document window (a real NSTextView) holding the scene's text;
//   2. drives the real mouse through the scene (select → popup → click), logging
//      every event's time;
//   3. records the screen region around the window with ScreenCaptureKit — only
//      this process's windows and QDuo-Debug's, so nothing else on the desktop
//      (notifications, other apps) can get into the shot — plus QDuo's audio.
//
// Usage: demorec <scene> <out-dir>        scene = liquid | donut | polish | read | probe
// Writes <out-dir>/<scene>.mov (ProRes 422, 60 fps, Retina pixels, cursor drawn),
// <out-dir>/<scene>.json (capture rect, scale, event times in seconds from the first frame).

import AppKit
import ApplicationServices
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - Scene text

struct Doc {
    let title: String      // window title
    let kicker: String
    let heading: String
    let lines: [String]    // body paragraphs; `target` indexes into these
    let target: Int
}

let docs: [String: Doc] = [
    "liquid": Doc(title: "随笔", kicker: "A LITTLE INSPIRATION", heading: "给灵感，留一点空间。",
                  lines: ["读到一句喜欢的话：", "Good ideas rarely arrive finished; give them room, and they grow.", "写下来，再让它慢慢长大。"], target: 1),
    "donut": Doc(title: "新建草稿", kicker: "FROM A SPARK TO A STORY", heading: "一封新品邀请",
                 lines: ["先记下几个要点：", "新版本 · 本周五上线 · 三种弹窗风格 · 选中即用 · 欢迎体验", "收件人：全体用户"], target: 1),
    "polish": Doc(title: "文稿", kicker: "MAKE EVERY WORD COUNT", heading: "让表达，更进一步。",
                  lines: ["初稿，还差一点：", "这个工具可以让你在写东西的时候更快一些，也不用来回切换窗口。", "发布之前，再读一遍。"], target: 1),
    "read": Doc(title: "Notes", kicker: "LET THE WORDS FLOW", heading: "Rest your eyes for a moment.",
                lines: ["Listen instead:", "Let your ideas flow freely, and the right words will follow.", "Close your eyes and let it finish."], target: 1),
]

// MARK: - Layout constants (points)

let windowSize = NSSize(width: 760, height: 520)
/// Room around the window inside the shot: the window's shadow, and popups that
/// reach past its edge.
let margin: CGFloat = 70
/// Film-matching backdrop behind the window.
let backdropColor = NSColor(srgbRed: 0.957, green: 0.969, blue: 0.984, alpha: 1)

// MARK: - Event log

final class Log {
    var t0: Double?           // host seconds of the first recorded frame
    var events: [[String: Any]] = []
    func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    func mark(_ name: String, _ extra: [String: Any] = [:]) {
        var e = extra; e["event"] = name; e["host"] = now()
        events.append(e)
        FileHandle.standardError.write("· \(name) \(extra)\n".data(using: .utf8)!)
    }
}
let log = Log()

// MARK: - Mouse

/// CG global coordinates: origin at the top-left of the primary display.
let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }!.frame.height
func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
func cocoa(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }

var mousePos = CGPoint.zero
var buttonDown = false

func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
    mousePos = p
}

func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

/// Move along a gentle arc (a quadratic Bézier bowed sideways), eased, at 120 Hz.
func move(to target: CGPoint, _ duration: Double, bow: CGFloat = 0.12) async {
    let from = mousePos
    let mid = CGPoint(x: (from.x + target.x) / 2, y: (from.y + target.y) / 2)
    let dx = target.x - from.x, dy = target.y - from.y
    let ctrl = CGPoint(x: mid.x - dy * bow, y: mid.y + dx * bow)
    let steps = max(1, Int(duration * 120))
    let start = log.now()
    for i in 1...steps {
        let t = CGFloat(easeInOut(Double(i) / Double(steps)))
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        let p = CGPoint(x: a * from.x + b * ctrl.x + c * target.x, y: a * from.y + b * ctrl.y + c * target.y)
        post(buttonDown ? .leftMouseDragged : .mouseMoved, p)
        let due = start + duration * Double(i) / Double(steps)
        let wait = due - log.now()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
}

func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func down(_ name: String = "down") { buttonDown = true; post(.leftMouseDown, mousePos); log.mark(name, ["x": mousePos.x, "y": mousePos.y]) }
func up(_ name: String = "up") { buttonDown = false; post(.leftMouseUp, mousePos); log.mark(name, ["x": mousePos.x, "y": mousePos.y]) }
func click(_ name: String) async { down(name); await wait(0.07); up(name + ".up") }

// MARK: - QDuo popup geometry, read over Accessibility

func qduoPID() -> pid_t? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier.map { $0 == "me.xueshi.qduo" || $0.hasSuffix(".qduo.debug") } == true }?.processIdentifier
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

/// QDuo's on-screen windows (CG coordinates), biggest first.
func qduoWindows() -> [CGRect] {
    guard let pid = qduoPID() else { return [] }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w -> CGRect? in
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              (w[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }.sorted { $0.width * $0.height > $1.width * $1.height }
}

/// Every element under QDuo whose title / description / value is `text`.
func findElements(_ text: String) -> [CGRect] {
    guard let pid = qduoPID() else { return [] }
    let app = AXUIElementCreateApplication(pid)
    var out: [CGRect] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard depth < 30 else { return }
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXLabelValueAttribute] {
            if let s: String = attr(el, key), s == text, let f = frame(el) { out.append(f); break }
        }
        for c: AXUIElement in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
    }
    for w: AXUIElement in (attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { walk(w, 0) }
    return out
}

func dumpAX() {
    guard let pid = qduoPID() else { print("no QDuo"); return }
    let app = AXUIElementCreateApplication(pid)
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard depth < 30 else { return }
        let role: String = attr(el, kAXRoleAttribute) ?? "?"
        let bits = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXLabelValueAttribute]
            .compactMap { k -> String? in (attr(el, k) as String?).map { "\(k)=\($0)" } }
        print(String(repeating: "  ", count: depth) + role + " " + bits.joined(separator: " ") + " " + (frame(el).map { "\($0)" } ?? ""))
        for c: AXUIElement in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
    }
    for w: AXUIElement in (attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { walk(w, 0) }
    print("CG windows:", qduoWindows())
}

/// Ring slot `index` of `count`, at the ring's mid radius: slots run clockwise
/// from twelve o'clock (WheelActionsView: `(idx + 0.5) * 2π / n`).
/// `r` defaults to near the rim, so a sweep tilts the ring hard without the arrow
/// sitting on the icons and captions.
func ringSlot(_ index: Int, of count: Int, center: CGPoint, r: CGFloat = 102) -> CGPoint {
    let a = (Double(index) + 0.5) * 2 * .pi / Double(count)
    return CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
}

// MARK: - Document window

/// Takes the first click, so a drag that starts while the window is not yet
/// active still selects.
final class DocText: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, so it needs telling that it may take keyboard focus.
final class DocNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Traffic lights, a centred title and a hairline, drawn like the system's.
final class TitleBar: NSView {
    let title: String
    init(frame: NSRect, title: String) { self.title = title; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let colors = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),
                      NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                      NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
        for (i, c) in colors.enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(i) * 20, y: bounds.midY - 6, width: 12, height: 12)).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 0.30, alpha: 1)]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        NSColor(white: 0, alpha: 0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

final class DocWindow {
    let window: DocNSWindow
    let backdrop: NSWindow
    let text: DocText
    let doc: Doc
    var bodyRanges: [NSRange] = []

    init(_ doc: Doc) {
        self.doc = doc
        let screen = NSScreen.screens.first { $0.frame.origin == .zero }!
        let origin = NSPoint(x: (screen.frame.midX - windowSize.width / 2).rounded(),
                             y: (screen.frame.midY - windowSize.height / 2 + 60).rounded())
        // Our own title bar: while a window is being captured, the system draws a
        // capture badge where its traffic lights go, which must not be in the film.
        window = DocNSWindow(contentRect: NSRect(origin: origin, size: windowSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false

        backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = backdropColor
        backdrop.level = .normal
        backdrop.ignoresMouseEvents = true
        backdrop.isReleasedWhenClosed = false

        let bar: CGFloat = 40
        text = DocText(frame: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height - bar))
        text.textContainerInset = NSSize(width: 145, height: 26)  // a centred 470-pt column
        text.isRichText = true
        text.isEditable = true
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .white
        text.allowsUndo = true
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        text.textStorage!.setAttributedString(render())
        // A narrow column: the selected sentence wraps, so the mouse lets go near the
        // middle of the page and the popup and its panel stay inside the window.
        text.textContainer!.widthTracksTextView = false
        text.textContainer!.containerSize = NSSize(width: 470, height: CGFloat(10000))
        let root = NSView(frame: NSRect(origin: .zero, size: windowSize))
        root.wantsLayer = true
        root.layer!.cornerRadius = 14
        root.layer!.masksToBounds = true
        root.layer!.borderWidth = 0.5
        root.layer!.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        root.addSubview(text)
        root.addSubview(TitleBar(frame: NSRect(x: 0, y: windowSize.height - bar, width: windowSize.width, height: bar), title: doc.title))
        window.contentView = root
    }

    func para(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0, after: CGFloat, lineHeight: CGFloat? = nil) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        if let lh = lineHeight { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
        return NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: p])
    }

    func render() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let cjk = { (size: CGFloat, w: NSFont.Weight) -> NSFont in
            NSFont(name: w == .semibold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size, weight: w)
        }
        out.append(para(doc.kicker, font: .systemFont(ofSize: 12, weight: .semibold),
                        color: NSColor(srgbRed: 0.45, green: 0.52, blue: 0.62, alpha: 1), kern: 2.6, after: 14))
        out.append(para(doc.heading, font: cjk(30, .semibold), color: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.22, alpha: 1), after: 22))
        for (i, line) in doc.lines.enumerated() {
            let start = out.length
            let isTarget = i == doc.target
            out.append(para(line, font: isTarget ? cjk(20, .regular) : cjk(17, .regular),
                            color: isTarget ? NSColor(srgbRed: 0.12, green: 0.16, blue: 0.25, alpha: 1)
                                            : NSColor(srgbRed: 0.40, green: 0.45, blue: 0.53, alpha: 1),
                            after: i == doc.target - 1 ? 66 : (isTarget ? 40 : 12), lineHeight: isTarget ? 34 : 28))
            bodyRanges.append(NSRange(location: start, length: (line as NSString).length))
        }
        return out
    }

    func show() {
        backdrop.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.count, length: 0))
        NSApp.activate(ignoringOtherApps: true)
    }

    /// CG-coordinate points at the left and right edges of the target line.
    /// The target line may wrap: start at its first character, end at its last.
    func targetEnds() -> (CGPoint, CGPoint) {
        let range = bodyRanges[doc.target]
        let first = text.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)  // screen, Cocoa
        let last = text.firstRect(forCharacterRange: NSRange(location: NSMaxRange(range) - 1, length: 1), actualRange: nil)
        return (cg(NSPoint(x: first.minX - 3, y: first.midY)), cg(NSPoint(x: last.maxX + 2, y: last.midY)))
    }

    /// The shot: window plus margin, CG coordinates, whole points.
    var captureRect: CGRect {
        let f = window.frame
        let r = CGRect(x: f.minX - margin, y: primaryHeight - f.maxY - margin,
                       width: f.width + 2 * margin, height: f.height + 2 * margin)
        // A bottom margin big enough for a result panel opening below the text.
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 120).integral
    }
}

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var writer: AVAssetWriter!
    var video: AVAssetWriterInput!
    var audio: AVAssetWriterInput!
    var started = false
    var frames = 0
    let queue = DispatchQueue(label: "rec")

    func start(rect: CGRect, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = content.displays.first { CGDisplayIsMain($0.displayID) != 0 }!
        let mine = getpid()
        let apps = content.applications.filter {
            $0.processID == mine || $0.bundleIdentifier == "me.xueshi.qduo" || $0.bundleIdentifier.hasSuffix(".qduo.debug")
        }
        guard apps.count == 2 else { throw NSError(domain: "demorec", code: 1, userInfo: [NSLocalizedDescriptionKey: "QDuo-Debug is not running (apps: \(apps.map(\.applicationName)))"]) }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        video.expectsMediaDataInRealTime = true
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        audio.expectsMediaDataInRealTime = true
        writer.add(video); writer.add(audio)
        writer.startWriting()

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        log.mark("capture-started", ["scale": scale, "w": cfg.width, "h": cfg.height])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if type == .screen {
            // Skip the "nothing changed" frames: they carry no image.
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                started = true
                let pts = sb.presentationTimeStamp
                writer.startSession(atSourceTime: pts)
                log.t0 = pts.seconds
            }
            if video.isReadyForMoreMediaData { video.append(sb); frames += 1 }
        } else if type == .audio, started, let t0 = log.t0, sb.presentationTimeStamp.seconds >= t0 {
            // Audio from before the first frame would precede the session start.
            if audio.isReadyForMoreMediaData { audio.append(sb) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!)
    }

    func stop() async throws {
        try await stream?.stopCapture()
        // Nothing to finish if start() failed before the writer existed; a take
        // with no frame at all is a failure, not an empty success.
        guard let writer, let video, let audio else { return }
        guard started else {
            writer.cancelWriting()
            throw NSError(domain: "demorec", code: 4, userInfo: [NSLocalizedDescriptionKey: "no video frames were captured"])
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                video.markAsFinished(); audio.markAsFinished()
                writer.finishWriting { c.resume() }
            }
        }
        if writer.status != .completed { throw writer.error ?? NSError(domain: "demorec", code: 2) }
    }
}

// MARK: - Scenes

func waitForPopup(_ timeout: Double = 3) async -> CGRect? {
    let end = log.now() + timeout
    while log.now() < end {
        if let w = qduoWindows().first { return w }
        await wait(0.02)
    }
    return nil
}

func waitForElement(_ text: String, timeout: Double = 3) async -> CGRect? {
    let end = log.now() + timeout
    while log.now() < end {
        if let r = findElements(text).first { return r }
        await wait(0.05)
    }
    return nil
}

func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

/// Where to point at a popup button: its caption is read over Accessibility, and
/// the button's middle sits between the icon above it and the caption.
func button(_ title: String, fallback: CGPoint) -> CGPoint {
    guard let f = findElements(title).min(by: { $0.minY < $1.minY }) else {
        log.mark("ax-miss", ["title": title]); return fallback
    }
    // A whole button (the capsule's): its middle, a little low so the arrow
    // sits on the icon's edge rather than over the caption.
    if f.height > 24 { return CGPoint(x: f.midX + 4, y: f.midY - 2) }
    // A ring caption: just right of it, inside the slice, the arrow not covering it.
    return CGPoint(x: f.maxX + 9, y: f.minY - 2)
}

/// Select the target line with a real drag, as a person would.
func selectTarget(_ doc: DocWindow, approach: Double = 0.7, drag: Double = 0.75) async {
    let (a, b) = doc.targetEnds()
    await move(to: a, approach, bow: 0.18)
    await wait(0.12)
    down("select.down")
    await move(to: b, drag, bow: 0.0)
    await wait(0.05)
    up("select.up")
    log.mark("selected", ["range": NSStringFromRange(doc.text.selectedRange())])
}

func rimPoint(_ c: CGPoint, _ angle: Double, r: CGFloat = 102) -> CGPoint {
    CGPoint(x: c.x + r * CGFloat(sin(angle)), y: c.y - r * CGFloat(cos(angle)))
}
func slotAngle(_ slot: Int, of n: Int) -> Double { (Double(slot) + 0.5) * 2 * .pi / Double(n) }

/// Slide along the rim from angle a0 to a1 (radians, clockwise), easing in and
/// out, logging a "hover" each time the pointer enters the next slot.
func arc(_ c: CGPoint, _ a0: Double, _ a1: Double, _ duration: Double, n: Int = 7) async {
    let steps = max(1, Int(duration * 120)), t0 = log.now()
    var lastSlot = Int((a0.truncatingRemainder(dividingBy: 2 * .pi)) / (2 * .pi / Double(n)))
    for i in 1...steps {
        let x = Double(i) / Double(steps)
        let a = a0 + (a1 - a0) * easeInOut(x)
        post(.mouseMoved, rimPoint(c, a))
        var norm = a.truncatingRemainder(dividingBy: 2 * .pi); if norm < 0 { norm += 2 * .pi }
        let slot = Int(norm / (2 * .pi / Double(n)))
        if slot != lastSlot { log.mark("hover", ["slot": slot]); lastSlot = slot }
        let wait = t0 + duration * x - log.now()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
}

/// Seconds per slot while gliding: an unhurried hand, not a showcase crawl.
let perSlot = 0.3

/// Once round the ring at an even glide, clockwise from `start`. The only stop is
/// the group slot: rest there ~1 s so its second ring opens and can be seen (the
/// pointer does not go into it), then glide on round to `end`.
func ringTour(_ c: CGPoint, n: Int, start: Int, group: Int, end: Int) async {
    let a0 = slotAngle(start, of: n)
    await move(to: rimPoint(c, a0), 0.45)
    log.mark("hover", ["slot": start])
    await wait(0.15)
    let toGroup = Double(((group - start) % n + n) % n)
    let aG = a0 + toGroup * 2 * .pi / Double(n)
    await arc(c, a0, aG, max(0.35, toGroup * perSlot))
    log.mark("hover.more")
    await wait(1.0)                                   // the second ring opens
    var rest = Double(((end - group) % n + n) % n)
    if rest == 0 { rest = Double(n) }
    if (group - start + n) % n + Int(rest) < n { rest += Double(n) }   // always a full turn
    await arc(c, aG, aG + rest * 2 * .pi / Double(n), rest * perSlot)
}

/// Glide the pointer along the capsule from one x to another at bar height,
/// logging a "hover" as it crosses each button.
func glide(_ from: CGFloat, _ to: CGFloat, y: CGFloat, buttons: [CGFloat], _ duration: Double) async {
    let steps = max(1, Int(duration * 120)), t0 = log.now()
    // The button it starts on was already logged when the pointer arrived there.
    var passed = Set(buttons.indices.filter { abs(buttons[$0] - from) < 8 })
    for i in 1...steps {
        let x = Double(i) / Double(steps)
        let px = from + (to - from) * CGFloat(easeInOut(x))
        post(.mouseMoved, CGPoint(x: px, y: y))
        for (k, b) in buttons.enumerated() where !passed.contains(k) && abs(px - b) < 8 {
            passed.insert(k); log.mark("hover", ["button": k])
        }
        let wait = t0 + duration * x - log.now()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
}

/// The capsule's version: left to right at an even glide; if `group` is given,
/// rest on it ~1 s so its dropdown opens, then glide on to the far right.
func capsuleTour(_ bar: CGRect, titles: [String], group: String?, until: String? = nil) async {
    let xs = titles.map { button($0, fallback: .zero) }.filter { $0.x > 0 }.map(\.x).sorted()
    guard let lo = xs.first, let hi = xs.last else { return }
    let y = bar.midY - 2
    let span = Double(xs.count - 1)
    await move(to: CGPoint(x: lo, y: y), 0.45)
    log.mark("sweep"); log.mark("hover", ["button": 0])
    await wait(0.15)
    if let group, let gx = Optional(button(group, fallback: .zero).x), gx > 0 {
        let k = Double(xs.firstIndex { abs($0 - gx) < 4 } ?? 3)
        await glide(lo, gx, y: y, buttons: xs, max(0.35, k * perSlot))
        log.mark("hover.more")
        await wait(1.0)                               // the dropdown opens
        await glide(gx, hi, y: y, buttons: xs, max(0.35, (span - k) * perSlot))
    } else if let until, let ux = Optional(button(until, fallback: .zero).x), ux > lo {
        // Straight along to `until`, no stop and no return trip.
        let k = Double(xs.firstIndex { abs($0 - ux) < 4 } ?? xs.count - 1)
        await glide(lo, ux, y: y, buttons: xs, max(0.35, k * perSlot))
    } else {
        await glide(lo, hi, y: y, buttons: xs, span * perSlot)
    }
}

let ringTitles = ["翻译", "润色", "写作", "更多", "搜索", "朗读", "复制"]

func scene(_ name: String, _ doc: DocWindow) async throws {
    // Start the pointer inside the window, low and to the left of the text.
    let (a, _) = doc.targetEnds()
    post(.mouseMoved, CGPoint(x: a.x + 40, y: a.y + 110))
    await wait(0.8)
    log.mark("start")
    switch name {
    case "liquid", "donut":
        await selectTarget(doc)
        guard let ring = await waitForPopup() else { throw err("no popup") }
        log.mark("popup", ["frame": "\(ring)"])
        await wait(0.3)
        let c = center(ring)
        // Once round the ring, resting only on 更多 so its second ring opens.
        if name == "liquid" {
            await ringTour(c, n: 7, start: 0, group: 3, end: 0)
        } else {
            await ringTour(c, n: 7, start: 2, group: 3, end: 2)
        }
        await wait(0.2)
        let title = name == "liquid" ? "翻译" : "写作"
        await move(to: button(title, fallback: ringSlot(name == "liquid" ? 0 : 2, of: 7, center: c)), 0.5)
        await wait(0.2)
        await click(name == "liquid" ? "click.translate" : "click.write")
        await wait(name == "liquid" ? 2.4 : 3.6)
    case "polish", "read":
        await selectTarget(doc)
        guard let bar = await waitForPopup() else { throw err("no popup") }
        log.mark("popup", ["frame": "\(bar)"])
        await wait(0.3)
        // Along the bar; the polish take rests on 更多 so its dropdown opens.
        if name == "polish" {
            await capsuleTour(bar, titles: ringTitles, group: "更多")
        } else {
            await capsuleTour(bar, titles: ringTitles, group: nil, until: "朗读")
        }
        if name == "polish" { await wait(0.2) }
        let title = name == "polish" ? "润色" : "朗读"
        // Polish travels back to 润色; read is already on 朗读 and just settles.
        await move(to: button(title, fallback: capsuleSlot(name == "polish" ? 1 : 5, of: 7, bar: bar)), name == "polish" ? 0.5 : 0.15)
        await wait(name == "polish" ? 0.15 : 0.1)
        await click("click.\(name)")
        if name == "polish" {
            await wait(2.4)
            // Replace is the header's arrow.2.squarepath button (tooltip "用这段结果替换选中的文字").
            guard let replace = await waitForElement("Two Arrows Following A Square Path", timeout: 2) else { dumpAX(); throw err("no Replace button") }
            await move(to: CGPoint(x: replace.midX + 2, y: replace.midY + 1), 0.5)
            await wait(0.12)
            await click("click.replace")
            await wait(1.4)
        } else {
            await wait(6.0)
        }
    case "probe":
        await selectTarget(doc)
        _ = await waitForPopup()
        await wait(0.6)
        dumpAX()
    default: throw err("unknown scene \(name)")
    }
    log.mark("end")
}

func capsuleSlot(_ i: Int, of n: Int, bar: CGRect) -> CGPoint {
    CGPoint(x: bar.minX + bar.width * (CGFloat(i) + 0.5) / CGFloat(n), y: bar.midY)
}

func err(_ s: String) -> NSError { NSError(domain: "demorec", code: 3, userInfo: [NSLocalizedDescriptionKey: s]) }

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: demorec <scene> <out-dir>"); exit(2) }
let sceneName = args[1]
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let doc = DocWindow(docs[sceneName] ?? docs["liquid"]!)
let recorder = Recorder()

Task { @MainActor in
    do {
        doc.show()
        await wait(0.6)
        // One click in the empty lower part of the page makes this app active
        // before the take starts (the take must not begin with an activating click).
        let f = doc.window.frame
        post(.mouseMoved, cg(NSPoint(x: f.midX, y: f.minY + 40)))
        await wait(0.1)
        post(.leftMouseDown, mousePos); await wait(0.05); post(.leftMouseUp, mousePos)
        await wait(0.5)
        let rect = doc.captureRect
        let record = sceneName != "probe"
        if record { try await recorder.start(rect: rect, url: outDir.appendingPathComponent("\(sceneName).mov")) }
        try await scene(sceneName, doc)
        if record {
            try await recorder.stop()
            let t0 = log.t0 ?? 0
            let events = log.events.map { e -> [String: Any] in
                var e = e; e["t"] = ((e["host"] as! Double) - t0); e.removeValue(forKey: "host"); return e
            }
            let meta: [String: Any] = ["scene": sceneName, "rect": [rect.minX, rect.minY, rect.width, rect.height],
                                       "window": [doc.window.frame.minX, primaryHeight - doc.window.frame.maxY,
                                                  doc.window.frame.width, doc.window.frame.height],
                                       "frames": recorder.frames, "events": events]
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outDir.appendingPathComponent("\(sceneName).json"))
            print("wrote \(sceneName).mov, \(recorder.frames) frames")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("FAILED: \(error.localizedDescription)\n".data(using: .utf8)!)
        if sceneName != "probe" { try? await recorder.stop() }
        exit(1)
    }
}
app.run()
