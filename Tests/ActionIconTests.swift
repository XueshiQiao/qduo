import XCTest
import AppKit
import ImageIO

/// The user's own icon pictures and the symbol search (issue #17), and the
/// shape a picture is drawn as (issue #21).
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

    // MARK: - The shape a picture is drawn as

    /// A `side`-square picture: `plate` filled over `plateRect` (nil = none),
    /// then `ink` filled over `inkRect`. Rects are in pixels, origin bottom-left.
    private func picture(side: Int = 128, plate: CGColor?, plateRect: CGRect? = nil,
                         ink: CGColor, inkRect: CGRect, inkIsEllipse: Bool = false,
                         mark: (CGColor, CGRect)? = nil) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let plate {
            context.setFillColor(plate)
            context.fill(plateRect ?? CGRect(x: 0, y: 0, width: side, height: side))
        }
        context.setFillColor(ink)
        if inkIsEllipse { context.fillEllipse(in: inkRect) } else { context.fill(inkRect) }
        if let mark {
            context.setFillColor(mark.0)
            context.fill(mark.1)
        }
        return context.makeImage()!
    }

    /// Alpha at (x, y), y counted from the top, of a 128-square image.
    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Shift the image so the wanted pixel lands on the single one drawn.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    private let orange = CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1)
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private func shape(_ image: CGImage) throws -> CGImage {
        try XCTUnwrap(ActionIconTemplate.shape(ofImage: image))
    }

    /// The fitted box is 85% of the square: from about 9.6 to 118.4 pixels.
    private let inside = 12, outside = 5

    /// On a transparent background the alpha is the shape, cut out of its
    /// margin and fitted into the box.
    func testATransparentPictureIsItsAlphaFittedToTheBox() throws {
        let out = try shape(picture(plate: nil, ink: orange, inkRect: CGRect(x: 44, y: 44, width: 40, height: 40)))
        XCTAssertEqual(out.width, ActionIconStore.side)
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertGreaterThan(alpha(out, inside, 64), 250, "the 40-pixel square is scaled up to the box")
        XCTAssertEqual(alpha(out, outside, 64), 0, "outside the box")
    }

    /// An app-icon-style picture: a round white mark on an orange plate. The
    /// plate is dropped, the mark kept and fitted to the box.
    func testThePlateIsTakenOffAndTheMarkFillsTheBox() throws {
        let out = try shape(picture(plate: orange, plateRect: CGRect(x: 8, y: 8, width: 112, height: 112),
                                    ink: white, inkRect: CGRect(x: 44, y: 44, width: 40, height: 40),
                                    inkIsEllipse: true))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250, "the mark is kept")
        XCTAssertGreaterThan(alpha(out, inside, 64), 250, "the mark is scaled up")
        XCTAssertEqual(alpha(out, outside, 64), 0)
        // The mark is round: the box's corner is clear. Had the plate stayed,
        // the square plate would fill the box, corner and all.
        XCTAssertEqual(alpha(out, inside, inside), 0, "the plate's corner is gone")
    }

    /// The plate is gone: beside a wide, flat mark, where the plate was, is clear.
    func testNothingOfThePlateIsLeft() throws {
        let out = try shape(picture(plate: orange, ink: white, inkRect: CGRect(x: 24, y: 54, width: 80, height: 20)))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertEqual(alpha(out, 64, 20), 0, "above the mark, where the plate was")
        XCTAssertEqual(alpha(out, 64, 108), 0, "below the mark")
    }

    /// A macOS-style icon: the plate has a soft dark shadow under it. The
    /// shadow is not opaque, so it is not shape, and it does not stop the mark
    /// from being scaled up.
    func testAShadowUnderThePlateIsNotShape() throws {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        context.fill(CGRect(x: 10, y: 4, width: 108, height: 108))
        context.setFillColor(orange)
        context.fill(CGRect(x: 10, y: 14, width: 108, height: 108))
        context.setFillColor(white)
        context.fill(CGRect(x: 44, y: 48, width: 40, height: 40))
        let out = try shape(context.makeImage()!)
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertGreaterThan(alpha(out, inside, 64), 250, "the shadow did not widen the cut")
    }

    /// A black glyph on white: the white is the plate.
    func testABlackShapeOnWhiteKeepsTheShape() throws {
        let out = try shape(picture(plate: white, ink: black, inkRect: CGRect(x: 14, y: 14, width: 100, height: 100),
                                    inkIsEllipse: true))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertEqual(alpha(out, 14, 14), 0, "the white corner is plate")
    }

    /// A light grey mark on white is still a full-strength mark: how far a
    /// colour must be from the plate is measured against the picture's own spread.
    func testALightGreyMarkOnWhiteIsSolid() throws {
        let grey = CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)
        let out = try shape(picture(plate: white, ink: grey, inkRect: CGRect(x: 34, y: 34, width: 60, height: 60)))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertGreaterThan(alpha(out, inside, 64), 250, "only the grey square, fitted")
    }

    /// A small highlight on a solid silhouette is not a mark on a plate: the
    /// silhouette is the shape, not the highlight blown up to fill the box. The
    /// highlight is 1.4% of the silhouette, so it is the 2% rule that decides,
    /// not the spread (which the 99th percentile would still find).
    func testASmallHighlightDoesNotReplaceTheSilhouette() throws {
        let out = try shape(picture(plate: black, plateRect: CGRect(x: 14, y: 14, width: 100, height: 100),
                                    ink: white, inkRect: CGRect(x: 16, y: 100, width: 12, height: 12)))
        // The highlight sits in the top-left corner; the bottom-right corner is
        // only silhouette, and the middle is silhouette too.
        XCTAssertGreaterThan(alpha(out, 115, 115), 250, "the far corner of the silhouette is drawn")
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
    }

    /// A black shape covering most of a white picture: the white reaches the
    /// edge, so the white is the plate, however much black there is.
    func testAMostlyBlackPictureOnWhiteIsNotInverted() throws {
        let out = try shape(picture(plate: white, ink: black, inkRect: CGRect(x: 6, y: 6, width: 116, height: 116),
                                    inkIsEllipse: true))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250, "the black circle is the shape")
        XCTAssertEqual(alpha(out, 1, 1), 0, "the white corner is not")
    }

    /// A round badge smaller than the square is still a plate: it fills most
    /// of its own box, and its edge is one colour.
    func testARoundBadgeIsAPlate() throws {
        let out = try shape(picture(plate: nil, ink: orange, inkRect: CGRect(x: 14, y: 14, width: 100, height: 100),
                                    inkIsEllipse: true, mark: (white, CGRect(x: 49, y: 49, width: 30, height: 30))))
        XCTAssertGreaterThan(alpha(out, 64, 64), 250, "the mark is kept")
        XCTAssertGreaterThan(alpha(out, inside, inside), 250, "the square mark fills the box")
    }

    /// A multi-coloured ring on a transparent background has no one-colour
    /// edge: it is drawn whole from its alpha, not cut into the colours
    /// unlike the median.
    func testAMultiColouredLogoIsDrawnWhole() throws {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colours = [CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1), CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1),
                       CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)]
        for (k, c) in colours.enumerated() {
            context.setFillColor(c)
            context.fill(CGRect(x: k % 2 * 64, y: k / 2 * 64, width: 64, height: 64))
        }
        let out = try shape(context.makeImage()!)
        for (x, y) in [(inside, inside), (115, inside), (inside, 115), (115, 115)] {
            XCTAssertGreaterThan(alpha(out, x, y), 250, "quarter at \(x),\(y)")
        }
    }

    /// A shaded shape on a transparent background — red to dark red with a
    /// highlight, like an emoji heart — runs through every shade between its
    /// edge colour and its highlight. It is drawn whole, not as the highlight.
    func testAShadedShapeIsDrawnWhole() throws {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let circle = CGRect(x: 14, y: 14, width: 100, height: 100)
        context.addEllipse(in: circle)
        context.clip()
        let shades = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                colors: [CGColor(srgbRed: 1, green: 0.75, blue: 0.75, alpha: 1),
                                         CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                         CGColor(srgbRed: 0.45, green: 0, blue: 0, alpha: 1)] as CFArray,
                                locations: [0, 0.4, 1])!
        context.drawRadialGradient(shades, startCenter: CGPoint(x: 50, y: 85), startRadius: 0,
                                   endCenter: CGPoint(x: 64, y: 64), endRadius: 52, options: [.drawsAfterEndLocation])
        let out = try shape(context.makeImage()!)
        // The whole circle: its middle and a point near its lower edge.
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertGreaterThan(alpha(out, 64, 110), 250, "the dark lower part is shape too")
        XCTAssertEqual(alpha(out, inside, inside), 0, "outside the circle")
    }

    /// A mark touching the picture's border on white: the white is still the
    /// plate, so the picture is not drawn as a solid square.
    func testAMarkTouchingTheBorderStillLeavesThePlate() throws {
        let out = try shape(picture(plate: white, ink: black, inkRect: CGRect(x: 0, y: 0, width: 128, height: 30)))
        // The band, fitted into the box, is wide and flat: above it is clear.
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
        XCTAssertEqual(alpha(out, 64, 30), 0, "where the white was")
    }

    /// A rounded-square plate with a strong top-to-bottom gradient, as macOS 26
    /// app icons have: most of its pixels are shades, yet it is a plate, and
    /// the white mark on it is kept.
    func testAGradientAppIconPlateIsStillTakenOff() throws {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: 120, height: 120),
                               cornerWidth: 26, cornerHeight: 26, transform: nil))
        context.clip()
        let plate = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [CGColor(srgbRed: 0.47, green: 0.725, blue: 0.96, alpha: 1),
                                        CGColor(srgbRed: 0.13, green: 0.325, blue: 0.79, alpha: 1)] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(plate, start: CGPoint(x: 64, y: 124), end: CGPoint(x: 64, y: 4), options: [])
        context.restoreGState()
        context.setFillColor(white)
        context.fillEllipse(in: CGRect(x: 44, y: 44, width: 40, height: 40))
        let out = try shape(context.makeImage()!)
        XCTAssertGreaterThan(alpha(out, 64, 64), 250, "the white mark is kept")
        // (20, 20) is inside the rounded square once fitted to the box, but
        // outside the round mark: plate only.
        XCTAssertEqual(alpha(out, 20, 20), 0, "the plate is gone, not drawn as a block")
    }

    /// A disc on a transparent background, red above and white below, is a
    /// two-coloured shape, not a white mark on a red plate: drawn whole.
    func testATwoColouredDiscIsDrawnWhole() throws {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.addEllipse(in: CGRect(x: 14, y: 14, width: 100, height: 100))
        context.clip()
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 44, width: 128, height: 84))
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 44))
        let out = try shape(context.makeImage()!)
        XCTAssertGreaterThan(alpha(out, 64, 30), 250, "the red half is shape")
        XCTAssertGreaterThan(alpha(out, 64, 100), 250, "the white half is shape")
    }

    /// A plain square has nothing on its plate; its alpha is the shape.
    func testAPlainSquareIsDrawnWhole() throws {
        let out = try shape(picture(plate: orange, ink: orange, inkRect: .zero))
        XCTAssertGreaterThan(alpha(out, inside, inside), 250)
    }

    /// A picture of another size, as a hand-written path may name, gives a
    /// shape of the stored side.
    func testAPictureOfAnotherSizeGivesAShapeOfTheStoredSide() throws {
        let out = try shape(picture(side: 300, plate: orange, ink: white,
                                    inkRect: CGRect(x: 100, y: 100, width: 100, height: 100)))
        XCTAssertEqual(out.width, ActionIconStore.side)
        XCTAssertEqual(out.height, ActionIconStore.side)
        XCTAssertGreaterThan(alpha(out, 64, 64), 250)
    }

    /// Nothing visible, nothing to draw: the caller draws the symbol instead.
    func testAnEmptyPictureHasNoShape() {
        XCTAssertNil(ActionIconTemplate.shape(of: picture(plate: nil, ink: orange, inkRect: .zero)))
    }

    /// What is cached and drawn is marked as a template.
    func testTheDrawnPictureIsATemplate() throws {
        let out = try XCTUnwrap(ActionIconTemplate.shape(of: picture(plate: nil, ink: orange,
                                                                     inkRect: CGRect(x: 0, y: 0, width: 64, height: 64))))
        XCTAssertTrue(out.isTemplate)
    }
}
