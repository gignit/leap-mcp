// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
import SQLite3
@testable import LeapCore

final class EvidenceTests:XCTestCase {
    var root:String = ""
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("leap-tests/integrated/\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath:root+"/.leap",withIntermediateDirectories:true)
        // The temporary directory is behind the /var -> /private/var symlink; Git reports the real path.
        if let real=realpath(root,nil) {root=String(cString:real);free(real)}
        // Give this fixture its own root so Evidence does not resolve the parent repository.
        let proc=Process();proc.executableURL=URL(fileURLWithPath:"/usr/bin/git");proc.arguments=["init","-q",root];try proc.run();proc.waitUntilExit()
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root+"/.leap/leap.db",&db),SQLITE_OK);defer{sqlite3_close(db)}
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE records(seq INTEGER PRIMARY KEY,session TEXT,interaction TEXT,kind TEXT,payload TEXT)",nil,nil,nil),SQLITE_OK)
        let large=String(repeating:"quote\" newline\n🐭",count:1000)
        let nodes:[[String:Any]]=[ ["key":"root","role":"AXWindow","depth":0,"label":"Test","screenFrame":[306,210,1080,748]], ["key":"root/button","parentKey":"root","ancestorKeys":["root"],"role":"AXButton","label":"Save","depth":1,"enabled":true,"selected":false,"screenFrame":[305.5,210,366,74.5],"value":large] ]
        let session=UUID().uuidString,interaction=UUID().uuidString
        for seq in [1,2] {
            var ns=nodes;if seq==2 {ns[1]["selected"]=true}
            let payload=try RecordingStore.json(["window":"Test","nodes":ns,"truncated":false,"readFailures":seq==2 ? 1:0])
            var stmt:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT INTO records VALUES(?,?,?,'snapshot',?)",-1,&stmt,nil)
            let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            sqlite3_bind_int(stmt,1,Int32(seq));sqlite3_bind_text(stmt,2,session,-1,transient);sqlite3_bind_text(stmt,3,interaction,-1,transient);sqlite3_bind_text(stmt,4,payload,-1,transient)
            XCTAssertEqual(sqlite3_step(stmt),SQLITE_DONE);sqlite3_finalize(stmt)
        }
    }
    func object(_ text:String) throws -> [String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])}
    func testProjectionAndAsset() throws {
        let e=try Evidence(project:root)
        let result=try object(e.ui(snapshot:1,types:["button"],ids:[],fields:[],contains:nil,rootKey:"root",depth:1,enabled:true,selected:nil,visible:nil,after:0,limit:10,maxBytes:2048))
        let items=try XCTUnwrap(result["items"] as? [[String:Any]]);XCTAssertEqual(items.count,1)
        let ref=try XCTUnwrap(items[0]["value"] as? [String:Any]);XCTAssertNotNil(ref["leapAsset"])
        let chunk=try e.asset(id:"s1:n2:value",mode:"text",offset:0,limit:40)
        XCTAssertTrue(chunk.contains("quote\" newline\n🐭"))
        let file=try object(e.asset(id:"s1:n2:value",mode:"file",offset:0,limit:40))
        let path=try XCTUnwrap(file["file"] as? String);XCTAssertTrue(path.hasPrefix(root+"/.leap/sessions/"))
        XCTAssertEqual(try String(contentsOfFile:path),String(repeating:"quote\" newline\n🐭",count:1000))
    }
    func testPaginationAndPartialDiff() throws {
        let e=try Evidence(project:root)
        let result=try object(e.ui(snapshot:1,types:[],ids:[],fields:["role","label"],contains:nil,rootKey:nil,depth:nil,enabled:nil,selected:nil,visible:nil,after:1,limit:1,maxBytes:2048))
        XCTAssertEqual((result["items"] as? [[String:Any]])?.first?["ordinal"] as? Int,2)
        let diff=try object(e.diff(before:1,after:2,cursor:0,limit:20,maxBytes:2048))
        XCTAssertEqual(diff["incomplete"] as? Bool,true)
        XCTAssertEqual((diff["changes"] as? [[String:Any]])?.first?["fields"] as? [String],["selected"])
    }
    func testJoinedOutcomeKeepsAcknowledgementUncertainty() throws {
        var db:OpaquePointer?;sqlite3_open(root+"/.leap/leap.db",&db);defer{sqlite3_close(db)}
        let entries:[(String,[String:Any])]=[
            ("action_intent",["actionId":"a1","tool":"click"]),
            ("action_result",["actionId":"a1","tool":"click","apiOutcome":"error; inspect evidence","result":"may have completed"]),
            ("expectation_result",["phase":"after","outcome":"met","label":"Saved","condition":"appears"])
        ]
        for (i,entry) in entries.enumerated() {
            var st:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT INTO records VALUES(?,'session','interaction',?,?)",-1,&st,nil)
            let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            sqlite3_bind_int(st,1,Int32(10+i));sqlite3_bind_text(st,2,entry.0,-1,transient)
            let json=try RecordingStore.json(entry.1);sqlite3_bind_text(st,3,json,-1,transient)
            XCTAssertEqual(sqlite3_step(st),SQLITE_DONE);sqlite3_finalize(st)
        }
        let result=try object(Evidence(project:root).interaction("interaction"))
        XCTAssertEqual(result["outcome"] as? String,"requested current-state checks met")
        XCTAssertEqual((result["actions"] as? [[String:Any]])?.first?["acknowledgement"] as? String,"error; inspect evidence")
    }
    func testInteractionBracketsAndFrozenTimeline() throws {
        var db:OpaquePointer?;sqlite3_open(root+"/.leap/leap.db",&db);defer{sqlite3_close(db)}
        let sql = """
        ALTER TABLE records ADD COLUMN wall TEXT NOT NULL DEFAULT '2026-09-20T12:00:00Z';
        UPDATE records SET interaction='trial';
        INSERT INTO records(seq,session,interaction,kind,payload) SELECT 3,session,'trial',kind,payload FROM records WHERE seq=1;
        INSERT INTO records(seq,session,interaction,kind,payload) SELECT 4,session,'trial','action_intent','{"actionId":"a","tool":"click"}' FROM records WHERE seq=1;
        INSERT INTO records(seq,session,interaction,kind,payload) SELECT 5,session,'trial',kind,payload FROM records WHERE seq=2;
        INSERT INTO records(seq,session,interaction,kind,payload) SELECT 6,session,'next','action_intent','{"actionId":"b","tool":"click"}' FROM records WHERE seq=1;
        """
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
        let e=try Evidence(project:root)
        let delta=try object(e.interactionDelta("trial"))
        XCTAssertEqual(delta["beforeSnapshot"] as? Int,3)
        XCTAssertEqual(delta["afterSnapshot"] as? Int,5)
        XCTAssertEqual(delta["available"] as? Bool,true)
        let missing=try object(e.interactionDelta("next"))
        XCTAssertEqual(missing["available"] as? Bool,false)
        let first=try object(e.timeline(session:nil,after:0,through:nil,limit:1))
        XCTAssertEqual(first["hasMore"] as? Bool,true)
        XCTAssertEqual(first["through"] as? Int,6)
        let next=try object(e.timeline(session:nil,after:1,through:6,limit:1))
        XCTAssertEqual((next["items"] as? [[String:Any]])?.first?["interaction"] as? String,"next")
        let frozen=try object(e.timeline(session:nil,after:1,through:5,limit:1))
        XCTAssertTrue((frozen["items"] as? [[String:Any]])?.isEmpty == true)
    }
    func testTimelineExcludesUnassociatedEventsWithoutDeletingThem() throws {
        var db:OpaquePointer?;sqlite3_open(root+"/.leap/leap.db",&db);defer{sqlite3_close(db)}
        let sql = """
        ALTER TABLE records ADD COLUMN wall TEXT NOT NULL DEFAULT '2026-09-20T12:00:00Z';
        UPDATE records SET interaction='observation';
        INSERT INTO records VALUES(3,'session','','ax_notification','{}','2026-09-20T12:00:01Z');
        INSERT INTO records VALUES(4,'session',NULL,'session_start','{}','2026-09-20T12:00:02Z');
        INSERT INTO records VALUES(5,'session','action','action_intent','{}','2026-09-20T12:00:03Z');
        """
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
        let e=try Evidence(project:root)
        let first=try object(e.timeline(session:nil,after:0,through:nil,limit:1))
        XCTAssertEqual(first["through"] as? Int,5)
        XCTAssertEqual(first["hasMore"] as? Bool,true)
        let second=try object(e.timeline(session:nil,after:1,through:5,limit:1))
        XCTAssertEqual((second["items"] as? [[String:Any]])?.first?["interaction"] as? String,"action")
        XCTAssertEqual(second["hasMore"] as? Bool,false)
        let scoped=try object(e.timeline(session:"session",after:0,through:4,limit:20))
        XCTAssertTrue((scoped["items"] as? [[String:Any]])?.isEmpty == true)
        var st:OpaquePointer?;sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM records WHERE interaction='' OR interaction IS NULL",-1,&st,nil)
        defer{sqlite3_finalize(st)}
        XCTAssertEqual(sqlite3_step(st),SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(st,0),2)
    }
    func testInvalidReferencesAndUnknownRoot() throws {
        let e=try Evidence(project:root)
        XCTAssertThrowsError(try e.asset(id:"../../outside",mode:"file",offset:0,limit:1))
        XCTAssertThrowsError(try e.asset(id:"s1:n300:value",mode:"text",offset:0,limit:1))
        XCTAssertThrowsError(try e.ui(snapshot:1,types:[],ids:[],fields:[],contains:nil,rootKey:"missing",depth:1,enabled:nil,selected:nil,visible:nil,after:0,limit:1,maxBytes:2048))
    }
}
