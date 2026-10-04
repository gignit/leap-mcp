// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import AppKit
@testable import LeapCore

final class AppKeyboardRoutingTests: XCTestCase {
    let window=WindowInfo(id:1234,pid:123,bounds:CGRect(x:200,y:100,width:800,height:600),layer:0,title:"Fixture")
    func testEveryKeyboardEventIsProcessDirected() throws {
        let delivery=try Input.appKeyboardDelivery(pid:123,window:window)
        guard case .app(let pid, _) = delivery else {return XCTFail("App keyboard must never use system delivery")}
        XCTAssertEqual(pid,123)
        for event in try Input.keyboardSequence(code:0,flags:.maskCommand,restoring:[]) {
            let routed=try Input.routedEvent(event,delivery)
            XCTAssertEqual(routed.getIntegerValueField(.eventTargetUnixProcessID),123)
        }
    }
    func testRejectsUnrelatedOrInvalidProcess() {
        XCTAssertThrowsError(try Input.appKeyboardDelivery(pid:456,window:window))
        XCTAssertThrowsError(try Input.appKeyboardDelivery(pid:0,window:window))
    }
}
