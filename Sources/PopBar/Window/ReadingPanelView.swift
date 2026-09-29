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
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ResultContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(width: width, height: height)
                .onPreferenceChange(ResultContentHeightKey.self) { model.onMeasuredContentHeight?($0) }
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
                Text(attributed(sentence.text, range: sentence.range))
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

    /// The sentence text with the spoken word marked, when it falls inside it.
    private func attributed(_ piece: String, range: NSRange) -> AttributedString {
        var result = AttributedString(piece)
        guard let hit = playback.highlight, let overlap = range.intersection(hit), overlap.length > 0 else {
            return result
        }
        let local = NSRange(location: overlap.location - range.location, length: overlap.length)
        if let r = Range(local, in: piece), let a = Range(r, in: result) {
            result[a].backgroundColor = Color.accentColor.opacity(0.28)
            result[a].foregroundColor = .primary
        }
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
