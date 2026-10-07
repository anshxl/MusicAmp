import Accelerate
import Foundation

/// 1024-point Hann-windowed FFT reduced to log-spaced bands, in dBFS
/// (a full-scale sine reads ~0 dB in its band).
public struct Spectrum {
    public static let size = 1024
    public let bandCount: Int
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: Spectrum.size, isHalfWindow: false)
    private let bandBins: [Range<Int>]

    public init(sampleRate: Double, bands: Int = 20, low: Double = 50, high: Double = 16_000) {
        bandCount = bands
        let binHz = sampleRate / Double(Spectrum.size)
        let top = min(high, sampleRate / 2 * 0.95)
        // Log-spaced edges in bin units; each band gets at least one bin of its own, so the
        // low end turns linear where log bands would be narrower than one bin.
        var ranges: [Range<Int>] = []
        var next = max(1, Int((low / binHz).rounded()))
        for i in 1...bands {
            let edge = Int((low * pow(top / low, Double(i) / Double(bands)) / binHz).rounded())
            let hi = min(Spectrum.size / 2, max(next + 1, edge))
            ranges.append(min(next, hi - 1)..<hi)
            next = hi
        }
        bandBins = ranges
    }

    /// `samples` must hold exactly `Spectrum.size` values.
    public func bandsDB(_ samples: [Float]) -> [Float] {
        let n = Spectrum.size
        let windowed = vDSP.multiply(samples, window)
        var re = [Float](repeating: 0, count: n / 2), im = re
        var outRe = re, outIm = re
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { reP in
            im.withUnsafeMutableBufferPointer { imP in
                outRe.withUnsafeMutableBufferPointer { oReP in
                    outIm.withUnsafeMutableBufferPointer { oImP in
                        var input = DSPSplitComplex(realp: reP.baseAddress!, imagp: imP.baseAddress!)
                        var output = DSPSplitComplex(realp: oReP.baseAddress!, imagp: oImP.baseAddress!)
                        windowed.withUnsafeBytes {
                            vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &input, 1, vDSP_Length(n / 2))
                        }
                        fft.forward(input: input, output: &output)
                        vDSP.squareMagnitudes(output, result: &power)
                    }
                }
            }
        }
        // zrip output is 2x the DFT; Hann coherent gain 0.5; sine splits across ±f -> amplitude = |Z| * 2 / n.
        let scale = 20 * log10f(2 / Float(n))
        return bandBins.map { r in
            let peak = r.clamped(to: 1..<(n / 2)).map { power[$0] }.max() ?? 0
            return 10 * log10f(max(peak, 1e-20)) + scale
        }
    }

    /// One block character per band, mapping -60...0 dB onto 8 heights.
    public static func render(_ db: [Float]) -> String {
        let blocks = Array(" ▁▂▃▄▅▆▇█")
        return String(db.map { v in blocks[Int(((v + 60) / 60 * 8).rounded()).clamped(0, 8)] })
    }

    public static func rmsDB(sumSquares: Double, count: Int) -> Double {
        count == 0 ? -.infinity : 10 * log10(max(sumSquares / Double(count), 1e-20))
    }

    /// `TapSpike --selftest`: 1 kHz full-scale sine must peak near 0 dB in the band holding 1 kHz.
    public static func selfTest() {
        let sr = 48_000.0
        let s = Spectrum(sampleRate: sr)
        let sine = (0..<size).map { Float(sin(2 * Double.pi * 1000 * Double($0) / sr)) }
        let db = s.bandsDB(sine)
        let loudest = db.indices.max { db[$0] < db[$1] }!
        let bin1k = Int(1000 / (sr / Double(size)))
        precondition(s.bandBins[loudest].contains(bin1k), "loudest band \(loudest) does not contain 1 kHz")
        precondition(abs(db[loudest]) < 1.5, "1 kHz full-scale sine read \(db[loudest]) dB, expected ~0")
        precondition(db.first! < -40, "50 Hz band leaked: \(db.first!) dB")
        for bands in [20, 75] { // bands must be non-empty, in order, and not share bins
            let b = Spectrum(sampleRate: sr, bands: bands).bandBins
            precondition(b.allSatisfy { !$0.isEmpty } && zip(b, b.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound })
        }
        let sumSq = sine.reduce(0.0) { $0 + Double($1 * $1) }
        precondition(abs(rmsDB(sumSquares: sumSq, count: size) + 3.01) < 0.1, "sine RMS should be -3 dBFS")
        print("selftest ok:", render(db), String(format: "peak %.2f dB in band %d", db[loudest], loudest))
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
