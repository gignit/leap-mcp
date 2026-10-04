// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import CoreFoundation
import SQLite3

/// Separate from UI recordings: usable before project binding and during recorder failure.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = configured()
    public static func configured(home:String = NSHomeDirectory()) -> Diagnostics {
        let path=home+"/.config/leap/leap.json"
        var level="info"
        var insightsEnabled=true
        do {
            if FileManager.default.fileExists(atPath:path) {
                let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path)))
                guard let config=raw as? [String:Any] else {throw LeapError.unsupported("leap.json must be an object")}
                if let insights=config["insights"] {
                    guard let object=insights as? [String:Any] else {throw LeapError.unsupported("insights must be an object")}
                    if let supplied=object["enabled"] {
                        guard let value=supplied as? Bool, CFGetTypeID(supplied as CFTypeRef) == CFBooleanGetTypeID() else {throw LeapError.unsupported("insights.enabled must be a boolean")}
                        insightsEnabled=value
                    }
                }
                if let logging=config["logging"] {
                    guard let object=logging as? [String:Any] else {throw LeapError.unsupported("logging must be an object")}
                    if let supplied=object["level"] {
                        guard let value=supplied as? String, ["debug","info","warning","error"].contains(value) else {throw LeapError.unsupported("logging.level must be debug, info, warning or error")}
                        level=value
                    }
                }
            }
            return Diagnostics(directory:home+"/.leap/logs",level:level,insightsEnabled:insightsEnabled)
        } catch {
            let result=Diagnostics(directory:home+"/.leap/logs")
            result.failure="Invalid Leap configuration at \(path): \(error). Correct it and restart; tool dispatch blocked."
            result.configurationInvalid=true
            FileHandle.standardError.write(Data((result.failure!+"\n").utf8))
            return result
        }
    }
    private let lock=NSLock()
    private var db:OpaquePointer?
    private var context:[String:String]=[:]
    public let directory:String
    public let process=UUID().uuidString
    private var failure:String?
    private var configurationInvalid=false
    private var warnings:[String]=[]
    public let level:String
    public let insightsEnabled:Bool
    public init(directory:String,level:String = "info",insightsEnabled:Bool = true) {self.directory=directory;self.level=level;self.insightsEnabled=insightsEnabled}
    deinit {sqlite3_close(db)}
    public func setContext(_ value:[String:String]) {lock.lock();defer{lock.unlock()};context=value;warnings=[]}
    private func open() throws {
        if configurationInvalid {throw LeapError.unsupported(failure ?? "Invalid diagnostics configuration")}
        if db != nil {return}
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open_v2(directory+"/diagnostics.db",&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {sqlite3_close(db);db=nil;throw LeapError.unsupported("Cannot open diagnostics store")}
        sqlite3_busy_timeout(db,2000)
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS diagnostics(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, time TEXT NOT NULL, process TEXT NOT NULL, level TEXT NOT NULL, kind TEXT NOT NULL, interaction TEXT, session TEXT, tool TEXT, app TEXT, detail TEXT NOT NULL); CREATE INDEX IF NOT EXISTS diagnostic_interaction ON diagnostics(interaction,seq);")
        } catch {sqlite3_close(db);db=nil;throw error}
    }
    private func exec(_ sql:String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw LeapError.unsupported("Diagnostics SQLite failure")}
    }
    @discardableResult public func record(level:String,kind:String,detail:String,fields:[String:String]=[:]) -> String? {
        lock.lock();defer{lock.unlock()}
        do {
            try open()
            let priorities=["debug":0,"info":1,"warning":2,"error":3]
            let keep=(priorities[level] ?? 1) >= (priorities[self.level] ?? 1)
            let id=UUID().uuidString, merged=context.merging(fields,uniquingKeysWith:{$1})
            if (level == "warning" || level == "error"), merged["interaction"] == context["interaction"], warnings.count<20 {
                warnings.append("\(kind): \(String(detail.prefix(300)))" + (keep ? " [diagnostic=\(id)]":" [not retained at logging.level=\(self.level)]"))
            }
            if !keep {return "excluded_by_log_level"}
            var st:OpaquePointer?;defer{sqlite3_finalize(st)}
            guard sqlite3_prepare_v2(db,"INSERT INTO diagnostics(id,time,process,level,kind,interaction,session,tool,app,detail) VALUES(?,?,?,?,?,?,?,?,?,?)",-1,&st,nil)==SQLITE_OK else {throw LeapError.unsupported("Diagnostics prepare failed")}
            let values=[id,ISO8601DateFormatter().string(from:Date()),process,level,kind,merged["interaction"] ?? "",merged["session"] ?? "",merged["tool"] ?? "",merged["app"] ?? "",String(detail.prefix(1200))]
            for (i,v) in values.enumerated(){sqlite3_bind_text(st,Int32(i+1),v,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
            guard sqlite3_step(st)==SQLITE_DONE else {throw LeapError.unsupported("Diagnostics append failed")}
            return id
        } catch {
            failure="Diagnostic evidence could not be persisted: \(error)"
            FileHandle.standardError.write(Data("leap diagnostics failure [\(kind)]: \(error)\n".utf8))
            return nil
        }
    }
    public func health() -> String? {lock.lock();defer{lock.unlock()};return failure}
    public func query(interaction:String?,session:String?,level:String?,kind:String?,after:Int,limit:Int) throws -> String {
        lock.lock();defer{lock.unlock()}
        try open()
        var sql="SELECT seq,id,time,process,level,kind,interaction,session,tool,app,detail FROM diagnostics WHERE seq>CAST(? AS INTEGER)"
        var args=[String(max(0,after))]
        if level == "issues" {sql += " AND level IN ('warning','error')"}
        for (key,value) in [("interaction",interaction),("session",session),("level",level == "issues" ? nil:level),("kind",kind)] {if let value {sql += " AND \(key)=?";args.append(value)}}
        let cap=max(1,min(limit,20));sql += " ORDER BY seq LIMIT CAST(? AS INTEGER)";args.append(String(cap+1))
        var st:OpaquePointer?;defer{sqlite3_finalize(st)}
        guard sqlite3_prepare_v2(db,sql,-1,&st,nil)==SQLITE_OK else {throw LeapError.unsupported("Diagnostics query unavailable")}
        for (i,v) in args.enumerated(){sqlite3_bind_text(st,Int32(i+1),v,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        var items:[[String:Any]]=[];var bytes=0;var more=false
        while true {
            let rc=sqlite3_step(st);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw LeapError.unsupported("Diagnostics read failed")}
            var row:[String:Any]=[:]
            for i in 0..<sqlite3_column_count(st){if let v=sqlite3_column_text(st,i){row[String(cString:sqlite3_column_name(st,i))]=String(cString:v)}}
            let size=try RecordingStore.json(row).utf8.count
            if items.count>=cap || (!items.isEmpty && bytes+size>12000) {more=true;break}
            items.append(row);bytes+=size
        }
        return try RecordingStore.json(["items":items,"hasMore":more,"nextCursor":Int(items.last?["seq"] as? String ?? "") ?? after,"store":directory+"/diagnostics.db","loggingLevel":self.level,"health":failure ?? "available","meaning":"Diagnostic events, not proof of application success. Details capped at 1200 characters; raw arguments and UI trees are not logged. No automatic pruning."])
    }
    /// Kinds that only restate the error or route already in the returned text (the result
    /// line names synthesized key/text/wheel routes). They stay in the durable store but are
    /// not repeated in the response (one message per call keeps responses compact).
    public static let echoKinds:Set<String>=["tool_error","tool_completed","input_error","check_unmet",
                                             "keyboard_route","text_keyboard_route","scroll_pointer_route","indicator_suppressed"]
    public func warningSummary(interaction:String) -> String? {
        lock.lock();defer{lock.unlock()}
        let novel=warnings.filter { entry in !Self.echoKinds.contains(where:{entry.hasPrefix($0+":")}) }
        if novel.isEmpty {return failure}
        return "Diagnostics: " + novel.prefix(3).joined(separator:"; ") + ". Query diagnostic_query(interaction_id: \(interaction)) for retained events. Logging level: \(level)."
    }
}
