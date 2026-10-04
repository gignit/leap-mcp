// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import AppKit
@testable import LeapCore

final class LabelTargetingTests: XCTestCase {
    func node(value: String?, identifier: String?) -> AXNode {
        AXNode(element: AXUIElementCreateApplication(0), role: "AXStaticText", subrole: nil, title: nil, value: value,
               description: nil, identifier: identifier, placeholder: nil, frame: nil, enabled: true, focused: false,
               selected: false, actions: [], settable: false, offscreen: false, depth: 1, key: "k")
    }

    func testIdentifierMatchesExactlyButNotAsSubstring() {
        let status = node(value: "Your move (white)", identifier: "status")
        XCTAssertTrue(status.exactLabels.contains("status"))
        XCTAssertFalse(status.visibleLabels.contains { $0.contains("stat") })
        XCTAssertTrue(status.visibleLabels.contains { $0.contains("your move") })
    }

    func testFilterKeepsHeaderAndMatchingElementsOnly() {
        let text = """
        ## App — window "W" — state #1
        [1] Window "W"
          [2] Button desc="e2, white pawn" id=square-e2
          [3] Button desc="e7, black pawn" id=square-e7
        Focused element: [1]
        """
        let out = Engine.filterElements(text, "white pawn")
        XCTAssertTrue(out.contains("## App"))
        XCTAssertTrue(out.contains("[2] Button desc=\"e2, white pawn\""))
        XCTAssertFalse(out.contains("[3]"))
        XCTAssertTrue(out.contains("Focused element: [1]"))
        XCTAssertTrue(out.contains("(1 of 3 elements contain \"white pawn\""))
    }

    func testErrorEvidenceSummarisesLargeFullTreesOnly() {
        let header = "## App — window \"W\" — state #4"
        let big = ([header] + (1...40).map { "[\($0)] Button desc=\"b\($0)\"" }).joined(separator: "\n")
        let summary = Engine.evidenceSummary(big)
        XCTAssertTrue(summary.hasPrefix(header))
        XCTAssertTrue(summary.contains("40 elements; full tree omitted"))
        XCTAssertFalse(summary.contains("[12]"))
        let small = ([header] + (1...5).map { "[\($0)] Button desc=\"b\($0)\"" }).joined(separator: "\n")
        XCTAssertEqual(Engine.evidenceSummary(small), small)
        let diff = big.replacingOccurrences(of: header, with: header + "\n## Diff vs state #3")
        XCTAssertEqual(Engine.evidenceSummary(diff), diff)
    }

    func testPidQueryTargetsOneProcess() throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            throw XCTSkip("Finder is not running")
        }
        XCTAssertEqual(try AppResolver.findRunning("pid:\(app.processIdentifier)")?.processIdentifier, app.processIdentifier)
        XCTAssertNil(try AppResolver.findRunning("pid:999999"))
    }
}
