// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import ApplicationServices

/// Shared workflow contract (selectors, expectations, verdicts). JSON stays at the adapter boundary; selectors and verdicts are
/// evaluated identically for Mac AX and XCTest observations.
public enum AutomationModel {
    static func sameOrientation(_ before:[String:Any],_ after:[String:Any]) -> Bool {
        guard before["orientation"] as? String == after["orientation"] as? String else {return false}
        if before["backend"] as? String == "wda" || after["backend"] as? String == "wda" {
            guard before["orientationStable"] as? Bool == true, after["orientationStable"] as? Bool == true,
                  let a=before["orientationIdentity"] as? String,!a.isEmpty,
                  let b=after["orientationIdentity"] as? String else {return false}
            return a == b
        }
        return true
    }
    static func fail(_ message: String) -> LeapError { .unsupported(message) }
    static func object(_ value: Any?) -> [String:Any] { value as? [String:Any] ?? [:] }
    static func role(_ value: String) -> String {
        value.replacingOccurrences(of:"XCUIElementType",with:"").replacingOccurrences(of:"AX",with:"").lowercased()
    }
    static let selectorKeys: Set<String> = ["id","identifier","role","label","contains","root","within"]
    static func validateSelector(_ selector: [String:Any]) throws {
        let unknown=Set(selector.keys).subtracting(selectorKeys)
        guard unknown.isEmpty else {throw fail("Invalid selector key(s) \(unknown.sorted()); use id, identifier, role, label, contains, root (ancestor id) or within (ancestor label)")}
        let nonString=selector.filter{!($0.value is String)}.keys.sorted()
        guard nonString.isEmpty else {throw fail("Selector values must be strings: \(nonString)")}
    }
    /// True when an id's final component is "Role[label]#ordinal" with exactly this label.
    static func ownLabel(of id:String,is label:String) -> Bool {
        guard let r=id.range(of:"[\(label)]#",options:.backwards) else {return false}
        let rest=id[r.upperBound...]
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    static func matches(_ node: [String:Any], _ selector: [String:Any]) -> Bool {
        for key in ["id","identifier","label"] {
            if let wanted=selector[key] as? String, node[key] as? String != wanted {return false}
        }
        if let r=selector["role"] as? String, role(node["role"] as? String ?? "") != role(r) {return false}
        if let text=selector["contains"] as? String,
           !((node["label"] as? String ?? "")+" "+(node["value"] as? String ?? "")).localizedCaseInsensitiveContains(text) {return false}
        // Ids are paths, so any container id (rendered or elided) scopes by prefix.
        if let root=selector["root"] as? String, node["id"] as? String != root,
           !(node["id"] as? String ?? "").hasPrefix(root+"/"),
           !(node["ancestors"] as? [String] ?? []).contains(root) {return false}
        // Scope by an ancestor's own label (ids end in "[label]#ordinal") so agents need not
        // reconstruct full-path ids: {"role":"AXTextArea","within":"Release notes"}.
        if let within=selector["within"] as? String,
           !(node["ancestors"] as? [String] ?? []).contains(where:{ownLabel(of:$0,is:within)}) {return false}
        return true
    }
    /// Missing optional metadata must not block unrelated controls or prove absence.
    static func selectionReliable(_ nodes:[[String:Any]],_ selector:[String:Any]) -> Bool {
        for node in nodes {
            let missing=Set(node["unavailableFields"] as? [String] ?? [])
            var relevant=Set(selector.keys).intersection(missing)
            if selector["contains"] != nil && !missing.isDisjoint(with:["label","value"]) {relevant.insert("contains")}
            if relevant.isEmpty {continue}
            let known=selector.filter{!relevant.contains($0.key)}
            if matches(node,known) {return false}
        }
        return true
    }
    static let conditions: Set<String> = ["exists","absent","enabled","disabled","selected","value_equals","value_contains","count"]
    static func validateExpectation(_ expectation: [String:Any]) throws {
        guard Set(expectation.keys).isSubset(of:["selector","condition","value"]),
              let condition=expectation["condition"] as? String, conditions.contains(condition),
              let selector=expectation["selector"] as? [String:Any] else {throw fail("Expectation needs condition and selector")}
        try validateSelector(selector)
        if condition.hasPrefix("value_") && !(expectation["value"] is String) {throw fail("Value assertion needs a string value")}
        if condition == "count" && !(expectation["value"] is Int) {throw fail("Count assertion needs integer value")}
    }
    static func verdict(nodes: [[String:Any]], complete: Bool, expectation: [String:Any]) -> String {
        let hits=nodes.filter {matches($0,object(expectation["selector"]))}
        let condition=expectation["condition"] as? String ?? ""
        // Incomplete reads cannot establish exhaustive counts, uniqueness or absence, but an observed match
        // is positive evidence: it proves `exists`, disproves `absent`, and a unique match whose state
        // satisfies a positive condition proves it. A failing state stays unknown (the target may be unseen).
        if !complete || !selectionReliable(nodes,object(expectation["selector"])) {
            guard !hits.isEmpty else {return "unknown"}
            switch condition {
            case "exists": return "passed"
            case "absent": return "failed"
            case "count": return "unknown"
            default:
                guard hits.count == 1 else {return "unknown"}
                return verdict(nodes:hits,complete:true,expectation:expectation) == "passed" ? "passed":"unknown"
            }
        }
        // Rows of long lists that were not read could hold a match: no absence/count claims there.
        let unread=nodes.contains {n in
            guard (n["omittedChildren"] as? Int ?? 0)>0 else {return false}
            guard let root=object(expectation["selector"])["root"] as? String else {return true}
            return n["id"] as? String == root || (n["ancestors"] as? [String] ?? []).contains(root)
        }
        switch condition {
        case "exists": return hits.isEmpty ? (unread ? "unknown":"failed"):"passed"
        case "absent": return hits.isEmpty ? (unread ? "unknown":"passed"):"failed"
        case "count": return unread ? "unknown" : (hits.count == expectation["value"] as? Int ? "passed":"failed")
        default: break
        }
        guard hits.count == 1 else {return hits.isEmpty ? "failed":"unknown"}
        let n=hits[0]
        // A field whose read failed defaults in the tree (e.g. enabled=true); never judge it.
        let missing=Set(n["unavailableFields"] as? [String] ?? [])
        let field=condition.hasPrefix("value_") ? "value" : (condition == "disabled" ? "enabled" : condition)
        if missing.contains(field) {return "unknown"}
        switch condition {
        case "enabled","disabled","selected":
            guard let value=n[condition == "disabled" ? "enabled":condition] as? Bool else {return "unknown"}
            return value == (condition != "disabled") ? "passed":"failed"
        case "value_equals","value_contains":
            guard let value=n["value"] as? String, n["valueLimited"] as? Bool != true else {return "unknown"}
            let wanted=expectation["value"] as? String ?? ""
            return (condition == "value_equals" ? value == wanted:value.contains(wanted)) ? "passed":"failed"
        default: return "unknown"
        }
    }
    static func coordinateBounds(_ value:Any?) -> [Double]? {
        // Mac observations contain CGFloat arrays; persisted JSON contains NSNumber.
        // Normalize both at the boundary instead of casting a live array to Double.
        guard let values=value as? [NSNumber],values.count==4,
              values.allSatisfy({CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite}) else {return nil}
        let result=values.map(\.doubleValue)
        guard result[2]>0,result[3]>0 else {return nil}
        return result
    }
    static func sameBounds(_ lhs:Any?, _ rhs:Any?) -> Bool {
        guard let a=coordinateBounds(lhs),let b=coordinateBounds(rhs) else {return false}
        return a == b
    }
    static func delta(_ before: [[String:Any]], _ after: [[String:Any]], complete: Bool) -> [String:Any] {
        func keyed(_ nodes: [[String:Any]]) -> [String:[String:Any]] {
            var result: [String:[String:Any]]=[:]
            for n in nodes {if let id=n["id"] as? String {result[id]=n}}
            return result
        }
        let old=keyed(before), new=keyed(after)
        // Deltas are read on every action: carry what identifies and describes a node,
        // not its ancestry/action lists (those stay in the retained snapshot).
        // Compact like "+ 153 button Cancel": identity plus only non-default state.
        func summary(_ n:[String:Any]) -> [String:Any] {
            var out=n.filter { ["index","role","label","value"].contains($0.key) }
            if n["enabled"] as? Bool == false {out["enabled"]=false}
            for k in ["selected","focused","offscreen"] where n[k] as? Bool == true {out[k]=true}
            return out
        }
        var changes:[[String:Any]]=[]
        var notObserved=0
        for id in Set(old.keys).union(new.keys).sorted() {
            if old[id] == nil {changes.append(["id":id,"change":"added","after":summary(new[id]!)])}
            else if new[id] == nil {
                // An incomplete scan cannot prove removal; count instead of listing noise.
                if complete {changes.append(["id":id,"change":"removed"])} else {notObserved += 1}
            }
            else {
                var fields:[String:Any]=[:]
                for k in ["label","value","enabled","selected","focused","frame","offscreen"] {
                    if String(describing:old[id]![k]) != String(describing:new[id]![k]) {
                        fields[k]=["before":old[id]![k] ?? NSNull(),"after":new[id]![k] ?? NSNull()]
                    }
                }
                // Geometry of elements whose coordinates are unreliable (offscreen/rotated) is noise.
                if old[id]!["offscreen"] as? Bool == true && new[id]!["offscreen"] as? Bool == true {fields["frame"]=nil}
                if !fields.isEmpty {changes.append(["id":id,"change":"changed","fields":fields])}
            }
        }
        var result:[String:Any]=["changes":Array(changes.prefix(12)),"totalChanges":changes.count,"omitted":max(0,changes.count-12),"complete":complete,"meaning":"Observed differences, not causal attribution; IDs can churn"]
        if notObserved > 0 {result["notObserved"]=notObserved}
        return result
    }
    /// Budget applies to the complete envelope. A full retained object is available by file.
    static func bounded(_ value: [String:Any], budget: Int, file: String) throws -> String {
        let full=try RecordingStore.json(value)
        if full.utf8.count <= budget {return full}
        var result:[String:Any]=["schemaVersion":2,"omittedFromResponse":true,"bytes":full.utf8.count,"file":file,"hint":"Read retained JSON or use ui_observe with snapshot and narrower fields/selector"]
        for key in ["session_id","interaction_id","snapshot","execution","verification","error","hasMore","nextCursor"] {result[key]=value[key]}
        return try RecordingStore.json(result)
    }
}

final class AutomationSession {
    let id:String, app:String, backend:String, store:RecordingStore
    var window:String?
    /// Opened with an explicit window: identity is enforced. Otherwise the session follows the key
    /// window (a sheet opening/closing is reported, not an error).
    let explicitWindow:Bool
    var windowIdentity:AXUIElement?
    let pid:pid_t?
    var wda:WDAClient?
    var latest:[String:Any]?
    init(id:String,app:String,backend:String,window:String?,store:RecordingStore,pid:pid_t?) {
        self.id=id; self.app=app; self.backend=backend; self.window=window; self.store=store; self.pid=pid
        self.explicitWindow=window != nil
    }
    func save(_ kind:String,_ value:[String:Any],interaction:String?) throws -> (Int,String) {
        let seq=try store.append(session:id,interaction:interaction,kind:"automation_"+kind,payload:value)
        let path=store.root+"/.leap/sessions/"+id+"/\(seq)-\(kind).json"
        try RecordingStore.json(value).write(toFile:path,atomically:true,encoding:.utf8)
        return (Int(seq),path)
    }
}
