// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation

/// Direct, local-only WebDriverAgent transport. No automatic network/input retry.
final class WDAClient {
    let endpoint:URL
    var sessionID:String = ""
    var appID:String = ""
    var deviceIdentity:String = ""
    init(endpoint:String) throws {
        guard let url=URL(string:endpoint), url.scheme == "http",
              ["127.0.0.1","localhost","::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {throw AutomationModel.fail("WDA endpoint must be a local HTTP origin with explicit port")}
        guard url.port != nil else {throw AutomationModel.fail("WDA endpoint requires port")}
        self.endpoint=url
    }
    func request(_ method:String,_ path:String,_ body:[String:Any]? = nil) async throws -> Any {
        guard let url=URL(string:endpoint.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+path) else {throw AutomationModel.fail("Invalid backend URL")}
        var req=URLRequest(url:url);req.httpMethod=method;req.timeoutInterval=20
        if let body {req.httpBody=try JSONSerialization.data(withJSONObject:body); req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        let (data,response)=try await URLSession.shared.data(for:req)
        guard data.count<=32*1024*1024 else {throw AutomationModel.fail("WDA response exceeds 32 MiB acquisition limit")}
        let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        let value=json["value"] ?? json
        if (response as? HTTPURLResponse)?.statusCode != 200 || (value as? [String:Any])?["error"] != nil {
            let message=(value as? [String:Any])?["message"] as? String ?? "Backend request failed"
            throw AutomationModel.fail("WDA \(method) \(path): \(String(message.prefix(1000)))")
        }
        return value
    }
    func open(app:String) async throws {
        let reply=try await request("POST","/session",["capabilities":["alwaysMatch":["bundleId":app,"forceAppLaunch":false,"shouldTerminateApp":false,"waitForIdleTimeout":2.0]]])
        guard let id=(reply as? [String:Any])?["sessionId"] as? String else {throw AutomationModel.fail("WDA session response lacks sessionId")}
        sessionID=id;appID=app
        let info=try await call("GET","/wda/device/info") as? [String:Any] ?? [:]
        deviceIdentity=info["uuid"] as? String ?? ""
        guard !deviceIdentity.isEmpty,deviceIdentity != "unknown" else {throw AutomationModel.fail("WDA device identity unavailable")}
        try await verifyTarget()
    }
    func verifyTarget() async throws {
        let info=try await call("GET","/wda/device/info") as? [String:Any] ?? [:]
        guard info["uuid"] as? String == deviceIdentity else {throw AutomationModel.fail("WDA device changed; no input sent")}
        let active=try await call("GET","/wda/activeAppInfo") as? [String:Any] ?? [:]
        guard active["bundleId"] as? String == appID else {throw AutomationModel.fail("WDA active application differs from selected guest app; no input sent")}
    }
    func call(_ method:String,_ path:String,_ body:[String:Any]? = nil) async throws -> Any {
        try await request(method,"/session/"+sessionID+path,body)
    }
    static func orientationValue(_ value:String) throws -> String {
        switch value {
        case "PORTRAIT", "LANDSCAPE": return value
        case "LANDSCAPE_RIGHT": return "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT"
        case "PORTRAIT_UPSIDEDOWN": return "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN"
        default: throw AutomationModel.fail("Unsupported device orientation")
        }
    }
    // /orientation deliberately collapses opposite directions in WDA. Retain both
    // interface rotation and physical device orientation for coordinate provenance.
    func orientationIdentity() async throws -> String {
        guard let rotation=try await call("GET","/rotation") as? [String:Any],
              let x=rotation["x"] as? Int,let y=rotation["y"] as? Int,let z=rotation["z"] as? Int,
              [0,90,180,270].contains(x),[0,90,180,270].contains(y),[0,90,180,270].contains(z),
              let device=try await call("GET","/wda/deviceOrientation") as? String,
              !device.isEmpty,device != "UIDeviceOrientationUnknown" else {
            throw AutomationModel.fail("WDA exact orientation unavailable; observation not safe for targeting")
        }
        return "interface:\(x),\(y),\(z);device:\(device)"
    }
    func observe() async throws -> [String:Any] {
        try await verifyTarget()
        let orientation=try await call("GET","/orientation")
        let orientationBefore=try await orientationIdentity()
        let tree=try await call("GET","/source?format=json")
        guard let root=tree as? [String:Any] else {throw AutomationModel.fail("WDA JSON source missing root")}
        var nodes:[[String:Any]]=[];var truncated=false
        func walk(_ raw:[String:Any],_ path:String,_ ancestors:[String]) {
            guard nodes.count<5000, ancestors.count<80 else {truncated=true;return}
            var n:[String:Any]=["id":path,"role":raw["type"] ?? "other","label":raw["label"] as? String ?? "","ancestors":ancestors,"depth":ancestors.count]
            n["identifier"]=raw["rawIdentifier"] as? String
            if let v=raw["value"], !(v is NSNull) {n["value"]=(v as? String) ?? String(describing:v)}
            for key in ["enabled","visible","focused","selected"] {
                let val=raw[key] ?? raw["is"+key.prefix(1).uppercased()+key.dropFirst()]
                if let b=val as? Bool {n[key]=b}
                else if let s=val as? String,["0","1","true","false"].contains(s) {n[key]=(s == "1" || s == "true")}
            }
            if let rect=raw["rect"] as? [String:Any] {n["frame"]=[rect["x"] ?? 0,rect["y"] ?? 0,rect["width"] ?? 0,rect["height"] ?? 0]}
            nodes.append(n)
            for (i,child) in (raw["children"] as? [[String:Any]] ?? []).enumerated() {walk(child,path+".\(i)",ancestors+[path])}
        }
        walk(root,"0",[])
        let orientationAfter=try await orientationIdentity()
        return ["deviceIdentity":deviceIdentity,"app":appID,"orientation":orientation,"orientationIdentity":orientationAfter,"orientationStable":orientationBefore == orientationAfter,"nodes":nodes,"complete":!truncated && orientationBefore == orientationAfter,"coordinateSpace":"device_points","bounds":nodes.first?["frame"] ?? [],"limitations":["XCTest accessibility projection; custom canvas content may be absent","selected may be unavailable; backend nodes are not durable handles"]]
    }
    func element(_ node:[String:Any]) async throws -> String {
        func quoted(_ s:String) -> String {"'"+s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'")+"'"}
        let role=node["role"] as? String ?? ""
        let type=role.hasPrefix("XCUIElementType") ? role:"XCUIElementType"+role
        var clauses=["type == "+quoted(type)]
        if let id=node["identifier"] as? String,!id.isEmpty {clauses.append("name == "+quoted(id))}
        else if let label=node["label"] as? String,!label.isEmpty {clauses.append("label == "+quoted(label))}
        else if role.isEmpty || role == "Any" {throw AutomationModel.fail("WDA action needs a specific role/name or explicit device coordinates")}
        let value=try await call("POST","/elements",["using":"predicate string","value":clauses.joined(separator:" AND ")])
        guard let hits=value as? [[String:Any]],hits.count==1,
              let id=(hits[0]["element-6066-11e4-a52e-4f735466cecf"] ?? hits[0]["ELEMENT"]) as? String else {throw AutomationModel.fail("WDA fresh selector is missing or ambiguous; no input sent")}
        return id
    }
    func action(_ action:String,node:[String:Any]?,args:[String:Any]) async throws {
        try await verifyTarget()
        switch action {
        case "activate": _ = try await call("POST","/wda/apps/activate",["bundleId":args["app"] ?? ""])
        case "click","double_click":
            if let node {
                let id=try await element(node)
                _ = try await call("POST",action == "click" ? "/element/\(id)/click":"/wda/element/\(id)/doubleTap",[:])
            } else {_ = try await call("POST",action == "click" ? "/wda/tap":"/wda/doubleTap",["x":args["x"] ?? 0,"y":args["y"] ?? 0])}
        case "type_text":
            guard let node else {throw AutomationModel.fail("WDA type_text requires selector")}
            let id=try await element(node)
            _ = try await call("POST","/element/\(id)/value",["value":[args["text"] as? String ?? ""]])
        case "scroll":
            guard let node else {throw AutomationModel.fail("WDA scroll needs selector for scroll container")}
            let id=try await element(node)
            _ = try await call("POST","/wda/element/\(id)/scroll",["direction":args["direction"] ?? "down"])
        case "rotate":
            _ = try await call("POST","/orientation",["orientation":try Self.orientationValue(args["orientation"] as? String ?? "")])
        case "press_key":
            let keys=["Return":"\n","Enter":"\n","Backspace":"\u{8}","Tab":"\t"]
            guard let key=keys[args["key"] as? String ?? ""] else {throw AutomationModel.fail("WDA supports Return, Enter, Backspace, Tab; other keys unsupported")}
            _ = try await call("POST","/wda/keys",["value":[key]])
        case "drag":
            _ = try await call("POST","/wda/dragfromtoforduration",["fromX":args["from_x"] ?? 0,"fromY":args["from_y"] ?? 0,"toX":args["to_x"] ?? 0,"toY":args["to_y"] ?? 0,"duration":0.3])
        default: throw AutomationModel.fail("Action unsupported by WDA adapter: \(action)")
        }
    }
    func screenshot() async throws -> Data {
        guard let value=try await call("GET","/screenshot") as? String,let data=Data(base64Encoded:value) else {throw AutomationModel.fail("Invalid WDA screenshot")}
        return data
    }
}
