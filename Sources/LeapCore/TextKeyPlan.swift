// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Carbon
import CoreGraphics
import Foundation

/// Translate literal text before dispatch. Hardware-forwarding apps (Simulator)
/// may ignore Unicode payloads and use only the physical keycode and modifiers.
enum TextKeyPlan {
    struct Stroke {
        let code: CGKeyCode
        let flags: CGEventFlags
        let text: String?
    }

    static func layoutMap() throws -> [String: Stroke] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw LeapError.unsupported("Current keyboard layout is unavailable; no text input sent")
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else {
            throw LeapError.unsupported("Keyboard layout has no data; no text input sent")
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let modifiers: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate), (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
        var result: [String: Stroke] = [:]
        for (carbonFlags, flags) in modifiers {
            for code in UInt16(0)..<UInt16(128) {
                var dead: UInt32 = 0
                var count = 0
                var output = [UniChar](repeating: 0, count: 16)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), carbonFlags,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                    output.count, &count, &output)
                guard status == noErr, count > 0, dead == 0 else { continue }
                let text = String(utf16CodeUnits: output, count: count)
                if result[text] == nil { result[text] = Stroke(code: code, flags: flags, text: text) }
            }
        }
        return result
    }

    static func plan(_ text: String, layout: [String: Stroke], requirePhysical: Bool) throws -> [Stroke] {
        try text.map { character in
            let value = String(character)
            if value == "\n" || value == "\r" || value == "\r\n" { return Stroke(code: 36, flags: [], text: nil) }
            if value == "\t" { return Stroke(code: 48, flags: [], text: nil) }
            if let key = layout[value] { return key }
            guard !requirePhysical else {
                throw LeapError.unsupported("Text contains a character unavailable as a single physical key in the current keyboard layout. Simulator Unicode-only input is unsafe; no text events sent. Use a supported text insertion method.")
            }
            return Stroke(code: 0, flags: [], text: value)
        }
    }
}
