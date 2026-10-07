import XCTest
import AppKit
import ImageIO

/// The user's own icon pictures and the symbol search (issue #17).
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
}
