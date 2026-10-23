import AppKit
import SwiftUI
import ImageIO

/// An action's icon, wherever one is drawn: the user's own picture when the
/// action has one (`iconImage`) and its file can be read, the SF Symbol
/// (`iconSymbol`) otherwise.
///
/// A picture is drawn the way a symbol is: as a template, a shape painted with
/// the caller's `foregroundStyle` — the skin's ink at rest, the brand gradient
/// when hovered — so a hovered picture is marked exactly like a hovered symbol
/// (issue #21). Only its shape is kept, not its colours; a picture on an opaque
/// plate has the plate taken off first, and every picture is fitted to about a
/// symbol's size (`ActionIconTemplate`).
struct ActionIconView: View {
    let symbol: String
    let image: String?
    /// The symbol's point size. A picture is drawn in a square a little larger,
    /// which is about the box a symbol of that size fills.
    let size: CGFloat
    var weight: Font.Weight = .medium

    init(symbol: String, image: String? = nil, size: CGFloat, weight: Font.Weight = .medium) {
        self.symbol = symbol
        self.image = image
        self.size = size
        self.weight = weight
    }

    init(_ action: PopBarActionConfig, size: CGFloat, weight: Font.Weight = .medium) {
        self.init(symbol: action.iconSymbol, image: action.iconImage, size: size, weight: weight)
    }

    var body: some View {
        if let picture = ActionIconStore.picture(named: image) {
            Image(nsImage: picture)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 1.2, height: size * 1.2)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
        }
    }
}

/// Where the user's icon pictures live and how one gets there.
///
/// The rule for a picture is ours to set, and it is short: a PNG file, 128×128.
/// Any PNG is accepted; one of another size is scaled into 128×128 when it is
/// imported (kept whole and centred, never stretched), and that copy is what the
/// app draws from then on. Nothing else about the picture is checked.
enum ActionIconStore {

    /// The side of a stored picture, in pixels. The largest a picture is ever
    /// drawn is 40 points (80 pixels on a Retina screen), in the editor's
    /// preview; on the ring and the capsule it is 18 points. 128 leaves room
    /// above that, and asking for no more says what an icon this small needs:
    /// a simple shape, not detail.
    static let side = 128

    enum ImportError: Error {
        case notPNG
        case unreadable
        case cannotWrite
    }

    /// `~/.config/<slug>/icons/` — beside the config file that names the
    /// pictures, so the two travel together.
    static var directory: URL {
        Brand.configDirectory.appendingPathComponent("icons", isDirectory: true)
    }

    /// The file an `iconImage` value names. A bare file name is looked up in
    /// `directory`. A value hand-written into the config may also be a path:
    /// absolute, from the home folder (`~/…`), or — anything else with a slash —
    /// from the folder the config file is in, never from wherever the app
    /// happened to be started.
    static func url(for name: String) -> URL {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        }
        if name.contains("/") {
            return Brand.configDirectory.appendingPathComponent(name).standardizedFileURL
        }
        return directory.appendingPathComponent(name)
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
    /// Names whose file could not be read, or holds nothing visible (the symbol
    /// is drawn for those too). Remembered too: this is asked from
    /// view bodies, and the ring redraws on every pointer move — a missing file
    /// must not mean a trip to the disk each time. Main thread only, like the
    /// views that ask. An import never reuses a name, so nothing here goes stale
    /// except a file added by hand, which shows after a restart (as a hand edit
    /// of the config does).
    private static var unreadable = Set<String>()

    /// The picture for an `iconImage` value, ready to draw as a template (see
    /// `ActionIconTemplate`); nil when there is none or its file cannot be read
    /// (the caller then draws the symbol). The plate is taken off once, when the
    /// file is first read, and the result is what is cached.
    static func picture(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        if unreadable.contains(name) { return nil }
        guard let source = image(at: url(for: name)) else {
            unreadable.insert(name)
            return nil
        }
        guard let shape = ActionIconTemplate.shape(of: source) else {
            unreadable.insert(name)
            return nil
        }
        cache.setObject(shape, forKey: name as NSString)
        return shape
    }

    /// The file's picture, no larger than `side` on its longer edge. Read
    /// scaled down, as `normalized` does: a hand-written path may name a huge
    /// image, and this runs on the main thread. A format ImageIO cannot read as
    /// a bitmap (PDF) is drawn at `side` through NSImage instead.
    private static func image(at url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        guard let picture = NSImage(contentsOf: url), picture.isValid else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        return picture.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Whether the file starts with the PNG signature. The file's name is not
    /// trusted: a JPEG renamed to .png is not a PNG.
    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// The rectangle a picture of `size` takes inside a `side`×`side` square:
    /// as large as fits, proportions kept, centred.
    static func fitted(_ size: CGSize, side: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(side / size.width, side / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
    }

    /// PNG data of any size → PNG data of exactly `side`×`side`.
    static func normalized(_ data: Data) throws -> Data {
        guard isPNG(data) else { throw ImportError.notPNG }
        // Scaled down WHILE it is decoded: a 20,000-pixel PNG must not be
        // unpacked whole just to be drawn at 128. (A smaller one comes out at
        // its own size and is scaled up by the draw below.)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable
        }
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImportError.unreadable
        }
        context.interpolationQuality = .high
        context.draw(image, in: fitted(CGSize(width: image.width, height: image.height), side: CGFloat(side)))
        guard let scaled = context.makeImage() else { throw ImportError.unreadable }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw ImportError.cannotWrite
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.cannotWrite }
        return out as Data
    }

    /// Copy a PNG the user chose into `directory`, scaled to `side`×`side`.
    /// Returns the file name to store in the action's `iconImage`.
    static func importPNG(at source: URL) throws -> String {
        guard let data = try? Data(contentsOf: source) else { throw ImportError.unreadable }
        let png = try normalized(data)
        let name = "icon-\(UUID().uuidString.prefix(8).lowercased()).png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw ImportError.cannotWrite
        }
        return name
    }
}

extension ActionIconStore {
    /// Delete pictures this app imported (bare names in `directory` only —
    /// never a file a hand-written path points at).
    static func discard(_ names: [String]) {
        for name in names where !name.contains("/") && name.hasPrefix("icon-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            cache.removeObject(forKey: name as NSString)
        }
    }
}

/// A picture turned into the shape a template draws.
///
/// macOS draws a template image (`NSImage.isTemplate`, SwiftUI's
/// `renderingMode(.template)`) from its alpha alone: every pixel takes the
/// paint, as solid as it is opaque. That suits a picture on a transparent
/// background. A picture on an opaque plate — an app-icon-style rounded
/// square, a glyph on white — is opaque all over, and would be drawn as a
/// solid block. macOS has no public call that finds the shape on such a plate
/// (the tinted app icons of iOS 18 and macOS 26 are made in the private
/// IconServices), so it is done here:
///
///     if the opaque pixels fill more than half of the box around them, and
///     the edge of the opaque area is mostly one colour (60% of it), the picture
///     may sit on a plate (a mark touching the picture's border leaves the rest):
///         plate colour = the median colour of that edge (an app icon's plate and
///             a white background both reach the edge; the mark on them does not)
///         spread = how far the most different pixels are from it (the 99th percentile)
///         a pixel is shape when it is opaque (a shadow or a soft margin around
///             the plate is not) and its colour is far from the plate's,
///             measured against the spread, so a light grey mark on white counts
///         if the spread is tiny (a plain square), or the shape is under 2% of the
///             opaque pixels (a small highlight on a solid silhouette):
///             no plate after all — the picture's alpha is the shape
///         if, besides, the outline is not a square (it fills 90% of its box
///         or less — an emoji, a round badge), a plate needs more evidence:
///             where the outline meets transparency, 80% of it is the plate colour
///             (a disc half red, half white is two colours, not a mark on a plate)
///             and no more than 40% of the opaque pixels are shades between plate
///             and mark (a shaded emoji heart runs through every shade; a mark
///             meets its plate at a hard edge)
///             otherwise the alpha is the shape
///     otherwise: the picture's alpha is the shape
///     the shape is cut out of its empty margin and fitted into 85% of the
///     square, so every picture is drawn about as large as a symbol
///
/// What this cannot do, and the editor's hint says so: detail told apart only
/// by colour on a transparent background is lost; a plate with a strong
/// gradient or a see-through plate is not taken off cleanly; a photo comes out
/// as patches of light and dark. On a transparent background, a flat shape
/// mostly of one colour with parts of another inside it (a black circle with
/// white eyes, a green battery with a dark tip, a folder in two blues) cannot
/// be told from a mark on a plate, and is drawn as those other parts.
enum ActionIconTemplate {

    /// Share of the opaque area's bounding box the opaque pixels must fill for
    /// the picture to sit on a plate. Measured against that box, not the whole
    /// square, so a round badge smaller than the square counts.
    static let plateCoverage = 0.5
    /// How alike the edge of the opaque area must be to be one plate colour:
    /// this share of its pixels within `edgeTolerance` of its median colour.
    static let edgeShare = 0.6
    static let edgeTolerance = 0.2
    /// A pixel at least this opaque counts as opaque.
    static let opaqueAlpha = 0.9
    /// Below this spread, every opaque pixel is the plate's colour: a plain square.
    static let minimumSpread = 0.06
    /// Colour distance from the plate, as a share of the spread: below the
    /// first, plate; above the second, shape; a smooth ramp between.
    static let knockout = (from: 0.35, to: 0.6)
    /// Alpha ramp for shape on a plate: anything less opaque is outside it.
    static let plateAlpha = (from: 0.85, to: 0.95)
    /// Less shape than this, as a share of the opaque pixels, is not a mark on a plate.
    static let minimumShare = 0.02
    /// Above this box fill the outline is a square or rounded square (an app
    /// icon's plate, a picture opaque to its edges); at or below it the
    /// outline is a shape of its own, and the two checks after this one apply.
    static let squareFill = 0.9
    /// Where the outline meets transparency, this share of it must be the
    /// plate colour when the outline is a shape.
    static let innerEdgeShare = 0.8
    /// Distances, as a share of the spread, that are neither plate nor mark…
    static let betweenBand = (from: 0.15, to: 0.85)
    /// …and the most of the opaque pixels that may lie there on a plate.
    static let maximumBetween = 0.4
    /// How much of a pixel must be shape for it to count when the margin is cut.
    static let inkThreshold = 0.1
    /// The share of the square the shape is fitted into.
    static let fill: CGFloat = 0.85

    /// The image to draw, marked as a template so it is painted even where no
    /// `renderingMode` is set.
    /// nil when nothing in the picture is visible: the caller then draws the symbol.
    static func shape(of image: CGImage) -> NSImage? {
        guard let shape = shape(ofImage: image) else { return nil }
        let picture = NSImage(cgImage: shape, size: NSSize(width: ActionIconStore.side, height: ActionIconStore.side))
        picture.isTemplate = true
        return picture
    }

    /// The shape, as white with the shape in its alpha, `ActionIconStore.side`
    /// square. nil when nothing in the picture is visible.
    static func shape(ofImage image: CGImage) -> CGImage? {
        let n = ActionIconStore.side
        guard let pixels = rgba(image, side: n) else { return nil }
        let count = n * n
        var alpha = [Double](repeating: 0, count: count)
        var opaque: [Int] = []
        for i in 0..<count {
            alpha[i] = Double(pixels[i * 4 + 3]) / 255
            if alpha[i] > opaqueAlpha { opaque.append(i) }
        }
        let filled = boxFill(opaque, side: n)
        let ink = (filled > plateCoverage
                   ? plateRemoved(pixels, alpha: alpha, opaque: opaque, boxFill: filled, side: n) : nil) ?? alpha

        var shape = [UInt8](repeating: 0, count: count * 4)
        var minX = n, minY = n, maxX = -1, maxY = -1
        for i in 0..<count where ink[i] > 0 {
            let byte = UInt8((ink[i] * 255).rounded())
            // White, premultiplied: the colour bytes equal the alpha.
            shape[i * 4] = byte; shape[i * 4 + 1] = byte; shape[i * 4 + 2] = byte; shape[i * 4 + 3] = byte
            if ink[i] > inkThreshold {
                let x = i % n, y = i / n
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX,
              let full = makeImage(from: &shape, side: n),
              let cut = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)),
              let context = bitmap(side: n) else { return nil }
        context.interpolationQuality = .high
        let box = CGFloat(n) * fill
        let fitted = ActionIconStore.fitted(CGSize(width: cut.width, height: cut.height), side: box)
        context.draw(cut, in: fitted.offsetBy(dx: (CGFloat(n) - box) / 2, dy: (CGFloat(n) - box) / 2))
        return context.makeImage()
    }

    /// The share of their own bounding box the opaque pixels fill.
    private static func boxFill(_ opaque: [Int], side n: Int) -> Double {
        guard !opaque.isEmpty else { return 0 }
        var minX = n, minY = n, maxX = -1, maxY = -1
        for i in opaque {
            minX = min(minX, i % n); maxX = max(maxX, i % n); minY = min(minY, i / n); maxY = max(maxY, i / n)
        }
        let box = Double((maxX - minX + 1) * (maxY - minY + 1))
        return Double(opaque.count) / box
    }

    /// How much of each pixel is shape once the plate is taken off; nil when
    /// the picture turns out not to be a mark on a plate.
    private static func plateRemoved(_ pixels: [UInt8], alpha: [Double], opaque: [Int], boxFill: Double,
                                     side n: Int) -> [Double]? {
        // A square or rounded-square outline says nothing by itself: drawn
        // from its alpha it is a block. Any other outline (an emoji, a round
        // badge) is a shape worth keeping, so a plate is believed only on
        // stronger evidence.
        let outlineIsAShape = boxFill <= squareFill
        // Colours are stored premultiplied; the plate is compared un-multiplied.
        func channel(_ i: Int, _ c: Int) -> Double { Double(pixels[i * 4 + c]) / 255 / max(alpha[i], 1 / 255) }
        // The edge of the opaque area: opaque pixels on the square's border or
        // next to one that is not opaque. A mark drawn on the plate is inside it.
        func isOpaque(_ x: Int, _ y: Int) -> Bool { alpha[y * n + x] > opaqueAlpha }
        let edge = opaque.filter { i in
            let x = i % n, y = i / n
            guard x > 0, y > 0, x < n - 1, y < n - 1 else { return true }
            return !isOpaque(x - 1, y) || !isOpaque(x + 1, y) || !isOpaque(x, y - 1) || !isOpaque(x, y + 1)
        }
        func median(_ c: Int) -> Double {
            let values = edge.map { channel($0, c) }.sorted()
            return values[values.count / 2]
        }
        let plate = (median(0), median(1), median(2))
        func distance(_ i: Int) -> Double {
            let dr = channel(i, 0) - plate.0, dg = channel(i, 1) - plate.1, db = channel(i, 2) - plate.2
            return (dr * dr + dg * dg + db * db).squareRoot() / 3.0.squareRoot()
        }
        // A plate is one colour along its edge; a multi-coloured logo is not.
        let alike = edge.filter { distance($0) <= edgeTolerance }.count
        guard Double(alike) >= edgeShare * Double(edge.count) else { return nil }
        // Where that outline meets transparency, not the picture's border, it
        // must be the plate colour almost all round: a disc half red, half
        // white is a two-coloured shape, not a white mark on a red plate.
        // Only the border may be crossed by a mark (a band on white).
        if outlineIsAShape {
            let inner = edge.filter { i in let x = i % n, y = i / n; return x > 0 && y > 0 && x < n - 1 && y < n - 1 }
            let innerAlike = inner.filter { distance($0) <= edgeTolerance }.count
            guard inner.isEmpty || Double(innerAlike) >= innerEdgeShare * Double(inner.count) else { return nil }
        }
        let spreads = opaque.map(distance).sorted()
        let spread = spreads[min(spreads.count - 1, spreads.count * 99 / 100)]
        guard spread >= minimumSpread else { return nil }

        var ink = [Double](repeating: 0, count: alpha.count)
        var marked = 0
        for i in 0..<alpha.count where alpha[i] > 0 {
            ink[i] = smoothstep(plateAlpha.from, plateAlpha.to, alpha[i])
                * smoothstep(knockout.from * spread, knockout.to * spread, distance(i))
            if ink[i] > 0.5 { marked += 1 }
        }
        guard Double(marked) >= minimumShare * Double(opaque.count) else { return nil }
        // A mark meets its plate at a hard edge: few colours lie between the
        // two. A shaded shape (an emoji heart, red to dark red with a
        // highlight) runs through every shade, and taking off its edge colour
        // would leave only the highlight. Too many in-between colours: it is
        // a shape, not a plate. A square outline is exempt: the plates of
        // macOS 26 app icons carry gradients and gloss just as shaded, and
        // their outline drawn from alpha would be a block anyway.
        if outlineIsAShape {
            let between = opaque.filter { (betweenBand.from * spread..<betweenBand.to * spread).contains(distance($0)) }.count
            guard Double(between) <= maximumBetween * Double(opaque.count) else { return nil }
        }
        return ink
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func bitmap(side: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(data: data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// `image` drawn into a `side`-square buffer, whole and centred. Row 0 is the top.
    private static func rgba(_ image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = bitmap(side: side, data: buffer.baseAddress) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: ActionIconStore.fitted(CGSize(width: image.width, height: image.height),
                                                          side: CGFloat(side)))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func makeImage(from pixels: inout [UInt8], side: Int) -> CGImage? {
        pixels.withUnsafeMutableBytes { buffer in bitmap(side: side, data: buffer.baseAddress)?.makeImage() }
    }
}

/// Every SF Symbol name this Mac knows, for the editor's search box.
///
/// There is no public call that lists them, so the names are read from the table
/// the system keeps beside the symbols themselves. If that file is ever gone the
/// catalogue is empty and the search offers only the name typed, when it is one.
enum SFSymbolCatalog {

    private static let table = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"

    static let names: [String] = {
        guard let plist = NSDictionary(contentsOfFile: table),
              let symbols = plist["symbols"] as? [String: Any] else { return [] }
        return symbols.keys.sorted()
    }()

    /// What is typed, as a symbol name would spell it: lower case, words joined
    /// by dots ("arrow up" → "arrow.up").
    static func normalized(_ query: String) -> String {
        query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .joined(separator: ".")
    }

    /// Names matching `query` out of `names`: the ones that START with it first,
    /// then the ones that only contain it, each group in name order.
    static func matches(_ query: String, in names: [String], limit: Int) -> [String] {
        let q = normalized(query)
        guard !q.isEmpty else { return [] }
        var starts: [String] = [], contains: [String] = []
        for name in names {
            if name.hasPrefix(q) { starts.append(name) }
            else if name.contains(q) { contains.append(name) }
        }
        return Array((starts + contains).prefix(limit))
    }

    /// Whether this Mac can draw the symbol. The table also lists names from
    /// systems newer or older than this one.
    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The last search and its answer. The editor asks from its view body, which
    /// is re-evaluated for every change to the action being edited, not only for
    /// a change to what is typed in the search box. Main thread only.
    private static var last: (query: String, limit: Int, found: [String])?

    /// The symbols to offer for what is typed: every match this Mac can draw.
    static func search(_ query: String, limit: Int = 240) -> [String] {
        let typed = normalized(query)
        if let last, last.query == typed, last.limit == limit { return last.found }
        var found = matches(query, in: names, limit: limit * 2).filter(exists)
        if found.isEmpty, !typed.isEmpty, exists(typed) { found = [typed] }
        found = Array(found.prefix(limit))
        last = (typed, limit, found)
        return found
    }
}
