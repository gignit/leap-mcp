// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import XCTest
@testable import LeapCore

final class ScrollEvidenceTests:XCTestCase {
    func nodes(_ y:Double)->[[String:Any]] {
        [["id":"a","frame":[10.0,y,20.0,20.0],"ancestors":["list"]],
         ["id":"b","frame":[10.0,y+30,20.0,20.0],"ancestors":["list"]]]
    }
    func testScopedTranslationAndUnchangedContent() {
        let before=nodes(100),after=nodes(70)
        XCTAssertEqual(ScrollEvidence.geometry(before:before,after:after,region:nil,root:"list",direction:"down")["status"] as? String,"movement_observed")
        XCTAssertEqual(ScrollEvidence.geometry(before:before,after:before,region:nil,root:"list",direction:"down")["status"] as? String,"unverified")
        XCTAssertEqual(ScrollEvidence.geometry(before:before,after:after,region:nil,root:nil,direction:"down")["status"] as? String,"unverified")
        XCTAssertEqual(ScrollEvidence.geometry(before:before,after:after,region:nil,root:"other",direction:"down")["status"] as? String,"unverified")
        XCTAssertEqual(ScrollEvidence.geometry(before:before,after:after,region:nil,root:"list",direction:"up")["status"] as? String,"unverified")
    }
    /// Writes a 1006x780 PNG: light background, dark stripes inside the sidebar region starting at `offset`.
    func stripedImage(_ url:URL, offset:Int) throws {
        let w=1006,h=780
        let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red:0.95,green:0.95,blue:0.95,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        ctx.setFillColor(CGColor(red:0.1,green:0.1,blue:0.1,alpha:1))
        var y=offset
        while y<h {ctx.fill(CGRect(x:25,y:y,width:220,height:20));y+=60}
        let rep=NSBitmapImageRep(cgImage:ctx.makeImage()!)
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
    func testRetainedScreenshotsSeparateVisualDifferenceFromMovement() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("leap-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let baseline=dir.appendingPathComponent("baseline.png"),scrolled=dir.appendingPathComponent("scrolled.png")
        try stripedImage(baseline,offset:0);try stripedImage(scrolled,offset:30)
        let before:[String:Any]=["file":baseline.path]
        let after:[String:Any]=["file":scrolled.path]
        XCTAssertEqual(try ScrollEvidence.pixels(before:before,after:before,region:[25,150,220,540],bounds:[130,99,1006,780])["status"] as? String,"no_visual_change_observed")
        XCTAssertEqual(try ScrollEvidence.pixels(before:before,after:after,region:[25,150,220,540],bounds:[130,99,1006,780])["status"] as? String,"visual_change_observed")
    }
    func testFullPageScrollWithNoSharedVisibleCenters() {
        XCTAssertEqual(ScrollEvidence.geometry(before:nodes(100),after:nodes(-360),region:[0,90,100,100],root:"list",direction:"down")["status"] as? String,"movement_observed")
    }
    func testScopedScrollbarValueWithoutChildMovement() {
        let a:[String:Any]=["id":"bar","role":"AXScrollBar","ancestors":["list"],"frame":[90,0,10,200],"value":"0"]
        var b=a;b["value"]="0.49"
        XCTAssertEqual(ScrollEvidence.geometry(before:[a],after:[b],region:nil,root:"list",direction:"down")["status"] as? String,"movement_observed")
        XCTAssertEqual(ScrollEvidence.geometry(before:[a],after:[b],region:nil,root:"other",direction:"down")["status"] as? String,"unverified")
        XCTAssertEqual(ScrollEvidence.geometry(before:[a],after:[b],region:nil,root:"list",direction:"up")["status"] as? String,"unverified")
    }
    func testRegionExcludesUnrelatedMovementAndValidatesBounds() {
        XCTAssertEqual(ScrollEvidence.geometry(before:nodes(100),after:nodes(70),region:[300,0,100,400],root:nil,direction:"down")["status"] as? String,"unverified")
        XCTAssertNotNil(ScrollEvidence.region([0,0,100,400],bounds:[130,99,1006,780]))
        XCTAssertNil(ScrollEvidence.region([950,0,100,400],bounds:[130,99,1006,780]))
        XCTAssertNil(ScrollEvidence.region([-1,0,100,400],bounds:[130,99,1006,780]))
    }
}
