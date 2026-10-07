import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey through Carbon's RegisterEventHotKey: public API, no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// `spec` is like "ctrl+option+w" or "cmd+shift+f5". Returns nil if it does not parse or is taken.
    init?(_ spec: String, action: @escaping () -> Void) {
        guard let (keyCode, modifiers) = Self.parse(spec) else { return nil }
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            Unmanaged<HotKey>.fromOpaque(me!).takeUnretainedValue().action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4D416D70), id: 1) // "MAmp"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// "ctrl+option+w" → (kVK_ANSI_W, controlKey | optionKey). Needs at least one modifier and exactly one key.
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0, key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil, let k = keyCodes[part] else { return nil }
                key = k
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    /// Display form for menus, e.g. "⌃⌥W".
    static func symbols(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        let mods = [("ctrl", "⌃"), ("control", "⌃"), ("opt", "⌥"), ("option", "⌥"), ("alt", "⌥"),
                    ("shift", "⇧"), ("cmd", "⌘"), ("command", "⌘")]
        return mods.filter { parts.contains($0.0) }.map(\.1).joined() + (parts.last ?? "").uppercased()
    }

    private static let keyCodes: [String: UInt32] = {
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
                       kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                       kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
                      kVK_ANSI_8, kVK_ANSI_9]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        var t: [String: UInt32] = ["space": UInt32(kVK_Space)]
        for (i, k) in letters.enumerated() { t[String(UnicodeScalar(UInt8(97 + i)))] = UInt32(k) }
        for (i, k) in digits.enumerated() { t[String(i)] = UInt32(k) }
        for (i, k) in fkeys.enumerated() { t["f\(i + 1)"] = UInt32(k) }
        return t
    }()
}
