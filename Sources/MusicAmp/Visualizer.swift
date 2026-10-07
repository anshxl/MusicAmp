import AudioTap
import CoreGraphics

/// Winamp's 76×16 visualizer: spectrum (thick or thin bars, falling peaks) or oscilloscope.
/// viscolor.txt: 0 background, 1 grid dots, 2…17 spectrum rows top to bottom, 18…22 oscilloscope, 23 peaks.
final class Visualizer {
    enum Mode: Int, CaseIterable {
        case thickBars, thinBars, oscilloscope, off
        var title: String { ["Thick bars", "Thin bars", "Oscilloscope", "Off"][rawValue] }
    }

    static let width = 76, height = 16
    // Calibration knobs: dB window mapped onto the 16 px, and fall speeds in px per frame (30 fps).
    static let floorDB: Float = -60, ceilingDB: Float = -6
    static let barFall = 1.0, peakGravity = 0.04

    var mode: Mode { didSet { bars = []; peaks = []; scope = [] } }
    private var spectrum: Spectrum
    private var sampleRate: Double
    private var bars: [Double] = [], peaks: [Double] = [], peakSpeed: [Double] = []
    private var scope: [Float] = []
    private var background: (colors: [CGColor], image: CGImage)?

    /// True when nothing would move: no bars, no peaks, no waveform. The view stops redrawing then.
    var isIdle: Bool { mode == .off || (scope.isEmpty && bars.allSatisfy { $0 == 0 } && peaks.allSatisfy { $0 == 0 }) }

    init(mode: Mode, sampleRate: Double = 48_000) {
        self.mode = mode
        self.sampleRate = sampleRate
        spectrum = Spectrum(sampleRate: sampleRate, bands: 75)
    }

    /// One animation frame. `samples` is the latest `Spectrum.size` mono samples, or nil for silence.
    func update(samples: [Float]?, sampleRate rate: Double) {
        if rate != sampleRate, rate > 0 {
            sampleRate = rate
            spectrum = Spectrum(sampleRate: rate, bands: 75)
        }
        switch mode {
        case .off: return
        case .oscilloscope:
            scope = samples.map { Array($0.suffix(576)) } ?? []
        case .thickBars, .thinBars:
            let db = samples.map(spectrum.bandsDB) ?? Array(repeating: -200, count: 75)
            let count = mode == .thinBars ? 75 : 19
            if bars.count != count {
                bars = Array(repeating: 0, count: count)
                peaks = bars
                peakSpeed = bars
            }
            for i in 0..<count {
                // Thick bars take the loudest of the ~4 thin bands they cover.
                let level = mode == .thinBars ? db[i] : db[(i * 75 / 19)..<((i + 1) * 75 / 19)].max()!
                let h = Double((level - Self.floorDB) / (Self.ceilingDB - Self.floorDB)) * Double(Self.height)
                bars[i] = max(min(h, Double(Self.height)), bars[i] - Self.barFall, 0)
                if bars[i] >= peaks[i] {
                    peaks[i] = bars[i]
                    peakSpeed[i] = 0
                } else {
                    peakSpeed[i] += Self.peakGravity
                    peaks[i] = max(0, peaks[i] - peakSpeed[i])
                }
            }
        }
    }

    /// Draws in a y-down context, top-left at `origin`.
    func draw(in ctx: CGContext, at origin: CGPoint, colors c: [CGColor]) {
        guard mode != .off, c.count >= 24 else { return }
        func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: Int(origin.x) + x, y: Int(origin.y) + y, width: w, height: h))
        }
        let bg = background?.colors == c ? background!.image : Self.makeBackground(c)
        background = (c, bg)
        ctx.saveGState() // the background is y-up like any CGImage
        ctx.translateBy(x: origin.x, y: origin.y + CGFloat(Self.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(bg, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        ctx.restoreGState()

        if mode == .oscilloscope {
            guard !scope.isEmpty else { return }
            var prev: Int?
            for x in 0..<75 {
                let s = scope[x * scope.count / 75]
                let y = min(15, max(0, Int((7.5 - Double(s) * 8).rounded())))
                let (top, bottom) = prev.map { (min($0, y), max($0, y)) } ?? (y, y)
                for row in top...bottom {
                    px(x, row, 1, 1, c[18 + min(4, Int(abs(Double(row) - 7.5)) / 2)])
                }
                prev = y
            }
            return
        }

        // One fill per colour row (16 + peaks) instead of one per bar pixel.
        let barWidth = mode == .thinBars ? 1 : 3, pitch = mode == .thinBars ? 1 : 4
        let heights = bars.map { Int($0.rounded()) }
        for row in 0..<Self.height {
            let rects = heights.indices.filter { heights[$0] >= Self.height - row }.map {
                CGRect(x: Int(origin.x) + $0 * pitch, y: Int(origin.y) + row, width: barWidth, height: 1)
            }
            if !rects.isEmpty {
                ctx.setFillColor(c[2 + row])
                ctx.fill(rects)
            }
        }
        let peakRects = peaks.indices.compactMap { i -> CGRect? in
            let row = Self.height - Int(peaks[i].rounded()) - 1
            return peaks[i] >= 1 && row >= 0 ? CGRect(x: Int(origin.x) + i * pitch, y: Int(origin.y) + row, width: barWidth, height: 1) : nil
        }
        ctx.setFillColor(c[23])
        ctx.fill(peakRects)
    }

    /// Colour 0 with colour-1 grid dots on every other pixel of every other row.
    private static func makeBackground(_ c: [CGColor]) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height)) // draw y-down, matching the view
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(c[0])
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(c[1])
        ctx.fill(stride(from: 1, to: height, by: 2).flatMap { y in
            stride(from: 0, to: width, by: 2).map { CGRect(x: $0, y: y, width: 1, height: 1) }
        })
        return ctx.makeImage()!
    }
}
