// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import CoreGraphics
@testable import LeapCore

final class KeyboardSequenceTests: XCTestCase {
    private func keycodes(_ events: [CGEvent]) -> [Int64] { events.map { $0.getIntegerValueField(.keyboardEventKeycode) } }

    func testChordPressesAndReleasesOnlyItsOwnModifier() throws {
        let events = try Input.keyboardSequence(code: 0, flags: .maskCommand, restoring: .maskShift)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events.map(\.flags), [[.maskShift, .maskCommand], .maskCommand, .maskCommand, .maskShift])
        XCTAssertEqual(keycodes(events), [55, 0, 0, 55])
    }
    func testUnmodifiedKeyHasNoFlagsChanged() throws {
        let events = try Input.keyboardSequence(code: 14, flags: [], restoring: [])
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(keycodes(events), [14, 14])
    }
    /// Keycode 0 is the physical A key. A flagsChanged at keycode 0 made
    /// Simulator see phantom A presses (dropped or extra letter a).
    func testModifierEventsNeverCarryTheAKeycode() throws {
        let events = try Input.keyboardSequence(code: 11, flags: [.maskCommand, .maskShift, .maskAlternate, .maskControl], restoring: [])
        let modifiers = events.filter { $0.type == .flagsChanged }
        XCTAssertEqual(keycodes(modifiers), [55, 56, 58, 59, 59, 58, 56, 55])
        XCTAssertEqual(modifiers.last?.flags, [])
        XCTAssertEqual(events.filter { $0.type != .flagsChanged }.map(\.flags),
                       [[.maskCommand, .maskShift, .maskAlternate, .maskControl], [.maskCommand, .maskShift, .maskAlternate, .maskControl]])
    }
    func testUnicodeSurrogatePairsArePreservedOnBothEdges() throws {
        let text = Array("A😀".utf16)
        let events = try Input.keyboardSequence(code: 0, flags: [], unicode: text, restoring: [])
        XCTAssertEqual(events.count, 2)
        for event in events {
            var actual = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &actual, unicodeString: &buffer)
            XCTAssertEqual(Array(buffer.prefix(actual)), text)
        }
    }
}
