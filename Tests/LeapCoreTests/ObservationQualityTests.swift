// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import ApplicationServices
@testable import LeapCore

final class ObservationQualityTests: XCTestCase {
    func testNodeOwnFieldsAreScopedButStructureIsBlocking() {
        for role in ["AXCheckBox", "AXTextField", "AXGroup", "AXUnknown"] {
            for a in ["AXSubrole","AXDescription","AXTitle","AXIdentifier","AXValue","AXEnabled"] {
                XCTAssertTrue(AX.advisoryFailure(attribute: a, role: role), "\(a) on \(role)")
            }
        }
        for a in ["AXChildren", "AXRole"] { XCTAssertFalse(AX.advisoryFailure(attribute: a, role: "AXButton")) }
    }
    func testTransportFailuresRemainBlockingAndScopedFailuresAreRecordedPerElement() {
        let el=AXUIElementCreateApplication(0)
        AX.withBudget(1) {
            AX.note(.cannotComplete,attribute:"AXDescription",element:el,role:"AXCheckBox")
            XCTAssertEqual(AX.budget?.advisoryFailures,0)
            AX.note(.failure,attribute:"AXDescription",element:el,role:"AXCheckBox")
            XCTAssertEqual(AX.budget?.advisoryFailures,1)
            XCTAssertEqual(AX.budget?.metadataFailures[CFHash(el)],["AXDescription"])
        }
    }
    func testUnreadListRowsBlockAbsenceButNotPresence() {
        let nodes:[[String:Any]]=[["id":"list","role":"AXTable","label":"","omittedChildren":3000],
                                   ["id":"list/row","role":"AXRow","label":"Groceries","ancestors":["list"]],
                                   ["id":"side","role":"AXButton","label":"New","ancestors":[]]]
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Groceries"],"condition":"exists"]),"passed")
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Taxes"],"condition":"exists"]),"unknown")
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Taxes"],"condition":"absent"]),"unknown")
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Taxes","root":"side"],"condition":"absent"]),"passed")
    }
    func testPartialObservationStillProvesPositiveConditions() {
        let nodes:[[String:Any]]=[["id":"r","role":"AXButton","label":"Revert","enabled":true]]
        func v(_ e:[String:Any]) -> String {AutomationModel.verdict(nodes:nodes,complete:false,expectation:e)}
        XCTAssertEqual(v(["selector":["label":"Revert"],"condition":"exists"]),"passed")
        XCTAssertEqual(v(["selector":["label":"Revert"],"condition":"enabled"]),"passed")
        XCTAssertEqual(v(["selector":["label":"Revert"],"condition":"disabled"]),"unknown")
        XCTAssertEqual(v(["selector":["label":"Revert"],"condition":"absent"]),"failed")
        XCTAssertEqual(v(["selector":["label":"Missing"],"condition":"absent"]),"unknown")
        XCTAssertEqual(v(["selector":["label":"Missing"],"condition":"exists"]),"unknown")
        XCTAssertEqual(v(["selector":["label":"Revert"],"condition":"count","value":1]),"unknown")
    }
    func testFailedStateFieldIsNeverJudged() {
        let nodes:[[String:Any]]=[["id":"b","role":"AXButton","label":"Save","enabled":true,"unavailableFields":["enabled"]]]
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Save"],"condition":"enabled"]),"unknown")
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["label":"Save"],"condition":"exists"]),"passed")
    }
    func testMissingMetadataCannotProveSelectorAbsenceOrUniqueness() {
        let nodes:[[String:Any]]=[
            ["id":"notes","role":"AXTextArea","label":"","value":"hello","unavailableFields":["label","identifier"]],
            ["id":"save","role":"AXButton","label":"Save"]]
        XCTAssertTrue(AutomationModel.selectionReliable(nodes,["role":"button","label":"Save"]))
        XCTAssertTrue(AutomationModel.selectionReliable(nodes,["id":"notes"]))
        XCTAssertFalse(AutomationModel.selectionReliable(nodes,["label":"Save"]))
        XCTAssertFalse(AutomationModel.selectionReliable(nodes,["identifier":"missing"]))
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["identifier":"missing"],"condition":"absent"]),"unknown")
        XCTAssertEqual(AutomationModel.verdict(nodes:nodes,complete:true,expectation:["selector":["id":"notes"],"condition":"value_equals","value":"hello"]),"passed")
    }
    func testErrorCountsStayCompleteWhenSamplesAreCapped() {
        let element = AXUIElementCreateApplication(0)
        AX.withBudget(1) {
            for _ in 0..<12 {
                AX.note(.failure, attribute: "AXSubrole", element: element, role: "AXCheckBox")
            }
            AX.note(.cannotComplete, attribute: "AXChildren", element: element, role: "AXGroup")
            AX.note(.cannotComplete, attribute: "AXSubrole", element: element, role: "AXCheckBox")
            AX.note(.attributeUnsupported, attribute: "AXSubrole", element: element)
            XCTAssertEqual(AX.budget?.failures, 14)
            XCTAssertEqual(AX.budget?.advisoryFailures, 12)
            XCTAssertEqual(AX.budget?.failureDetails.count, 8)
        }
    }
}
