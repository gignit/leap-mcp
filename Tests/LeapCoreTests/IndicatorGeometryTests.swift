// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
@testable import LeapCore

final class IndicatorGeometryTests: XCTestCase {
    func testRejectsObservedSimulatorGeometryAndClipping() {
        let window = CGRect(x:377,y:61,width:1006,height:780)
        XCTAssertNil(IndicatorGeometry.point(frame:CGRect(x:795,y:1031,width:16,height:16),window:window,offscreen:false))
        XCTAssertNil(IndicatorGeometry.point(frame:CGRect(x:400,y:830,width:20,height:20),window:window,offscreen:false))
        XCTAssertNil(IndicatorGeometry.point(frame:CGRect(x:400,y:100,width:20,height:20),window:window,offscreen:true))
    }
    func testValidSecondaryDisplayAndInvalidFrames() {
        let window = CGRect(x:-1200,y:100,width:1000,height:800)
        XCTAssertEqual(IndicatorGeometry.point(frame:CGRect(x:-1100,y:200,width:20,height:20),window:window,offscreen:false),CGPoint(x:-1090,y:210))
        XCTAssertNil(IndicatorGeometry.point(frame:nil,window:window,offscreen:false))
        XCTAssertNil(IndicatorGeometry.point(frame:.zero,window:window,offscreen:false))
        XCTAssertNil(IndicatorGeometry.point(frame:CGRect(x:CGFloat.nan,y:200,width:20,height:20),window:window,offscreen:false))
    }
}
