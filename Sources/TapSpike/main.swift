import AppKit
import AudioTap
import CoreAudio

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when stdout is a file/pipe (app-bundle mode)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("TapSpike: \(msg)\n".utf8))
    exit(1)
}

if CommandLine.arguments.contains("--selftest") {
    Spectrum.selfTest()
    exit(0)
}

// `--pid N` taps any process instead (pipeline test with e.g. afplay).
let pidArg = CommandLine.arguments.firstIndex(of: "--pid").flatMap { Int32(CommandLine.arguments[$0 + 1]) }
guard let pid = pidArg ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier else {
    fail("Music.app is not running. Start it, play a track, and rerun.")
}

let queue = DispatchQueue(label: "tapspike.audio") // IOProc + printer share it, so no locks
var ring: [Float] = []
var sumSquares = 0.0
var sampleCount = 0

let tap: ProcessTap
do {
    guard let process = try audioProcessObject(pid: pid) else {
        fail("pid \(pid) has no Core Audio process object yet. Play a track once, then rerun.")
    }
    tap = try ProcessTap(process: process, queue: queue) { samples in
        ring.append(contentsOf: samples)
        if ring.count > Spectrum.size { ring.removeFirst(ring.count - Spectrum.size) }
        for s in samples { sumSquares += Double(s * s) }
        sampleCount += samples.count
    }
} catch {
    fail("\(error)")
}

let f = tap.format
print("Tapping pid \(pid): \(f.mSampleRate) Hz, \(f.mChannelsPerFrame) ch, flags 0x\(String(f.mFormatFlags, radix: 16)). Ctrl+C to stop.")
let spectrum = Spectrum(sampleRate: f.mSampleRate)

let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
timer.setEventHandler {
    let bars = ring.count == Spectrum.size ? Spectrum.render(spectrum.bandsDB(ring))
                                           : String(repeating: " ", count: spectrum.bandCount)
    let note = sampleCount == 0 ? "  (no callbacks)" : sumSquares == 0 ? "  (digital silence)" : ""
    print(String(format: "RMS %7.1f dBFS |%@|%@", Spectrum.rmsDB(sumSquares: sumSquares, count: sampleCount), bars, note))
    sumSquares = 0
    sampleCount = 0
}
timer.resume()

let signalSources = [SIGINT, SIGTERM].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        timer.cancel()
        tap.stop()
        print("\nTap and aggregate device destroyed.")
        exit(0)
    }
    src.resume()
    return src
}

dispatchMain()
