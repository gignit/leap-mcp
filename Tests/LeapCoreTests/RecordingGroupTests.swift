// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import SQLite3
@testable import LeapCore

final class RecordingGroupTests:XCTestCase {
    func testGroupsResumeAndRetainedHistory() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("leap-tests/timeline-filter/\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath:root+"/.leap",withIntermediateDirectories:true)
        let git=Process();git.executableURL=URL(fileURLWithPath:"/usr/bin/git");git.arguments=["init","-q",root];try git.run();git.waitUntilExit()
        // A session left open by an earlier server must be marked as an unobserved gap on reopen.
        do {
            let store=try RecordingStore(project:root)
            let open=try store.attach(app:"Earlier",pid:1)
            try store.append(session:open,interaction:"earlier-call",kind:"snapshot",payload:["nodes":[]])
            var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root+"/.leap/leap.db",&db),SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db,"UPDATE sessions SET ended=NULL; UPDATE sessions SET id='earlier' WHERE app='Earlier'; UPDATE records SET session='earlier'",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        }
        var group="",capture=""
        do {
            let store=try RecordingStore(project:root)
            XCTAssertNil(store.activeGroup)
            XCTAssertThrowsError(try store.selectGroup(action:"resume",name:nil,id:"missing"))
            group=try store.selectGroup(action:"start",name:"Simulator parity",id:nil)
            capture=try store.attach(app:"Simulator",pid:2)
            try store.append(session:capture,interaction:"call-2",kind:"snapshot",payload:["nodes":[]])
            try store.append(session:capture,kind:"ax_notification",payload:[:])
        }
        do {
            let store=try RecordingStore(project:root)
            XCTAssertNil(store.activeGroup, "Restart requires explicit resume")
            XCTAssertEqual(try store.selectGroup(action:"resume",name:nil,id:group),group)
            let second=try store.attach(app:"Notes",pid:3)
            try store.append(session:second,interaction:"call-3",kind:"snapshot",payload:["nodes":[]])
            XCTAssertNotEqual(second,capture)
            _ = try store.selectGroup(action:"end",name:nil,id:nil)
            XCTAssertNil(store.activeGroup)
            let ungrouped=try store.attach(app:"Other",pid:4)
            try store.append(session:ungrouped,interaction:"call-4",kind:"snapshot",payload:[:])
            let evidence=try Evidence(project:root)
            let timeline=try JSONSerialization.jsonObject(with:Data(evidence.timeline(session:nil,after:0,through:nil,limit:20,group:group).utf8)) as! [String:Any]
            XCTAssertEqual((timeline["items"] as? [[String:Any]])?.count,2)
            XCTAssertEqual(try evidence.rows("SELECT payload FROM records WHERE seq=1").first?["payload"] as? String,"{\"nodes\":[]}")
            XCTAssertEqual(try evidence.rows("SELECT COUNT(*) AS n FROM records").first?["n"] as? String,"5")
            XCTAssertEqual(try evidence.rows("SELECT ended FROM sessions WHERE id='earlier'").first?["ended"] as? String,"interrupted; unobserved interval")
            let summary=try JSONSerialization.jsonObject(with:Data(evidence.sessions(view:"recordings",group:group,after:0,limit:1).utf8)) as! [String:Any]
            XCTAssertEqual(summary["hasMore"] as? Bool,true)
            let next=summary["nextCursor"] as! Int
            let page=try JSONSerialization.jsonObject(with:Data(evidence.sessions(view:"recordings",group:group,after:next,limit:1).utf8)) as! [String:Any]
            XCTAssertEqual(page["hasMore"] as? Bool,false)
            XCTAssertEqual((page["items"] as? [[String:Any]])?.first?["sessionId"] as? String,second)
            XCTAssertTrue(try evidence.sessions(view:"groups",group:nil,after:0,limit:20).contains("Simulator parity"))
        }
    }
}
