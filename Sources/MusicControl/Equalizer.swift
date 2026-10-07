import Foundation

/// Music's EQ over AppleScript, as tested on Music 1.7 / macOS 27.0.1:
/// - preset band 1–10 and preamp: read and write work (-12…+12 dB).
/// - `EQ enabled`: read works, write fails (-10006).
/// - `current EQ preset`: read and write both fail (-1731), so we cannot know or pick the active preset.
/// So edits only reach the sound if the user turns EQ on and selects that preset in Music.
public struct EQPreset: Sendable {
    public static let frequencies = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    public let name: String
    public var preamp: Double
    public var bands: [Double] // 10 values, 32 Hz … 16 kHz
}

public enum Equalizer {
    public static var isEnabled: Bool {
        get throws { try tellMusic("EQ enabled").booleanValue }
    }

    public static func presetNames() throws -> [String] {
        try tellMusic("name of every EQ preset").items.compactMap(\.stringValue)
    }

    /// Reads preamp and all 10 bands in one Apple Event.
    public static func preset(named name: String) throws -> EQPreset {
        let props = (["preamp"] + (1...10).map { "band \($0)" }).joined(separator: ", ")
        let v = try tellMusic("get {\(props)} of EQ preset \(quoted(name))").items.map(\.double)
        return EQPreset(name: name, preamp: v[0], bands: Array(v[1...]))
    }

    /// `band` 1…10, or 0 for the preamp. Value is clamped to -12…+12 dB.
    public static func set(preset name: String, band: Int, to dB: Double) throws {
        precondition((0...10).contains(band), "band must be 0 (preamp) or 1…10")
        let prop = band == 0 ? "preamp" : "band \(band)"
        try tellMusic("set \(prop) of EQ preset \(quoted(name)) to \(number(min(12, max(-12, dB))))")
    }
}
