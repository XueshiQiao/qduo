import SwiftUI

/// The reading window: the whole text being read, with the word being spoken
/// highlighted and kept in view, and pause / replay / copy / close. Lives in the
/// popup's result panel, so it sizes, pins and closes exactly like a result.
/// Closing it stops the read.
struct ReadingPanelView: View {
    @ObservedObject var playback: SpeechPlayback
    @ObservedObject var model: PopBarPanelModel
    let width: CGFloat
    let fixedHeight: CGFloat

    private var sentences: [SpeechPlayback.Sentence] { playback.sentences }

    /// The word highlighted before the current one, and a counter that ticks once
    /// per word. The renderer slides the pill from the previous word to the
    /// current one as the counter animates up by one.
    @State private var previousHighlight: NSRange?
    @State private var lastHighlight: NSRange?
    @State private var highlightStep: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            status
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        textBody
                        Color.clear.frame(height: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Room for the highlight's margin, so a word at a line's start or
                    // on the first line isn't clipped by the scroll view's edge. The
                    // frame below widens by the same amount and is pulled back, so
                    // the text itself stays exactly where it was.
                    .padding(.horizontal, WordHighlight.padX)
                    .padding(.vertical, WordHighlight.padY)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ResultContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(width: width + 2 * WordHighlight.padX, height: height)
                .padding(.horizontal, -WordHighlight.padX)
                .padding(.vertical, -WordHighlight.padY)
                .onPreferenceChange(ResultContentHeightKey.self) { model.onMeasuredContentHeight?($0) }
                .onChange(of: playback.highlight) { hit in
                    previousHighlight = lastHighlight
                    lastHighlight = hit
                    withAnimation(WordHighlight.slide) { highlightStep += 1 }
                }
                .onChange(of: currentSentence) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(ResultTextStyle.insets)
    }

    // MARK: - Pieces

    private var toolbar: some View {
        HStack(spacing: 4) {
            ChromeButton(symbol: model.isPinned ? "pin.fill" : "pin",
                         help: L(model.isPinned ? "popbar.unpin" : "popbar.pin"),
                         active: model.isPinned) { model.onTogglePin?() }
            Label(playback.reader.name, systemImage: "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)
            toolbarStatus
            Spacer()
            switch playback.state {
            case .playing:
                ChromeButton(symbol: "pause.fill", help: L("speech.pause")) { playback.togglePause() }
            case .paused:
                ChromeButton(symbol: "play.fill", help: L("speech.resume")) { playback.togglePause() }
            default:
                EmptyView()
            }
            ChromeButton(symbol: "arrow.counterclockwise", help: L("speech.replay")) { playback.replay() }
            CopyButton { model.onCopyResult?(playback.text) }
            ChromeButton(symbol: "xmark", help: L("popbar.close")) { model.onClose?() }
        }
    }

    /// Short, passing states sit in the toolbar next to the reader's name, so
    /// the text below never moves when they come and go.
    @ViewBuilder
    private var toolbarStatus: some View {
        switch playback.state {
        case .preparing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("speech.preparing"))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case .playing, .paused, .finished:
            if playback.fromCache {
                Text("· " + L("speech.fromCache"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    /// What stays for the whole read: a failure (with Retry) or the text being
    /// cut short — known from the start, so it does not appear mid-read.
    @ViewBuilder
    private var status: some View {
        if case .failed(let message) = playback.state {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("speech.retry")) { playback.start() }
                    .controlSize(.small)
            }
            .frame(width: width)
        } else if playback.wasTruncated {
            note(String(format: L("speech.truncated"), SpeechPlayback.maxCharacters))
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sentences, id: \.id) { sentence in
                sentenceText(sentence)
                    .font(.system(size: model.resultFontSize))
                    .foregroundStyle(Color.primary.opacity(ResultTextStyle.inkOpacity))
                    .lineSpacing(model.resultFontSize * ResultTextStyle.lineSpacingEm)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(sentence.id)
            }
        }
    }

    /// One sentence, with the spoken word marked when it falls inside it. The
    /// word keeps the same font, weight and colour as the rest: only a shape is
    /// drawn behind it, so nothing in the line moves as the highlight walks.
    @ViewBuilder
    private func sentenceText(_ sentence: SpeechPlayback.Sentence) -> some View {
        let piece = sentence.text
        if let hit = local(playback.highlight, in: sentence),
           let r = Range(hit, in: piece) {
            if #available(macOS 15, *) {
                marked(piece, current: r,
                       previous: local(previousHighlight, in: sentence).flatMap { Range($0, in: piece) })
                    .textRenderer(WordHighlight.Renderer(step: highlightStep, target: highlightStep.rounded(.up)))
            } else {
                // macOS 13–14 have no text renderer: fall back to a plain
                // background on the word's own glyphs (no margin, no corners).
                Text(fallbackAttributed(piece, r))
            }
        } else {
            Text(verbatim: piece)
        }
    }

    private func local(_ hit: NSRange?, in sentence: SpeechPlayback.Sentence) -> NSRange? {
        guard let hit, let overlap = sentence.range.intersection(hit), overlap.length > 0 else { return nil }
        return NSRange(location: overlap.location - sentence.range.location, length: overlap.length)
    }

    /// The sentence as one Text, with the current word (and the previous one, when
    /// it is in this sentence and doesn't overlap) tagged for the renderer. Every
    /// part is verbatim, so `*`, `_` etc. in the text are never read as Markdown.
    @available(macOS 15, *)
    private func marked(_ piece: String, current: Range<String.Index>,
                        previous: Range<String.Index>?) -> Text {
        var cuts: [(Range<String.Index>, any TextAttribute)] = [(current, WordHighlight.Mark())]
        if let previous, !previous.overlaps(current) { cuts.append((previous, WordHighlight.PreviousMark())) }
        cuts.sort { $0.0.lowerBound < $1.0.lowerBound }
        var out = Text(verbatim: "")
        var at = piece.startIndex
        for (range, mark) in cuts {
            let plain = Text(verbatim: String(piece[at..<range.lowerBound]))
            let tagged: Text
            if mark is WordHighlight.Mark {
                tagged = Text(verbatim: String(piece[range])).customAttribute(WordHighlight.Mark())
            } else {
                tagged = Text(verbatim: String(piece[range])).customAttribute(WordHighlight.PreviousMark())
            }
            out = Text("\(out)\(plain)\(tagged)")
            at = range.upperBound
        }
        return Text("\(out)\(Text(verbatim: String(piece[at...])))")
    }

    private func fallbackAttributed(_ piece: String, _ r: Range<String.Index>) -> AttributedString {
        var result = AttributedString(piece)
        if let a = Range(r, in: result) { result[a].backgroundColor = WordHighlight.fill }
        return result
    }

    private var currentSentence: Int? {
        guard let hit = playback.highlight else { return nil }
        return sentences.first { NSLocationInRange(hit.location, $0.range) }?.id
    }

    private var height: CGFloat {
        guard model.autoExpandHeight else { return max(fixedHeight, 160) }
        return model.resultContentHeight ?? max(fixedHeight, 160)
    }
}

/// The reading window's spoken-word highlight: a soft rounded pill drawn behind
/// the word, a few points wider than its glyphs. It is drawn, not styled: the
/// word's font, weight and colour are untouched, so the text never re-flows.
enum WordHighlight {
    static let padX: CGFloat = 3
    static let padY: CGFloat = 1.5
    static let radius: CGFloat = 5
    static let fill = Color.accentColor.opacity(0.22)

    /// How the pill moves to the next word: the wheel's spring, quicker, since
    /// words change every 0.25–0.4 s and the pill must never trail the voice.
    static let slide = Animation.spring(response: 0.22, dampingFraction: 0.9)

    /// Tags the word being spoken.
    @available(macOS 15, *)
    struct Mark: TextAttribute {}
    /// Tags the word spoken just before, where the pill slides in from.
    @available(macOS 15, *)
    struct PreviousMark: TextAttribute {}

    /// Draws the pill behind the current word, then the text on top exactly as
    /// SwiftUI laid it out. While `step` animates up to `target`, the pill is
    /// interpolated from the previous word's box to the current one's, so it
    /// slides along the line instead of jumping. On a new line, or when the
    /// previous word is in another sentence, the pill simply appears there.
    @available(macOS 15, *)
    struct Renderer: TextRenderer {
        var step: Double
        var target: Double
        var animatableData: Double {
            get { step }
            set { step = newValue }
        }

        func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
            var current: [CGRect] = []   // one box per line the word sits on
            var previous: CGRect?
            for line in layout {
                var cur: CGRect?
                for run in line {
                    let r = run.typographicBounds.rect
                    if run[Mark.self] != nil { cur = cur.map { $0.union(r) } ?? r }
                    if run[PreviousMark.self] != nil { previous = previous.map { $0.union(r) } ?? r }
                }
                if let cur { current.append(cur) }
            }
            let t = min(max(step - (target - 1), 0), 1)
            for (i, box) in current.enumerated() {
                var shown = box
                // Slide only along a line: a hop to the next line would cut
                // diagonally across the text, so there the pill just appears.
                if i == 0, let previous, t < 1, abs(previous.midY - box.midY) < box.height / 2 {
                    shown = lerp(previous, box, t)
                }
                let pill = shown.insetBy(dx: -padX, dy: -padY)
                ctx.fill(Path(roundedRect: pill, cornerRadius: radius, style: .continuous),
                         with: .color(fill))
            }
            for line in layout { ctx.draw(line) }
        }

        private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
            let t = CGFloat(t)
            return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                          width: a.width + (b.width - a.width) * t,
                          height: a.height + (b.height - a.height) * t)
        }
    }
}
