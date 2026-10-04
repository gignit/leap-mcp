// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
@testable import LeapCore

final class ClickGeometryTests: XCTestCase {
    func testClippedEdgeDoesNotBecomeClickTarget() {
        let frame = CGRect(x: 10, y: 90, width: 80, height: 80)
        let visible = frame.intersection(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(ClickGeometry.center(frame: frame, visible: visible))
    }
    func testVisibleCenterStaysAtControlCenter() {
        let frame = CGRect(x: -1100, y: 90, width: 80, height: 80)
        let visible = frame.intersection(CGRect(x: -1200, y: 100, width: 300, height: 200))
        XCTAssertEqual(ClickGeometry.center(frame: frame, visible: visible), CGPoint(x: -1060, y: 130))
    }
    func testMalformedSimulatorFrameRejected() {
        let window = CGRect(x: 69, y: 80, width: 1006, height: 780)
        let frame = CGRect(x: 964, y: 1021, width: 35, height: 63)
        XCTAssertNil(ClickGeometry.center(frame: frame, visible: frame.intersection(window)))
    }
}
