// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import AppKit
@testable import LeapCore

final class PointerRoutingTests:XCTestCase {
    let window=WindowInfo(id:1234,pid:123,bounds:CGRect(x:200,y:100,width:800,height:600),layer:0,title:"Fixture")

    func testMouseEventKeepsTargetWindowAndScreenPoint() throws {
        let point=CGPoint(x:350,y:240)
        let raw=try XCTUnwrap(CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left))
        raw.setIntegerValueField(.mouseEventClickState,value:2)
        let event=try Input.routedEvent(raw,.app(123,window:window))
        XCTAssertEqual(event.location,point)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer),1234)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),1234)
        XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID),123)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState),2)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype),3)
        XCTAssertEqual(try XCTUnwrap(NSEvent(cgEvent:event)).windowNumber,1234)
    }

    func testMissingWindowNeverFallsBackToRawPointerEvent() throws {
        let raw=try XCTUnwrap(CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left))
        XCTAssertThrowsError(try Input.routedEvent(raw,.app(123)))
        let wheel=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:30,wheel2:0,wheel3:0))
        XCTAssertThrowsError(try Input.routedEvent(wheel,.app(123)))
    }

    func testActivationCarriesWindowIdentity() throws {
        let activated=try XCTUnwrap(NSEvent(cgEvent:Input.activationEvent(windowID:1234,active:true)))
        XCTAssertEqual(activated.type,.appKitDefined)
        XCTAssertEqual(activated.subtype.rawValue,1)
        XCTAssertEqual(activated.windowNumber,1234)
        XCTAssertEqual(activated.modifierFlags.rawValue & 0xc0000,0xc0000)
        let deactivated=try XCTUnwrap(NSEvent(cgEvent:Input.activationEvent(windowID:1234,active:false)))
        XCTAssertEqual(deactivated.subtype.rawValue,2)
    }
}
