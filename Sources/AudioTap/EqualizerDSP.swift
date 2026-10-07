import Accelerate
import CoreAudio
import Foundation
import os

/// Winamp-style 10-band stereo EQ: one peaking biquad per band plus a preamp, in 32-bit float.
///
/// Thread use: `update` on any thread; `process` on the real-time audio thread only. `process`
/// never allocates and never blocks: settings arrive through a try-lock and wait for the next
/// buffer if the lock is busy.
public final class EqualizerDSP: @unchecked Sendable {
    /// Winamp's band centres, matching the labels on eqmain.bmp.
    public static let frequencies: [Double] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    public static let q = 1.4 // about one octave wide

    public struct Settings: Equatable, Sendable, Codable {
        public var enabled = false
        public var preamp = 0.0 // dB
        public var bands = Array(repeating: 0.0, count: 10) // dB, -12…+12
        public var autoHeadroom = true // lower the output by the largest boost, so boosts cannot clip
        public init() {}

        /// Total output gain in dB: preamp minus the largest boost when `autoHeadroom` is on.
        public var outputGainDB: Double { preamp - (autoHeadroom ? max(0, bands.max() ?? 0) : 0) }
        /// True when processing would not change a single sample.
        public var isTransparent: Bool { bands.allSatisfy { $0 == 0 } && outputGainDB == 0 }
    }

    private let setup: vDSP_biquadm_Setup
    private let lock = OSAllocatedUnfairLock()
    private var pending: (settings: Settings, coefficients: [Double])? // computed off the audio thread

    // Audio-thread state.
    private var current = Settings()
    private var gain: Float = 1
    private let maxFrames = 8_192
    private let scratch: UnsafeMutablePointer<Float>
    private let work: UnsafeMutablePointer<Float>
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init() {
        setup = vDSP_biquadm_CreateSetup(Self.coefficients(bands: Array(repeating: 0, count: 10), sampleRate: 48_000), 10, 2)!
        scratch = .allocate(capacity: maxFrames * 2)
        work = .allocate(capacity: maxFrames * 2)
        inPtrs = .allocate(capacity: 2)
        outPtrs = .allocate(capacity: 2)
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        scratch.deallocate()
        work.deallocate()
        inPtrs.deallocate()
        outPtrs.deallocate()
    }

    /// Takes effect on the next audio buffer. `sampleRate` is the tap's.
    public func update(_ settings: Settings, sampleRate: Double) {
        // The rate is appended so a rate change reloads coefficients even if the bands did not change.
        let coefficients = Self.coefficients(bands: settings.bands, sampleRate: sampleRate) + [sampleRate]
        lock.withLock { pending = (settings, coefficients) }
    }
    // ponytail: replacing these on the audio thread can free the old array there (only when settings change);
    // swap in preallocated buffers if that ever causes a glitch.
    private var appliedCoefficients: [Double] = []

    /// Processes interleaved stereo in place. Returns false when the EQ is disabled (the caller then
    /// outputs silence and Music plays unprocessed). When transparent, `samples` is left bit-identical.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        lock.withLockIfAvailable {
            guard let p = pending else { return }
            if p.coefficients != appliedCoefficients {
                vDSP_biquadm_SetCoefficientsDouble(setup, p.coefficients, 0, 0, 10, 2) // keeps filter state
                appliedCoefficients = p.coefficients
            }
            current = p.settings
            pending = nil
        }
        guard current.enabled else { return false }
        guard !current.isTransparent, frames <= maxFrames else {
            gain = 1
            return true
        }

        // Interleaved stereo: channel c starts at offset c with stride 2.
        inPtrs[0] = UnsafePointer(samples)
        inPtrs[1] = UnsafePointer(samples + 1)
        outPtrs[0] = scratch
        outPtrs[1] = scratch + 1
        vDSP_biquadm(setup, inPtrs, 2, outPtrs, 2, vDSP_Length(frames))

        // Output gain, ramped across the buffer so slider moves do not click.
        let target = Float(pow(10, current.outputGainDB / 20))
        let step = (target - gain) / Float(frames)
        for f in 0..<frames {
            let g = gain + step * Float(f + 1)
            samples[2 * f] = scratch[2 * f] * g
            samples[2 * f + 1] = scratch[2 * f + 1] * g
        }
        gain = target
        return true
    }

    /// Real-time render for `ProcessTap`'s output mode: interleaved stereo float from the tap in, the
    /// device's buffers out (any layout). Writes silence when disabled, so only Music's own output plays.
    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frames = 0
        if let first = ins.first, first.mNumberChannels == 2, let src = first.mData?.assumingMemoryBound(to: Float.self) {
            frames = min(maxFrames, Int(first.mDataByteSize) / (2 * MemoryLayout<Float>.size))
            work.update(from: src, count: frames * 2)
        }
        let on = frames > 0 && process(work, frames: frames)
        for buf in outs {
            guard let dst = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(buf.mNumberChannels), n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            dst.update(repeating: 0, count: n)
            guard on, ch > 0 else { continue }
            for f in 0..<min(frames, n / ch) {
                for c in 0..<min(ch, 2) { dst[f * ch + c] = work[2 * f + c] }
            }
        }
    }

    /// RBJ "Audio EQ Cookbook" peaking filters, `[b0, b1, b2, a1, a2] / a0` per section, repeated
    /// per channel (layout: section-major, both channels identical).
    static func coefficients(bands: [Double], sampleRate: Double) -> [Double] {
        zip(frequencies, bands).flatMap { f0, dB -> [Double] in
            let a = pow(10, dB / 40), w0 = 2 * Double.pi * min(f0, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q), cosw = cos(w0)
            let a0 = 1 + alpha / a
            let c = [(1 + alpha * a) / a0, -2 * cosw / a0, (1 - alpha * a) / a0, -2 * cosw / a0, (1 - alpha / a) / a0]
            return c + c // left, right
        }
    }

    /// Checks the response with sines (run by `MusicAmp --selftest`).
    public static func selfTest() {
        let sr = 48_000.0, n = 9_600
        func gainDB(_ freq: Double, _ settings: Settings) -> Double {
            let dsp = EqualizerDSP()
            dsp.update(settings, sampleRate: sr)
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
            defer { buf.deallocate() }
            for f in 0..<n {
                let s = Float(0.25 * sin(2 * .pi * freq * Double(f) / sr))
                buf[2 * f] = s
                buf[2 * f + 1] = s
            }
            for start in stride(from: 0, to: n, by: 512) { _ = dsp.process(buf + 2 * start, frames: min(512, n - start)) }
            // RMS of the second half (after filter settling) for both channels, versus the input's 0.25 / √2.
            var sum = 0.0
            for f in n / 2..<n { sum += Double(buf[2 * f] * buf[2 * f] + buf[2 * f + 1] * buf[2 * f + 1]) }
            return 20 * log10(sqrt(sum / Double(n)) / (0.25 / sqrt(2)))
        }
        var s = Settings()
        s.enabled = true
        s.autoHeadroom = false
        s.bands[4] = 12 // +12 dB at 1 kHz
        precondition(abs(gainDB(1_000, s) - 12) < 0.5, "1 kHz band should boost 1 kHz by 12 dB, got \(gainDB(1_000, s))")
        precondition(abs(gainDB(60, s)) < 0.5, "1 kHz band should leave 60 Hz alone, got \(gainDB(60, s))")
        s.bands[4] = 0
        s.bands[0] = -12
        precondition(abs(gainDB(60, s) + 12) < 0.5, "60 Hz cut, got \(gainDB(60, s))")
        precondition(abs(gainDB(3_000, s)) < 0.5, "60 Hz band should leave 3 kHz alone")
        var h = Settings()
        h.enabled = true
        h.bands[4] = 9
        precondition(h.outputGainDB == -9 && abs(gainDB(1_000, h)) < 0.5, "auto headroom should cancel the 9 dB peak")
        h.preamp = -3
        precondition(h.outputGainDB == -12, "preamp adds to headroom")
        precondition(Settings().isTransparent && !h.isTransparent, "transparency")
        print("EQ selftest ok")
    }
}
