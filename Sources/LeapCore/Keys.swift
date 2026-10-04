// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import CoreGraphics
import Foundation

/// A parsed keyboard chord such as `super+shift+s`, `Return`, or `KP_0`.
///
/// Key names follow xdotool / X keysym conventions (the same syntax the model
/// already knows from other computer-use tools), with common aliases accepted.
public struct KeyChord: Equatable {
    public var keyCode: CGKeyCode?
    public var flags: CGEventFlags
    /// Set when the key has no virtual keycode in the table and must be typed
    /// as a unicode string instead (e.g. `€`).
    public var unicodeFallback: String?

    public init(keyCode: CGKeyCode?, flags: CGEventFlags, unicodeFallback: String? = nil) {
        self.keyCode = keyCode
        self.flags = flags
        self.unicodeFallback = unicodeFallback
    }
}

public enum KeyParseError: Error, CustomStringConvertible {
    case unknown(String)
    case empty
    case noKey(String)

    public var description: String {
        switch self {
        case .unknown(let key): return "Unknown key name \(key); use type_text for literal text."
        case .empty: return "empty key chord"
        case .noKey(let chord): return "chord \"\(chord)\" has modifiers but no key"
        }
    }
}

public enum Keys {
    static let modifiers: [String: CGEventFlags] = [
        "super": .maskCommand, "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
        "super_l": .maskCommand, "super_r": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl, "control_l": .maskControl, "control_r": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "alt_l": .maskAlternate, "alt_r": .maskAlternate,
        "shift": .maskShift, "shift_l": .maskShift, "shift_r": .maskShift,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    /// ANSI-US virtual keycodes (Carbon `kVK_*` values).
    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, "backspace": 51,
        "delete": 117, "escape": 53, "esc": 53, "capslock": 57, "caps_lock": 57,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "page_up": 116, "pageup": 116, "prior": 116,
        "page_down": 121, "pagedown": 121, "next": 121, "insert": 114, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88,
        "kp_7": 89, "kp_8": 91, "kp_9": 92, "kp_decimal": 65, "kp_multiply": 67, "kp_add": 69,
        "kp_subtract": 78, "kp_divide": 75, "kp_equal": 81, "kp_clear": 71,
        "numpad_0": 82, "numpad_1": 83, "numpad_2": 84, "numpad_3": 85, "numpad_4": 86,
        "numpad_5": 87, "numpad_6": 88, "numpad_7": 89, "numpad_8": 91, "numpad_9": 92,
        "minus": 27, "equal": 24, "bracketleft": 33, "bracketright": 30, "backslash": 42,
        "semicolon": 41, "apostrophe": 39, "quoteright": 39, "grave": 50, "comma": 43,
        "period": 47, "slash": 44,
        "plus": 24, "underscore": 27, "braceleft": 33, "braceright": 30, "bar": 42, "colon": 41,
        "quotedbl": 39, "asciitilde": 50, "less": 43, "greater": 47, "question": 44,
        "exclam": 18, "at": 19, "numbersign": 20, "dollar": 21, "percent": 23,
        "asciicircum": 22, "ampersand": 26, "asterisk": 28, "parenleft": 25, "parenright": 29,
    ]

    /// Names in `named` that are the shifted variant of a key.
    static let shiftedNames: Set<String> = [
        "plus", "underscore", "braceleft", "braceright", "bar", "colon", "quotedbl", "asciitilde",
        "less", "greater", "question", "exclam", "at", "numbersign", "dollar", "percent",
        "asciicircum", "ampersand", "asterisk", "parenleft", "parenright",
    ]

    static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\n": 36, "\t": 48,
    ]

    static let shiftedCharacters: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

    /// Printable character for a keycode (US layout), for matching menu key equivalents.
    public static func character(for code: CGKeyCode) -> Character? {
        characters.first { $0.value == code && !" \n\t".contains($0.key) }?.key
    }

    /// Parse `a`, `Return`, `super+c`, `Control_L+Shift_L+period`, `KP_0`, ...
    public static func parse(_ chord: String) throws -> KeyChord {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A literal "+" key is written as "plus" (or as the last empty part of "shift++").
        var tokens = parts.filter { !$0.isEmpty }
        if parts.last == "" && parts.count > 1 { tokens.append("plus") }
        guard !tokens.isEmpty else { throw KeyParseError.empty }

        var flags: CGEventFlags = []
        var keyToken: String?
        for token in tokens {
            if let mod = modifiers[token.lowercased()] {
                flags.insert(mod)
            } else if keyToken == nil {
                keyToken = token
            } else {
                // Two non-modifier tokens: treat everything after the first as part of the name.
                keyToken! += "+" + token
            }
        }
        guard let key = keyToken else { throw KeyParseError.noKey(chord) }
        return try resolve(key: key, flags: flags)
    }

    static func resolve(key: String, flags: CGEventFlags) throws -> KeyChord {
        let lower = key.lowercased()
        if let code = named[lower] {
            var f = flags
            if shiftedNames.contains(lower) { f.insert(.maskShift) }
            return KeyChord(keyCode: code, flags: f)
        }
        if key.count == 1, let ch = key.first {
            if let code = characters[Character(ch.lowercased())] {
                var f = flags
                if ch.isUppercase && ch.isLetter { f.insert(.maskShift) }
                return KeyChord(keyCode: code, flags: f)
            }
            if let base = shiftedCharacters[ch], let code = characters[base] {
                var f = flags
                f.insert(.maskShift)
                return KeyChord(keyCode: code, flags: f)
            }
            return KeyChord(keyCode: nil, flags: flags, unicodeFallback: String(ch))
        }
        // Reject misspelled key names before input, rather than typing the typo.
        throw KeyParseError.unknown(key)
    }
}
