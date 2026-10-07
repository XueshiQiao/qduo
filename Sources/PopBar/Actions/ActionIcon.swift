import AppKit
import SwiftUI
import ImageIO

/// An action's icon, wherever one is drawn: the user's own picture when the
/// action has one (`iconImage`) and its file can be read, the SF Symbol
/// (`iconSymbol`) otherwise.
///
/// The picture is drawn as it is — its own colours, scaled to fit the slot. It
/// does not take the skin's ink or the hover gradient the way a symbol does; how
/// it looks on the ring is up to whoever made it.
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
    /// Names whose file could not be read. Remembered too: this is asked from
    /// view bodies, and the ring redraws on every pointer move — a missing file
    /// must not mean a trip to the disk each time. Main thread only, like the
    /// views that ask. An import never reuses a name, so nothing here goes stale
    /// except a file added by hand, which shows after a restart (as a hand edit
    /// of the config does).
    private static var unreadable = Set<String>()

    /// The picture for an `iconImage` value; nil when there is none or its file
    /// cannot be read (the caller then draws the symbol).
    static func picture(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        if unreadable.contains(name) { return nil }
        guard let picture = NSImage(contentsOf: url(for: name)), picture.isValid else {
            unreadable.insert(name)
            return nil
        }
        cache.setObject(picture, forKey: name as NSString)
        return picture
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
