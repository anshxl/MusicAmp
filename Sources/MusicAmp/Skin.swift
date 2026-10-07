import CoreGraphics
import Foundation
import ImageIO
import ZIPFoundation

/// A loaded .wsz skin. Any sprite or colour the skin lacks comes from `fallback` (the bundled default).
final class Skin {
    static let sheets: Set<String> = [
        "main", "titlebar", "cbuttons", "numbers", "nums_ex", "text", "posbar",
        "volume", "balance", "playpaus", "monoster", "shufrep", "eqmain", "pledit", "eq_ex",
    ]
    static let maxEntrySize: UInt64 = 8 << 20 // per entry, counted while inflating (zip bombs lie in headers)
    static let maxImageSide = 2_048 // real skin bitmaps are under 500 px; a BMP header can claim anything

    let url: URL
    let visColors: [CGColor] // 24 colours, see viscolor.txt
    let playlistStyle: PlaylistStyle
    /// region.txt polygons by lowercased section ("normal", "windowshade", "equalizer", "equalizerws").
    /// Only from the skin itself: no region means a rectangular window.
    let regions: [String: [[CGPoint]]]
    private let images: [String: CGImage]
    private let fallback: Skin?
    private var cache: [Sprite: CGImage] = [:]

    init(url: URL, fallback: Skin?) throws {
        self.url = url
        self.fallback = fallback
        let archive = try Archive(url: url, accessMode: .read)
        var images: [String: CGImage] = [:]
        var visText: String?, pleditText: String?, regionText: String?
        for entry in archive where entry.type == .file && entry.uncompressedSize < Self.maxEntrySize {
            // Match on the file name only, case-insensitively: skins often nest files in a folder.
            let file = (entry.path as NSString).lastPathComponent.lowercased()
            let base = (file as NSString).deletingPathExtension
            guard file.hasSuffix(".bmp") && Self.sheets.contains(base) && images[base] == nil
                    || file == "viscolor.txt" && visText == nil
                    || file == "pledit.txt" && pleditText == nil
                    || file == "region.txt" && regionText == nil else { continue }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                guard UInt64(data.count + chunk.count) <= Self.maxEntrySize else {
                    throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: entry.path])
                }
                data.append(chunk)
            }
            if file == "viscolor.txt" {
                visText = String(decoding: data, as: UTF8.self)
            } else if file == "pledit.txt" {
                pleditText = String(decoding: data, as: UTF8.self)
            } else if file == "region.txt" {
                regionText = String(decoding: data, as: UTF8.self)
            } else if let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      img.width <= Self.maxImageSide, img.height <= Self.maxImageSide {
                images[base] = Self.rgba(img)
            }
        }
        self.images = images
        let parsed = Self.parseVisColors(visText ?? "")
        visColors = parsed + (fallback?.visColors.dropFirst(parsed.count) ?? [])
        playlistStyle = PlaylistStyle(ini: pleditText ?? "", fallback: fallback?.playlistStyle)
        regions = Self.parseRegions(regionText ?? "")
        if fallback == nil && (visColors.count < 24 || images.count < Self.sheets.count - 1) {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Decodes once into RGBA. Drawing the lazily decoded, often RLE and palette-based BMP
    /// directly would decode and convert it again on every frame.
    private static func rgba(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    func has(_ sheet: String) -> Bool { images[sheet] != nil }

    /// The sprite's pixels from this skin, or from the fallback skin if the bitmap is missing or too small.
    func image(_ s: Sprite) -> CGImage? {
        if let hit = cache[s] { return hit }
        var img: CGImage?
        if let sheet = images[s.sheet], CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height).contains(s.rect) {
            img = sheet.cropping(to: s.rect)
        }
        img = img ?? fallback?.image(s)
        cache[s] = img
        return img
    }

    /// region.txt: `[Section]`, `NumPoints=4,4,…` (points per polygon) and `PointList=x,y x,y …` on one line.
    /// Comments start with ";". A section whose counts do not match its points is ignored.
    static func parseRegions(_ text: String) -> [String: [[CGPoint]]] {
        var result: [String: [[CGPoint]]] = [:]
        var section = "", counts: [Int] = [], points: [Int] = []
        func flush() {
            // Bound each count by the points present before summing: huge counts from a crafted file
            // would otherwise overflow (a trap) and, since the skin path is saved, crash every launch.
            guard !section.isEmpty, result[section] == nil, !counts.isEmpty,
                  counts.allSatisfy({ $0 >= 3 && $0 <= points.count }),
                  counts.reduce(0, +) * 2 == points.count else { return }
            var polygons: [[CGPoint]] = [], i = 0
            for n in counts {
                polygons.append((0..<n).map { CGPoint(x: points[i + 2 * $0], y: points[i + 2 * $0 + 1]) })
                i += 2 * n
            }
            result[section] = polygons
        }
        let numbers = { (s: Substring) in s.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) } }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                section = line.dropFirst().dropLast().lowercased()
                counts = []
                points = []
            } else if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "numpoints" { counts = numbers(line[line.index(after: eq)...]) }
                if key == "pointlist" { points = numbers(line[line.index(after: eq)...]) }
            }
        }
        flush()
        return result
    }

    /// One colour per line: the first three integers are r, g, b. Comments and junk are ignored.
    static func parseVisColors(_ text: String) -> [CGColor] {
        let colors = text.split(whereSeparator: \.isNewline).compactMap { line -> CGColor? in
            let n = line.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            return CGColor(srgbRed: CGFloat(min(n[0], 255)) / 255, green: CGFloat(min(n[1], 255)) / 255,
                           blue: CGFloat(min(n[2], 255)) / 255, alpha: 1)
        }
        return Array(colors.prefix(24))
    }
}

/// Playlist colours and font from pledit.txt (`[Text]` section, `Key=#RRGGBB`).
struct PlaylistStyle {
    var normal = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    var current = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    var normalBG = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    var selectedBG = CGColor(srgbRed: 0, green: 0, blue: 0.78, alpha: 1)
    var font = "Arial"

    init(ini: String, fallback: PlaylistStyle?) {
        if let fallback { self = fallback }
        for line in ini.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "normal": normal = Self.color(kv[1]) ?? normal
            case "current": current = Self.color(kv[1]) ?? current
            case "normalbg": normalBG = Self.color(kv[1]) ?? normalBG
            case "selectedbg": selectedBG = Self.color(kv[1]) ?? selectedBG
            case "font" where !kv[1].isEmpty: font = kv[1]
            default: break
            }
        }
    }

    /// "#RRGGBB" (the "#" is optional; some skins omit it).
    static func color(_ s: String) -> CGColor? {
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
