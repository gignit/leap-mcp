// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import ApplicationServices
@testable import LeapCore

final class ObservationTextTests: XCTestCase {
    func testCustomActionDescriptorsShowTheirName() {
        XCTAssertEqual(AX.actionName("Name:pin\nTarget:0x0\nSelector:(null)"), "pin")
        XCTAssertEqual(AX.actionName("AXPress"), "Press")
        XCTAssertEqual(AX.actionName("ICMacTextViewAccessibilityActionShowExtensionsMenu"), "ICMacTextViewAccessibilityActionShowExtensionsMenu")
    }
    func testDuplicateKeysNeverShareAnIndex() {
        func node(_ key:String) -> AXNode {
            AXNode(element: AXUIElementCreateApplication(0), role: "AXButton", subrole: nil, title: nil, value: nil, description: nil,
                   identifier: nil, placeholder: nil, frame: nil, enabled: true, focused: false, selected: false, actions: [],
                   settable: false, offscreen: false, depth: 1, key: key)
        }
        var nodes=[node("w/AXSheet[alert]#0/AXButton[action-button-1]#0"), node("w/AXSheet[alert]#0/AXButton[action-button-1]#0"), node("w/x#0")]
        AXWalker.makeKeysUnique(&nodes)
        XCTAssertEqual(Set(nodes.map(\.key)).count, 3)
        XCTAssertEqual(nodes[1].key, "w/AXSheet[alert]#0/AXButton[action-button-1]#0~2")
    }
    func testDisabledRunsCollapseButLoneDisabledControlsStay() async {
        let engine = Engine()
        let inactive = (1...6).map { "  [\($0)] Button desc=\"Old \($0)\" [disabled]" }
        let text = (["[1] Button desc=\"Save\" [disabled]", "[2] Button desc=\"Cancel\""] + inactive + ["[9] Button desc=\"Next\""]).joined(separator: "\n")
        let out = await engine.compactObservation(text)
        XCTAssertTrue(out.contains("desc=\"Save\" [disabled]"))
        XCTAssertTrue(out.contains("6 disabled elements"))
        XCTAssertFalse(out.contains("Old 4"))
        XCTAssertTrue(out.contains("desc=\"Next\""))
    }
    func testUnrecordedCollapseNamesItsExpansionAndIsIdempotent() {
        let inactive = (1...7).map { "  [\($0)] StaticText value=\"Tab \($0)\" [disabled]" }
        let text = (["[1] Button desc=\"Library\""] + inactive).joined(separator: "\n")
        let hint = "get_app_state include_disabled=true for detail"
        let once = Engine.collapseDisabledRuns(text, detailHint: hint)
        XCTAssertTrue(once.contains("7 disabled elements"))
        XCTAssertTrue(once.contains(hint))
        XCTAssertFalse(once.contains("Tab 5"))
        XCTAssertEqual(Engine.collapseDisabledRuns(once, detailHint: hint), once)
    }
    func testEachAccessibilityElementIsWalkedOnce() {
        // Device Hub exposes the guest content group under two parents; CFEqual elements render once.
        let visited = VisitedElements()
        XCTAssertTrue(visited.insert(AXUIElementCreateApplication(4242)))
        XCTAssertFalse(visited.insert(AXUIElementCreateApplication(4242)))
        XCTAssertTrue(visited.insert(AXUIElementCreateApplication(4243)))
    }
    func testSimulatorHostsIncludeDeviceHub() {
        XCTAssertTrue(AppResolver.simulatorHostBundles.contains("com.apple.dt.Devices"))
        XCTAssertTrue(AppResolver.simulatorHostBundles.contains("com.apple.iphonesimulator"))
        XCTAssertTrue(AX.nodeScopedAttributes.contains("AXServesAsTitleForUIElements"))
    }
}
