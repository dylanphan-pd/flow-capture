import AppKit
import Carbon

/// A global shortcut: one or more modifiers plus a key (or a function key on its own).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon flags: cmdKey, optionKey, controlKey, shiftKey
    var key: String            // lowercase character, used as the menu key equivalent

    private static let special: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    var isFunctionKey: Bool { Shortcut.special[keyCode]?.hasPrefix("F") == true }
    /// True when the key can be shown as a menu key equivalent (a plain printable character).
    var isPrintable: Bool { Shortcut.special[keyCode] == nil && !key.isEmpty }

    var symbols: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
    }
    var display: String { symbols + (Shortcut.special[keyCode] ?? key.uppercased()) }

    var nsModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// Builds a shortcut from a key press. Needs a modifier, unless it is a function key.
    static func from(_ e: NSEvent) -> Shortcut? {
        let f = e.modifierFlags.intersection([.control, .option, .shift, .command])
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods, key: e.charactersIgnoringModifiers?.lowercased() ?? "")
        return mods != 0 || s.isFunctionKey ? s : nil
    }
}

enum ShortcutAction: String, CaseIterable {
    case captureWindow, captureSelection, finishFlow, previewFlow, removeLastStep

    var id: UInt32 { UInt32(ShortcutAction.allCases.firstIndex(of: self)! + 1) }

    var title: String {
        switch self {
        case .captureWindow: return "Capture Window Content"
        case .captureSelection: return "Capture Selection"
        case .finishFlow: return "Finish Flow → FigJam"
        case .previewFlow: return "Preview Flow"
        case .removeLastStep: return "Remove Last Step"
        }
    }

    /// Two keys by default (⌥ + a digit) to keep the effort low.
    var defaultShortcut: Shortcut {
        let codes: [ShortcutAction: (UInt32, String)] = [
            .captureWindow: (UInt32(kVK_ANSI_1), "1"), .captureSelection: (UInt32(kVK_ANSI_2), "2"),
            .finishFlow: (UInt32(kVK_ANSI_3), "3"), .previewFlow: (UInt32(kVK_ANSI_4), "4"),
            .removeLastStep: (UInt32(kVK_ANSI_Z), "z"),
        ]
        let c = codes[self]!
        return Shortcut(keyCode: c.0, modifiers: UInt32(optionKey), key: c.1)
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static func shortcut(_ a: ShortcutAction) -> Shortcut {
        if let data = d.data(forKey: "shortcut.\(a.rawValue)"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        return a.defaultShortcut
    }

    /// Pass nil to go back to the default.
    static func setShortcut(_ s: Shortcut?, for a: ShortcutAction) {
        if let s, let data = try? JSONEncoder().encode(s) { d.set(data, forKey: "shortcut.\(a.rawValue)") }
        else { d.removeObject(forKey: "shortcut.\(a.rawValue)") }
    }

    /// Whether "Capture Selection" reopens on the previous area. On by default.
    static var rememberSelection: Bool {
        get { d.object(forKey: "rememberSelection") as? Bool ?? true }
        set { d.set(newValue, forKey: "rememberSelection") }
    }

    /// Last selection area in global screen points (origin top-left).
    static var lastSelection: CGRect? {
        get {
            guard let v = d.array(forKey: "lastSelection") as? [Double], v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        set { d.set(newValue.map { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: "lastSelection") }
    }

    /// Size of the capture overlay's controls: 0.75 compact (default), 1.0 regular, 1.3 large.
    static let uiScales: [CGFloat] = [0.75, 1.0, 1.3]
    static var uiScale: CGFloat {
        get { let v = d.double(forKey: "uiScale"); return v > 0 ? CGFloat(v) : 0.75 }
        set { d.set(Double(newValue), forKey: "uiScale") }
    }

    /// How far the user has dragged the overlay toolbar from its default spot.
    static var toolbarOffset: CGSize {
        get { guard let v = d.array(forKey: "toolbarOffset") as? [Double], v.count == 2 else { return .zero }; return CGSize(width: v[0], height: v[1]) }
        set { d.set([Double(newValue.width), Double(newValue.height)], forKey: "toolbarOffset") }
    }

    /// Corner radius for selection captures.
    static var selectionRadius: Double {
        get { d.double(forKey: "selectionRadius") }
        set { d.set(newValue, forKey: "selectionRadius") }
    }
}
