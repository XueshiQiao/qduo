import XCTest
import AppKit
import ImageIO
import SwiftUI

/// The user's own icon pictures and the symbol search (issue #17), and the ring
/// a hovered picture draws around itself (issue #21).
final class ActionIconTests: XCTestCase {

    // MARK: - Symbol search

    private let names = ["arrow.down", "arrow.up", "arrow.up.circle", "doc", "square.and.arrow.up", "up.arrow"]

    func testNamesThatStartWithTheQueryComeFirst() {
        XCTAssertEqual(SFSymbolCatalog.matches("arrow.up", in: names, limit: 10),
                       ["arrow.up", "arrow.up.circle", "square.and.arrow.up"])
    }

    func testSpacesAndCaseAreForgiven() {
        XCTAssertEqual(SFSymbolCatalog.normalized("  Arrow Up "), "arrow.up")
        XCTAssertEqual(SFSymbolCatalog.matches("Arrow Up", in: names, limit: 10).first, "arrow.up")
    }

    func testEmptyQueryMatchesNothingAndTheLimitHolds() {
        XCTAssertEqual(SFSymbolCatalog.matches("  ", in: names, limit: 10), [])
        XCTAssertEqual(SFSymbolCatalog.matches("a", in: names, limit: 2).count, 2)
    }

    // MARK: - Pictures

    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    func testAnyPNGComesOutAtTheStoredSize() throws {
        for (w, h) in [(128, 128), (256, 256), (1024, 1024), (64, 64), (400, 100)] {
            let out = try ActionIconStore.normalized(png(width: w, height: h))
            XCTAssertTrue(ActionIconStore.isPNG(out))
            XCTAssertEqual(pixelSize(out), CGSize(width: ActionIconStore.side, height: ActionIconStore.side), "\(w)×\(h)")
        }
    }

    func testAFileThatIsNotAPNGIsRefused() {
        XCTAssertThrowsError(try ActionIconStore.normalized(Data("not a picture".utf8))) { error in
            guard case ActionIconStore.ImportError.notPNG = error else { return XCTFail("\(error)") }
        }
        // The signature alone is not a picture.
        XCTAssertThrowsError(try ActionIconStore.normalized(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))) { error in
            guard case ActionIconStore.ImportError.unreadable = error else { return XCTFail("\(error)") }
        }
    }

    func testAPictureIsFittedWholeAndCentred() {
        XCTAssertEqual(ActionIconStore.fitted(CGSize(width: 400, height: 100), side: 256),
                       CGRect(x: 0, y: 96, width: 256, height: 64))
        XCTAssertEqual(ActionIconStore.fitted(CGSize(width: 64, height: 64), side: 256),
                       CGRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertEqual(ActionIconStore.fitted(.zero, side: 256), .zero)
    }

    func testABareNameIsInTheIconsFolderAndAPathIsAPath() {
        XCTAssertEqual(ActionIconStore.url(for: "icon-1.png").deletingLastPathComponent().lastPathComponent, "icons")
        XCTAssertEqual(ActionIconStore.url(for: "/tmp/a.png").path, "/tmp/a.png")
        // A relative path is from the config folder, not from where the app was started.
        XCTAssertTrue(ActionIconStore.url(for: "pictures/a.png").path.hasSuffix("/pictures/a.png"))
        XCTAssertEqual(ActionIconStore.url(for: "icons/a.png").path, ActionIconStore.url(for: "a.png").path)
        XCTAssertTrue(ActionIconStore.url(for: "~/a.png").path.hasSuffix("/a.png"))
        XCTAssertFalse(ActionIconStore.url(for: "~/a.png").path.contains("~"))
    }

    // MARK: - The config key

    func testIconImageRoundTripsAndIsLeftOutWhenUnset() throws {
        let json = #"[{ "id": "a", "title": "A", "iconSymbol": "star", "iconImage": "icon-1.png", "kind": "copy" },"#
                 + #" { "id": "b", "title": "B", "iconSymbol": "star", "kind": "copy" }]"#
        let actions = try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(actions[0].iconImage, "icon-1.png")
        XCTAssertNil(actions[1].iconImage)
        let written = String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)
        XCTAssertEqual(written.components(separatedBy: "iconImage").count - 1, 1)
    }

    // MARK: - Hover ring

    /// The picture's centre pixel is the same hovered or not, and a pixel about a
    /// point outside the picture's edge is clear until the ring is on.
    ///
    /// The ring is drawn outside the icon's layout size, so the rendered view is
    /// padded: otherwise that pixel would fall outside the bitmap. The file name
    /// is unique because `ActionIconStore` caches pictures, by the path string,
    /// for the whole process.
    @MainActor
    func testAHoveredPictureKeepsItsCentreAndGainsARingOutsideIt() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qduo-icon-hover-\(UUID().uuidString).png")
        try png(width: 64, height: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let scale: CGFloat = 2
        let pad: CGFloat = 4
        let side = CGFloat(15) * 1.2   // ActionIconView's picture box, `size * 1.2`
        let ringOutset: CGFloat = 3.5
        let lineWidth: CGFloat = 1.25
        let pictureRight = pad + side
        // strokeBorder draws inside the outset box, so the ink runs from
        // `lineWidth` inside that box's edge back to the edge.
        let bandOuter = pictureRight + ringOutset / 2
        let bandInner = bandOuter - lineWidth
        let bandMid = (bandInner + bandOuter) / 2
        let mid = pad + side / 2
        let cx = Int(mid * scale)
        let cy = cx
        let ox = Int(bandMid * scale)
        let oy = cy
        let sample = (CGFloat(ox) + 0.5) / scale
        XCTAssertGreaterThan(sample, bandInner)
        XCTAssertLessThan(sample, bandOuter)
        // The right edge is straight through the middle; the corners are rounded
        // and would miss the stroke.
        let corner = (side + ringOutset) * 0.28
        let localY = (CGFloat(oy) + 0.5) / scale - (mid - (side + ringOutset) / 2)
        XCTAssertGreaterThan(localY, corner)
        XCTAssertLessThan(localY, side + ringOutset - corner)

        guard let cold = renderedIcon(path: url.path, hot: false, pad: pad, side: side, scale: scale),
              let hot = renderedIcon(path: url.path, hot: true, pad: pad, side: side, scale: scale) else {
            XCTFail("ImageRenderer produced no image for an NSImage-backed ActionIconView. This test bundle is not hosted in the app, so a picture view may not render here.")
            return
        }
        let expected = Int(((side + pad * 2) * scale).rounded())
        guard cold.width == expected, cold.height == expected,
              hot.width == expected, hot.height == expected else {
            XCTFail("ImageRenderer produced \(cold.width)×\(cold.height) and \(hot.width)×\(hot.height), expected \(expected)×\(expected).")
            return
        }
        guard let coldCentre = pixel(cold, x: cx, y: cy), let hotCentre = pixel(hot, x: cx, y: cy),
              let coldOut = pixel(cold, x: ox, y: oy), let hotOut = pixel(hot, x: ox, y: oy) else {
            return XCTFail("sample pixel outside the rendered image")
        }
        XCTAssertGreaterThan(coldCentre[3], UInt8(200), "the picture should be drawn at its centre")
        XCTAssertEqual(coldCentre, hotCentre, "hover must not change the picture's own pixels")
        XCTAssertEqual(coldOut[3], UInt8(0), "the pixel just outside the picture should be clear when the ring is off")
        XCTAssertGreaterThan(hotOut[3], UInt8(0), "the ring should cover the pixel just outside the picture")
        XCTAssertNotEqual(hotOut, hotCentre)
    }

    /// A symbol draws no ring. `hot` is only read when a picture is drawn, so
    /// the pixel the picture test samples — about a point outside the picture's
    /// edge — stays clear when the symbol is hovered.
    @MainActor
    func testAHoveredSymbolLeavesThePixelOutsideThePictureClear() {
        let scale: CGFloat = 2
        let pad: CGFloat = 4
        let side = CGFloat(15) * 1.2
        let outside = outerRingSample(pad: pad, side: side, scale: scale)

        guard let hot = renderedIcon(hot: true, pad: pad, side: side, scale: scale) else {
            XCTFail("ImageRenderer produced no image for a symbol ActionIconView. This test bundle is not hosted in the app, so a symbol view may not render here.")
            return
        }
        let expected = Int(((side + pad * 2) * scale).rounded())
        guard hot.width == expected, hot.height == expected else {
            XCTFail("ImageRenderer produced \(hot.width)×\(hot.height), expected \(expected)×\(expected).")
            return
        }
        guard let hotOut = pixel(hot, x: outside.x, y: outside.y) else {
            return XCTFail("sample pixel outside the rendered image")
        }
        XCTAssertEqual(hotOut[3], UInt8(0), "a hovered symbol should leave the pixel just outside the picture clear")
    }

    /// `hotOpacity` is how solid the picture's ring is. The same pixel the
    /// picture test samples is still covered at 0.55, and fainter than at 1.
    ///
    /// The file name is unique because `ActionIconStore` caches pictures, by
    /// the path string, for the whole process.
    @MainActor
    func testALowerHotOpacityDrawsAFainterRing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qduo-icon-hot-opacity-\(UUID().uuidString).png")
        try png(width: 64, height: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let scale: CGFloat = 2
        let pad: CGFloat = 4
        let side = CGFloat(15) * 1.2
        let outside = outerRingSample(pad: pad, side: side, scale: scale)

        guard let solid = renderedIcon(path: url.path, hot: true, hotOpacity: 1, pad: pad, side: side, scale: scale),
              let faint = renderedIcon(path: url.path, hot: true, hotOpacity: 0.55, pad: pad, side: side, scale: scale) else {
            XCTFail("ImageRenderer produced no image for an NSImage-backed ActionIconView. This test bundle is not hosted in the app, so a picture view may not render here.")
            return
        }
        let expected = Int(((side + pad * 2) * scale).rounded())
        guard solid.width == expected, solid.height == expected,
              faint.width == expected, faint.height == expected else {
            XCTFail("ImageRenderer produced \(solid.width)×\(solid.height) and \(faint.width)×\(faint.height), expected \(expected)×\(expected).")
            return
        }
        guard let solidOut = pixel(solid, x: outside.x, y: outside.y),
              let faintOut = pixel(faint, x: outside.x, y: outside.y) else {
            return XCTFail("sample pixel outside the rendered image")
        }
        XCTAssertGreaterThan(faintOut[3], UInt8(0), "a ring at hotOpacity 0.55 should still cover the pixel just outside the picture")
        XCTAssertLessThan(faintOut[3], solidOut[3], "hotOpacity 0.55 should draw that pixel fainter than hotOpacity 1")
    }

    /// The pixel `testAHoveredPictureKeepsItsCentreAndGainsARingOutsideIt`
    /// samples: about a point outside the picture's right edge, midway through
    /// the stroke, on the straight side. The corners are rounded and would miss
    /// the stroke.
    private func outerRingSample(pad: CGFloat, side: CGFloat, scale: CGFloat) -> (x: Int, y: Int) {
        let ringOutset: CGFloat = 3.5
        let lineWidth: CGFloat = 1.25
        let pictureRight = pad + side
        let bandOuter = pictureRight + ringOutset / 2
        let bandInner = bandOuter - lineWidth
        let bandMid = (bandInner + bandOuter) / 2
        let mid = pad + side / 2
        return (x: Int(bandMid * scale), y: Int(mid * scale))
    }

    /// `ActionIconView` padded so the ring, which sits outside the picture, is
    /// inside the bitmap. `path` nil draws the SF Symbol and no picture.
    ///
    /// A symbol sizes to its glyph, which is smaller than the picture box. That
    /// render is framed to the same canvas the picture test uses, so the pixel
    /// just outside the picture is inside the bitmap. The frame does not scale
    /// the glyph.
    @MainActor
    private func renderedIcon(path: String? = nil, hot: Bool, hotOpacity: Double = 1,
                              pad: CGFloat, side: CGFloat, scale: CGFloat) -> CGImage? {
        let canvas = side + pad * 2
        if let path {
            let renderer = ImageRenderer(content:
                ActionIconView(symbol: "star", image: path, size: 15, hot: hot, hotOpacity: hotOpacity).padding(pad))
            renderer.proposedSize = ProposedViewSize(width: canvas, height: canvas)
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.cgImage
        }
        let renderer = ImageRenderer(content:
            ActionIconView(symbol: "star", size: 15, hot: hot, hotOpacity: hotOpacity)
                .padding(pad)
                .frame(width: canvas, height: canvas))
        renderer.proposedSize = ProposedViewSize(width: canvas, height: canvas)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// One pixel as premultiplied RGBA, origin at the top left.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drew ? bytes : nil
    }
}
