// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import ApplicationServices
import SQLite3
import Darwin

/// A single writer per project. SQLite is the durable evidence, not a command queue.
public final class RecordingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var owner: Int32 = -1
    public let root: String
    public var warning: String = ""
    private var failure: String?
    private var writes = 0
    private(set) var activeGroup: String?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func git(_ root: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        } catch { return nil }
    }

    public init(project: String) throws {
        var isDirectory: ObjCBool = false
        guard project.hasPrefix("/"), FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LeapError.unsupported("recording_start requires an existing absolute project directory; MCP cwd is not inferred")
        }
        root = Self.git(project, ["rev-parse", "--show-toplevel"]) ?? URL(fileURLWithPath: project).standardizedFileURL.path
        let dir = root + "/.leap"
        try FileManager.default.createDirectory(atPath: dir + "/sessions", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        owner = Darwin.open(dir + "/writer.lock", O_CREAT | O_RDWR, 0o600)
        guard owner >= 0, flock(owner, LOCK_EX | LOCK_NB) == 0 else {
            if owner >= 0 { close(owner); owner = -1 }
            throw LeapError.unsupported("Another Leap recorder owns this project. Stop that recording/server before attaching here.")
        }
        do {
            guard sqlite3_open_v2(dir + "/leap.db", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error() }
            sqlite3_busy_timeout(db, 5000)
            try sql("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            let version = try rows("PRAGMA user_version", [])
            let n = version.first?["user_version"] as? Int64 ?? 0
            guard n == 0 || n == 1 else { throw LeapError.unsupported("Unsupported Leap recording schema \(n); database preserved") }
            if n == 0 {
                guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", []).isEmpty else {
                    throw LeapError.unsupported("Unrecognized recording database; preserved unchanged")
                }
                try sql("""
                BEGIN IMMEDIATE;
                CREATE TABLE sessions(id TEXT PRIMARY KEY, app TEXT NOT NULL, pid INTEGER NOT NULL, epoch TEXT NOT NULL, started TEXT NOT NULL, ended TEXT);
                CREATE TABLE records(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL REFERENCES sessions(id), interaction TEXT, kind TEXT NOT NULL, wall TEXT NOT NULL, monotonic REAL NOT NULL, payload TEXT NOT NULL);
                CREATE INDEX record_session ON records(session,seq);
                CREATE INDEX record_interaction ON records(interaction,seq);
                CREATE TABLE recording_groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, started TEXT NOT NULL, ended TEXT);
                CREATE TABLE recording_group_members(session TEXT PRIMARY KEY REFERENCES sessions(id), group_id TEXT NOT NULL REFERENCES recording_groups(id));
                CREATE INDEX group_members ON recording_group_members(group_id);
                PRAGMA user_version=1;
                COMMIT;
                """)
            }
            // A missing end marker from an earlier server means a recording gap, not continuity.
            try sql("UPDATE sessions SET ended='interrupted; unobserved interval' WHERE ended IS NULL")
            if let path = Self.git(root, ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"]) {
                do {
                    let u = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let old = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                    let present = old.components(separatedBy: .newlines).contains { ["/.leap/", ".leap/", ".leap", "/.leap"].contains($0.trimmingCharacters(in: .whitespaces)) }
                    if !present { try (old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + "/.leap/\n").write(to: u, atomically: true, encoding: .utf8) }
                    if Self.git(root, ["check-ignore", ".leap/leap.db"]) == nil { warning = "Git exclusion could not be verified" }
                } catch { warning = "Git exclusion failed: \(error)" }
            }
        } catch {
            sqlite3_close(db); db = nil; close(owner); owner = -1; throw error
        }
    }
    deinit { sqlite3_close(db); if owner >= 0 { flock(owner, LOCK_UN); close(owner) } }
    private func error() -> Error { LeapError.unsupported("Recording storage: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")") }
    private func sql(_ text: String) throws { guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func rows(_ query: String, _ bindings: [String]) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() { sqlite3_bind_text(stmt, Int32(i+1), b, -1, transient) }
        var result: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { throw error() }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[key] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
                case SQLITE_NULL: row[key] = NSNull()
                default: row[key] = String(cString: sqlite3_column_text(stmt, i))
                }
            }
            result.append(row)
        }
    }
    public static func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
    func selectGroup(action:String,name:String?,id:String?) throws -> String {
        lock.lock(); defer {lock.unlock()}
        let selected:String
        switch action {
        case "start":
            guard let name=name?.trimmingCharacters(in:.whitespacesAndNewlines), !name.isEmpty, name.utf8.count<=200 else {throw LeapError.unsupported("name required, maximum 200 UTF-8 bytes")}
            selected=UUID().uuidString
            _ = try rows("INSERT INTO recording_groups(id,name,started) VALUES(?,?,?)",[selected,name,ISO8601DateFormatter().string(from:Date())])
        case "resume":
            guard let id, !(try rows("SELECT id FROM recording_groups WHERE id=?",[id])).isEmpty else {throw LeapError.unsupported("Unknown group_id; use recording_sessions(view: groups)")}
            selected=id
            _ = try rows("UPDATE recording_groups SET ended=NULL WHERE id=?",[id])
        case "end":
            guard let current=activeGroup else {throw LeapError.unsupported("No active group in this connection; resume it first")}
            selected=current
            _ = try rows("UPDATE recording_groups SET ended=? WHERE id=?",[ISO8601DateFormatter().string(from:Date()),current])
        default: throw LeapError.unsupported("action must be start, resume or end")
        }
        activeGroup=action == "end" ? nil:selected
        return selected
    }
    func attach(app: String, pid: pid_t) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString
        try sql("BEGIN IMMEDIATE")
        do {
            _ = try rows("INSERT INTO sessions(id,app,pid,epoch,started) VALUES(?,?,?,?,?)", [id,app,String(pid),UUID().uuidString,ISO8601DateFormatter().string(from: Date())])
            if let group=activeGroup {
                _ = try rows("INSERT INTO recording_group_members(session,group_id) VALUES(?,?)",[id,group])
            }
            try sql("COMMIT")
        } catch {try? sql("ROLLBACK");throw error}
        try FileManager.default.createDirectory(atPath: root + "/.leap/sessions/" + id, withIntermediateDirectories: true)
        return id
    }
    @discardableResult func append(session: String, interaction: String? = nil, kind: String, payload: [String: Any], wall: Date = Date(), mono: Double = ProcessInfo.processInfo.systemUptime) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw LeapError.unsupported("Recording stopped after storage failure: \(failure)") }
        do {
            writes += 1
            if writes % 128 == 1 {
                let base = root + "/.leap/leap.db"
                let size = [base,base+"-wal"].reduce(Int64(0)) { total,path in total + (((try? FileManager.default.attributesOfItem(atPath:path)[.size]) as? NSNumber)?.int64Value ?? 0) }
                guard size < 256 * 1024 * 1024 else { throw LeapError.unsupported("Recording reached 256 MiB storage budget; capture stopped. Evidence retained; archive before starting a new store.") }
            }
            _ = try rows("INSERT INTO records(session,interaction,kind,wall,monotonic,payload) VALUES(?,?,?,?,?,?)", [session,interaction ?? "",kind,ISO8601DateFormatter().string(from: wall),String(mono),try Self.json(payload)])
            return sqlite3_last_insert_rowid(db)
        } catch { failure = String(describing: error); throw error }
    }
    func finish(_ session: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try rows("UPDATE sessions SET ended=? WHERE id=?", [ISO8601DateFormatter().string(from: Date()),session])
    }
    func health() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    public static func query(project: String, session: String?, interaction: String?, kind: String?, contains: String?, after: Int, limit: Int, snapshot: Int? = nil, outline: Bool = false, review: String? = nil, through: Int? = nil) throws -> String {
        guard project.hasPrefix("/") else { throw LeapError.unsupported("project must be absolute") }
        let root = git(project, ["rev-parse", "--show-toplevel"]) ?? project
        let path = root + "/.leap/leap.db"
        guard FileManager.default.fileExists(atPath: path) else { return "{\"sessions\":[],\"records\":[],\"storeExists\":false}" }
        // A separate read-only connection never initializes or changes a store.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); throw LeapError.unsupported("Cannot open recording read-only") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var clause = "seq > ?"; var args = [String(max(0,after))]
        for (column, value) in [("session",session),("interaction",interaction),("kind",kind)] { if let value { clause += " AND \(column)=?"; args.append(value) } }
        if let contains { clause += " AND instr(lower(payload),lower(?))>0"; args.append(contains) }
        let cap = min(100,max(1,limit)); args.append(String(cap+1))
        func read(_ sql: String, _ args: [String]) throws -> [[String: Any]] {
            var st: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&st,nil)==SQLITE_OK else { throw LeapError.unsupported("Recording query/schema unavailable") }; defer { sqlite3_finalize(st) }
            for (i,v) in args.enumerated() { sqlite3_bind_text(st,Int32(i+1),v,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
            var out:[[String:Any]]=[]
            while true { let rc=sqlite3_step(st); if rc==SQLITE_DONE { break }; guard rc==SQLITE_ROW else { throw LeapError.unsupported("Recording read failed") }
                var r:[String:Any]=[:]; for i in 0..<sqlite3_column_count(st) { let k=String(cString:sqlite3_column_name(st,i)); if let v=sqlite3_column_text(st,i) { let t=String(cString:v); r[k] = k == "payload" ? ((try? JSONSerialization.jsonObject(with:Data(t.utf8))) ?? t) : t } }; out.append(r)
            }; return out
        }
        if let review {
            guard ["overview","actions","issues","events"].contains(review) else {throw LeapError.unsupported("Unknown review view")}
            // Freeze the read transaction and return its high-water mark for stable later pages.
            _ = try read("BEGIN",[])
            let maximum=try read("SELECT COALESCE(MAX(seq),0) AS high FROM records",[]).first?["high"] as? String ?? "0"
            let high=min(max(0,through ?? Int(maximum) ?? 0),Int(maximum) ?? 0)
            var scope="seq <= ?";var bindings=[String(high)]
            for (column,value) in [("session",session),("interaction",interaction)] {
                if let value {scope += " AND \(column)=?";bindings.append(value)}
            }
            let issue="""
            (kind='capture_gap' OR kind='coverage'
             OR (kind='action_result' AND json_extract(payload,'$.apiOutcome') LIKE 'error%')
             OR (kind='expectation_result' AND json_extract(payload,'$.phase')='after' AND json_extract(payload,'$.outcome')!='met')
             OR (kind='subscription' AND json_extract(payload,'$.result') NOT IN (0,-25209)))
            """
            let counts=try read("SELECT kind,COUNT(*) AS count,MIN(seq) AS first,MAX(seq) AS last FROM records WHERE \(scope) GROUP BY kind ORDER BY kind",bindings)
            let totals=try read("SELECT COUNT(*) AS records,MIN(seq) AS first,MAX(seq) AS last,SUM(CASE WHEN \(issue) THEN 1 ELSE 0 END) AS attentionRecords FROM records WHERE \(scope)",bindings)
            let pageSize=min(50,cap)
            let sql:String
            if review == "events" {
                sql="""
                SELECT session,MIN(seq) AS seq,MAX(seq) AS last,COUNT(*) AS count,
                  json_extract(payload,'$.notification') AS notification,
                  json_extract(payload,'$.elementHash') AS elementHash,
                  MIN(wall) AS firstReceipt,MAX(wall) AS lastReceipt
                FROM records WHERE \(scope) AND kind='ax_notification'
                GROUP BY session,json_extract(payload,'$.notification'),json_extract(payload,'$.elementHash')
                HAVING MIN(seq)>CAST(? AS INTEGER) ORDER BY MIN(seq) LIMIT ?
                """
            } else {
                let selection = review == "actions" ? "kind IN ('action_intent','action_result','expectation_result')" : issue
                sql="""
                SELECT seq,session,interaction,kind,wall,
                  json_extract(payload,'$.actionId') AS actionId,
                  json_extract(payload,'$.tool') AS tool,
                  json_extract(payload,'$.apiOutcome') AS apiOutcome,
                  json_extract(payload,'$.phase') AS phase,
                  json_extract(payload,'$.outcome') AS expectation,
                  substr(COALESCE(json_extract(payload,'$.label'),''),1,160) AS label,
                  substr(COALESCE(json_extract(payload,'$.detail'),json_extract(payload,'$.result'),payload),1,400) AS excerpt,
                  length(payload) AS retainedCharacters
                FROM records WHERE \(scope) AND \(selection) AND seq>? ORDER BY seq LIMIT ?
                """
            }
            var page=try read(sql,bindings+[String(max(0,after)),String(pageSize+1)])
            var more=page.count>pageSize;if more {page.removeLast()}
            var kept:[[String:Any]]=[];var bytes=0
            for row in page {let size=try json(row).utf8.count;if !kept.isEmpty && bytes+size>10000 {more=true;break};kept.append(row);bytes+=size}
            let cursor=Int(kept.last?["seq"] as? String ?? "") ?? max(0,after)
            return try json(["view":review,"historical":true,"through":high,"counts":counts,"totals":totals,
                "items":kept,"hasMore":more,"nextCursor":cursor,
                "scope":["session":session ?? "all","interaction":interaction ?? "all"],
                "coverage":"Recorded evidence only. API errors are not proof of failed effects; unsupported notifications and capture gaps require attention. Events grouped by session, notification and ephemeral element hash; separate actions are never merged.",
                "next":["page":"recording_review with same filters, through and after=nextCursor",
                        "actions":"recording_review(view: actions)","events":"recording_review(view: events)",
                        "evidence":"recording_query(after: record seq minus 1, limit: 1)",
                        "tree":"recording_nodes(snapshot: snapshot seq, outline: true)"],
                "presentation":"Values/excerpts may be shortened; full retained records remain stored. Overview lists attention records first; counts cover the whole selected history, not just this page."])
        }
        if let snapshot {
            let meta=try read("SELECT seq,session,wall,json_extract(payload,'$.truncated') AS truncated,json_extract(payload,'$.nodeCount') AS nodeCount FROM records WHERE seq=? AND kind='snapshot'",[String(snapshot)])
            guard !meta.isEmpty else {throw LeapError.unsupported("Snapshot not found")}
            var nodes=try read("SELECT CAST(j.key AS INTEGER)+1 AS ordinal,j.value AS payload FROM records r,json_each(r.payload,'$.nodes') j WHERE r.seq=? AND CAST(j.key AS INTEGER)+1>CAST(? AS INTEGER) AND instr(lower(j.value),lower(?))>0 ORDER BY CAST(j.key AS INTEGER) LIMIT ?",[String(snapshot),String(max(0,after)),contains ?? "",String(cap+1)])
            var more=nodes.count>cap;if more{nodes.removeLast()}
            var bytes=0; var kept:[[String:Any]]=[]
            for var row in nodes {
                if outline, let node=row["payload"] as? [String:Any] {
                    row["payload"]=node.filter { ["key","role","depth","label","enabled","offscreen"].contains($0.key) }
                }
                if let payload=row["payload"], let encoded=try? json(payload),encoded.utf8.count>8000 {row["payload"]=["omittedFromResponse":true,"bytes":encoded.utf8.count,"hint":"Full node remains in project SQLite database"]}
                let size=(try? json(row).utf8.count) ?? 0
                if !kept.isEmpty && bytes+size>16000 {more=true;break};kept.append(row);bytes+=size
            };nodes=kept
            return try json(["snapshot":meta,"nodes":nodes,"hasMore":more,"nextCursor":nodes.last?["ordinal"] ?? String(after),"historical":true])
        }
        var records=try read("SELECT * FROM records WHERE \(clause) ORDER BY seq LIMIT ?",args)
        var more=records.count>cap; if more { records.removeLast() }
        for i in records.indices {
            if let payload=records[i]["payload"], let encoded=try? json(payload), encoded.utf8.count>4000 {
                records[i]["payload"]=["omittedFromResponse":true,"bytes":encoded.utf8.count,"hint":"Use recording_nodes with this snapshot seq for nodes; full record remains in SQLite."]
            }
        }
        var bytes=0;var kept:[[String:Any]]=[]
        for row in records {let size=(try? json(row).utf8.count) ?? 0;if !kept.isEmpty && bytes+size>16000 {more=true;break};kept.append(row);bytes+=size};records=kept
        return try json(["project":root,"sessions":try read("SELECT * FROM sessions ORDER BY started DESC LIMIT 50",[]),"records":records,"hasMore":more,"nextCursor":records.last?["seq"] ?? String(after),"historical":true])
    }
}

/// Dedicated run loop: AX notifications continue while the engine is blocked in AXPress.
final class AXRecording: @unchecked Sendable {
    let store: RecordingStore
    let id: String
    private let queue = DispatchQueue(label: "leap.recording.events")
    private let stateLock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var loop: CFRunLoop?
    private var observer: AXObserver?
    private var registrations = Set<String>()
    private var subscriptionLimitReported = false
    private var active = true
    private let stopped = DispatchSemaphore(value: 0)
    private var interaction: String?
    func setInteraction(_ id:String?) {stateLock.lock();interaction=id;stateLock.unlock()}
    init(store: RecordingStore, app: String, pid: pid_t) throws {
        self.store=store; id=try store.attach(app:app,pid:pid)
        let ready=DispatchSemaphore(value:0)
        Thread.detachNewThread { [self] in
            defer { stopped.signal() }
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                let me=Unmanaged<AXRecording>.fromOpaque(context).takeUnretainedValue()
                me.receive(kind:"ax_notification",payload:["notification":notification as String,"elementHash":String(CFHash(element)),"source":"AXObserver","valuesCaptured":false])
            }
            var obs:AXObserver?; let err=AXObserverCreate(pid,callback,&obs)
            stateLock.lock(); loop=CFRunLoopGetCurrent();observer=obs;stateLock.unlock()
            if let obs {
                CFRunLoopAddSource(CFRunLoopGetCurrent(),AXObserverGetRunLoopSource(obs),.defaultMode)
                subscribeNow(AXUIElementCreateApplication(pid), names:["AXWindowCreated","AXFocusedWindowChanged","AXFocusedUIElementChanged","AXApplicationActivated","AXApplicationDeactivated","AXLayoutChanged"])
            } else { receive(kind:"coverage",payload:["observerError":err.rawValue]) }
            ready.signal()
            if obs != nil { CFRunLoopRun() }
            if let obs { CFRunLoopRemoveSource(CFRunLoopGetCurrent(),AXObserverGetRunLoopSource(obs),.defaultMode) }
        }
        ready.wait()
    }
    private func receive(kind:String,payload:[String:Any]) {
        let wall=Date(), mono=ProcessInfo.processInfo.systemUptime
        stateLock.lock(); guard active else {stateLock.unlock();return}
        if pending>=2048 {dropped += 1;stateLock.unlock();return}; pending += 1
        let loss=dropped;dropped=0;let context=interaction;stateLock.unlock()
        queue.async { [self] in
            do {
                if loss>0 {try store.append(session:id,kind:"capture_gap",payload:["droppedNotifications":loss])}
                try store.append(session:id,interaction:context,kind:kind,payload:payload,wall:wall,mono:mono)
            } catch {Diagnostics.shared.record(level:"error",kind:"observer_recording_failed",detail:String(describing:error),fields:["session":id,"interaction":context ?? "","tool":"observer"])}
            stateLock.lock();pending -= 1;stateLock.unlock()
        }
    }
    private func subscribeNow(_ element:AXUIElement,names:[String]) {
        guard let observer else {return}
        for name in names {
            if registrations.count >= 8192 {
                if !subscriptionLimitReported {subscriptionLimitReported=true;receive(kind:"coverage",payload:["subscriptionLimitReached":8192,"remainingElementsUnsubscribed":true])}
                return
            }
            let key="\(CFHash(element)):\(name)";guard registrations.insert(key).inserted else {continue}
            let err=AXObserverAddNotification(observer,element,name as CFString,Unmanaged.passUnretained(self).toOpaque())
            receive(kind:"subscription",payload:["notification":name,"elementHash":String(CFHash(element)),"result":err.rawValue])
        }
    }
    func subscribe(_ snapshot:AXWindowSnapshot) {
        stateLock.lock();let loop=loop;stateLock.unlock();guard let loop else{return}
        CFRunLoopPerformBlock(loop,CFRunLoopMode.defaultMode.rawValue) { [self] in
            subscribeNow(snapshot.window,names:["AXUIElementDestroyed","AXWindowMoved","AXWindowResized","AXLayoutChanged","AXTitleChanged"])
            let candidates = snapshot.nodes.filter { $0.enabled && ($0.settable || $0.role == "AXScrollArea" || $0.role == "AXOutline" || $0.role == "AXTable") }
            for n in candidates.prefix(64) { subscribeNow(n.element,names:["AXValueChanged","AXSelectedChildrenChanged"]) }
            if candidates.count>64 {receive(kind:"coverage",payload:["candidateNodes":candidates.count,"subscribedCandidateLimit":64])}
        };CFRunLoopWakeUp(loop)
    }
    func flush() {
        queue.sync {}
        stateLock.lock(); let loss=dropped; dropped=0; stateLock.unlock()
        if loss>0 {do {try store.append(session:id,kind:"capture_gap",payload:["droppedNotifications":loss])} catch {Diagnostics.shared.record(level:"error",kind:"gap_recording_failed",detail:String(describing:error),fields:["session":id])}}
    }
    func stop() {
        stateLock.lock();active=false;let loop=loop;stateLock.unlock()
        if let loop {CFRunLoopStop(loop);CFRunLoopWakeUp(loop)}
        _ = stopped.wait(timeout: .now() + 2)
        flush()
        do {try store.finish(id)} catch {Diagnostics.shared.record(level:"error",kind:"recording_close_failed",detail:String(describing:error),fields:["session":id])}
    }
}
