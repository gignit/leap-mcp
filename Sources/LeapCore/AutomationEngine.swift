// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import AppKit
import ApplicationServices

extension Engine {
    static let macActions:Set<String> = ["click","double_click","type_text","set_value","press_key","scroll","drag","activate",
                                         "perform_action","select_text","paste"]
    static let deviceActions:Set<String> = ["click","double_click","type_text","drag","scroll","press_key","rotate","activate"]

    /// Called within the server's serial operation boundary. All workflow tools share the same
    /// journal and selector/check implementation; adapters own only acquisition and input.
    public func automation(_ tool:String,json:String) async throws -> String {
        guard let args=try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any] else {throw AutomationModel.fail("Arguments must be an object")}
        if tool == "target_list" {
            var targets:[[String:Any]]=AppResolver.listApps(includeInstalled:false).map { a in
                ["id":a.bundleId ?? a.name,"name":a.name,"backend":"mac_ax","pid":a.pid ?? 0,"foreground":a.isActive,"actions":Self.macActions.sorted(),"acceptance":"capabilities, not certification"]
            }
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");process.arguments=["simctl","list","devices","available","--json"]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            var warning:String?
            do {
                try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                guard process.terminationStatus == 0 else {throw AutomationModel.fail("simctl unavailable")}
                let devices=(try JSONSerialization.jsonObject(with:data) as? [String:Any])?["devices"] as? [String:[[String:Any]]] ?? [:]
                for (runtime,items) in devices {for d in items {targets.append(["id":d["udid"] ?? "","name":d["name"] ?? "","state":d["state"] ?? "","runtime":runtime,"backend":"wda","readiness":"requires local WDA runner endpoint","actions":Self.deviceActions.sorted()])}}
            } catch {warning=String(describing:error)}
            return try RecordingStore.json(["schemaVersion":2,"targets":targets,"warning":warning ?? ""])
        }
        if tool == "evidence_read" {
            let e=try Evidence(project:recordingProject(args["project"] as? String))
            guard let id=args["session_id"] as? String,let seq=args["record"] as? Int,
                  let row=try e.rows("SELECT payload FROM records WHERE session=? AND seq=? AND kind LIKE 'automation_%'",[id,String(seq)]).first,
                  let payload=row["payload"] as? String else {throw AutomationModel.fail("Retained automation record not found")}
            var value:Any=try JSONSerialization.jsonObject(with:Data(payload.utf8))
            for key in args["path"] as? [String] ?? [] {
                if let obj=value as? [String:Any],let child=obj[key] {value=child}
                else if let arr=value as? [Any],let i=Int(key),arr.indices.contains(i) {value=arr[i]}
                else {throw AutomationModel.fail("Evidence path not found; use object keys or array indices")}
            }
            let raw:String
            if let text=value as? String {raw=text} else {
                raw=String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]),as:UTF8.self)
            }
            let offset=max(0,args["offset"] as? Int ?? 0),limit=max(128,min(8000,args["max_bytes"] as? Int ?? 4000))
            var chunk=String(raw.dropFirst(offset).prefix(limit))
            while chunk.utf8.count>limit {chunk.removeLast()}
            return "Retained record \(seq), character offset \(offset), nextOffset=\(offset+chunk.count), hasMore=\(offset+chunk.count<raw.count)\n"+chunk
        }
        if tool == "session_history" {
            let evidence=try Evidence(project:recordingProject(args["project"] as? String))
            let kind=args["kind"] as? String ?? "automation_result"
            guard ["automation_session","automation_result","automation_step","automation_intent","automation_artifact"].contains(kind) else {throw AutomationModel.fail("Unsupported history kind")}
            let limit=max(1,min(20,args["limit"] as? Int ?? 10)),after=max(0,args["after"] as? Int ?? 0)
            var sql="SELECT seq,session,interaction,wall,kind,json_extract(payload,'$.execution') AS execution,json_extract(payload,'$.verification') AS verification FROM records WHERE seq>CAST(? AS INTEGER) AND kind=?"
            var values=[String(after),kind]
            if let id=args["session_id"] as? String {sql += " AND session=?";values.append(id)}
            sql += " ORDER BY seq LIMIT \(limit+1)"
            let rows=try evidence.rows(sql,values)
            let items=rows.prefix(limit).map {row -> [String:Any] in
                var r=row
                r["file"]=evidence.root+"/.leap/sessions/\(row["session"] ?? "")/\(row["seq"] ?? "")-\(kind.dropFirst(11)).json"
                return r
            }
            return try RecordingStore.json(["schemaVersion":2,"items":items,"hasMore":rows.count>limit,"nextCursor":Int(items.last?["seq"] as? String ?? "") ?? after])
        }
        if tool == "session_open" {
            guard let app=args["app"] as? String,!app.isEmpty,let project=args["project"] as? String else {throw AutomationModel.fail("session_open requires project and app")}
            let backend=args["backend"] as? String ?? "mac_ax"
            guard ["mac_ax","wda"].contains(backend) else {throw AutomationModel.fail("backend must be mac_ax or wda")}
            _ = try bindProject(project)
            guard let root=boundProject,let store=recordingStores[root] else {throw AutomationModel.fail("Project store unavailable")}
            let window=args["window"] as? String
            var pid:pid_t?,client:WDAClient?
            if backend == "mac_ax" {
                let native=try await session(for:app);pid=native.pid
            } else {
                guard let endpoint=args["endpoint"] as? String else {throw AutomationModel.fail("WDA requires endpoint from scripts/wda.py; no implicit host-AX fallback")}
                // The guest app's bundle id is subject to the same allow-list as Mac apps.
                try AppResolver.enforceAllowList(identities:[app],query:app)
                guard !automationSessions.values.contains(where:{$0.wda?.endpoint.absoluteString == endpoint}) else {throw AutomationModel.fail("WDA endpoint already owned by a Leap session")}
                client=try WDAClient(endpoint:endpoint)
            }
            let id=try store.attach(app:app,pid:pid ?? 0)
            let s=AutomationSession(id:id,app:app,backend:backend,window:window,store:store,pid:pid)
            s.wda=client
            _ = try s.save("session",["backend":backend,"app":app,"window":window ?? "","endpoint":args["endpoint"] ?? "","lifecycle":"opening; WDA may launch/activate guest app, no reset"],interaction:recordingInteraction)
            do {
                if let client {try await client.open(app:app)}
                automationSessions[id]=s
                let snap=try await automationObserve(s)
                return try RecordingStore.json(["schemaVersion":2,"session_id":id,"backend":backend,"app":app,"snapshot":snap["snapshot"]!,"file":snap["file"]!,"actions":(backend == "mac_ax" ? Self.macActions:Self.deviceActions).sorted(),"next":"ui_observe(session_id) or ui_perform(session_id, steps)","insights_enabled":Diagnostics.shared.insightsEnabled,"restart":"Live handles expire at MCP restart; history remains; open a new live session"])
            } catch {
                automationSessions[id]=nil
                _ = try? s.save("open_failed",["error":String(describing:error),"lifecycle":"Guest launch/activation may have occurred"],interaction:recordingInteraction)
                try? store.finish(id)
                throw error
            }
        }
        guard let id=args["session_id"] as? String else {throw AutomationModel.fail("session_id required")}
        // Historical snapshot retrieval works after restart without reviving live handles.
        if tool == "ui_observe",let seq=args["snapshot"] as? Int {
            let root=try recordingProject(args["project"] as? String)
            let e=try Evidence(project:root)
            guard let row=try e.rows("SELECT payload FROM records WHERE seq=? AND session=? AND kind='automation_snapshot'",[String(seq),id]).first,
                  let payload=row["payload"] as? String,
                  var snapshot=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any] else {throw AutomationModel.fail("Snapshot not found in session")}
            snapshot["snapshot"]=seq;snapshot["file"]=root+"/.leap/sessions/\(id)/\(seq)-snapshot.json"
            return try automationPage(snapshot,args:args)
        }
        guard let s=automationSessions[id] else {throw AutomationModel.fail("Live session unavailable or expired after restart; open a new session. Retained snapshots/history remain readable.")}
        switch tool {
        case "session_close":
            try s.store.finish(s.id);automationSessions[id]=nil
            // Do not DELETE WDA session: external backend lifecycle can terminate guest apps.
            return try RecordingStore.json(["schemaVersion":2,"session_id":id,"closed":true,"applicationTerminated":false])
        case "ui_observe":return try automationPage(try await automationObserve(s),args:args)
        case "ui_inspect":return try await automationInspect(s,args:args)
        case "ui_perform":return try await automationPerform(s,args:args)
        default:throw AutomationModel.fail("Unknown automation tool")
        }
    }

    /// Normalized nodes for selectors and verdicts, shared by full observations and quick reads.
    static func automationNodes(_ snap:AXWindowSnapshot,_ native:AppSession) -> [[String:Any]] {
        var ancestors:[(Int,String)]=[]
        return snap.nodes.map {n in
            while let last=ancestors.last,last.0>=n.depth {ancestors.removeLast()}
            var node:[String:Any]=["id":n.key,"role":n.role,"label":n.title ?? n.description ?? n.placeholder ?? "","enabled":n.enabled,"selected":n.selected,"focused":n.focused,"offscreen":n.offscreen,"depth":n.depth,"ancestors":ancestors.map{$0.1},"actions":n.actions.map(AX.actionName),"valueLimited":n.valueLimited]
            node["unavailableFields"]=n.unavailableFields;node["identifier"]=n.identifier;if n.omittedChildren>0 {node["omittedChildren"]=n.omittedChildren};node["value"]=n.capturedValue ?? n.value;node["index"]=native.indexByKey[n.key]
            if let f=n.frame {node["frame"]=[f.minX-snap.frame.minX,f.minY-snap.frame.minY,f.width,f.height]}
            ancestors.append((n.depth,n.key));return node
        }
    }

    /// A plain walk of the target window: no settle loop, rendering, recording or delta. Used to poll
    /// waits cheaply (every 250 ms) and to resolve a target just before
    /// input. Evidence still comes from full observations.
    func automationQuickRead(_ s:AutomationSession,budget:Double=2) async throws -> (nodes:[[String:Any]],complete:Bool,snap:AXWindowSnapshot,native:AppSession) {
        let native=try await session(for:s.app,launch:false)
        guard native.pid == s.pid else {throw AutomationModel.fail("Target process changed; open a new session")}
        let window=try await waitForWindow(native,timeout:min(2,max(0.05,budget)))
        guard let snap=walker.snapshot(window:window,app:native.axApp,timeout:min(2,max(0.05,budget))) else {throw AutomationModel.fail("AX snapshot unavailable")}
        return (Self.automationNodes(snap,native),snap.supportsStateChecks,snap,native)
    }

    /// Raw, unnormalized attributes for triage (settles app-versus-tool questions).
    func automationInspect(_ s:AutomationSession,args:[String:Any]) async throws -> String {
        guard s.wda == nil else {throw AutomationModel.fail("ui_inspect reads macOS accessibility; not available for wda sessions")}
        let selector=AutomationModel.object(args["selector"]);try AutomationModel.validateSelector(selector)
        let quick=try await automationQuickRead(s)
        let limit=max(1,min(10,args["limit"] as? Int ?? 3))
        let matched=quick.snap.nodes.enumerated().filter{AutomationModel.matches(quick.nodes[$0.offset],selector)}
        func raw(_ v:CFTypeRef?) -> Any {
            guard let v else {return NSNull()}
            if let s=v as? String {return String(s.prefix(300))}
            if let n=v as? NSNumber {return n}
            if CFGetTypeID(v) == AXValueGetTypeID() {return String(describing:v).components(separatedBy:"{value = ").last.map{"{"+$0} ?? String(describing:v)}
            if CFGetTypeID(v) == AXUIElementGetTypeID() {let e=v as! AXUIElement;return "element \((AX.attr(e,kAXRoleAttribute) as String?) ?? "?") \"\((AX.attr(e,kAXTitleAttribute) as String?) ?? (AX.attr(e,kAXDescriptionAttribute) as String?) ?? "")\""}
            if let a=v as? [AnyObject] {return "array(\(a.count))"}
            return String(String(describing:v).prefix(200))
        }
        let items:[[String:Any]]=matched.prefix(limit).map {(i,n) in
            var names:CFArray?;AXUIElementCopyAttributeNames(n.element,&names)
            var attrs:[String:Any]=[:]
            for name in (names as? [String] ?? []) where ![kAXChildrenAttribute,"AXChildrenInNavigationOrder","AXPath"].contains(name) {
                if name.hasPrefix("AXAttributed") {var v:CFTypeRef?;if AXUIElementCopyAttributeValue(n.element,name as CFString,&v) == .success,let a=v as? NSAttributedString {attrs[name]=String(a.string.prefix(300))};continue}
                var v:CFTypeRef?;let err=AXUIElementCopyAttributeValue(n.element,name as CFString,&v)
                attrs[name]=err == .success ? raw(v) : "error \(err.rawValue)"
            }
            var actions:CFArray?;AXUIElementCopyActionNames(n.element,&actions)
            var chain:[String]=[];var p:AXUIElement?=AX.attr(n.element,kAXParentAttribute)
            for _ in 0..<8 {guard let e=p else {break};chain.append("\((AX.attr(e,kAXRoleAttribute) as String?) ?? "?") \"\((AX.attr(e,kAXTitleAttribute) as String?) ?? (AX.attr(e,kAXDescriptionAttribute) as String?) ?? "")\"");p=AX.attr(e,kAXParentAttribute)}
            return ["id":n.key,"index":quick.nodes[i]["index"] ?? NSNull(),"attributes":attrs,"actions":actions as? [String] ?? [],"parents":chain]
        }
        return try RecordingStore.json(["schemaVersion":2,"session_id":s.id,"window":quick.snap.title ?? "","matched":matched.count,"items":items,"meaning":"Raw provider data, unnormalized; compare with ui_observe to separate app behavior from Leap behavior. Read-only."])
    }

    func automationObserve(_ s:AutomationSession,settle:Bool=true) async throws -> [String:Any] {
        let started=ISO8601DateFormatter().string(from:Date())
        var observation:[String:Any]
        if let wda=s.wda {observation=try await wda.observe()}
        else {
            let native=try await session(for:s.app,launch:false)
            guard native.pid == s.pid else {throw AutomationModel.fail("Target process changed; open a new session")}
            var opts=StateOptions();opts.settle=settle
            _ = try await state(app:s.app,opts,window:s.window)
            guard let snap=native.automationSnapshot else {throw AutomationModel.fail("AX snapshot unavailable")}
            observation=try automationObservation(s,snap:snap,native:native)
        }
        return try automationSaveObservation(s,observation,started:started)
    }

    /// Normalize one AX snapshot into an observation (window identity rules included).
    func automationObservation(_ s:AutomationSession,snap:AXWindowSnapshot,native:AppSession) throws -> [String:Any] {
            var windowChanged=false
            if let identity=s.windowIdentity,!CFEqual(identity,snap.window) {
                guard !s.explicitWindow else {throw AutomationModel.fail("Selected window changed; open a new explicitly targeted session")}
                windowChanged=true
            }
            s.windowIdentity=snap.window
            let nodes=Self.automationNodes(snap,native)
            return ["nodes":nodes,"complete":snap.supportsStateChecks && !snap.retainedEarlierObservation,"windowChanged":windowChanged,"coordinateSpace":"window_points","bounds":[snap.frame.minX,snap.frame.minY,snap.frame.width,snap.frame.height],"window":snap.title ?? "","pid":native.pid,"blockingReadFailures":snap.blockingReadFailures,"advisoryReadFailures":snap.advisoryReadFailures,"limitations":["AX acquisition is not atomic; frame intersection is not occlusion","Simulator host AX geometry can be invalid; prefer device backend"]]
    }

    func automationSaveObservation(_ s:AutomationSession,_ input:[String:Any],started:String) throws -> [String:Any] {
        var observation=input
        observation["schemaVersion"]=2;observation["session_id"]=s.id;observation["backend"]=s.backend
        observation["started_at"]=started;observation["finished_at"]=ISO8601DateFormatter().string(from:Date())
        let (seq,file)=try s.save("snapshot",observation,interaction:recordingInteraction)
        observation["snapshot"]=seq;observation["file"]=file;s.latest=observation
        return observation
    }

    func automationPage(_ snapshot:[String:Any],args:[String:Any]) throws -> String {
        let selector=AutomationModel.object(args["selector"]);try AutomationModel.validateSelector(selector)
        let nodes=snapshot["nodes"] as? [[String:Any]] ?? []
        let rootDepth=nodes.first { $0["id"] as? String == selector["root"] as? String }?["depth"] as? Int ?? 0
        let all=nodes.filter {node in
            AutomationModel.matches(node,selector) && (args["depth"] as? Int).map { (node["depth"] as? Int ?? 0)-rootDepth <= max(0,$0) } != false
        }
        let after=max(0,args["after"] as? Int ?? 0), limit=max(1,min(100,args["limit"] as? Int ?? 20))
        let budget=max(2048,min(32000,args["max_bytes"] as? Int ?? 10000))
        let fields=args["fields"] as? [String] ?? ["id","role","label","identifier","value","enabled","selected","frame","unavailableFields"]
        var result=snapshot.filter{$0.key != "nodes"}
        result["selectorComplete"]=(snapshot["complete"] as? Bool == true && AutomationModel.selectionReliable(nodes,selector));result["matched"]=all.count;result["historical"]=args["snapshot"] != nil
        var items:[[String:Any]]=[]
        for node in all.dropFirst(after).prefix(limit) {
            var item=node.filter{fields.contains($0.key)}
            for (key,value) in item {if let text=value as? String,text.utf8.count>512 {item[key]=["preview":String(text.prefix(100)),"retained":snapshot["file"] ?? "","node":node["id"] ?? "","field":key]}}
            items.append(item)
            result["items"]=items;result["nextCursor"]=after+items.count;result["hasMore"]=after+items.count<all.count
            if try RecordingStore.json(result).utf8.count>budget {items.removeLast();break}
        }
        result["items"]=items;result["nextCursor"]=after+items.count;result["hasMore"]=after+items.count<all.count
        if items.isEmpty && after<all.count {throw AutomationModel.fail("One node exceeds budget; request fewer fields or larger max_bytes. Full snapshot: \(snapshot["file"] ?? "")")}
        return try AutomationModel.bounded(result,budget:budget,file:snapshot["file"] as? String ?? "")
    }

    func automationCheck(_ s:AutomationSession,expectation:[String:Any],timeout:Double) async throws -> (String,[String:Any]) {
        let end=ProcessInfo.processInfo.systemUptime+max(0,timeout)
        // Poll quick reads every 250 ms and keep the read that decided the verdict as the evidence
        // snapshot. A second, full observation after the fact cost about a second on Simulator host
        // trees (already-true waits took 1.0-1.7 s) and pushed timed-out waits 1-2 s past their
        // timeout. Each read is bounded by the time left, so the check ends at its timeout.
        if s.wda == nil {
            let started=ISO8601DateFormatter().string(from:Date())
            var last:(nodes:[[String:Any]],complete:Bool,snap:AXWindowSnapshot,native:AppSession)?
            repeat {
                let remaining=end-ProcessInfo.processInfo.systemUptime
                // A read that cannot finish in the time left comes back incomplete and would turn a
                // clear mismatch into "unknown"; judge from the last complete read instead.
                if last?.complete == true, remaining<0.3 {break}
                // The first read always gets a normal budget so a zero-timeout assert still sees the UI.
                guard let quick=try? await automationQuickRead(s,budget:last == nil ? 2:max(0.1,remaining)) else {break}
                // Keep the last complete read as the evidence unless this one is also complete.
                if quick.complete || last?.complete != true {last=quick}
                let verdict=AutomationModel.verdict(nodes:quick.nodes,complete:quick.complete,expectation:expectation)
                if verdict == "passed" {
                    let evidence=try automationSaveObservation(s,try automationObservation(s,snap:quick.snap,native:quick.native),started:started)
                    return (verdict,evidence)
                }
                if ProcessInfo.processInfo.systemUptime>=end-0.05 {break}
                let pause=min(0.25,end-ProcessInfo.processInfo.systemUptime)
                if pause>0 {try await Task.sleep(nanoseconds:UInt64(pause*1_000_000_000))}
            } while ProcessInfo.processInfo.systemUptime<end
            if let last {
                let verdict=AutomationModel.verdict(nodes:last.nodes,complete:last.complete,expectation:expectation)
                return (verdict,try automationSaveObservation(s,try automationObservation(s,snap:last.snap,native:last.native),started:started))
            }
        }
        while true {
            let snap=try await automationObserve(s,settle:s.wda != nil)
            let verdict=AutomationModel.verdict(nodes:snap["nodes"] as? [[String:Any]] ?? [],complete:snap["complete"] as? Bool == true,expectation:expectation)
            if verdict == "passed" || ProcessInfo.processInfo.systemUptime>=end {return(verdict,snap)}
            try await Task.sleep(nanoseconds:200_000_000)
        }
    }

    func automationCapture(_ s:AutomationSession) async throws -> [String:Any] {
        let path=s.store.root+"/.leap/sessions/"+s.id+"/"+UUID().uuidString+".png"
        let data:Data
        var meta:[String:Any]=["file":path,"type":"screenshot","session_id":s.id,"snapshot":s.latest?["snapshot"] ?? NSNull()]
        if let wda=s.wda {data=try await wda.screenshot();meta["coordinateSpace"]="device_screenshot_pixels"}
        else {let shot=try await screenshot(app:s.app,png:true,window:s.window);data=shot.data;meta["pointsPerPixel"]=shot.pointsPerPixel;meta["width"]=shot.pixelWidth;meta["height"]=shot.pixelHeight;meta["coordinateSpace"]="window_screenshot_pixels"}
        try data.write(to:URL(fileURLWithPath:path),options:.atomic)
        meta["bytes"]=data.count
        _ = try s.save("artifact",meta,interaction:recordingInteraction)
        return meta
    }

    func automationPerform(_ s:AutomationSession,args:[String:Any]) async throws -> String {
        guard let steps=args["steps"] as? [[String:Any]],!steps.isEmpty,steps.count<=50 else {throw AutomationModel.fail("steps must contain 1–50 objects")}
        // Validate every step before any input. Backend-specific capabilities are explicit.
        let allowed=s.backend == "mac_ax" ? Self.macActions:Self.deviceActions
        for (stepIndex,step) in steps.enumerated() {
            let stepKeys:Set<String>=["id","type","action","selector","arguments","before","expect","timeout","fields"]
            let unknown=Set(step.keys).subtracting(stepKeys)
            guard unknown.isEmpty else {throw AutomationModel.fail("Step \(stepIndex): unknown field(s) \(unknown.sorted()); allowed: \(stepKeys.sorted()). No input sent")}
            if step["fields"] != nil, step["type"] as? String != "observe" {throw AutomationModel.fail("Step \(stepIndex): fields applies to observe steps only. No input sent")}
            if let raw=step["selector"],!(raw is [String:Any]) {throw AutomationModel.fail("Selector must be object")}
            if let raw=step["arguments"],!(raw is [String:Any]) {throw AutomationModel.fail("Arguments must be object")}
            guard let type=step["type"] as? String,["action","assert","wait","observe","capture"].contains(type) else {throw AutomationModel.fail("Invalid step type")}
            if let selector=step["selector"] as? [String:Any] {
                do {try AutomationModel.validateSelector(selector)} catch {throw AutomationModel.fail("Step \(stepIndex): \(error)")}
            }
            for key in ["before","expect"] {if let value=step[key] {
                guard let e=value as? [String:Any] else {throw AutomationModel.fail("Step \(stepIndex): \(key) must be an object. No input sent")}
                do {try AutomationModel.validateExpectation(e)} catch {throw AutomationModel.fail("Step \(stepIndex) \(key): \(error)")}
            }}
            if ["assert","wait"].contains(type),step["expect"] == nil {throw AutomationModel.fail("assert/wait requires expect")}
            if type == "action" {
                guard let action=step["action"] as? String,allowed.contains(action) else {throw AutomationModel.fail("Unsupported action for \(s.backend); no steps sent")}
                let a=AutomationModel.object(step["arguments"])
                var keys:Set<String>
                switch action {
                case "click","double_click": keys=["x","y","snapshot","space"]
                case "drag":keys=["from_x","from_y","to_x","to_y","snapshot","space"]
                case "type_text","set_value":keys=["text"]
                case "press_key":keys=["key"]
                case "scroll":keys=["direction","observation_region"]
                case "rotate":keys=["orientation"]
                case "perform_action":keys=["name"]
                case "select_text":keys=["text","prefix","suffix","selection_type"]
                case "paste":keys=["text","html"]
                default:keys=[]
                }
                if s.backend == "mac_ax" {
                    keys.insert("foreground")
                    if ["click","double_click","drag"].contains(action) {keys.insert("modifiers")}
                    if ["click","double_click"].contains(action) {keys.insert("button")}
                    if action == "scroll" {keys.formUnion(["pages","x","y","snapshot","space"])}
                }
                guard Set(a.keys).isSubset(of:keys) else {throw AutomationModel.fail("Unsupported arguments \(Set(a.keys).subtracting(keys).sorted()) for \(s.backend) \(action); accepted: \(keys.sorted()). No input sent")}
                for (key,value) in a {
                    if ["x","y","from_x","from_y","to_x","to_y","snapshot","pages"].contains(key) {
                        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else {throw AutomationModel.fail("\(key) must be a finite number")}
                    } else if key == "observation_region" {
                        guard AutomationModel.coordinateBounds(value) != nil else {throw AutomationModel.fail("observation_region must be [x,y,width,height]")}
                    } else if key == "foreground" {
                        guard let number=value as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() else {throw AutomationModel.fail("foreground must be boolean")}
                    } else if !(value is String) {throw AutomationModel.fail("\(key) must be a string")}
                }
                if let button=a["button"] as? String,MouseButton(alias:button) == nil {throw AutomationModel.fail("Invalid mouse button")}
                if s.backend == "wda",action == "press_key",!["Return","Enter","Backspace","Tab"].contains(a["key"] as? String ?? "") {throw AutomationModel.fail("Unsupported device key; no steps sent")}
                if ["type_text","set_value","select_text","paste"].contains(action),!(a["text"] is String) {throw AutomationModel.fail("Step \(stepIndex): \(action) needs arguments.text. No input sent")}
                if ["perform_action","select_text"].contains(action),step["selector"] == nil {throw AutomationModel.fail("Step \(stepIndex): \(action) needs a selector. No input sent")}
                if action == "perform_action",(a["name"] as? String ?? "").isEmpty {throw AutomationModel.fail("Step \(stepIndex): perform_action needs arguments.name (an action listed on the element). No input sent")}
                if action == "select_text",let t=a["selection_type"] as? String,Engine.SelectionType(rawValue:t) == nil {throw AutomationModel.fail("Step \(stepIndex): selection_type must be text, cursor_before or cursor_after. No input sent")}
                if action == "scroll", !["up","down","left","right"].contains(a["direction"] as? String ?? "") {throw AutomationModel.fail("Scroll needs valid direction")}
                if action == "scroll",step["selector"] == nil, !(s.backend == "mac_ax" && a["x"] is NSNumber && a["y"] is NSNumber) {throw AutomationModel.fail("Scroll requires selector or Mac x/y with snapshot and space")}
                if action == "rotate", !["PORTRAIT","PORTRAIT_UPSIDEDOWN","LANDSCAPE","LANDSCAPE_RIGHT"].contains(a["orientation"] as? String ?? "") {throw AutomationModel.fail("Invalid orientation")}
                if action == "press_key",!(a["key"] is String) {throw AutomationModel.fail("press_key needs arguments.key")}
                if ["type_text","set_value"].contains(action),step["selector"] == nil {throw AutomationModel.fail("Text actions require selector")}
                if ["click","double_click"].contains(action),step["selector"] == nil,!(a["x"] is NSNumber && a["y"] is NSNumber) {throw AutomationModel.fail("Click needs selector or x/y")}
                if action == "drag", !["from_x","from_y","to_x","to_y"].allSatisfy({a[$0] is NSNumber}) {throw AutomationModel.fail("Drag needs from_x/from_y/to_x/to_y")}
            }
        }
        if let expected=args["expected_snapshot"] as? Int,expected != s.latest?["snapshot"] as? Int {throw AutomationModel.fail("Expected snapshot is no longer current; observe before acting")}
        let interaction=recordingInteraction ?? UUID().uuidString
        let started=ProcessInfo.processInfo.systemUptime
        let deadline=started+min(120,max(0.1,args["timeout"] as? Double ?? 60))
        var results:[[String:Any]]=[], stopped=false,overall="passed"
        for (i,step) in steps.enumerated() {
            var r:[String:Any]=["id":step["id"] ?? String(i),"index":i,"type":step["type"]!,"dispatch":"not_sent","verification":"not_evaluated","started_at":ISO8601DateFormatter().string(from:Date())]
            if stopped {r["execution"]="skipped";results.append(r);continue}
            var attempted=false
            var scrollBefore:[String:Any]?,scrollRegion:[Double]?,scrollRoot:String?
            var scrollErrors:[String]=[]
            do {
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw AutomationModel.fail("Workflow scheduling deadline exceeded")}
                if let health=s.store.health() {throw AutomationModel.fail("Recording unavailable: \(health)")}
                let type=step["type"] as! String
                // Waits and asserts are judged by the check itself (quick reads plus one evidence snapshot);
                // a full pre-observation with its post-action settle only delayed them.
                let judgedOnly=type == "wait" || type == "assert"
                var pre:[String:Any]=judgedOnly ? ["nodes":[[String:Any]](),"complete":false] : try await automationObserve(s)
                // Post-transition wait (~1 s + up to 5 s while state changes): a screen that is
                // still being built gives incomplete reads. Re-observe until complete within the step's
                // timeout; input is still never sent on an incomplete observation.
                if pre["complete"] as? Bool != true, step["selector"] != nil {
                    let settle=min(deadline,ProcessInfo.processInfo.systemUptime+min(10,max(1,step["timeout"] as? Double ?? 5)))
                    var reads=0
                    while pre["complete"] as? Bool != true,ProcessInfo.processInfo.systemUptime<settle {
                        try await Task.sleep(nanoseconds:250_000_000)
                        pre=try await automationObserve(s);reads+=1
                    }
                    r["observation_retries"]=reads
                }
                r["before_snapshot"]=pre["snapshot"]
                if let before=step["before"] as? [String:Any] {
                    let (v,snap)=try await automationCheck(s,expectation:before,timeout:min(5,max(0,deadline-ProcessInfo.processInfo.systemUptime)))
                    pre=snap;r["precondition"]=v
                    guard v == "passed" else {r["verification"]=v;throw AutomationModel.fail("Precondition not established; no input sent")}
                }
                if type == "action" {
                    let action=step["action"] as! String,a=AutomationModel.object(step["arguments"])
                    r["before_snapshot"]=pre["snapshot"]
                    let nodes=pre["nodes"] as? [[String:Any]] ?? []
                    var node:[String:Any]?
                    if let selector=step["selector"] as? [String:Any] {
                        var hits=nodes.filter{AutomationModel.matches($0,selector)}
                        if hits.count>1 {
                            // While a sheet is up, input cannot reach the window under
                            // a modal sheet, so prefer matches inside it.
                            let inSheet=hits.filter{($0["id"] as? String ?? "").contains("/AXSheet[")}
                            if !inSheet.isEmpty,inSheet.count<hits.count {hits=inSheet;r["disambiguated"]="modal sheet"}
                        }
                        if hits.count>1 {
                            // A disabled match cannot be the target of an action.
                            let enabled=hits.filter{$0["enabled"] as? Bool != false}
                            if enabled.count==1 {hits=enabled;r["disambiguated"]=(r["disambiguated"] as? String).map{$0+", only enabled match"} ?? "only enabled match"}
                        }
                        // No occlusion inference: probes showed SwiftUI's AX hit-test returns hidden-layer elements
                        // at visible controls (a hidden "Route library" at the editor's Cancel), so it can pick the
                        // wrong duplicate. Scope with within/root/role.
                        guard hits.count<=1 else {
                            let sample=hits.prefix(5).map{"\($0["role"] as? String ?? "?") \"\($0["label"] as? String ?? "")\" id=\($0["id"] as? String ?? "")"}.joined(separator:"; ")
                            throw AutomationModel.fail("Selector matches \(hits.count) elements (\(sample)); add role/id/root to make it unique. No input sent")
                        }
                        guard pre["complete"] as? Bool == true else {throw AutomationModel.fail("Observation incomplete (blocking read failures, deadline or truncation), so a unique match cannot be established; no input sent. Inspect ui_observe or the retained snapshot")}
                        guard AutomationModel.selectionReliable(nodes,selector) else {throw AutomationModel.fail("An element whose selector fields could not be read might also match; use id, role or root to disambiguate. No input sent")}
                        guard hits.count==1 else {throw AutomationModel.fail("No element matches the selector in a complete observation; no input sent")}
                        node=hits[0]
                        guard node?["enabled"] as? Bool != false else {throw AutomationModel.fail("Target disabled; no input sent")}
                        if s.wda == nil,let index=node?["index"] as? Int,let other=await hitTestReport(s.app,index) {
                            r["hit_test"]="At this control's center the accessibility hit-test reports \(other). The control may be covered by another layer, or the hit-test may be imprecise (SwiftUI). Check the outcome."
                        }
                    }
                    if action == "drag" || (["click","double_click","scroll"].contains(action) && node == nil) {
                        guard let baseline=a["snapshot"] as? Int,let prior=try automationStoredSnapshot(s,seq:baseline),
                              prior["coordinateSpace"] as? String == a["space"] as? String,
                              prior["coordinateSpace"] as? String == pre["coordinateSpace"] as? String,
                              AutomationModel.sameOrientation(prior,pre),
                              AutomationModel.sameBounds(prior["bounds"],pre["bounds"]),
                              prior["window"] as? String == pre["window"] as? String else {throw AutomationModel.fail("Coordinates require snapshot and space with unchanged window, bounds and orientation; no input sent")}
                        // As with a coordinate click, content may have changed since the snapshot (clocks,
                        // animations); only the geometric mapping must hold. The expectation judges the outcome.
                        guard let b=AutomationModel.coordinateBounds(pre["bounds"]) else {throw AutomationModel.fail("Coordinate bounds unavailable")}
                        let pairs=action == "drag" ? [("from_x","from_y"),("to_x","to_y")]:[("x","y")]
                        for (x,y) in pairs {guard let px=a[x] as? Double,let py=a[y] as? Double,px.isFinite,py.isFinite,px>=0,py>=0,px<b[2],py<b[3] else {throw AutomationModel.fail("Coordinate outside target bounds")}}
                    }
                    if action == "scroll", Diagnostics.shared.insightsEnabled {
                        if let raw=a["observation_region"] {
                            guard let region=ScrollEvidence.region(raw,bounds:pre["bounds"]) else {throw AutomationModel.fail("observation_region outside target bounds; no input sent")}
                            scrollRegion=region
                        }
                        scrollRoot=node?["id"] as? String
                        do {scrollBefore=try await automationCapture(s)} catch {
                            scrollErrors.append(String(describing:error))
                            Diagnostics.shared.record(level:"warning",kind:"scroll_evidence_failed",detail:String(describing:error))
                        }
                    }
                    _ = try s.save("intent",["step":i,"action":action,"dispatch":"not_sent","arguments":"omitted","snapshot":pre["snapshot"]!],interaction:interaction)
                    guard Diagnostics.shared.record(level:"info",kind:"automation_input_attempt",detail:"\(s.backend) \(action) step \(i)") != nil else {throw AutomationModel.fail("Diagnostics unavailable; no input sent")}
                    guard ProcessInfo.processInfo.systemUptime<deadline else {throw AutomationModel.fail("Workflow deadline reached before dispatch; no input sent")}
                    if let node {
                        r["target"] = node.filter { ["id","index","role","label","frame"].contains($0.key) }
                    }
                    r["action"] = action
                    attempted=true;r["dispatch"]="attempted"
                    r["input_result"] = try await automationInput(s,action:action,node:node,args:a)
                    if (r["input_result"] as? String ?? "").contains("cannotComplete (-25204)") {
                        r["ax_result"]="cannotComplete (-25204)";r["dispatch"]="uncertain"
                        r["side_effect_note"]="The accessibility action reported cannotComplete; it may have applied, possibly with side effects (e.g. unexpected navigation). The expectation below decides; never re-press."
                    }
                    r["acknowledgement"]="returned"
                }
                var post=pre
                if let expectation=step["expect"] as? [String:Any] {
                    // A pass on a condition that already held says nothing about the action's effect
                    // (e.g. a disabled inactive view still contains the target screen's controls).
                    if type == "action", AutomationModel.verdict(nodes:pre["nodes"] as? [[String:Any]] ?? [],complete:pre["complete"] as? Bool == true,expectation:expectation) == "passed" {
                        r["expectation_met_before"]=true
                        r["note"]="Expectation already held before input; a pass does not show the action's effect. Use a condition that distinguishes the new state (e.g. enabled, value, a unique label)."
                    }
                    let wait=type == "assert" ? 0:min(30,max(0,step["timeout"] as? Double ?? 5))
                    let checkStarted=ProcessInfo.processInfo.systemUptime
                    let (v,snap)=try await automationCheck(s,expectation:expectation,timeout:min(wait,max(0,deadline-ProcessInfo.processInfo.systemUptime)))
                    // Time spent judging the expectation; a failure screenshot taken afterwards is not part of it.
                    r["check_ms"]=Int((ProcessInfo.processInfo.systemUptime-checkStarted)*1000)
                    post=snap;r["verification"]=v
                    if v != "passed" {stopped=true;overall=v}
                } else if type == "action", Diagnostics.shared.insightsEnabled {post=try await automationObserve(s)}
                if type == "action",step["action"] as? String == "scroll",Diagnostics.shared.insightsEnabled {
                    let a=AutomationModel.object(step["arguments"])
                    let end=min(deadline,ProcessInfo.processInfo.systemUptime+0.8)
                    var samples=0
                    var effect:[String:Any]=[:]
                    repeat {
                        effect=ScrollEvidence.geometry(before:pre["nodes"] as? [[String:Any]] ?? [],after:post["nodes"] as? [[String:Any]] ?? [],region:scrollRegion,root:scrollRoot,direction:a["direction"] as? String ?? "down")
                        if effect["status"] as? String == "movement_observed" || ProcessInfo.processInfo.systemUptime>=end {break}
                        try await Task.sleep(nanoseconds:200_000_000)
                        post=try await automationObserve(s);samples += 1
                    } while samples<4
                    if pre["complete"] as? Bool != true || post["complete"] as? Bool != true || !AutomationModel.sameBounds(pre["bounds"],post["bounds"]) || !AutomationModel.sameOrientation(pre,post) {
                        effect["status"]="unverified";effect["reason"]="Incomplete observation or changed target geometry"
                    }
                    effect["additionalObservations"]=samples
                    effect["boundary"]="unknown"
                    effect["before_snapshot"]=pre["snapshot"];effect["after_snapshot"]=post["snapshot"]
                    if let scrollBefore {
                        effect["before_artifact"]=scrollBefore
                        do {
                            let after=try await automationCapture(s);effect["after_artifact"]=after
                            guard AutomationModel.sameBounds(pre["bounds"],post["bounds"]),AutomationModel.sameOrientation(pre,post) else {throw AutomationModel.fail("Scroll evidence target geometry changed")}
                            effect["visual"]=try ScrollEvidence.pixels(before:scrollBefore,after:after,region:scrollRegion,bounds:pre["bounds"])
                        } catch {
                            scrollErrors.append(String(describing:error))
                            Diagnostics.shared.record(level:"warning",kind:"scroll_evidence_failed",detail:String(describing:error))
                        }
                    }
                    if !scrollErrors.isEmpty {effect["errors"]=scrollErrors}
                    r["scroll_effect"]=effect
                }
                if type == "capture" {r["artifact"]=try await automationCapture(s)}
                // An observe step answers "what is there": return the matched elements themselves.
                if type == "observe", let selector=step["selector"] as? [String:Any] {
                    let hits=(pre["nodes"] as? [[String:Any]] ?? []).filter{AutomationModel.matches($0,selector)}
                    r["matched"]=hits.count
                    let wanted=Set((step["fields"] as? [String]) ?? ["index","id","role","label","value","enabled","selected","focused","frame","omittedChildren"])
                    r["items"]=hits.prefix(20).map{$0.filter{wanted.contains($0.key)}}
                }
                if !Diagnostics.shared.insightsEnabled && type == "action" && step["expect"] == nil {
                    r["insights"]="disabled; no automatic post-action observation or delta"
                } else { r["after_snapshot"]=post["snapshot"] }
                if judgedOnly {r["before_snapshot"]=nil}
                if Diagnostics.shared.insightsEnabled && !judgedOnly { r["delta"]=AutomationModel.delta(pre["nodes"] as? [[String:Any]] ?? [],post["nodes"] as? [[String:Any]] ?? [],complete:pre["complete"] as? Bool == true && post["complete"] as? Bool == true) }
                if type == "action", r["verification"] as? String == "failed", (r["delta"] as? [String:Any])?["totalChanges"] as? Int == 0,
                   AutomationModel.object(step["arguments"])["foreground"] as? Bool != true,
                   ["drag","scroll"].contains(step["action"] as? String ?? "") || (r["input_result"] as? String ?? "").contains("clicked") {
                    r["hint"]="Pointer input was dispatched in the background but no UI change was observed. Some apps (e.g. SwiftUI) ignore background pointer events; foreground:true activates the app first. Not replayed automatically."
                }
                r["execution"]="completed"
            } catch {
                let overallBefore=overall
                stopped=true;overall="unknown";r["execution"]="failed";r["error"]=String(describing:error)
                if attempted {r["dispatch"]="uncertain"}
                if r["verification"] as? String == "not_evaluated" {r["verification"]="unknown"}
                Diagnostics.shared.record(level:"error",kind:"automation_step_failed",detail:String(describing:error))
                if attempted,let expectation=step["expect"] as? [String:Any] {
                    // The input API answered with an error, but it may have applied. Let the expectation decide: if it passes, the workflow continues
                    // and the record keeps dispatch "uncertain" plus the raw error. Never replay.
                    do {
                        let wait=min(30,max(0,step["timeout"] as? Double ?? 5))
                        let (v,post)=try await automationCheck(s,expectation:expectation,timeout:min(wait,max(0,deadline-ProcessInfo.processInfo.systemUptime)))
                        r["after_snapshot"]=post["snapshot"];r["verification"]=v
                        if v == "passed" {
                            stopped=false;overall=overallBefore;r["execution"]="completed"
                            r["dispatch_error"]=r["error"];r["error"]=nil
                            r["note"]="The input call reported an error, but the expected outcome was observed. Dispatch stays uncertain; check for side effects."
                        }
                    } catch {r["observation_error"]=String(describing:error)}
                } else if Diagnostics.shared.insightsEnabled { do {
                    let post=try await automationObserve(s);r["after_snapshot"]=post["snapshot"]
                } catch {r["observation_error"]=String(describing:error)} }
            }
            if stopped && Diagnostics.shared.insightsEnabled {do {r["failure_artifact"]=try await automationCapture(s)} catch {r["capture_error"]=String(describing:error)}}
            r["finished_at"]=ISO8601DateFormatter().string(from:Date())
            _ = try s.save("step",r,interaction:interaction)
            results.append(r)
        }
        let hasAssertions=results.contains{$0["verification"] as? String != "not_evaluated"}
        let result:[String:Any]=["schemaVersion":2,"session_id":s.id,"interaction_id":interaction,"execution":stopped ? "stopped":"completed","verification":hasAssertions ? overall:"not_evaluated","steps":results,"duration_ms":Int((ProcessInfo.processInfo.systemUptime-started)*1000),"inputReplay":"never","deadlineOverrun":ProcessInfo.processInfo.systemUptime>deadline]
        let (_,file)=try s.save("result",result,interaction:interaction)
        return try AutomationModel.bounded(result,budget:16000,file:file)
    }

    func automationStoredSnapshot(_ s:AutomationSession,seq:Int) throws -> [String:Any]? {
        let e=try Evidence(project:s.store.root)
        guard let row=try e.rows("SELECT payload FROM records WHERE seq=? AND session=? AND kind='automation_snapshot'",[String(seq),s.id]).first,let payload=row["payload"] as? String else {return nil}
        return try JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any]
    }

    /// What the accessibility hit-test reports at the target's center when that is not the target, one of
    /// its descendants or a close container. Reported, never used to refuse or choose: SwiftUI hit-tests can
    /// return hidden-layer elements at visible controls (probe: a hidden "Route library" at the visible
    /// editor Cancel), but for a covered control they usually name what covers it.
    func hitTestReport(_ app:String,_ index:Int) async -> String? {
        guard let native=try? await session(for:app,launch:false),let rec=try? native.element(index),
              !rec.node.offscreen,!rec.node.untransformedFrame,let frame=AX.frame(rec.node.element),frame.width>0,frame.height>0 else {return nil}
        func reaches(_ hit:AXUIElement) -> Bool {
            var current:AXUIElement?=hit
            for _ in 0..<40 {guard let c=current else {break};if CFEqual(c,rec.node.element) {return true};current=AX.attr(c,kAXParentAttribute)}
            var up:AXUIElement?=AX.attr(rec.node.element,kAXParentAttribute)
            for _ in 0..<3 {guard let u=up else {break};if CFEqual(u,hit) {return true};up=AX.attr(u,kAXParentAttribute)}
            return false
        }
        // SwiftUI's hit-test can return a hidden layer at one point of a visible, topmost control
        // (the editor's Cancel reported the header's "Route library" at its center). Probe the
        // center and four interior points; if any reaches the target, it is not reported covered.
        // A control covered by an opaque layer (Create scenario under the notes editor) misses at all.
        var centerHit:AXUIElement?
        for (fx,fy) in [(0.5,0.5),(0.25,0.25),(0.75,0.25),(0.25,0.75),(0.75,0.75)] {
            var hit:AXUIElement?
            let x=frame.minX+frame.width*fx, y=frame.minY+frame.height*fy
            guard AXUIElementCopyElementAtPosition(native.axApp,Float(x),Float(y),&hit) == .success,let hit else {continue}
            if reaches(hit) {return nil}
            if centerHit == nil {centerHit=hit}
        }
        guard let hit=centerHit else {return nil}
        let role:String=AX.attr(hit,kAXRoleAttribute) ?? "?"
        let label:String=AX.attr(hit,kAXTitleAttribute) ?? AX.attr(hit,kAXDescriptionAttribute) ?? AX.attr(hit,kAXPlaceholderValueAttribute) ?? ""
        return "\(role) \"\(label.prefix(60))\""
    }

    func automationInput(_ s:AutomationSession,action:String,node:[String:Any]?,args:[String:Any]) async throws -> String {
        if let wda=s.wda {var a=args;a["app"]=s.app;try await wda.action(action,node:node,args:a);return "WebDriverAgent acknowledged \(action); effect requires verification"}
        let index=node?["index"] as? Int
        // The element behind the index must be the observed target: same identity key and label.
        if let index,let node,s.wda == nil {
            let native=try await session(for:s.app,launch:false)
            // Resolve the target again from a fresh read immediately before input (find and press in one
            // pass, validating element identity): SwiftUI can replace
            // a control during a transition, and pressing the earlier reference can silently do nothing.
            let fresh=try await automationQuickRead(s)
            guard let freshNode=fresh.snap.nodes.first(where:{$0.key == node["id"] as? String}) else {
                throw AutomationModel.fail("Target \"\(node["label"] as? String ?? "")\" is not present in a fresh read just before input (the screen changed). No input sent; observe again")
            }
            native.refresh(index,with:freshNode)
            let rec=try native.element(index)
            let label=rec.node.title ?? rec.node.description ?? rec.node.placeholder ?? ""
            guard rec.node.key == node["id"] as? String, label == node["label"] as? String ?? "" else {
                throw AutomationModel.fail("Target identity changed between observation and dispatch: selected \"\(node["label"] as? String ?? "")\" (\(node["id"] as? String ?? "")) but index \(index) is \"\(label)\" (\(rec.node.key)). No input sent; observe again")
            }
        }
        let target=Target(elementIndex:index,x:(args["x"] as? Double).map { CGFloat($0) },y:(args["y"] as? Double).map { CGFloat($0) })
        let mode=InputMode(foreground:args["foreground"] as? Bool ?? false)
        switch action {
        case "click","double_click":return try await click(app:s.app,target:target,button:MouseButton(alias:args["button"] as? String ?? "left") ?? .left,count:action == "double_click" ? 2:1,modifiers:args["modifiers"] as? String,mode:mode)
        case "type_text":return try await typeText(app:s.app,text:args["text"] as? String ?? "",elementIndex:index,mode:mode)
        case "set_value":guard let index else {throw AutomationModel.fail("set_value requires selector")};return try await setValue(app:s.app,elementIndex:index,value:args["text"] as? String ?? "",mode:mode)
        case "press_key":return try await pressKey(app:s.app,key:args["key"] as? String ?? "",mode:mode)
        case "scroll":return try await scroll(app:s.app,target:target,direction:args["direction"] as? String ?? "down",pages:args["pages"] as? Double ?? 1,mode:mode)
        case "drag":return try await drag(app:s.app,from:Target(x:(args["from_x"] as? Double).map { CGFloat($0) },y:(args["from_y"] as? Double).map { CGFloat($0) }),to:Target(x:(args["to_x"] as? Double).map { CGFloat($0) },y:(args["to_y"] as? Double).map { CGFloat($0) }),modifiers:args["modifiers"] as? String,mode:mode)
        case "activate":return try await activate(app:s.app)
        case "perform_action":guard let index else {throw AutomationModel.fail("perform_action requires selector")};return try await performAction(app:s.app,elementIndex:index,action:args["name"] as? String ?? "")
        case "select_text":
            guard let index else {throw AutomationModel.fail("select_text requires selector")}
            return try await selectText(app:s.app,elementIndex:index,text:args["text"] as? String ?? "",prefix:args["prefix"] as? String,suffix:args["suffix"] as? String,selection:Engine.SelectionType(rawValue:args["selection_type"] as? String ?? "text") ?? .text)
        case "paste":return try await paste(app:s.app,text:args["text"] as? String ?? "",html:args["html"] as? String,mode:mode)
        default:throw AutomationModel.fail("Unsupported action")
        }
    }
}
