// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
@testable import LeapCore

final class AutomationModelTests:XCTestCase {
    func testWDAOrientationProtocolTranslation() throws {
        XCTAssertEqual(try WDAClient.orientationValue("LANDSCAPE_RIGHT"),"UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT")
        XCTAssertEqual(try WDAClient.orientationValue("PORTRAIT_UPSIDEDOWN"),"UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN")
        XCTAssertEqual(try WDAClient.orientationValue("LANDSCAPE"),"LANDSCAPE")
        XCTAssertThrowsError(try WDAClient.orientationValue("unknown"))
    }
    func testOppositeLandscapeAndUnstableReadRejectCoordinates() {
        let before:[String:Any] = ["backend":"wda","orientation":"LANDSCAPE","orientationIdentity":"interface:0,0,90;device:left","orientationStable":true]
        var after=before
        XCTAssertTrue(AutomationModel.sameOrientation(before,after))
        after["orientationIdentity"]="interface:0,0,270;device:right"
        XCTAssertFalse(AutomationModel.sameOrientation(before,after))
        after=before;after["orientationStable"]=false
        XCTAssertFalse(AutomationModel.sameOrientation(before,after))
        after=before;after.removeValue(forKey:"orientationIdentity")
        XCTAssertFalse(AutomationModel.sameOrientation(before,after))
        XCTAssertTrue(AutomationModel.sameOrientation(["backend":"mac_ax"],["backend":"mac_ax"]))
    }
    func testMacCGFloatBoundsNormalizeLikeStoredJSON() throws {
        let live:[CGFloat]=[130,99,1006,780]
        XCTAssertEqual(AutomationModel.coordinateBounds(live),[130,99,1006,780])
        let stored=try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:live))
        XCTAssertEqual(AutomationModel.coordinateBounds(live),AutomationModel.coordinateBounds(stored))
        XCTAssertNil(AutomationModel.coordinateBounds([true,0,1006,780] as [Any]))
        XCTAssertNil(AutomationModel.coordinateBounds([0,0,0,780]))
        XCTAssertNil(AutomationModel.coordinateBounds([0,0,1006,Double.infinity]))
    }
    func testBoundsSurviveJSONRoundTrip() throws {
        let live:[Double]=[0,0,1180,820]
        let stored=try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:live))
        XCTAssertTrue(AutomationModel.sameBounds(live,stored))
        XCTAssertFalse(AutomationModel.sameBounds(live,[0,0,820,1180]))
        XCTAssertFalse(AutomationModel.sameBounds(live,[0,0,1180]))
        XCTAssertFalse(AutomationModel.sameBounds(live,[0,0,Double.nan,820]))
    }
    func testPartialAcquisitionCannotProveAbsenceOrCountButObservedMatchesArePositiveEvidence() {
        let node:[String:Any] = ["label":"Save","enabled":true]
        let expected=["absent":"failed","count":"unknown","enabled":"passed","exists":"passed"]
        for (condition,verdict) in expected {
            XCTAssertEqual(AutomationModel.verdict(nodes:[node],complete:false,expectation:["selector":["label":"Save"],"condition":condition,"value":1]),verdict,condition)
        }
    }
    func testDuplicatesAreUnknownForStateChecks() {
        let node:[String:Any] = ["label":"Save","enabled":true]
        XCTAssertEqual(AutomationModel.verdict(nodes:[node,node],complete:true,expectation:["selector":["label":"Save"],"condition":"enabled"]),"unknown")
        XCTAssertEqual(AutomationModel.verdict(nodes:[node,node],complete:true,expectation:["selector":["label":"Save"],"condition":"count","value":2]),"passed")
    }
    func testTruncatedValueCannotEstablishEquality() {
        XCTAssertEqual(AutomationModel.verdict(nodes:[["label":"Notes","value":"x","valueLimited":true]],complete:true,expectation:["selector":["label":"Notes"],"condition":"value_equals","value":"x"]),"unknown")
    }
    func testSelectorScopeAndExactMatching() throws {
        let node:[String:Any] = ["id":"child","label":"Save as","role":"AXButton","ancestors":["root"]]
        XCTAssertFalse(AutomationModel.matches(node,["label":"Save"]))
        XCTAssertTrue(AutomationModel.matches(node,["contains":"Save","role":"button","root":"root"]))
        XCTAssertThrowsError(try AutomationModel.validateSelector(["lable":"Save"]))
    }
    func testWithinScopesByAncestorLabel() {
        let node:[String:Any]=["id":"w/AXWindow[App]#0/AXScrollArea[Release notes]#1/AXTextArea[]#0","role":"AXTextArea","label":"",
                               "ancestors":["w/AXWindow[App]#0","w/AXWindow[App]#0/AXScrollArea[Release notes]#1"]]
        XCTAssertTrue(AutomationModel.matches(node,["role":"AXTextArea","within":"Release notes"]))
        XCTAssertFalse(AutomationModel.matches(node,["role":"AXTextArea","within":"Player notes"]))
        XCTAssertFalse(AutomationModel.matches(node,["role":"AXTextArea","within":"notes"]))
        XCTAssertTrue(AutomationModel.ownLabel(of:"a/AXGroup[Tag #1]#12",is:"Tag #1"))
        XCTAssertNoThrow(try AutomationModel.validateSelector(["within":"Release notes"]))
    }
    func testRootMatchesElidedContainerIdsByPathPrefix() {
        let node:[String:Any]=["id":"w/AXWindow[G]#0/AXGroup[]#0/AXButton[Save]#0","role":"AXButton","label":"Save","ancestors":["w/AXWindow[G]#0"]]
        XCTAssertTrue(AutomationModel.matches(node,["label":"Save","root":"w/AXWindow[G]#0/AXGroup[]#0"]))
        XCTAssertFalse(AutomationModel.matches(node,["label":"Save","root":"w/AXWindow[G]#0/AXGroup[]#1"]))
        XCTAssertFalse(AutomationModel.matches(node,["label":"Save","root":"w/AXWindow[G]#0/AXGroup[]"]))
    }
    func testSelectorErrorsNameTheOffendingKey() {
        XCTAssertThrowsError(try AutomationModel.validateSelector(["label":"Save","match":"x"])) { error in
            XCTAssertTrue("\(error)".contains("match"))
        }
        XCTAssertThrowsError(try AutomationModel.validateSelector(["label":1])) { error in
            XCTAssertTrue("\(error)".contains("label"))
        }
    }
    func testIncompleteDeltaDoesNotClaimRemoval() {
        let d=AutomationModel.delta([["id":"a"]],[],complete:false)
        XCTAssertEqual((d["changes"] as? [[String:Any]])?.count,0)
        XCTAssertEqual(d["notObserved"] as? Int,1)
    }
    func testDeltaSummarizesAddedNodesWithoutAncestry() {
        let d=AutomationModel.delta([],[["id":"b","role":"AXButton","label":"Save","ancestors":["w","w/x"],"actions":["AXPress"],"depth":3]],complete:true)
        let after=(d["changes"] as? [[String:Any]])?.first?["after"] as? [String:Any]
        XCTAssertEqual(after?["label"] as? String,"Save")
        XCTAssertNil(after?["ancestors"])
        XCTAssertNil(after?["actions"])
    }
    func testWholeResponseBudgetRetainsReference() throws {
        let result=try AutomationModel.bounded(["session_id":"s","steps":String(repeating:"x",count:30000)],budget:2048,file:"/repo/.leap/result.json")
        XCTAssertLessThan(result.utf8.count,2048)
        let decoded=try JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any]
        XCTAssertEqual(decoded?["file"] as? String,"/repo/.leap/result.json")
    }
    func testWDARejectsNonlocalAndCredentialEndpoints() {
        for endpoint in ["https://example.com:8100","http://user:pass@127.0.0.1:8100","http://localhost","http://localhost:8100/path"] {
            XCTAssertThrowsError(try WDAClient(endpoint:endpoint))
        }
    }
}
