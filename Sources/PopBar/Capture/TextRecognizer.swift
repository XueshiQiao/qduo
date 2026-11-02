import Foundation
import CoreGraphics
import Vision
import CoreText

/// Vision-backed OCR. Runs the recognition off the main thread and hands back the
/// text in natural reading order.
///
/// This uses the old `VNRecognizeTextRequest`, not the new `RecognizeTextRequest`
/// (macOS 15+). The new one does not shorten the first-use compile described at
/// `warmUp()`: on a fresh process it took 23.7–23.9 s with auto-detect (3 runs) and
/// 12.3 s with a language list (1 run), the same as the old one. QDuo still supports
/// macOS 13 and 14, where the new request does not exist, so using it would mean
/// keeping two code paths for no gain.
enum TextRecognizer {

    private static let log = FileLog("PopBar.OCR")

    /// One queue for the warm-up and every real recognition, so a capture made while
    /// the warm-up is still running waits for it instead of starting a second
    /// compilation next to it.
    private static let queue = DispatchQueue(label: "me.xueshi.qduo.ocr", qos: .userInitiated)

    /// How close two observations' vertical positions must be to count as the same
    /// line (normalized coordinates, so this is a fraction of image height).
    private static let sameLineTolerance: CGFloat = 0.02

    /// Runs Vision OCR OFF the main thread. Calls `completion` on the MAIN thread with
    /// the recognized text joined in reading order ("\n" between lines), or "" if nothing.
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        let width = image.width
        let height = image.height

        queue.async {
            let start = Date()

            // An empty result is not always "no text in the image": in a 24 h run, one
            // recognition of an image that had text returned nothing in 8 ms. So an empty
            // result (or a thrown error) is tried exactly once more before giving up.
            let text = recognizeWithRetry(image)

            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            log.info("OCR \(width)x\(height) px -> \(text.count) chars in \(elapsedMs)ms")

            DispatchQueue.main.async { completion(text) }
        }
    }

    /// `recognizeOnce`, and if that gives nothing, exactly one more time. Runs on `queue`.
    private static func recognizeWithRetry(_ image: CGImage) -> String {
        let start = Date()
        let first = recognizeOnce(image)
        guard first.isEmpty else { return first }
        log.warn("OCR came back empty after \(Int(Date().timeIntervalSince(start) * 1000))ms — trying once more")
        return recognizeOnce(image)
    }

    /// One Vision pass over `image`. Returns "" if Vision threw or found nothing
    /// (text that is only spaces counts as nothing).
    private static func recognizeOnce(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        } catch {
            log.warn("OCR request failed: \(error)")
            return ""
        }
        return orderedText(from: req.results ?? []).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var warmedUp = false

    /// The first time a newly built or newly installed copy of the app runs Vision text
    /// recognition, macOS compiles the recognizer's networks for the Neural Engine
    /// (ANECompilerService). Measured here on freshly compiled test programs: the whole
    /// cost is about 24 s, and it is paid in different shapes. Starting with real
    /// screenshots (4 of 4 programs), the first recognition took 12–14 s and the second
    /// another 12–13 s. Starting with the generated image below (5 of 5 programs), the
    /// first recognition took 23–27 s and every later one, real screenshots included,
    /// took 75–150 ms. Why it splits in two for real screenshots is not known. So run
    /// that one generated image in the background as soon as Screenshot Text is on,
    /// with the same settings as `recognize`, to pay the whole cost before the user's
    /// first capture. A capture made while it is still running waits for it, which is
    /// why the caller shows a "recognizing…" hint.
    /// Not yet seen cold inside the app itself: the Xcode-signed Debug build was always
    /// already warm when this ran (90–105 ms).
    /// Main thread only; does nothing after the first call.
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        queue.async {
            let start = Date()
            guard let image = warmUpImage() else { return }
            _ = recognizeWithRetry(image)
            log.info("OCR warm-up finished in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        }
    }

    /// A white image with a line of black text on it, so the warm-up runs the whole
    /// recognition path rather than being skipped for an empty image.
    private static func warmUpImage() -> CGImage? {
        let size = CGSize(width: 400, height: 60)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Hello 你好 12345",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 32, nil),
                         .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 10, y: 18)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    // MARK: - Reading order

    /// Sort observations top→bottom, then left→right within a line, and join their
    /// best candidate strings with newlines.
    ///
    /// Vision's `boundingBox` is normalized with y measured from the BOTTOM (0 at
    /// bottom, 1 at top), so "top first" means DESCENDING `maxY`.
    private static func orderedText(from observations: [VNRecognizedTextObservation]) -> String {
        let topDown = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        // Group runs that sit on roughly the same visual line.
        var lines: [[VNRecognizedTextObservation]] = []
        var line: [VNRecognizedTextObservation] = []
        var lineTop: CGFloat = 0

        func flush() {
            guard !line.isEmpty else { return }
            // Left→right within the line.
            lines.append(line.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
            line.removeAll(keepingCapacity: true)
        }

        for obs in topDown {
            if line.isEmpty {
                lineTop = obs.boundingBox.maxY
            } else if abs(obs.boundingBox.maxY - lineTop) > sameLineTolerance {
                flush()
                lineTop = obs.boundingBox.maxY
            }
            line.append(obs)
        }
        flush()

        // Join fragments WITHIN a line with a space; separate lines with newlines — so
        // multiple observations on one visual line don't each become their own line.
        return lines
            .map { row in row.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
