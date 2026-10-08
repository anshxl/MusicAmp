import CoreGraphics
import Foundation
import ImageIO

/// The current track's cover as a main-window background: centre-cropped to the window's shape,
/// pixelated into 4 px blocks and darkened. MainView draws it with "lighten" over main.bmp, so the
/// skin's dark display shows the art while bright chrome and text stay on top.
/// Its most vivid colour also replaces the visualizer's spectrum and peak colours.
struct AlbumArt {
    static let block = 4
    static let brightness = 0.45

    let overlay: CGImage // MainView.size
    let spectrum: [CGColor] // viscolor.txt 2…17, top bar row first
    let peak: CGColor // viscolor.txt 23

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let art = CGImageSourceCreateImageAtIndex(src, 0, nil), art.width > 0, art.height > 0 else { return nil }
        let size = MainView.size
        let cols = Int(size.width) / Self.block + 1, rows = Int(size.height) / Self.block + 1

        // Aspect fill: the largest centred crop with the window's proportions.
        let aspect = CGFloat(cols) / CGFloat(rows), w = CGFloat(art.width), h = CGFloat(art.height)
        let crop = w / h > aspect
            ? CGRect(x: (w - h * aspect) / 2, y: 0, width: h * aspect, height: h)
            : CGRect(x: 0, y: (h - w / aspect) / 2, width: w, height: w / aspect)
        guard let cropped = art.cropping(to: crop.integral), let small = Self.context(cols, rows) else { return nil }
        small.interpolationQuality = .high
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: cols, height: rows))

        // Most vivid cell (saturation × value), normalised to full brightness.
        let p = small.data!.assumingMemoryBound(to: UInt8.self)
        var best = (score: -1.0, rgb: (1.0, 1.0, 1.0))
        for i in stride(from: 0, to: cols * rows * 4, by: 4) {
            let (r, g, b) = (Double(p[i]) / 255, Double(p[i + 1]) / 255, Double(p[i + 2]) / 255)
            let hi = max(r, g, b), lo = min(r, g, b)
            if hi > 0, (hi - lo) / hi * hi > best.score { best = ((hi - lo) / hi * hi, (r / hi, g / hi, b / hi)) }
        }
        let (r, g, b) = best.rgb
        spectrum = (0..<16).map { CGColor(srgbRed: r * (1 - Double($0) * 0.04), green: g * (1 - Double($0) * 0.04),
                                          blue: b * (1 - Double($0) * 0.04), alpha: 1) }
        peak = CGColor(srgbRed: (r + 1) / 2, green: (g + 1) / 2, blue: (b + 1) / 2, alpha: 1)

        small.setFillColor(CGColor(gray: 0, alpha: 1 - Self.brightness))
        small.fill(CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let dark = small.makeImage(), let big = Self.context(Int(size.width), Int(size.height)) else { return nil }
        big.interpolationQuality = .none // nearest neighbour keeps the blocks sharp
        big.draw(dark, in: CGRect(x: 0, y: 0, width: cols * Self.block, height: rows * Self.block))
        guard let overlay = big.makeImage() else { return nil }
        self.overlay = overlay
    }

    /// The skin's 24 visualizer colours with the spectrum and peaks taken from the art.
    func visColors(over skin: [CGColor]) -> [CGColor] {
        guard skin.count >= 24 else { return skin }
        var c = skin
        c.replaceSubrange(2...17, with: spectrum)
        c[23] = peak
        return c
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

extension AlbumArt {
    /// Grey left half, red right half: the spectrum is red and no overlay pixel is brighter than `brightness`.
    static func selfTest() {
        precondition(AlbumArt(data: Data("not an image".utf8)) == nil)
        let c = context(60, 60)!
        c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 30, y: 0, width: 30, height: 60))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        let art = AlbumArt(data: data as Data)!
        precondition(art.overlay.width == Int(MainView.size.width) && art.overlay.height == Int(MainView.size.height))
        let top = art.spectrum[0].components!
        precondition(top[0] > 0.95 && top[1] < 0.05 && top[2] < 0.05, "spectrum should take the red: \(top)")
        let o = context(art.overlay.width, art.overlay.height)!
        o.draw(art.overlay, in: CGRect(x: 0, y: 0, width: o.width, height: o.height))
        let p = o.data!.assumingMemoryBound(to: UInt8.self)
        let brightest = (0..<o.width * o.height * 4).filter { $0 % 4 != 3 }.map { p[$0] }.max()!
        precondition(Double(brightest) <= brightness * 255 + 2, "overlay too bright: \(brightest)")
        precondition(p[0] > 50 && p[1] > 50, "left edge should be the grey half") // first row, first pixel
    }
}
