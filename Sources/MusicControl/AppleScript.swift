import Foundation

public struct MusicError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    public var description: String { "Music AppleScript error \(code): \(message)" }
}

/// Compiled scripts by source. Profiling showed per-call compiles were a large share of the 4 Hz poll's CPU.
nonisolated(unsafe) private var compiled: [String: NSAppleScript] = [:]

/// Runs `tell application "Music" to …` source. Main thread only (NSAppleScript is not thread-safe).
@discardableResult
func tellMusic(_ body: String) throws -> NSAppleEventDescriptor {
    if compiled.count > 64 { compiled.removeAll() } // ponytail: crude bound; seek/volume sources vary by value
    let script = compiled[body] ?? NSAppleScript(source: "tell application \"Music\"\n\(body)\nend tell")!
    compiled[body] = script
    var info: NSDictionary?
    let result = script.executeAndReturnError(&info)
    if let info {
        throw MusicError(code: info[NSAppleScript.errorNumber] as? Int ?? 0,
                         message: info[NSAppleScript.errorMessage] as? String ?? "unknown")
    }
    return result
}

/// Quotes a Swift string as an AppleScript string literal.
func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Formats a number for AppleScript source (never exponent notation like `1e-05`).
func number(_ x: Double) -> String { String(format: "%.3f", x) }

extension NSAppleEventDescriptor {
    /// Items of an AppleScript list (1-based in Apple Events, 0-based here).
    var items: [NSAppleEventDescriptor] {
        numberOfItems == 0 ? [] : (1...numberOfItems).compactMap { atIndex($0) }
    }
    var double: Double { Double(stringValue ?? "") ?? 0 }
}
