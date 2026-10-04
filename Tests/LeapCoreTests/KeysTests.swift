// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import CoreGraphics
import XCTest
@testable import LeapCore

final class KeysTests: XCTestCase {
    func testSimpleKeys() throws {
        XCTAssertEqual(try Keys.parse("a").keyCode, 0)
        XCTAssertEqual(try Keys.parse("Return").keyCode, 36)
        XCTAssertEqual(try Keys.parse("KP_0").keyCode, 82)
        XCTAssertEqual(try Keys.parse("Tab").flags, [])
    }

    func testChords() throws {
        let c = try Keys.parse("super+c")
        XCTAssertEqual(c.keyCode, 8)
        XCTAssertTrue(c.flags.contains(.maskCommand))
        let s = try Keys.parse("Control_L+Shift_L+period")
        XCTAssertEqual(s.keyCode, 47)
        XCTAssertTrue(s.flags.contains(.maskControl) && s.flags.contains(.maskShift))
    }

    func testShiftedCharacters() throws {
        XCTAssertTrue(try Keys.parse("A").flags.contains(.maskShift))
        let bang = try Keys.parse("!")
        XCTAssertEqual(bang.keyCode, 18)
        XCTAssertTrue(bang.flags.contains(.maskShift))
        XCTAssertTrue(try Keys.parse("plus").flags.contains(.maskShift))
    }

    func testUnicodeFallback() throws {
        let euro = try Keys.parse("€")
        XCTAssertNil(euro.keyCode)
        XCTAssertEqual(euro.unicodeFallback, "€")
    }

    func testErrors() {
        XCTAssertThrowsError(try Keys.parse(""))
        XCTAssertThrowsError(try Keys.parse("shift"))
        XCTAssertThrowsError(try Keys.parse("super+Retun"))
        XCTAssertThrowsError(try Keys.parse("hello world"))
    }
}
