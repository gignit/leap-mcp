// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import SQLite3

/// Read-only evidence access. Captured JSON is authoritative; files are optional materializations.
public final class Evidence {
    private var db: OpaquePointer?
    public let root: String
    public init(project:String) throws {
        guard project.hasPrefix("/") else {throw LeapError.unsupported("Project must be absolute")}
        root=RecordingStore.git(project,["rev-parse","--show-toplevel"]) ?? URL(fileURLWithPath:project).standardizedFileURL.path
        guard sqlite3_open_v2(root+"/.leap/leap.db",&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            sqlite3_close(db);db=nil;throw LeapError.unsupported("No readable evidence for project; bind/record first")
        }
        sqlite3_busy_timeout(db,1000)
    }
    deinit {sqlite3_close(db)}
    func rows(_ sql:String,_ args:[String]=[]) throws -> [[String:Any]] {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else {throw LeapError.unsupported("Evidence query unavailable")}
        defer {sqlite3_finalize(stmt)}
        for (i,a) in args.enumerated(){sqlite3_bind_text(stmt,Int32(i+1),a,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        var out:[[String:Any]]=[]
        while true {
            let rc=sqlite3_step(stmt);if rc==SQLITE_DONE {break};guard rc==SQLITE_ROW else {throw LeapError.unsupported("Evidence read failed")}
            var row:[String:Any]=[:]
            for i in 0..<sqlite3_column_count(stmt) {if let v=sqlite3_column_text(stmt,i){row[String(cString:sqlite3_column_name(stmt,i))]=String(cString:v)}}
            out.append(row)
        };return out
    }
    func snapshot(_ id:Int) throws -> ([String:Any],[[String:Any]]) {
        guard let row=try rows("SELECT session,interaction,payload FROM records WHERE seq=? AND kind='snapshot'",[String(id)]).first,
              let raw=row["payload"] as? String,let payload=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],let nodes=payload["nodes"] as? [[String:Any]] else {throw LeapError.unsupported("Snapshot not found")}
        var meta=payload;meta.removeValue(forKey:"nodes");meta["session"]=row["session"];meta["interaction"]=row["interaction"];meta["snapshot"]=id
        return(meta,nodes)
    }
    static func assetRef(snapshot:Int,ordinal:Int,field:String,value:String) -> [String:Any] {
        ["leapAsset":["assetId":"s\(snapshot):n\(ordinal):\(field)","mediaType":"text/plain; charset=utf-8","bytes":value.utf8.count,"characters":value.count,"preview":String(value.prefix(100)),"available":true]]
    }
    static func page(_ items:[[String:Any]], budget:Int, after:Int, cursor:String="ordinal") throws -> ([ [String:Any] ],Bool,Int) {
        let cap=max(2048,min(32000,budget));var kept:[[String:Any]]=[];var used=0
        for item in items {
            let bytes=try RecordingStore.json(item).utf8.count
            if used+bytes>cap {return(kept,true,kept.last?[cursor] as? Int ?? after)}
            kept.append(item);used+=bytes
        };return(kept,false,kept.last?[cursor] as? Int ?? after)
    }
    public func ui(snapshot id:Int,types:[String],ids:[String],fields:[String],contains:String?,rootKey:String?,depth:Int?,enabled:Bool?,selected:Bool?,visible:Bool?,after:Int,limit:Int,maxBytes:Int) throws -> String {
        let (meta,nodes)=try snapshot(id)
        let rootDepth=rootKey.flatMap {key in nodes.first(where:{$0["key"] as? String==key})?["depth"] as? Int} ?? 0
        if let rootKey, !nodes.contains(where:{$0["key"] as? String==rootKey}) {throw LeapError.unsupported("Root key not found in this snapshot")}
        func role(_ s:String)->String {s.lowercased().replacingOccurrences(of:"ax",with:"").replacingOccurrences(of:"_",with:"")}
        let defaultFields=["key","parentKey","role","label","value","enabled","selected","focused","offscreen","screenFrame","index","valueLimited"]
        let wanted=Set(fields.isEmpty ? defaultFields:fields)
        var matches:[[String:Any]]=[]
        for (i,n) in nodes.enumerated() {
            let ordinal=i+1;let key=n["key"] as? String ?? ""
            guard types.isEmpty || types.map(role).contains(role(n["role"] as? String ?? "")) else {continue}
            guard ids.isEmpty || ids.contains(key) || ids.contains(String(ordinal)) else {continue}
            if let rootKey,key != rootKey && !(n["ancestorKeys"] as? [String] ?? []).contains(rootKey) {continue}
            if let depth,(n["depth"] as? Int ?? 0)-rootDepth>max(0,depth){continue}
            if let enabled,n["enabled"] as? Bool != enabled {continue}
            if let selected,n["selected"] as? Bool != selected {continue}
            if let visible {if n["screenFrame"] == nil || (n["offscreen"] as? Bool ?? false) == visible {continue}}
            if let contains,!((n["label"] as? String ?? "")+" "+(n["value"] as? String ?? "")).localizedCaseInsensitiveContains(contains) {continue}
            var item=n.filter {wanted.contains($0.key)};item["ordinal"]=ordinal
            for (field,value) in item {
                if let text=value as? String,text.utf8.count>256 {item[field]=Self.assetRef(snapshot:id,ordinal:ordinal,field:field,value:text)}
                else if JSONSerialization.isValidJSONObject(value),let encoded=try? RecordingStore.json(value),encoded.utf8.count>512 {item[field]=Self.assetRef(snapshot:id,ordinal:ordinal,field:field,value:encoded)}
            }
            matches.append(item)
        }
        let candidates=matches.filter {($0["ordinal"] as? Int ?? 0)>after}
        let count=max(1,min(100,limit));let proposed=Array(candidates.prefix(count))
        let (page,cut,next)=try Self.page(proposed,budget:maxBytes,after:after)
        guard !page.isEmpty || proposed.isEmpty else {throw LeapError.unsupported("One node exceeds response budget; request fewer fields or increase max_bytes")}
        return try RecordingStore.json(["snapshot":meta,"historical":true,"coordinateSpace":"screen points, top-left origin; visibility is frame-based, not occlusion","matched":matches.count,"items":page,"hasMore":cut || candidates.count>page.count,"nextCursor":next,"next":"ui_to_text with same snapshot and filters, after=nextCursor; leap_asset for references","liveTargetWarning":"Historical indices/keys require fresh target validation before input"])
    }
    public func asset(id:String,mode:String,offset:Int,limit:Int) throws -> String {
        let parts=id.split(separator:":").map(String.init)
        guard parts.count==3,parts[0].hasPrefix("s"),parts[1].hasPrefix("n"),let snap=Int(parts[0].dropFirst()),let ordinal=Int(parts[1].dropFirst()),ordinal>0 else {throw LeapError.unsupported("Invalid asset reference")}
        let (meta,nodes)=try snapshot(snap)
        guard ordinal<=nodes.count,let retained=nodes[ordinal-1][parts[2]] else {throw LeapError.unsupported("Captured asset unavailable")}
        let value:String
        if let text=retained as? String {value=text}
        else if JSONSerialization.isValidJSONObject(retained) {value=try RecordingStore.json(retained)}
        else {throw LeapError.unsupported("Not a retrievable text/object asset") }
        let bytes=value.utf8.count
        if mode=="info" {return try RecordingStore.json(["assetId":id,"bytes":bytes,"characters":value.count,"mediaType":"text/plain","session":meta["session"] ?? "","captureLimited":nodes[ordinal-1]["valueLimited"] ?? false])}
        if mode=="file" || (mode=="auto" && bytes>8000) {
            guard let session=meta["session"] as? String,UUID(uuidString:session) != nil else {throw LeapError.unsupported("Invalid stored session identity")}
            let interaction=(meta["interaction"] as? String).flatMap{UUID(uuidString:$0)?.uuidString} ?? "observation"
            let directory=root+"/.leap/sessions/"+session+"/content/"+interaction
            try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // File name derives only from parsed numbers and a fixed extension, never a caller path.
            let fieldTag=Data(parts[2].utf8).base64EncodedString().replacingOccurrences(of:"/",with:"_")
            let file=directory+"/s\(snap)-n\(ordinal)-\(fieldTag).txt"
            try value.write(toFile:file,atomically:true,encoding:.utf8)
            return try RecordingStore.json(["assetId":id,"file":file,"bytes":bytes,"mediaType":"text/plain"])
        }
        guard ["auto","text"].contains(mode) else {throw LeapError.unsupported("mode must be auto, info, text or file")}
        let start=max(0,offset);let count=max(1,min(4000,limit));let chunk=String(value.dropFirst(start).prefix(count))
        return "Asset \(id) — characters \(start)..<\(start+chunk.count) of \(value.count); nextOffset=\(start+chunk.count); hasMore=\(start+chunk.count<value.count)\n"+chunk
    }
    public func interaction(_ id:String) throws -> String {
        // Never load raw tree payloads just to explain an interaction.
        let facts=try rows("SELECT seq,kind,payload FROM records WHERE interaction=? AND kind IN ('action_intent','action_result','expectation_result','capture_gap') ORDER BY seq LIMIT 201",[id])
        var actions:[String:[String:Any]]=[:];var order:[String]=[];var checks:[[String:Any]]=[];var gaps=0
        for row in facts.prefix(200) {
            guard let raw=row["payload"] as? String,let p=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else {continue}
            let kind=row["kind"] as? String ?? ""
            if kind=="capture_gap" {gaps+=1}
            if kind=="expectation_result" {checks.append(["record":row["seq"] ?? "","phase":p["phase"] ?? "","outcome":p["outcome"] ?? "unknown","label":String((p["label"] as? String ?? "").prefix(160)),"condition":p["condition"] ?? ""])}
            if let action=p["actionId"] as? String {
                if actions[action]==nil {actions[action]=["actionId":action,"tool":p["tool"] ?? "","acknowledgement":"not recorded; dispatch unknown"];order.append(action)}
                if kind=="action_intent" {actions[action]?["intentRecord"]=row["seq"]}
                if kind=="action_result" {actions[action]?["resultRecord"]=row["seq"];actions[action]?["acknowledgement"]=p["apiOutcome"];actions[action]?["detail"]=String((p["result"] as? String ?? "").prefix(300))}
            }
        }
        let snapshots=try rows("SELECT MIN(seq) AS first,MAX(seq) AS last,COUNT(*) AS count FROM records WHERE interaction=? AND kind='snapshot'",[id])
        let post=checks.filter{$0["phase"] as? String=="after"}
        let outcome=facts.count>200 ? "unknown: review clipped" : post.isEmpty ? "not verified" : post.allSatisfy{$0["outcome"] as? String=="met"} ? "requested current-state checks met" : "requested checks not established"
        let result:[String:Any]=["interaction":id,"outcome":outcome,"actions":order.prefix(20).compactMap{actions[$0]},"checks":Array(checks.prefix(20)),"snapshots":snapshots,"captureGapRecords":gaps,"omitted":facts.count>200 || order.count>20 || checks.count>20,"meaning":"Current-state checks do not prove persistence or causation. Preserve API uncertainty; never replay merely because acknowledgement failed.","next":"recording_review(view: actions, interaction_id: this interaction) for all records; ui_diff for snapshot changes"]
        return try RecordingStore.json(result)
    }
    /// Bracket inputs by record order; never use a previous interaction's displayed baseline.
    /// What an agent needs to judge an observation; full capture metadata stays in the store.
    static func qualitySummary(_ m:[String:Any]) -> [String:Any] {
        let blocking=(m["readFailures"] as? Int ?? 0)-(m["advisoryReadFailures"] as? Int ?? 0)
        let complete=blocking<=0 && !(m["truncated"] as? Bool ?? false) && !(m["deadlineExceeded"] as? Bool ?? false)
        var out:[String:Any]=["complete":complete,"nodes":m["nodeCount"] ?? NSNull()]
        if !complete {out["blockingReadFailures"]=max(0,blocking);out["truncated"]=m["truncated"] ?? false;out["deadlineExceeded"]=m["deadlineExceeded"] ?? false}
        return out
    }
    public func interactionDelta(_ id: String) throws -> String {
        let intents = try rows("SELECT MIN(seq) AS first,MAX(seq) AS last FROM records WHERE interaction=? AND kind='action_intent'", [id])
        guard let first = intents.first?["first"] as? String,
              let last = intents.first?["last"] as? String else {
            return try RecordingStore.json(["available":false,"reason":"No retained action intent"])
        }
        let before = try rows("SELECT seq FROM records WHERE interaction=? AND kind='snapshot' AND seq<CAST(? AS INTEGER) ORDER BY seq DESC LIMIT 1", [id,first]).first?["seq"] as? String
        let after = try rows("SELECT seq FROM records WHERE interaction=? AND kind='snapshot' AND seq>CAST(? AS INTEGER) ORDER BY seq DESC LIMIT 1", [id,last]).first?["seq"] as? String
        guard let before,let b=Int(before),let after,let a=Int(after) else {
            return try RecordingStore.json(["available":false,"reason":"Missing pre/post observation; no state inferred or input replayed"])
        }
        let (bm,_)=try snapshot(b), (am,_)=try snapshot(a)
        var result: [String:Any] = ["beforeSnapshot":b,"afterSnapshot":a,
            "beforeQuality":Self.qualitySummary(bm),"afterQuality":Self.qualitySummary(am),
            "next":"ui_diff(before: beforeSnapshot, after_snapshot: afterSnapshot) for more changes; ui_to_text(snapshot: ...) for full controls"]
        do {
            let raw=try diff(before:b,after:a,cursor:0,limit:10,maxBytes:4000)
            result["delta"]=try JSONSerialization.jsonObject(with:Data(raw.utf8))
            result["available"]=true
        } catch {
            result["available"]=false;result["reason"]="Comparison unavailable: \(error)"
        }
        return try RecordingStore.json(result)
    }
    public func sessions(view:String,group:String?,after:Int,limit:Int) throws -> String {
        guard ["groups","recordings"].contains(view) else {throw LeapError.unsupported("view must be groups or recordings")}
        let modern = !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='recording_groups'")).isEmpty
        let cap=max(1,min(20,limit))
        var items:[[String:Any]]=[]
        if view == "groups" {
            if modern {
                items=try rows("SELECT rowid AS ordinal,id AS groupId,name,started,ended,(SELECT COUNT(*) FROM recording_group_members m WHERE m.group_id=g.id) AS captureCount FROM recording_groups g WHERE rowid>CAST(? AS INTEGER)" + (group == nil ? "" : " AND id=?") + " ORDER BY rowid LIMIT CAST(? AS INTEGER)",[String(after)] + (group.map {[$0]} ?? []) + [String(cap+1)])
            }
        } else {
            var args=[String(after)]
            let membership=modern ? "(SELECT group_id FROM recording_group_members m WHERE m.session=s.id)" : "NULL"
            let filter=group == nil ? "" : " AND \(membership)=?"
            if let group {args.append(group)}
            args.append(String(cap+1))
            items=try rows("SELECT s.rowid AS ordinal,s.id AS sessionId,s.app,s.started,s.ended,\(membership) AS groupId,(SELECT COUNT(*) FROM records r WHERE r.session=s.id) AS records,(SELECT COUNT(DISTINCT NULLIF(interaction,'')) FROM records r WHERE r.session=s.id) AS interactions,(SELECT COUNT(*) FROM records r WHERE r.session=s.id AND kind='snapshot') AS snapshots FROM sessions s WHERE s.rowid>CAST(? AS INTEGER)\(filter) ORDER BY s.rowid LIMIT CAST(? AS INTEGER)",args)
        }
        let page=Array(items.prefix(cap))
        var sizes:[String:Int64]=[:]
        for name in ["leap.db","leap.db-wal","leap.db-shm"] {sizes[name]=((try? FileManager.default.attributesOfItem(atPath:root+"/.leap/"+name)[.size]) as? NSNumber)?.int64Value ?? 0}
        let totals=try rows("SELECT COUNT(*) AS records,COUNT(DISTINCT session) AS recordedSessions,COUNT(DISTINCT NULLIF(interaction,'')) AS interactions,SUM(CASE WHEN kind='snapshot' THEN 1 ELSE 0 END) AS snapshots FROM records").first ?? [:]
        return try RecordingStore.json(["items":page,"hasMore":items.count>cap,"nextCursor":Int(page.last?["ordinal"] as? String ?? "") ?? after,"projectTotals":totals,"storageBytes":sizes,
            "storage":"Payloads are in .leap/leap.db. Session directories may be empty until assets are materialized. WAL sizes vary without deleting history.",
            "coverage":"Each recording is an application capture epoch, not continuous task history. Groups can span epochs/apps/restarts. Missing ended means not explicitly closed, not proof of a live observer.",
            "next":"recording_sessions(view: recordings, group_id) for members; interaction_timeline(group_id or session_id) for calls; recording_query for background events"])
    }
    public func timeline(session:String?,after:Int,through:Int?,limit:Int,group:String? = nil) throws -> String {
        let ceiling: Int
        if let through { ceiling = through }
        else { ceiling = Int((try rows("SELECT MAX(seq) AS seq FROM records").first?["seq"] as? String) ?? "0") ?? 0 }
        let count=max(1,min(20,limit))
        var args=[String(ceiling)]
        var filter=session == nil ? "" : " AND session=?"
        if let session { args.append(session) }
        if let group {filter += " AND session IN (SELECT session FROM recording_group_members WHERE group_id=?)";args.append(group)}
        args += [String(after),String(count+1)]
        let groups=try rows("SELECT interaction,session,MIN(seq) AS ordinal,MIN(wall) AS startedAt,MAX(wall) AS lastRecordedAt, SUM(CASE WHEN kind='action_intent' THEN 1 ELSE 0 END) AS inputs,MIN(CASE WHEN kind='snapshot' THEN seq END) AS firstSnapshot,MAX(CASE WHEN kind='snapshot' THEN seq END) AS lastSnapshot FROM records WHERE interaction IS NOT NULL AND interaction<>'' AND seq<=CAST(? AS INTEGER)"+filter+" GROUP BY interaction,session HAVING MIN(seq)>CAST(? AS INTEGER) ORDER BY MIN(seq) LIMIT CAST(? AS INTEGER)",args)
        let items=groups.prefix(count).map { row -> [String:Any] in
            var item=row
            item["ordinal"]=Int(row["ordinal"] as? String ?? "0") ?? 0
            item["next"]="interaction_result(interaction_id) for acknowledgement/checks; interaction_delta(interaction_id) for bracketed changes"
            return item
        }
        let (page,cut,next)=try Self.page(items,budget:12000,after:after)
        return try RecordingStore.json(["items":page,"through":ceiling,"nextCursor":next,
            "hasMore":cut || groups.count>page.count,
            "meaning":"Recorded interactions only, frozen through cursor. lastRecordedAt is not a completion assertion. first/lastSnapshot include prechecks; interaction_delta brackets actual input.",
            "next":"interaction_timeline with same session/through and after=nextCursor"])
    }
    public func diff(before:Int,after:Int,cursor:Int,limit:Int,maxBytes:Int) throws -> String {
        let (bm,bn)=try snapshot(before);let(am,an)=try snapshot(after)
        guard bm["session"] as? String == am["session"] as? String,bm["window"] as? String == am["window"] as? String else {throw LeapError.unsupported("Snapshots must belong to the same recorded app session/window title; cross-process identity is not inferred")}
        var old:[String:[String:Any]]=[:];for n in bn {if let k=n["key"] as? String {old[k]=n}}
        var changes:[[String:Any]]=[]
        for (i,n) in an.enumerated() {
            guard let k=n["key"] as? String else {continue}
            let prior=old.removeValue(forKey:k)
            let fields=["label","value","enabled","selected","focused","offscreen","screenFrame"]
            let changed=fields.filter { field in
                let left=prior?[field] ?? NSNull(), right=n[field] ?? NSNull()
                let a=try? JSONSerialization.data(withJSONObject:[left],options:[.sortedKeys])
                let b=try? JSONSerialization.data(withJSONObject:[right],options:[.sortedKeys])
                return a != b
            }
            if prior == nil || !changed.isEmpty {
                var item:[String:Any]=["change":prior == nil ? "added":"changed","key":k,"label":String((n["label"] as? String ?? "").prefix(160))]
                if prior != nil {item["fields"]=changed}
                func projection(_ node: [String:Any]?) -> [String:Any] {
                    var out:[String:Any]=[:]
                    for field in changed {
                        if let value=node?[field] {
                            if let text=value as? String, text.utf8.count>128 {
                                out[field]=["preview":String(text.prefix(64)),"shortened":true]
                            } else {out[field]=value}
                        }
                    }
                    return out
                }
                // Added elements: their state, not their geometry (ui_to_text has frames).
                if prior == nil {item["afterValues"]=projection(n).filter{$0.key != "screenFrame" && $0.key != "label"}}
                else {item["beforeValues"]=projection(prior);item["afterValues"]=projection(n)}
                if k.utf8.count>256 {item["key"]=Self.assetRef(snapshot:after,ordinal:i+1,field:"key",value:k)}
                changes.append(item)
            }
        }
        for k in old.keys.sorted(){changes.append(["change":"removed","key":String(k.prefix(256)),"keyShortened":k.count>256])}
        for i in changes.indices {changes[i]["ordinal"]=i+1}
        let candidates=changes.filter {($0["ordinal"] as? Int ?? 0)>cursor};let proposed=Array(candidates.prefix(max(1,min(100,limit))))
        let(page,cut,next)=try Self.page(proposed,budget:maxBytes,after:cursor)
        // Node-scoped (advisory) read failures do not make the tree partial.
        func blocking(_ m:[String:Any]) -> Bool {(m["readFailures"] as? Int ?? 0)-(m["advisoryReadFailures"] as? Int ?? 0)>0}
        let partial=(bm["truncated"] as? Bool ?? false)||(am["truncated"] as? Bool ?? false)||blocking(bm)||blocking(am)||(bm["deadlineExceeded"] as? Bool ?? false)||(am["deadlineExceeded"] as? Bool ?? false)
        return try RecordingStore.json(["before":before,"after":after,"changes":page,"total":changes.count,"hasMore":cut || candidates.count>page.count,"nextCursor":next,"incomplete":partial,"meaning":"Observed differences, not causal proof. Removal from a partial tree does not prove disappearance. Content-based keys can change when labels change."])
    }
}
