import CoreAudio
import Foundation

public struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    public var description: String { "\(what) failed: OSStatus \(status) ('\(fourCC(status))')" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

private func fourCC(_ s: OSStatus) -> String {
    let b = withUnsafeBytes(of: UInt32(bitPattern: s).bigEndian, Array.init)
    return b.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: b, as: UTF8.self) : "\(s)"
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

/// Translates a PID to its Core Audio process object. Returns nil if the
/// process has never touched Core Audio (e.g. Music.app before first playback).
public func audioProcessObject(pid: pid_t) throws -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj),
              "TranslatePIDToProcessObject")
    return obj == kAudioObjectUnknown ? nil : obj
}

/// The UID of the current default output device (for `ProcessTap`'s output mode).
public func defaultOutputDeviceUID() throws -> String {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
              "read default output device")
    addr = address(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "read output device UID")
    return uid!.takeRetainedValue() as String
}

/// Process tap on one process (stereo mixdown), wrapped in a private aggregate device.
public final class ProcessTap {
    /// Called on the real-time IO thread: Music's audio in, the output device's buffers out
    /// (output mode only). Must not allocate, lock or block.
    public typealias Render = (_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) -> Void

    public private(set) var format = AudioStreamBasicDescription()
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Tap-only mode (TapSpike): mono samples delivered on `queue`.
    public convenience init(process: AudioObjectID, queue: DispatchQueue, onSamples: @escaping ([Float]) -> Void) throws {
        try self.init(process: process, outputDeviceUID: nil, queue: queue) { input, _ in onSamples(Self.mono(input)) }
    }

    /// With `outputDeviceUID`, the aggregate also contains that device as its clock, so `render` reads
    /// the tap and writes the device's output in the same IO cycle. `queue` must be nil then (real-time thread).
    public init(process: AudioObjectID, outputDeviceUID: String?, queue: DispatchQueue? = nil,
                muted: Bool = false, render: @escaping Render) throws {
        description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "MusicAmp"
        description.muteBehavior = muted ? .muted : .unmuted
        description.isPrivate = true
        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

            var addr = address(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "read tap format")

            var config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MusicAmp",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            if let outputDeviceUID {
                config[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
                config[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
            }
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
                render(input, output)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        } catch {
            stop()
            throw error
        }
    }

    /// Muted: Music's own output is silenced and only what `render` writes is heard.
    public func setMuted(_ muted: Bool) throws {
        description.muteBehavior = muted ? .muted : .unmuted
        var addr = address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(description).toOpaque()
        try check(AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref),
                  "set tap mute behavior")
    }

    /// Mixes interleaved or planar Float32 buffers down to mono.
    private static func mono(_ list: UnsafePointer<AudioBufferList>) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return [] }
        let channels = Int(first.mNumberChannels) // >1 means interleaved
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(channels, 1)
        var out = [Float](repeating: 0, count: frames)
        var totalChannels = 0
        for buf in buffers {
            guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(buf.mNumberChannels)
            for f in 0..<frames { for c in 0..<ch { out[f] += p[f * ch + c] } }
            totalChannels += ch
        }
        if totalChannels > 1 { for i in out.indices { out[i] /= Float(totalChannels) } }
        return out
    }

    /// Idempotent teardown: IOProc, aggregate device, then tap.
    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let id = ioProcID {
                AudioDeviceStop(aggregateID, id)
                AudioDeviceDestroyIOProcID(aggregateID, id)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
