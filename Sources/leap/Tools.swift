// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import LeapCore
import MCP

// MARK: - Schema helpers

private func prop(_ type: String, _ description: String, enumValues: [String]? = nil) -> Value {
    var v: [String: Value] = ["type": .string(type)]
    if !description.isEmpty { v["description"] = .string(description) }
    if let enumValues { v["enum"] = .array(enumValues.map { .string($0) }) }
    return .object(v)
}

private func schema(_ props: [String: Value], required: [String] = []) -> Value {
    .object([
        "type": "object",
        "properties": .object(props),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": false,
    ])
}

private let appProp = prop("string", "App name, bundle id or .app path; launched in the background if not running.")
private let foregroundProp = prop("boolean", "True brings the app to the front (interrupts the user); only when background input had no effect.")
private let thenStateProp = prop("boolean", "False skips the returned state.")

private let labelProp = prop("string", "Instead of element_index: visible text or id; exact match first, else a unique substring.")

private let targetProps: [String: Value] = [
    "element_index": prop("integer", "Index from the latest state ([42] → 42); preferred over x/y."),
    "label": labelProp,
    "x": prop("number", "Window points; relative to the element if element_index is set."),
    "y": prop("number", "Window points."),
]

// MARK: - Tool definitions

enum LeapTools {
    static let all: [Tool] = [
        Tool(name:"evidence_read",description:"Read a stored workflow record, or one nested field, as raw text in chunks (no JSON escaping). path: object keys and array indices.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"session_id":prop("string",""),"record":prop("integer","Record or snapshot number."),"path":.object(["type":.string("array"),"items":.object(["type":.string("string")])]),"offset":prop("integer","Characters."),"max_bytes":prop("integer","Chunk size 128–8000, default 4000.")],required:["session_id","record"]),annotations:.init(readOnlyHint:true)),
        Tool(name:"target_list",description:"List Mac apps and Simulator devices for session_open, with backend support and readiness.",inputSchema:schema([:]),annotations:.init(readOnlyHint:true)),
        Tool(name:"session_open",description:"Start a workflow session for ui_observe/ui_perform: mac_ax (Mac app) or wda (iOS app via local XCTest runner). No backend fallback or data reset.",inputSchema:schema(["project":prop("string","Existing absolute project path."),"app":prop("string","Mac app, or iOS bundle id for wda."),"backend":prop("string","Default mac_ax.",enumValues:["mac_ax","wda"]),"window":prop("string","Mac window title."),"endpoint":prop("string","Local WDA URL with port (scripts/wda.py).")],required:["project","app"])),
        Tool(name:"session_close",description:"End a workflow session; history is kept, the app runs on.",inputSchema:schema(["session_id":prop("string","")],required:["session_id"])),
        Tool(name:"ui_inspect",description:"Raw accessibility attributes, actions and parents of matched elements, to tell app bugs from Leap's. Read-only.",inputSchema:schema(["session_id":prop("string","mac_ax session."),"selector":prop("object","As ui_observe."),"limit":prop("integer","1–10, default 3.")],required:["session_id","selector"])),
        Tool(name:"ui_observe",description:"Query a workflow session's UI (fresh or a retained snapshot) as JSON by selector, with field choice and paging.",inputSchema:schema(["session_id":prop("string",""),"project":prop("string","For history after a restart."),"snapshot":prop("integer","Omit for fresh."),"selector":prop("object","Exact id, identifier, role or label; contains; root (ancestor id); within (ancestor label)."),"fields":.object(["type":.string("array"),"items":.object(["type":.string("string")])]),"depth":prop("integer","Max depth below the match."),"after":prop("integer","Paging cursor."),"limit":prop("integer","1–100, default 20."),"max_bytes":prop("integer","Response budget 2048–32000.")],required:["session_id"])),
        Tool(name:"ui_perform",description:"Run 1–50 workflow steps, each re-targeted fresh, with optional before (precondition) and expect (check). Stops at the first failure or unknown outcome; input is never replayed. Step: {type: action|wait|assert|observe|capture, action, selector, arguments, before, expect, timeout}. Selector as ui_observe. Expect: {selector, condition: exists|absent|enabled|disabled|selected|value_equals|value_contains|count, value}. Actions: session_open capabilities. Coordinates need arguments.snapshot and space from an observation.",inputSchema:schema(["session_id":prop("string",""),"steps":.object(["type":.string("array"),"items":.object(["type":.string("object")])]),"timeout":prop("number","Seconds, max 120; OS calls may overrun."),"expected_snapshot":prop("integer","Refuse if this snapshot is stale.")],required:["session_id","steps"])),
        Tool(name:"session_history",description:"Read stored workflow results, also after a restart. kind: automation_result (default), automation_step or automation_intent.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"session_id":prop("string","Filter."),"kind":prop("string",""),"after":prop("integer","Paging cursor."),"limit":prop("integer","Default 10.")]),annotations:.init(readOnlyHint:true)),
        Tool(name:"interaction_timeline",description:"List recorded interactions in time order, with snapshot references and input counts. Paged; pass through from the first page back.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"session_id":prop("string","Filter."),"group_id":prop("string","Filter by group."),"after":prop("integer","Paging cursor."),"through":prop("integer","From the first page."),"limit":prop("integer","Max 20, default 10.")]),annotations:.init(readOnlyHint:true)),
        Tool(name:"interaction_delta",description:"What changed in the UI across one recorded interaction (before its first input to after its last). Use ui_diff to page or compare other snapshots.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"interaction_id":prop("string","")],required:["interaction_id"]),annotations:.init(readOnlyHint:true)),
        Tool(name:"interaction_result",description:"Explain one recorded interaction: input sent and acknowledged, check results, observations, and what remains uncertain. A passing check is current state, not a save.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"interaction_id":prop("string","Returned by an action.")],required:["interaction_id"]),annotations:.init(readOnlyHint:true)),
        Tool(name:"diagnostic_query",description:"Read Leap's own log of errors, warnings and fallbacks, paged; works without a project. A logged success does not prove the app changed.",inputSchema:schema(["interaction_id":prop("string","Filter."),"session_id":prop("string","Filter."),"level":prop("string","info, warning, error, or issues (warn+error)."),"kind":prop("string","Event kind."),"after":prop("integer","Paging cursor."),"limit":prop("integer","Max 20, default 10.")]),annotations:.init(readOnlyHint:true)),
        Tool(name:"recording_group",description:"Start, resume or end a named task that groups recordings across apps and restarts; new observations join it. Requires bind_project.",inputSchema:schema(["action":prop("string","",enumValues:["start","resume","end"]),"name":prop("string","For start; up to 200 bytes."),"group_id":prop("string","For resume.")],required:["action"])),
        Tool(name:"recording_sessions",description:"List stored recording sessions or groups.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"view":prop("string","Default recordings.",enumValues:["recordings","groups"]),"group_id":prop("string","Filter by group."),"after":prop("integer","Paging cursor."),"limit":prop("integer","Max 20, default 10.")]),annotations:.init(readOnlyHint:true)),
        Tool(name:"bind_project",description:"Set the project whose .leap store keeps evidence; later actions are recorded automatically and evidence tools can omit project.",inputSchema:schema(["project":prop("string","Absolute path.")],required:["project"])),
        Tool(name:"ui_to_text",description:"Compact JSON of a UI, fresh (with app) or from a stored snapshot, filtered by role, id, label, state, subtree or fields. Long strings become leapAsset references. Needs a bound project; for a quick filtered read use get_app_state(contains).",inputSchema:schema(["app":appProp,"window":prop("string","For fresh reads."),"project":prop("string","For historical reads."),"snapshot":prop("integer","Omit (with app) for fresh."),"types":.object(["type":.string("array"),"items":.object(["type":.string("string")])]),"ids":.object(["type":.string("array"),"items":.object(["type":.string("string")])]),"fields":.object(["type":.string("array"),"items":.object(["type":.string("string")])]),"contains":prop("string","Label or value substring."),"root":prop("string","Subtree key."),"depth":prop("integer","Max depth below root."),"enabled":prop("boolean","Filter."),"selected":prop("boolean","Filter."),"visible":prop("boolean","Inside the window frame (not occlusion)."),"after":prop("integer","Paging cursor."),"limit":prop("integer","Max 100, default 20."),"max_bytes":prop("integer","2048–32000, default 8000.")]),annotations:.init(readOnlyHint:true)),
        Tool(name:"leap_asset",description:"Fetch the long string behind a leapAsset reference: info (metadata), text (a chunk), file (exact text written to disk) or auto. Captured value, never the live one.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"asset_id":prop("string","From a leapAsset reference."),"mode":prop("string","Default auto.",enumValues:["auto","info","text","file"]),"offset":prop("integer","Characters (text mode)."),"limit":prop("integer","Characters, max 4000, default 2000.")],required:["asset_id"])),
        Tool(name:"ui_diff",description:"Compare two stored snapshots of one window: added, changed, removed controls. Partial snapshots can't prove removal.",inputSchema:schema(["project":prop("string","Defaults to the bound project."),"before":prop("integer","Earlier snapshot."),"after_snapshot":prop("integer","Later snapshot."),"after":prop("integer","Paging cursor (not a snapshot)."),"limit":prop("integer","Max 100, default 20."),"max_bytes":prop("integer","Default 8000.")],required:["before","after_snapshot"]),annotations:.init(readOnlyHint:true)),
        Tool(name: "recording_review", description: "Summarize recorded activity without trees. view: overview (issues and counts), actions (inputs and checks), issues (errors, failed checks, capture gaps), events (grouped notifications). Historical, not a fresh read.", inputSchema:schema(["project":prop("string","Defaults to the only active recording."),"session_id":prop("string","Filter."),"interaction_id":prop("string","What happened during this action."),"view":prop("string","Default overview.",enumValues:["overview","actions","issues","events"]),"after":prop("integer","Paging cursor."),"through":prop("integer","From the first page."),"limit":prop("integer","1–50, default 10.")]),annotations:.init(readOnlyHint:true)),
        Tool(name: "recording_start", description: "Record an app's accessibility events into <project>/.leap (git-excluded) before acting; returns the session ID and initial state. Covers supported notifications while Leap runs, not every event.", inputSchema: schema(["app":appProp,"project":prop("string","Absolute project path (not the app)."),"window":prop("string","Window title substring to pin.")],required:["app","project"])),
        Tool(name: "recording_stop", description: "Stop recording an app; history is kept.", inputSchema:schema(["app":appProp],required:["app"])),
        Tool(name: "recording_query", description: "Read raw stored records (events, actions, snapshots), read-only. Large snapshots: use recording_nodes. A notification shows that something changed, not its prior value or cause.", inputSchema:schema(["project":prop("string","Absolute project path."),"session_id":prop("string","Filter."),"interaction_id":prop("string","Filter."),"kind":prop("string","ax_notification, subscription, snapshot, action_intent, action_result, capture_gap, session_start or expectation_result."),"contains":prop("string","Substring of the record JSON (any case)."),"after":prop("integer","Paging cursor."),"limit":prop("integer","1–100, default 20.")],required:["project"]),annotations:.init(readOnlyHint:true)),
        Tool(name: "recording_nodes", description: "Read a stored snapshot's nodes, filtered and paged, without re-reading the app. A partial snapshot can't prove absence.", inputSchema:schema(["project":prop("string","Absolute project path."),"snapshot":prop("integer","ID from a state footer or query."),"outline":prop("boolean","Structure and labels only."),"contains":prop("string","Text filter (any case)."),"after":prop("integer","Paging cursor."),"limit":prop("integer","1–100, default 20.")],required:["project","snapshot"]),annotations:.init(readOnlyHint:true)),
        Tool(name: "verified_action", description: "Run one action once, then check an expectation about the current UI; the action result and the check are reported separately, and input is never retried. Passing proves current state, not saving: reopen to verify.", inputSchema:schema(["app":appProp,"action":prop("object","{tool, ...its arguments} without app, e.g. {tool:click,label:Save}."),"expect_label":prop("string","Label of the expected element; must be unique."),"condition":prop("string","",enumValues:["appears","disappears","enabled","disabled","value_contains"]),"value":prop("string","For value_contains."),"timeout":prop("number","Seconds, default 5.")],required:["app","action","expect_label","condition"])),

        Tool(name: "list_apps",
             description: "List running apps (frontmost first, with window counts), optionally installed ones. Skip if you know the app's name.",
             inputSchema: schema(["include_installed": prop("boolean", "Also list installed apps that are not running.")]),
             annotations: .init(readOnlyHint: true)),

        Tool(name: "get_app_state",
             description: "Read the app's key window as an indexed accessibility tree (text, no image). Later reads return only the diff; indices stay stable. Call before acting.",
             inputSchema: schema([
                "app": appProp,
                "include_screenshot": prop("boolean", "Only for visual questions the tree can't answer (canvas, 3D, zoom, rendering)."),
                "disable_diff": prop("boolean", "Full tree instead of the diff."),
                "scale": prop("number", "Screenshot scale 0.1–1; 1 = one pixel per window point."),
                "window": prop("string", "Window title substring; sticks for later actions; \"\" returns to the key window."),
                "include_frames": prop("boolean", "Add element frames (for coordinate clicks and drags)."),
                "include_disabled": prop("boolean", "List runs of disabled elements instead of one summary line."),
                "contains": prop("string", "Only elements whose line contains this text (label, value, role or id)."),
             ], required: ["app"]),
             annotations: .init(readOnlyHint: true)),

        Tool(name: "screenshot",
             description: "Capture a window image, only for visual questions (layout, rendering, canvas, 3D) or a diff that contradicts expectations. Prefer scale ≤ 0.5 or a crop. save_path writes a file and returns text only.",
             inputSchema: schema([
                "app": appProp,
                "window": prop("string", "Window title substring; sticks for later actions."),
                "x": prop("number", "Crop, window points."), "y": prop("number", "Crop."),
                "width": prop("number", "Crop."), "height": prop("number", "Crop."),
                "scale": prop("number", "0.1–1, default 1 (full resolution)."),
                "save_path": prop("string", "PNG or JPEG by extension; folders are created."),
                "embed": prop("boolean", "Also return the image when save_path is set."),
             ], required: ["app"]),
             annotations: .init(readOnlyHint: true)),

        Tool(name: "click",
             description: "Click an element by index or label (accessibility press), or a window point for canvases only.",
             inputSchema: schema(targetProps.merging([
                "app": appProp,
                "button": prop("string", "Default left.", enumValues: ["left", "right", "middle"]),
                "click_count": prop("integer", "2 = double, 3 = triple."),
                "modifiers": prop("string", "e.g. \"shift\", \"cmd+alt\"."),
                "foreground": foregroundProp, "then_state": thenStateProp,
             ]) { a, _ in a }, required: ["app"])),

        Tool(name: "drag",
             description: "Drag between two window points (canvas orbit, slider, reorder). Unverified; SwiftUI ignores background drags: if nothing changed, retry with foreground=true.",
             inputSchema: schema([
                "app": appProp,
                "from_x": prop("number", ""), "from_y": prop("number", ""),
                "to_x": prop("number", ""), "to_y": prop("number", ""),
                "steps": prop("integer", "Move events, default 12."),
                "modifiers": prop("string", "Keys held down."),
                "foreground": foregroundProp, "then_state": thenStateProp,
             ], required: ["app", "from_x", "from_y", "to_x", "to_y"])),

        Tool(name: "scroll",
             description: "Scroll an element or point by pages (default 1) or pixels.",
             inputSchema: schema(targetProps.merging([
                "app": appProp,
                "direction": prop("string", "", enumValues: ["up", "down", "left", "right"]),
                "pages": prop("number", "A page ≈ 85% of the visible extent."),
                "pixels": prop("integer", "Overrides pages."),
                "foreground": foregroundProp, "then_state": thenStateProp,
             ]) { a, _ in a }, required: ["app", "direction"])),

        Tool(name: "press_key",
             description: "Press a key or chord (xdotool names, e.g. Return, super+s, KP_0), sent to this app only.",
             inputSchema: schema([
                "app": appProp,
                "key": prop("string", ""),
                "foreground": foregroundProp, "then_state": thenStateProp,
             ], required: ["app", "key"])),

        Tool(name: "type_text",
             description: "Type text into the focus, or into element_index/label after focusing it. Newlines press Return (may submit a form); use set_value or paste for multi-line.",
             inputSchema: schema([
                "app": appProp,
                "text": prop("string", ""),
                "element_index": prop("integer", "Element to focus first."),
                "label": labelProp,
                "foreground": foregroundProp, "then_state": thenStateProp,
             ], required: ["app", "text"])),

        Tool(name: "set_value",
             description: "Replace an editable element's value (field, slider, checkbox) via accessibility; falls back to select-all and typing.",
             inputSchema: schema([
                "app": appProp,
                "element_index": prop("integer", ""),
                "label": labelProp,
                "value": prop("string", ""),
                "then_state": thenStateProp,
             ], required: ["app", "value"])),

        Tool(name: "select_text",
             description: "Select text in an editable element, or put the caret before/after it, without keystrokes. Then type_text replaces or inserts.",
             inputSchema: schema([
                "app": appProp,
                "element_index": prop("integer", ""),
                "label": labelProp,
                "text": prop("string", "Exact, case-sensitive."),
                "prefix": prop("string", "Text right before the match (disambiguates)."),
                "suffix": prop("string", "Text right after the match."),
                "selection_type": prop("string", "text selects; cursor_before/after places the caret.", enumValues: ["text", "cursor_before", "cursor_after"]),
                "then_state": thenStateProp,
             ], required: ["app", "text"])),

        Tool(name: "wait_for",
             description: "Wait until an element appears, disappears, becomes enabled/disabled, or its value contains text. For results that arrive after the UI settles (network, saves). Fails on timeout, stopping a batch.",
             inputSchema: schema([
                "app": appProp,
                "label": prop("string", "Visible text or id; exact match first, else substring."),
                "condition": prop("string", "Default appears.", enumValues: ["appears", "disappears", "enabled", "disabled", "value_contains"]),
                "value": prop("string", "For value_contains."),
                "timeout": prop("number", "Seconds, default 10, max 60."),
                "then_state": thenStateProp,
             ], required: ["app", "label"])),

        Tool(name: "perform_action",
             description: "Run an action from an element's actions= list (e.g. ShowMenu, Increment, Expand, Raise).",
             inputSchema: schema([
                "app": appProp,
                "element_index": prop("integer", ""),
                "label": labelProp,
                "action": prop("string", "Name as shown."),
                "then_state": thenStateProp,
             ], required: ["app", "action"])),

        Tool(name: "paste",
             description: "Insert text or HTML through the clipboard, then restore the user's clipboard. For multi-line or formatted text.",
             inputSchema: schema([
                "app": appProp,
                "text": prop("string", ""),
                "html": prop("string", "Optional HTML version."),
                "foreground": foregroundProp, "then_state": thenStateProp,
             ], required: ["app", "text"])),

        Tool(name: "list_windows",
             description: "All on-screen windows front to back (app, pid, title, frame) and each display's usable area, as text. For arranging windows without screenshots.",
             inputSchema: schema([:]),
             annotations: .init(readOnlyHint: true)),

        Tool(name: "set_window_frame",
             description: "Move and/or resize an app's window in screen points, without activating it; returns the frame the app accepted.",
             inputSchema: schema([
                "app": appProp,
                "window": prop("string", "Window title substring; default the key window."),
                "x": prop("number", ""), "y": prop("number", ""),
                "width": prop("number", ""), "height": prop("number", ""),
             ], required: ["app"])),

        Tool(name: "activate",
             description: "Bring the app to the front, interrupting the user; only when they should see it or it ignores background input.",
             inputSchema: schema(["app": appProp], required: ["app"])),

        Tool(name: "batch",
             description: "Run a predictable sequence of actions on one app in one call, then return the state. Stops at the first error and lists the steps already applied; never repeat those.",
             inputSchema: schema([
                "app": appProp,
                "actions": .object([
                    "type": "array",
                    "description": "[{tool: click|drag|scroll|press_key|type_text|set_value|select_text|perform_action|paste|wait_for|wait, ...that tool's arguments}]; app is implied; {tool: wait, seconds: 1.5} pauses.",
                    "items": .object(["type": "object"]),
                ]),
                "include_screenshot": prop("boolean", "Only for visual questions."),
                "then_state": thenStateProp,
             ], required: ["app", "actions"])),

        Tool(name: "permissions",
             description: "Check Leap's Accessibility and Screen Recording permissions.",
             inputSchema: schema(["prompt": prop("boolean", "Raise the macOS prompts for missing ones.")]),
             annotations: .init(readOnlyHint: true)),
    ]

    // MARK: - Dispatch

    static func call(_ params: CallTool.Parameters, engine: Engine) async -> CallTool.Result {
        Inactivity.touch()
        let args = Args(params.arguments ?? [:])
        do {
            // One tool call — action plus its follow-up state, or a whole batch — runs to
            // completion before the next starts, even if the client issues calls in parallel.
            let name = params.name
            return try await engine.serialized {
                let interaction = await engine.beginInteraction()
                Diagnostics.shared.setContext(["interaction":interaction,"tool":name,"app":args.string("app") ?? ""])
                defer { Diagnostics.shared.setContext([:]) }
                guard Diagnostics.shared.record(level:"info",kind:"tool_started",detail:"Dispatch requested; not evidence of input delivery") != nil else {
                    await engine.endInteraction()
                    return .init(content:[.text(text:"Error: Diagnostic logging unavailable; tool was not dispatched. Check diagnostic store permissions/free space.",annotations:nil,_meta:nil)],isError:true)
                }
                Diagnostics.shared.record(level:"debug",kind:"dispatch_context",detail:"Argument names only: \((params.arguments ?? [:]).keys.sorted().joined(separator:", ")). Values omitted.")
                var result: CallTool.Result
                do { result = try await dispatch(name, args, engine) }
                catch {
                    Diagnostics.shared.record(level:"error",kind:"tool_error",detail:String(describing:error))
                    var message = "Error: \(error)\ninteraction=\(interaction)"
                    if let app = args.string("app"), Self.actionTools.contains(name) || name == "batch" || name == "verified_action" {
                        do { let state = try await engine.state(app:app); message += "\nFresh evidence (does not imply action failed):\n" + Engine.evidenceSummary(state.text) }
                        catch { Diagnostics.shared.record(level:"error",kind:"post_error_observation_failed",detail:String(describing:error)); message += "\nPost-error observation unavailable: \(error). Do not blindly repeat prior input." }
                    }
                    result = .init(content:[.text(text:message,annotations:nil,_meta:nil)],isError:true)
                }
                // Successful single-action calls return the recorded outcome/delta rather
                // than duplicating the entire rendered tree. Preserve full errors and batches.
                if result.isError != true && (Self.actionTools.contains(name) || name == "verified_action"),
                   args.bool("then_state") != false {
                    do { if let summary = try await engine.interactionResult() {result = summary.result} }
                    catch { Diagnostics.shared.record(level:"warning",kind:"summary_fallback",detail:"Returning original response; summary failed: \(error). Input not replayed.") }
                }
                await engine.endInteraction()
                Diagnostics.shared.record(level:result.isError == true ? "error":"info",kind:"tool_completed",detail:result.isError == true ? "Returned error; inspect per-operation dispatch evidence. Read-only operations send no input." : "Returned without tool error; does not establish expected app state.")
                if name != "diagnostic_query", let warning=Diagnostics.shared.warningSummary(interaction:interaction) {
                    result = .init(content:result.content + [.text(text:warning,annotations:nil,_meta:nil)],isError:result.isError)
                }
                if let failure=Diagnostics.shared.health() {result = .init(content:result.content + [.text(text:failure,annotations:nil,_meta:nil)],isError:result.isError)}
                return result
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    static func dispatch(_ name: String, _ a: Args, _ engine: Engine) async throws -> CallTool.Result {
        if ["target_list","session_open","session_close","ui_observe","ui_inspect","ui_perform","session_history","evidence_read"].contains(name) {
            let encoded = try JSONEncoder().encode(a.raw)
            return try await engine.automation(name,json:String(decoding:encoded,as:UTF8.self)).result
        }
        switch name {
        case "diagnostic_query":
            return try Diagnostics.shared.query(interaction:a.string("interaction_id"),session:a.string("session_id"),level:a.string("level"),kind:a.string("kind"),after:a.int("after") ?? 0,limit:a.int("limit") ?? 10).result
        case "interaction_timeline":
            return try Evidence(project:await engine.recordingProject(a.string("project"))).timeline(session:a.string("session_id"),after:a.int("after") ?? 0,through:a.int("through"),limit:a.int("limit") ?? 10,group:a.string("group_id")).result
        case "interaction_delta":
            guard let id=a.string("interaction_id") else {throw LeapError.unsupported("interaction_id required")}
            return try Evidence(project:await engine.recordingProject(a.string("project"))).interactionDelta(id).result
        case "interaction_result":
            guard let id=a.string("interaction_id") else {throw LeapError.unsupported("interaction_id required")}
            return try Evidence(project:await engine.recordingProject(a.string("project"))).interaction(id).result
        case "recording_group":
            guard let action=a.string("action") else {throw LeapError.unsupported("action required")}
            return try await engine.recordingGroup(action:action,name:a.string("name"),id:a.string("group_id")).result
        case "recording_sessions":
            return try Evidence(project:await engine.recordingProject(a.string("project"))).sessions(view:a.string("view") ?? "recordings",group:a.string("group_id"),after:a.int("after") ?? 0,limit:a.int("limit") ?? 10).result
        case "bind_project":
            guard let project=a.string("project") else {throw LeapError.unsupported("project required")}
            return try await engine.bindProject(project).result
        case "ui_to_text":
            let project:String
            do { project=try await engine.recordingProject(a.string("project")) }
            catch where a.int("snapshot")==nil {
                throw LeapError.unsupported("ui_to_text reads through a project's evidence store; bind_project first. For a fresh filtered read without a project, use get_app_state(app, contains: \"...\"). Nothing was read.")
            }
            let snapshot:Int
            if let id=a.int("snapshot") {snapshot=id} else {
                let bound=try await engine.recordingProject(nil)
                guard project==bound else {throw LeapError.unsupported("Fresh UI evidence must use the bound project")}
                snapshot=try await engine.observeSnapshot(app:try a.app(),window:a.string("window"))
            }
            return try Evidence(project:project).ui(snapshot:snapshot,types:a.strings("types"),ids:a.strings("ids"),fields:a.strings("fields"),contains:a.string("contains"),rootKey:a.string("root"),depth:a.int("depth"),enabled:a.bool("enabled"),selected:a.bool("selected"),visible:a.bool("visible"),after:a.int("after") ?? 0,limit:a.int("limit") ?? 20,maxBytes:a.int("max_bytes") ?? 8000).result
        case "leap_asset":
            guard let id=a.string("asset_id") else {throw LeapError.unsupported("asset_id required")}
            return try Evidence(project:await engine.recordingProject(a.string("project"))).asset(id:id,mode:a.string("mode") ?? "auto",offset:a.int("offset") ?? 0,limit:a.int("limit") ?? 2000).result
        case "ui_diff":
            guard let before=a.int("before"),let after=a.int("after_snapshot") else {throw LeapError.unsupported("before and after_snapshot required")}
            return try Evidence(project:await engine.recordingProject(a.string("project"))).diff(before:before,after:after,cursor:a.int("after") ?? 0,limit:a.int("limit") ?? 20,maxBytes:a.int("max_bytes") ?? 8000).result
        case "recording_review":
            let project = try await engine.recordingProject(a.string("project"))
            return try RecordingStore.query(project:project,session:a.string("session_id"),interaction:a.string("interaction_id"),kind:nil,contains:nil,after:a.int("after") ?? 0,limit:a.int("limit") ?? 10,review:a.string("view") ?? "overview",through:a.int("through")).result
        case "recording_start":
            guard let project=a.string("project") else {throw LeapError.unsupported("project required")}
            return try await engine.startRecording(app:try a.app(),project:project,window:a.string("window")).result
        case "recording_stop": return try await engine.stopRecording(app:try a.app()).result
        case "recording_query", "recording_nodes":
            if name == "recording_nodes", a.int("snapshot") == nil {throw LeapError.unsupported("snapshot sequence ID required")}
            guard let project=a.string("project") else {throw LeapError.unsupported("project required")}
            return try RecordingStore.query(project:project,session:a.string("session_id"),interaction:a.string("interaction_id"),kind:a.string("kind"),contains:a.string("contains"),after:a.int("after") ?? 0,limit:a.int("limit") ?? 20,snapshot:name == "recording_nodes" ? a.int("snapshot") : nil,outline:a.bool("outline") ?? false).result
        case "verified_action":
            guard var obj=a.raw["action"]?.objectValue, let tool=obj["tool"]?.stringValue, Self.actionTools.contains(tool), tool != "wait_for" else {throw LeapError.unsupported("action must name a supported input tool")}
            obj["app"] = .string(try a.app())
            guard let label=a.string("expect_label"), let condition=a.string("condition"), let parsed=Engine.WaitCondition(rawValue:condition) else {throw LeapError.unsupported("expect_label and valid condition required")}
            guard !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw LeapError.unsupported("Expectation label must be nonempty; no input sent")}
            if parsed == .valueContains && (a.string("value") ?? "").isEmpty {throw LeapError.unsupported("value_contains requires a nonempty value; no input sent")}
            var before="unknown", beforeMet=false
            do { before = try await engine.waitFor(app:try a.app(),label:label,condition:parsed,value:a.string("value"),timeout:0.1);beforeMet=true } catch { before="not established: \(error)" }
            try await engine.recordCheck(app:try a.app(),phase:"before",label:label,condition:condition,met:beforeMet,detail:before)
            var actionResult="", actionError=false
            do { actionResult=try await performAction(tool,Args(obj),engine) } catch {actionResult="Action outcome uncertain/rejected: \(error)";actionError=true}
            var check="", checkFailed=false
            do {check=try await engine.waitFor(app:try a.app(),label:label,condition:parsed,value:a.string("value"),timeout:a.double("timeout") ?? 5)} catch {check="Expectation not established: \(error)";checkFailed=true}
            try await engine.recordCheck(app:try a.app(),phase:"after",label:label,condition:condition,met:!checkFailed,detail:check)
            let state=try await engine.state(app:try a.app())
            let summary=try await engine.interactionResult() ?? "Before: \(before)\nAction: \(actionResult)\nCurrent-state check: \(check)\nNo input retry occurred."
            return .init(content:[.text(text:summary+"\n"+state.text,annotations:nil,_meta:nil)],isError:actionError || checkFailed)
        case "list_apps":
            let apps = AppResolver.listApps(includeInstalled: a.bool("include_installed") ?? false)
            var text = "## Apps (\(apps.filter { $0.isRunning }.count) running)\n"
            for app in apps {
                var line = app.isRunning ? "• " : "  "
                line += app.name
                if let b = app.bundleId { line += "  (\(b))" }
                if app.isRunning { line += "  pid=\(app.pid ?? 0) windows=\(app.windowCount)" }
                if app.isActive { line += "  [frontmost]" }
                text += line + "\n"
            }
            return text.result

        case "permissions":
            let prompt = a.bool("prompt") ?? false
            if prompt {
                _ = Permissions.accessibilityTrusted(prompt: true)
                if !Permissions.screenRecordingGranted() { _ = Permissions.requestScreenRecording() }
            }
            let who = Bundle.main.bundleIdentifier != nil
                ? "the \"Leap\" entry"
                : "the MCP client that launched this development build"
            let allGranted = Permissions.accessibilityTrusted() && Permissions.screenRecordingGranted()
            return ("leap permissions: " + Permissions.summary() + (allGranted ? "" : "\nGrant missing ones in System Settings › Privacy & Security › Accessibility / Screen & System Audio Recording — enable \(who). A new Screen Recording grant applies after the host restarts Leap; permissions(prompt: true) opens the right pane.")).result

        case "get_app_state":
            var opts = Engine.StateOptions()
            opts.includeScreenshot = a.bool("include_screenshot") ?? false
            opts.disableDiff = a.bool("disable_diff") ?? false
            if let s = a.double("scale") { opts.scale = s }
            opts.includeFrames = a.bool("include_frames") ?? false
            opts.includeDisabled = a.bool("include_disabled") ?? false
            opts.contains = a.string("contains")
            let st = try await engine.state(app: try a.app(), opts, announce: true, window: a.string("window"))
            return result(text: st.text, shot: st.screenshot)

        case "screenshot":
            var region: CGRect?
            if let x = a.double("x"), let y = a.double("y"), let w = a.double("width"), let h = a.double("height") {
                region = CGRect(x: x, y: y, width: w, height: h)
            }
            let savePath = a.string("save_path").flatMap { $0.isEmpty ? nil : $0 }
            let wantsPNG = savePath?.lowercased().hasSuffix(".png") ?? false
            let shot = try await engine.screenshot(app: try a.app(), region: region, scale: a.double("scale") ?? 1.0,
                                                   png: wantsPNG, window: a.string("window"))
            var saved = ""
            if let path = savePath {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try shot.data.write(to: url)
                saved = " — saved to \(url.path)"
            }
            // When saving to disk, don't also stream the image back unless asked: a capture pass
            // of many screens should not cost a screenshot's worth of context per shot.
            let embed = a.bool("embed") ?? (savePath == nil)
            let text = "screenshot \(shot.pixelWidth)x\(shot.pixelHeight) px, \(String(format: "%.2f", shot.pointsPerPixel)) points/px" + (region.map { " (region \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "") + saved
            return result(text: text, shot: embed ? shot : nil)

        case "list_windows":
            return await engine.windowLayout().result

        case "set_window_frame":
            return try await engine.setWindowFrame(app: try a.app(), window: a.string("window"),
                                                   x: a.double("x").map { CGFloat($0) }, y: a.double("y").map { CGFloat($0) },
                                                   width: a.double("width").map { CGFloat($0) }, height: a.double("height").map { CGFloat($0) }).result

        case "activate":
            return try await engine.activate(app: try a.app()).result

        case "batch":
            let app = try a.app()
            guard let actions = a.raw["actions"]?.arrayValue else { throw LeapError.unsupported("actions must be an array") }
            guard actions.count <= 50 else { throw LeapError.unsupported("batch is limited to 50 actions (got \(actions.count))") }
            // Hold focus for the whole batch: the app is activated at most once (lazily, only
            // if some action needs synthesized events) and the user's app is restored once.
            try await engine.beginInputSession(app: app, mode: Engine.InputMode(
                foreground: a.bool("foreground") ?? false))
            var log: [String] = []
            do {
                for (i, item) in actions.enumerated() {
                    guard var obj = item.objectValue, let tool = obj["tool"]?.stringValue else {
                        throw LeapError.unsupported("actions[\(i)] needs a \"tool\" string")
                    }
                    obj["app"] = .string(app)
                    obj["then_state"] = .bool(false)
                    let sub = Args(obj)
                    if tool == "wait" {
                        let secs = sub.double("seconds") ?? 1
                        try await Task.sleep(nanoseconds: UInt64(max(0, min(secs, 30)) * 1_000_000_000))
                        log.append("[\(i + 1)] waited \(secs)s")
                        continue
                    }
                    guard Self.actionTools.contains(tool) else { throw LeapError.unsupported("actions[\(i)]: \"\(tool)\" is not a batchable action") }
                    let r = try await performAction(tool, sub, engine)
                    log.append("[\(i + 1)] \(tool): \(r)")
                }
            } catch {
                await engine.endInputSession()
                // The steps that ran did run. Report them so the caller never re-sends them.
                let done = log.isEmpty ? "(none)" : log.joined(separator: "\n")
                throw LeapError.unsupported("Batch stopped at step \(log.count + 1) of \(actions.count): \(error)\nCompleted steps (already applied — do not repeat them):\n\(done)")
            }
            await engine.endInputSession()
            var text = "## Batch (all \(log.count) steps applied)\n" + log.joined(separator: "\n")
            var shot: Screenshot?
            if a.bool("then_state") ?? true {
                var opts = Engine.StateOptions()
                opts.includeScreenshot = a.bool("include_screenshot") ?? false
                do {
                    let st = try await engine.state(app: app, opts)
                    text += "\n\n" + st.text
                    shot = st.screenshot
                } catch {
                    text += "\n\n(state unavailable after the batch: \(error) — the actions above were applied; call get_app_state)"
                }
            }
            return result(text: text, shot: shot)

        default:
            guard Self.actionTools.contains(name) else { throw LeapError.unsupported("unknown tool \(name)") }
            let message = try await performAction(name, a, engine)
            guard a.bool("then_state") ?? true else { return message.result }
            var opts = Engine.StateOptions()
            opts.includeScreenshot = false
            // The action is done; a failed *observation* (Save closed the window, the app quit)
            // must not be reported as a failed action, or the caller will retry it.
            do {
                let st = try await engine.state(app: try a.app(), opts)
                return result(text: message + "\n\n" + st.text, shot: nil)
            } catch {
                return result(text: message + "\n\n(action applied; state unavailable afterwards: \(error) — call get_app_state)", shot: nil)
            }
        }
    }

    static let actionTools: Set<String> = ["click", "drag", "scroll", "press_key", "type_text", "set_value", "select_text", "perform_action", "paste", "wait_for"]

    /// Executes one input action and returns a one-line description of what happened.
    static func performAction(_ name: String, _ argsIn: Args, _ engine: Engine) async throws -> String {
        let app=try argsIn.app()
        let action=try await engine.beginRecordedAction(app:app,tool:name)
        guard Diagnostics.shared.record(level:"info",kind:"input_attempt",detail:"Invoking \(name); actionId=\(action ?? "unrecorded"). Not proof of delivery.",fields:["app":app]) != nil else {throw LeapError.unsupported("Diagnostics unavailable before input; not dispatched")}
        let result:String
        do { result=try await dispatchAction(name,argsIn,engine) }
        catch {
            let original=error
            // The returned error states whether input was sent; do not guess here.
            if name == "wait_for" {
                Diagnostics.shared.record(level:"warning",kind:"check_unmet",detail:"\(name): \(error). Read-only check; no input sent.",fields:["app":app])
            } else {
                Diagnostics.shared.record(level:"error",kind:"input_error",detail:"\(name): \(error)",fields:["app":app])
            }
            do {try await engine.endRecordedAction(app:app,action:action,tool:name,message:String(describing:original),error:true)}
            catch {throw LeapError.unsupported("Input may already have been sent. Original: \(original). Recording failure: \(error). Do not replay.")}
            throw original
        }
        Diagnostics.shared.record(level:"info",kind:"input_returned",detail:"\(name) API returned; expected application effect requires separate check. actionId=\(action ?? "unrecorded")",fields:["app":app])
        do {try await engine.endRecordedAction(app:app,action:action,tool:name,message:result,error:false)}
        catch {throw LeapError.unsupported("Operation returned: \(result). Recording failed after operation: \(error). Do not replay.")}
        return result + (action.map { " [action=\($0)]" } ?? "")
    }

    static func dispatchAction(_ name: String, _ argsIn: Args, _ engine: Engine) async throws -> String {
        let app = try argsIn.app()
        // `label` is sugar for element_index, resolved here so every action supports it. A label
        // names the caller's intent, not one element object: if the UI re-laid out or replaced the
        // element before any input was sent (the stale-element check runs before input), look
        // the label up again on a fresh read and try once more. Index targets stay strict.
        guard name != "wait_for", argsIn.int("element_index") == nil, let label = argsIn.string("label"), !label.isEmpty else {
            return try await dispatchResolved(name, argsIn, engine)
        }
        func resolved(_ fresh: Bool) async throws -> Args {
            var raw = argsIn.raw
            raw["element_index"] = .int(try await engine.findElement(app: app, label: label, fresh: fresh))
            return Args(raw)
        }
        do {
            return try await dispatchResolved(name, try await resolved(false), engine)
        } catch LeapError.staleElement {
            return try await dispatchResolved(name, try await resolved(true), engine)
        }
    }

    static func dispatchResolved(_ name: String, _ a: Args, _ engine: Engine) async throws -> String {
        let app = try a.app()
        let mode = Engine.InputMode(foreground: a.bool("foreground") ?? false)
        switch name {
        case "click":
            let button = MouseButton(alias: a.string("button") ?? "left") ?? .left
            return try await engine.click(app: app, target: a.target(), button: button,
                                          count: max(1, min(a.int("click_count") ?? 1, 3)), modifiers: a.string("modifiers"), mode: mode)
        case "drag":
            guard let fx = a.double("from_x"), let fy = a.double("from_y"), let tx = a.double("to_x"), let ty = a.double("to_y") else {
                throw LeapError.unsupported("drag needs from_x, from_y, to_x, to_y")
            }
            return try await engine.drag(app: app, from: .init(x: fx, y: fy), to: .init(x: tx, y: ty),
                                         steps: a.int("steps") ?? 12, modifiers: a.string("modifiers"), mode: mode)
        case "scroll":
            guard let dir = a.string("direction") else { throw LeapError.unsupported("scroll needs direction") }
            var target = a.target()
            if target.elementIndex == nil && target.x == nil {
                target = try await centerTarget(app, engine) // default: window center
            }
            return try await engine.scroll(app: app, target: target, direction: dir,
                                           pages: a.double("pages") ?? 1, pixels: a.int("pixels"), mode: mode)
        case "press_key":
            guard let key = a.string("key") else { throw LeapError.unsupported("press_key needs key") }
            return try await engine.pressKey(app: app, key: key, mode: mode)
        case "type_text":
            guard let text = a.string("text") else { throw LeapError.unsupported("type_text needs text") }
            return try await engine.typeText(app: app, text: text, elementIndex: a.int("element_index"), mode: mode)
        case "set_value":
            guard let i = a.int("element_index"), let v = a.string("value") else { throw LeapError.unsupported("set_value needs element_index (or label) and value") }
            return try await engine.setValue(app: app, elementIndex: i, value: v)
        case "wait_for":
            guard let label = a.string("label") else { throw LeapError.unsupported("wait_for needs label") }
            guard let cond = Engine.WaitCondition(rawValue: a.string("condition") ?? "appears") else {
                throw LeapError.unsupported("condition must be appears, disappears, enabled, disabled or value_contains")
            }
            return try await engine.waitFor(app: app, label: label, condition: cond, value: a.string("value"),
                                            timeout: a.double("timeout") ?? 10)
        case "select_text":
            guard let i = a.int("element_index"), let text = a.string("text") else { throw LeapError.unsupported("select_text needs element_index (or label) and text") }
            let sel = Engine.SelectionType(rawValue: a.string("selection_type") ?? "text") ?? .text
            return try await engine.selectText(app: app, elementIndex: i, text: text, prefix: a.string("prefix"),
                                               suffix: a.string("suffix"), selection: sel)
        case "perform_action":
            guard let i = a.int("element_index"), let act = a.string("action") else { throw LeapError.unsupported("perform_action needs element_index (or label) and action") }
            return try await engine.performAction(app: app, elementIndex: i, action: act)
        case "paste":
            guard let text = a.string("text") else { throw LeapError.unsupported("paste needs text") }
            return try await engine.paste(app: app, text: text, html: a.string("html"), mode: mode)
        default:
            throw LeapError.unsupported("unknown action \(name)")
        }
    }

    static func centerTarget(_ app: String, _ engine: Engine) async throws -> Engine.Target {
        let frame = try await engine.windowFrame(app: app)
        return .init(x: frame.width / 2, y: frame.height / 2)
    }

    static func result(text: String, shot: Screenshot?) -> CallTool.Result {
        var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
        if let shot {
            content.append(.image(data: shot.data.base64EncodedString(), mimeType: shot.mimeType, annotations: nil, _meta: nil))
        }
        return .init(content: content, isError: false)
    }
}

private extension String {
    var result: CallTool.Result { .init(content: [.text(text: self, annotations: nil, _meta: nil)], isError: false) }
}

/// Typed access to tool arguments.
struct Args {
    let raw: [String: Value]
    init(_ raw: [String: Value]) { self.raw = raw }

    func strings(_ k:String)->[String] {raw[k]?.arrayValue?.compactMap{$0.stringValue} ?? []}
    func string(_ k: String) -> String? { raw[k]?.stringValue }
    func bool(_ k: String) -> Bool? { raw[k]?.boolValue }
    /// Numbers are bounded and finite before conversion: `Int(Double.nan)` and oversized
    /// values trap, which would take the whole server down on one malformed argument.
    func int(_ k: String) -> Int? {
        if let i = raw[k]?.intValue { return max(-1_000_000, min(1_000_000, i)) }
        if let d = raw[k]?.doubleValue, d.isFinite { return Int(max(-1_000_000, min(1_000_000, d.rounded()))) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let d = raw[k]?.doubleValue, d.isFinite { return max(-1_000_000, min(1_000_000, d)) }
        if let i = raw[k]?.intValue { return Double(max(-1_000_000, min(1_000_000, i))) }
        return nil
    }
    func app() throws -> String {
        guard let app = string("app"), !app.isEmpty else { throw LeapError.unsupported("\"app\" is required") }
        return app
    }
    func target() -> Engine.Target {
        .init(elementIndex: int("element_index"), x: double("x").map { CGFloat($0) }, y: double("y").map { CGFloat($0) })
    }
}
