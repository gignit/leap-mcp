// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import ApplicationServices
import AppKit
import Foundation

/// Coordinates app sessions and executes actions. One instance per server.
public actor Engine {
    var sessions: [pid_t: AppSession] = [:]
    var automationSessions: [String: AutomationSession] = [:]
    var recordings: [pid_t: AXRecording] = [:]
    var recordingStores: [String: RecordingStore] = [:]
    var boundProject: String?
    var recordingSuppressed = Set<pid_t>()
    var latestEvidence: [pid_t:Int] = [:]
    var recordingInteraction: String?
    public var walker = AXWalker()
    /// Wait after an input action before the next state capture so the UI can settle.
    public var settleDelay: TimeInterval = 0.6

    public init() {}

    // MARK: - Exclusive operations

    /// Tail of the operation chain. Swift actors interleave work at `await`s, so one tool
    /// call (action + follow-up state, or a whole batch) is not exclusive by itself; a client
    /// issuing parallel tool calls could interleave clicks or clobber a batch's focus hold.
    /// `serialized` runs bodies strictly one after another.
    private var chain: Task<Void, Never> = Task {}

    public func serialized<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task<T, Error> {
            _ = await previous.value
            return try await body()
        }
        chain = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Sessions

    /// bundle path → pid of the session we last handed out for that app, so a relaunch
    /// (new pid, same app) is recognised and reported instead of silently re-indexed.
    var pidByIdentity: [String: pid_t] = [:]

    public func session(for query: String, launch: Bool = true) async throws -> AppSession {
        let app = try await AppResolver.resolve(query, launch: launch)
        let pid = AppResolver.pid(of: app)
        if let s = sessions[pid], !s.app.isTerminated {try autoRecord(s); return s}
        let identity = app.bundleURL?.path ?? app.bundleIdentifier ?? "pid \(pid)"
        let s = AppSession(app: app)
        if let oldPid = pidByIdentity[identity], oldPid != pid, sessions[oldPid] != nil {
            recordings.removeValue(forKey: oldPid)?.stop()
            sessions[oldPid] = nil
            s.relaunchedFrom = oldPid
        }
        sessions[pid] = s
        pidByIdentity[identity] = pid
        try autoRecord(s)
        return s
    }

    /// Session for an *action*. Refuses when the process was replaced since the last
    /// state, or when an element_index/label arrives before any state was ever read: in both
    /// cases the caller's indices refer to a tree it has not seen. Coordinate-only actions
    /// still index silently (they only need the window frame).
    func actionSession(_ query: String, needsElements: Bool) async throws -> AppSession {
        let s = try await session(for: query)
        if s.relaunchedFrom != nil { throw LeapError.processChanged(s.displayName) }
        if needsElements && s.elements.isEmpty { throw LeapError.notActive(s.displayName) }
        try await ensureIndexed(s)
        return s
    }

    func requireAX() throws {
        guard Permissions.accessibilityTrusted() else {
            throw LeapError.permission("Accessibility permission is missing for this process. Grant it in System Settings › Privacy & Security › Accessibility (\(Bundle.main.bundleIdentifier != nil ? "the \"Leap\" entry" : "the app that launched this development build"); restart the MCP client if it was just granted), then retry.")
        }
    }

    /// All of the app's windows with their titles (for the state header and `window:` targeting).
    func windows(_ s: AppSession) -> [(AXUIElement, String)] {
        let ws: [AXUIElement] = AX.attr(s.axApp, kAXWindowsAttribute) ?? []
        return ws.map { ($0, (AX.attr($0, kAXTitleAttribute) as String?) ?? "") }
    }

    /// Poll for the target window: the pinned one (by title substring) if set, else the key window.
    /// Apps that were just launched need a moment, hence the polling.
    func waitForWindow(_ s: AppSession, timeout: TimeInterval = 6) async throws -> AXUIElement {
        if let ready = s.lazyTreeReadyAt {
            s.lazyTreeReadyAt = nil
            let wait = ready.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        let deadline=ProcessInfo.processInfo.systemUptime+max(0.01,timeout)
        while ProcessInfo.processInfo.systemUptime<deadline {
            let candidate:AXUIElement? = try AX.withBudget(deadline-ProcessInfo.processInfo.systemUptime) {
                if let pin=s.pinnedWindow {
                    let hits=windows(s).filter{$0.1.localizedCaseInsensitiveContains(pin)}
                    if hits.count==1 {return hits[0].0}
                    if hits.count>1 {
                        let exact=hits.filter{$0.1.caseInsensitiveCompare(pin) == .orderedSame}
                        if exact.count==1 {return exact[0].0}
                        throw LeapError.unsupported("Window selection is ambiguous; specify a unique title")
                    }
                    return nil
                }
                return walker.keyWindow(of:s.axApp)
            }
            if let candidate {return candidate}
            let left=deadline-ProcessInfo.processInfo.systemUptime
            if left>0 {try await Task.sleep(nanoseconds:UInt64(min(0.2,left)*1_000_000_000))}
        }
        let titles = windows(s).map { "\"\($0.1)\"" }
        if let pin = s.pinnedWindow {
            throw LeapError.unsupported("No window of \(s.displayName) matches \"\(pin)\". Windows: \(titles.isEmpty ? "none" : titles.joined(separator: ", ")). Pass window=\"\" for the key window.")
        }
        throw LeapError.unsupported("\(s.displayName) exposes no accessible window (closed, minimized, on another Space, or full-screen elsewhere). Open or reveal a window, then observe again. No input was sent.")
    }

    // MARK: - State

    public struct StateOptions {
        public var includeScreenshot = false
        public var disableDiff = false
        public var scale: CGFloat = 1.0
        public var jpegQuality: CGFloat? = 0.8
        /// Per-element window-relative frames in the tree. Off by default (the screenshot carries
        /// geometry) — saves ~20 tokens per element.
        public var includeFrames = false
        /// Poll until the tree stops changing after a recent action (~1 s + up to 5 s). Evidence reads
        /// taken after a condition already resolved skip it.
        public var settle = true
        /// Render runs of disabled elements (an inactive tab kept alive in the tree) line by line
        /// instead of collapsing them into one summary line.
        public var includeDisabled = false
        /// Return only element lines containing this text (case-insensitive), from the full tree.
        public var contains: String?
        public init() {}
    }

    public struct State {
        public var text: String
        public var screenshot: Screenshot?
        public var warning: String?
    }

    /// `announce` shows the "thinking" face over the window; used by the explicit
    /// get_app_state tool, not by the state that follows an action (which keeps the action's face).
    public func state(app query: String, _ opts: StateOptions = .init(), announce: Bool = false, window: String? = nil) async throws -> State {
        try requireAX()
        let s = try await session(for: query)
        if let window { s.pinnedWindow = window.isEmpty ? nil : window }
        let st = try await state(session: s, opts)
        if announce { await signal(indicatorPoint(s, nil), .observe) }
        return st
    }

    /// Extra time allowed after an action while the tree is still changing (loading indicators,
    /// list refreshes). We wait ~1 s plus up to 5 s more while the app shows
    /// a loading indicator or other signs of state changes, polling for stability.
    public var maxSettleAfterAction: TimeInterval = 5.0
    /// Smallest budget worth starting a settle re-scan with (a typical full window scan takes 0.1–0.2 s).
    static let minSettleScan: TimeInterval = 0.75

    public func state(session s: AppSession, _ opts: StateOptions = .init()) async throws -> State {
        try requireAX()
        try await settle(s)
        let window = try await waitForWindow(s)
        guard var snap = walker.snapshot(window: window, app: s.axApp) else {
            throw LeapError.axFailure("window frame", .cannotComplete)
        }
        // Settle until stable: two consecutive reads that agree, or the deadline. "Stopped
        // changing" is not "finished" (a network result can land later), so the outcome is
        // reported in the header and wait_for exists for explicit conditions.
        let sinceAction = Date().timeIntervalSince(s.lastActionAt)
        s.lastSettleStable = nil
        var retainedObservationNotice = ""
        if opts.settle && sinceAction < maxSettleAfterAction {
            let deadline = s.lastActionAt.addingTimeInterval(settleDelay + maxSettleAfterAction)
            var previous = Self.fingerprint(snap)
            var previousUsable = snap.supportsStateChecks
            var retainedEarlier = false
            var stable = false
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 300_000_000)
                // A scan started with only milliseconds left is truncated by construction
                // and would mark the whole (otherwise complete) observation incomplete.
                // Stop settling instead; the header still reports "not stable".
                let remaining = deadline.timeIntervalSinceNow
                guard remaining >= Self.minSettleScan else { break }
                guard let again = walker.snapshot(window: window, app: s.axApp, timeout: remaining) else { break }
                let now = Self.fingerprint(again)
                let busy = again.nodes.contains { $0.role == "AXProgressIndicator" || $0.role == "AXBusyIndicator" }
                // Do not replace a usable observation with a sparse deadline scan.
                if again.supportsStateChecks || !snap.supportsStateChecks {
                    snap = again
                    retainedEarlier = false
                } else { retainedEarlier = true }
                if now == previous && previousUsable && !busy && again.supportsStateChecks { stable = true; break }
                previous = now
                previousUsable = again.supportsStateChecks
            }
            s.lastSettleStable = stable
            snap.retainedEarlierObservation = retainedEarlier
            if retainedEarlier { retainedObservationNotice = "\nUsing an earlier usable observation from this call; the final scan was incomplete. This does not establish the latest state." }
        }
        let (full, diff) = s.render(snap, walker: walker, includeFrames: opts.includeFrames)
        s.relaunchedFrom = nil
        var text = (opts.disableDiff || opts.contains != nil ? full : (diff ?? full))
        text += retainedObservationNotice
        if s.generation == 1 { text += "\n" + Self.capabilities(s) }
        // Tooltip-sized AXDialog popups (Simulator shows a 52x20 "Window") are not targets.
        let others = windows(s).filter { !CFEqual($0.0, snap.window) }
            .filter { (AX.frame($0.0).map { $0.width * $0.height } ?? 0) >= 4000 }.map { $0.1 }
        if let note = AppResolver.choiceNotes.removeValue(forKey: s.pid) { text += "\n" + note }
        if !others.isEmpty {
            text += "\nOther windows of \(s.displayName): " + others.map { "\"\($0)\"" }.joined(separator: ", ") + " — target one with get_app_state(window: \"<title part>\")."
        }
        var shot: Screenshot?
        var warning: String?
        let info = WindowInfo.match(pid: s.pid, frame: snap.frame, title: snap.title)
        // Hold the capture indicator while leap is actively reading/driving this window, so the
        // user sees the same "this window is being watched" badge. Released after idle.
        if let info { await ShareIndicator.shared.hold(info.id) }
        if opts.includeScreenshot {
            if let info {
                do {
                    shot = try await Capture.window(info, scale: opts.scale, jpegQuality: opts.jpegQuality)
                    text += "\n(screenshot: \(shot!.pixelWidth)x\(shot!.pixelHeight) px, \(String(format: "%.2f", shot!.pointsPerPixel)) points/px)"
                } catch {
                    Diagnostics.shared.record(level:"warning",kind:"screenshot_unavailable",detail:String(describing:error))
                    warning = "\(error)"
                    text += "\n(screenshot unavailable: \(error))"
                }
            } else {
                text += "\n(screenshot unavailable: window is not on screen — minimized or on another Space)"
            }
        }
        if !snap.supportsStateChecks {
            text += "\nObservation incomplete: readFailures=\(snap.readFailures), deadline=\(snap.deadlineExceeded), captureTruncated=\(snap.truncated). Missing controls do not prove absence."
        }
        if snap.nodes.contains(where: \.untransformedFrame) {
            text += "\n[rotated]: this Simulator device is landscape but reports portrait-space frames. Click those elements by index/label (AXPress) or type_text/set_value with element_index; coordinates from their frames are refused. Screenshot coordinates remain valid; the wda backend handles rotation."
        }
        // Advisory (per-node optional metadata) failures do not affect what the agent can do;
        // they stay in the retained snapshot and the structured observation metadata, not the text.
        do {
            let footer=try recordSnapshot(snap, session:s)
            let recorded = recordings[s.pid] != nil
            // Inactive views kept alive in the tree (SwiftUI TabView pages) render as long runs of
            // disabled lines. Collapse them for every reader, not only recorded sessions.
            if !opts.includeDisabled {
                text = Self.collapseDisabledRuns(text, detailHint: recorded ? "ui_to_text for detail" : "get_app_state include_disabled=true for detail")
            }
            if recorded {text=compactObservation(text)}
            text += footer
        }
        catch { Diagnostics.shared.record(level:"error",kind:"snapshot_recording_failed",detail:String(describing:error)); text += "\nRecording failure: \(error). Prior input may have been sent; do not replay. Further recorded actions will be refused." }
        if let needle = opts.contains?.lowercased(), !needle.isEmpty { text = Self.filterElements(text, needle) }
        return State(text: text, screenshot: shot, warning: warning)
    }

    static func isElementLine(_ line: Substring) -> Bool {
        let t = line.drop { $0 == " " }
        return t.first == "[" && t.dropFirst().first?.isNumber == true
    }

    /// Keep header and notes, and only the element lines that contain `needle`.
    static func filterElements(_ text: String, _ needle: String) -> String {
        var kept: [Substring] = [], total = 0, hits = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isElementLine(line) {
                total += 1
                guard line.lowercased().contains(needle) else { continue }
                hits += 1
                kept.append(line.drop { $0 == " " })
            } else {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n") + "\n(\(hits) of \(total) elements contain \"\(needle)\"; others omitted)"
    }

    /// For error responses: a diff as is, but a full tree only as a one-line summary, so a
    /// failed call does not repeat a large tree the caller can read with get_app_state.
    public static func evidenceSummary(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let elements = lines.filter(isElementLine).count
        guard !text.contains("## Diff vs state"), elements > 30 else { return text }
        let header = lines.first.map(String.init) ?? ""
        return header + "\n(\(elements) elements; full tree omitted. Call get_app_state(disable_diff: true) to read it.)"
    }

    /// Cheap identity of a snapshot's visible content, for the stability poll.
    static func fingerprint(_ snap: AXWindowSnapshot) -> Int {
        var h = Hasher()
        h.combine(snap.title ?? "")
        for n in snap.nodes {
            h.combine(n.key); h.combine(n.value ?? ""); h.combine(n.title ?? ""); h.combine(n.description ?? "")
            h.combine(n.enabled); h.combine(n.selected); h.combine(n.focused)
        }
        return h.finalize()
    }

    /// What works for this target, stated once per session (first state) — the model should
    /// not have to discover by failing that a background Simulator ignores keystrokes.
    static func capabilities(_ s: AppSession) -> String {
        let bundle = s.app.bundleIdentifier ?? ""
        var caps = ["Capabilities of \(s.displayName): accessibility actions and value/selection edits: yes (verified by read-back);",
                    "coordinate clicks/drags/scrolls: posted to the process, not verified;"]
        if AppResolver.simulatorHostBundles.contains(bundle) {
            caps.append("background keystrokes: NOT delivered to a Simulator window (use set_value / type_text with element_index, which go through accessibility); tvOS device windows expose no app tree (screenshots + press_key with foreground=true).")
        } else if bundle.contains("electron") || bundle.hasPrefix("com.openai.chat") || bundle.hasPrefix("com.microsoft.VSCode") || bundle.hasPrefix("com.google.Chrome") || bundle.hasPrefix("com.microsoft.edgemac") {
            caps.append("background keystrokes: Chromium/Electron apps often ignore them; prefer accessibility edits or a browser tool.")
        } else {
            caps.append("background keystrokes: delivered to the key window once an element is focused; ⌘-chords go through menu items.")
        }
        return caps.joined(separator: " ")
    }

    func settle(_ s: AppSession) async throws {
        let since = Date().timeIntervalSince(s.lastActionAt)
        if since < settleDelay {
            try await Task.sleep(nanoseconds: UInt64((settleDelay - since) * 1_000_000_000))
        }
    }

    // MARK: - Actions

    public struct Target {
        public var elementIndex: Int?
        public var x: CGFloat?
        public var y: CGFloat?
        public init(elementIndex: Int? = nil, x: CGFloat? = nil, y: CGFloat? = nil) {
            self.elementIndex = elementIndex; self.x = x; self.y = y
        }
    }

    /// Make sure the session has an indexed snapshot so element_index / window-relative
    /// coordinates resolve even when the caller skipped get_app_state.
    func ensureIndexed(_ s: AppSession) async throws {
        guard s.elements.isEmpty else { return }
        let window = try await waitForWindow(s)
        guard let snap = walker.snapshot(window: window, app: s.axApp) else {
            throw LeapError.axFailure("window frame", .cannotComplete)
        }
        _ = s.render(snap, walker: walker)
    }

    /// Resolve a target to a screen point. Window-relative coordinates are offset by the
    /// window frame captured in the latest state.
    static func requireTransformedFrame(_ rec: ElementRecord) throws {
        guard rec.node.untransformedFrame else { return }
        throw LeapError.unsupported("Element [\(rec.index)] is inside a landscape Simulator device, whose accessibility frames are reported in unrotated portrait space; a coordinate derived from them would hit a different control. No pointer input was sent. Use an accessibility route (click without foreground uses AXPress; type_text/set_value with element_index insert through accessibility), a window coordinate read from a screenshot, or the wda backend.")
    }

    func screenPoint(_ s: AppSession, _ t: Target, allowUntransformed: Bool = false) throws -> (CGPoint, ElementRecord?) {
        if let i = t.elementIndex {
            let rec = try s.element(i)
            if !allowUntransformed { try Engine.requireTransformedFrame(rec) }
            guard let f = rec.node.frame else { throw LeapError.unsupported("element \(i) has no frame; use coordinates") }
            var p = CGPoint(x: f.midX, y: f.midY)
            if let x = t.x, let y = t.y { p = CGPoint(x: f.minX + x, y: f.minY + y) }
            return (p, rec)
        }
        guard let x = t.x, let y = t.y else { throw LeapError.unsupported("provide element_index or both x and y") }
        s.refreshWindowFrame() // the window may have moved since the state the caller read
        let wf = s.lastWindowFrame
        return (CGPoint(x: wf.minX + x, y: wf.minY + y), nil)
    }

    /// How synthesized input reaches the app.
    ///
    /// Background (`postToPid`) is the default and the app is *never* activated implicitly —
    /// the user keeps their mouse, keyboard and frontmost window while the agent works.
    /// Accessibility actions (press, set value, insert text, menu commands) are preferred over
    /// synthesized events precisely because they always work from the background.
    public struct InputMode {
        /// Opt in to activating the app. Pointer events remain window-targeted; keyboard fallback uses HID. For apps that
        /// ignore posted events (some games, custom GL/Metal canvases).
        public var foreground = false
        public init(foreground: Bool = false) { self.foreground = foreground }
    }

    /// Runs `body` with the app able to receive real input events. Unless the app is already
    /// frontmost (or `keepBackground` is set), it is activated for the duration of the call and
    /// the previously frontmost app is restored afterwards, so the user's focus survives.
    /// An activation held across a sequence of actions (a `batch`), so the app is brought
    /// forward at most once and the user's app is restored at most once.
    final class FocusHold {
        let session: AppSession
        let mode: InputMode
        /// nil until an action actually needs synthesized input; AX-only batches never activate.
        var delivery: Delivery?
        var restoreTo: NSRunningApplication?
        init(session: AppSession, mode: InputMode) { self.session = session; self.mode = mode }
    }

    var hold: FocusHold?

    /// Begin a held-focus sequence. Activation is lazy: a batch that only performs
    /// accessibility actions still runs entirely in the background.
    public func beginInputSession(app query: String, mode: InputMode = .init()) async throws {
        let s = try await session(for: query)
        hold = FocusHold(session: s, mode: mode)
    }

    /// End the sequence. Foreground mode does not re-activate the user's previous app: macOS 14
    /// ignores activation requests from a non-frontmost process, so a "restore" would be a
    /// no-op that lies. The user gets their app back by clicking it; the tool description says so.
    public func endInputSession() async {
        hold = nil
    }

    /// Flash the on-screen indicator (virtual pointer + sonar ripple) at a screen point.
    /// Purely cosmetic; never moves the user's real cursor.
    func signal(_ point: CGPoint?, _ ping: Overlay.Ping) async {
        await MainActor.run {
            if let point { Overlay.shared.signal(at: point, ping: ping) }
            else { Overlay.shared.hide() }
        }
    }

    /// Screen-point centre of an element index, for the indicator.
    func indicatorPoint(_ s: AppSession, _ index: Int?) -> CGPoint? {
        s.refreshWindowFrame()
        if let index {
            guard let rec = try? s.element(index) else { return nil }
            return IndicatorGeometry.point(frame: rec.node.frame, window: s.lastWindowFrame,
                                           offscreen: rec.node.offscreen)
        }
        return IndicatorGeometry.point(frame: s.lastWindowFrame, window: s.lastWindowFrame, offscreen: false)
    }

    static func isSheet(_ focused: AXUIElement, of window: AXUIElement) -> Bool {
        if let parent: AXUIElement = AX.attr(focused, kAXParentAttribute), CFEqual(parent, window) { return true }
        let children: [AXUIElement] = AX.attr(window, kAXChildrenAttribute) ?? []
        return children.contains { CFEqual($0, focused) }
    }

    /// Keyboard events posted to a process land in its key window. When the caller pinned a
    /// window that is not the key one (two Simulator devices, two documents), make it key via
    /// accessibility — this does not activate the app — and verify; otherwise refuse rather
    /// than type into the wrong window.
    func ensureKeyWindow(_ s: AppSession, foreground: Bool = false) throws {
        guard s.pinnedWindow != nil, let target = s.lastWindow else { return }
        let focused: AXUIElement? = AX.attr(s.axApp, kAXFocusedWindowAttribute)
        if let focused, CFEqual(focused, target) { return }
        // A sheet/alert attached to the selected window is its key surface: keys meant for the window go
        // there (keys go to the process, which routes them to its key window).
        if let focused, Self.isSheet(focused, of: target) { return }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        usleep(80_000)
        let now: AXUIElement? = AX.attr(s.axApp, kAXFocusedWindowAttribute)
        guard let now, CFEqual(now, target) else {
            let title: String = AX.attr(target, kAXTitleAttribute) ?? ""
            let advice = foreground
                ? "foreground=true was already requested and the app still kept another window key"
                : "the app refused to make it key from the background; foreground=true may help"
            throw LeapError.unsupported("Keyboard input would go to \(s.displayName)'s key window, not to the selected window \"\(title)\"; \(advice). Nothing was typed. set_value/type_text with element_index use accessibility and do not depend on the key window.")
        }
    }

    /// Verify live focus after activation/window selection, never infer it from a successful write.
    func requireTextFocus(_ element: AXUIElement, session s: AppSession) throws {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<5 {
            let focused: Bool = AX.attr(element, kAXFocusedAttribute) ?? false
            let active: AXUIElement? = AX.attr(s.axApp, kAXFocusedUIElementAttribute)
            if focused || active.map({ CFEqual($0, element) }) == true { return }
            usleep(40_000)
        }
        Diagnostics.shared.record(level:"error",kind:"text_focus_unverified",detail:"Live field focus could not be verified after window preparation. No keyboard input sent.")
        throw LeapError.unsupported("Editable control focus could not be verified. No keyboard input sent. Click the control using fresh geometry and inspect its focus before typing.")
    }

    func withInput<T>(_ s: AppSession, _ mode: InputMode, _ body: (Delivery) throws -> T) async throws -> T {
        let wantsForeground = mode.foreground || (hold?.session.pid == s.pid && hold?.mode.foreground == true)
        if wantsForeground { try await activate(s) }
        try ensureKeyWindow(s, foreground: wantsForeground)
        s.refreshWindowFrame()
        let title: String? = s.lastWindow.flatMap { AX.attr($0, kAXTitleAttribute) }
        guard !s.app.isTerminated,
              let window = WindowInfo.match(pid: s.pid, frame: s.lastWindowFrame, title: title) else {
            throw LeapError.unsupported("Keyboard target window is unavailable. No keyboard input sent.")
        }
        // Resolve the keyboard target, then post to the process (postToPid), even when
        // the app is foreground. Activation is a policy,
        // not permission to send keys into the system-wide input stream.
        let delivery = try Input.appKeyboardDelivery(pid: s.pid, window: window)
        hold?.delivery = delivery
        Diagnostics.shared.record(level:"info",kind:"keyboard_target",detail:"Process-directed keyboard delivery pid=\(s.pid) window=\(window.id); foreground requested=\(wantsForeground). No system-wide fallback.")
        return try body(delivery)
    }

    /// Native pointer transport is independent of foreground policy. Both modes
    /// resolve the same window and use the same scoped process-directed delivery.
    func withPointerInput<T>(_ s: AppSession, _ mode: InputMode, background: Input.BackgroundPointer = .activateWindow,
                             at point: CGPoint? = nil,
                             _ body: (Delivery, CGEventFlags) throws -> T) async throws -> T {
        let originalFrame = s.lastWindowFrame
        let wantsForeground = mode.foreground || (hold?.session.pid == s.pid && hold?.mode.foreground == true)
        if wantsForeground { try await activate(s) }
        s.refreshWindowFrame()
        guard originalFrame.approximatelyEquals(s.lastWindowFrame) else {
            throw LeapError.unsupported("The target window moved or resized before pointer delivery. No pointer input was sent; read get_app_state and retry.")
        }
        let title: String? = s.lastWindow.flatMap { AX.attr($0, kAXTitleAttribute) }
        guard let window = WindowInfo.match(pid: s.pid, frame: s.lastWindowFrame, title: title),
              window.bounds.approximatelyEquals(s.lastWindowFrame) else {
            throw LeapError.unsupported("Could not resolve the selected window for pointer delivery. No pointer input was sent; read get_app_state and retry.")
        }
        // Resolve the target window at the event point from the app's ordered windows. An alert sheet is its own window above the
        // main one; routing its clicks to the main window made them hit nothing.
        var target = window
        if let point, let front = WindowInfo.onScreen().first(where: { $0.pid == s.pid && $0.layer == 0 && $0.bounds.contains(point) }) {
            target = front
        }
        let delivery = Delivery.app(s.pid, window: target)
        return try Input.withPointerGesture(delivery, background: background) { try body(delivery, $0) }
    }

    /// Activate the app and *verify* it became frontmost. Never returns normally while another
    /// app is active, so synthesized HID events can't leak into the user's current app.
    func activate(_ s: AppSession) async throws {
        guard !AppResolver.isFrontmost(s.pid) else { return }
        Self.bringToFront(s.app, pid: s.pid)
        var deadline = Date().addingTimeInterval(1.0)
        while !AppResolver.isFrontmost(s.pid) && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if !AppResolver.isFrontmost(s.pid), let url = s.app.bundleURL {
            // LaunchServices fallback (works for apps that ignore AX frontmost).
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            Diagnostics.shared.record(level:"warning",kind:"activation_fallback",detail:"AX foreground activation did not establish frontmost; trying LaunchServices")
            do {_ = try await NSWorkspace.shared.openApplication(at:url,configuration:config)}
            catch {Diagnostics.shared.record(level:"error",kind:"activation_fallback_failed",detail:String(describing:error))}
            deadline = Date().addingTimeInterval(1.5)
            while !AppResolver.isFrontmost(s.pid) && Date() < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        guard AppResolver.isFrontmost(s.pid) else {
            throw LeapError.unsupported("Could not bring \(s.displayName) to the front to deliver input (macOS refused activation). No events were sent. Use an accessibility action (click by element_index / set_value) or retry with foreground=true.")
        }
        try await Task.sleep(nanoseconds: 80_000_000) // key window + first responder settle
    }

    /// Accessibility-based activation works from any AX-trusted process, unlike
    /// `NSRunningApplication.activate()` which macOS 14 ignores for non-frontmost callers.
    static func bringToFront(_ app: NSRunningApplication, pid: pid_t) {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window: AXUIElement = AX.attr(ax, kAXFocusedWindowAttribute) ?? AX.attr(ax, kAXMainWindowAttribute) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        app.activate()
    }

    /// Activate instead of Command-clicking when a click may change a selection, in web
    /// content and on Catalyst menu buttons; the role under the point is the available signal.
    static let selectionSensitiveRoles: Set<String> = ["AXRow", "AXCell", "AXOutline", "AXTable", "AXList",
        "AXLink", "AXWebArea", "AXMenuButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    static func backgroundPointer(role: String?) -> Input.BackgroundPointer {
        guard let role else { return .activateWindow }
        return selectionSensitiveRoles.contains(role) ? .activateWindow : .commandClick
    }
    /// Role of the element under a screen point in the target app.
    static func roleAt(_ s: AppSession, _ p: CGPoint) -> String? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(s.axApp, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
        return AX.attr(hit, kAXRoleAttribute)
    }

    public func click(app query: String, target: Target, button: MouseButton = .left, count: Int = 1,
                      modifiers: String? = nil, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: target.elementIndex != nil)
        // Rotated Simulator elements resolve here but may only use AXPress below.
        let (initialPoint, rec) = try screenPoint(s, target, allowUntransformed: true)
        var p = initialPoint
        let flags = try modifierFlags(modifiers)
        defer { s.lastActionAt = Date() }
        // Prefer the AX action: no synthesized events, no focus change, works for background apps.
        // Text elements are excluded: AXPress does not place the caret, so a later ⌘A / type
        // would act on the wrong first responder.
        // Inside a rotated Simulator device AXPress is the only correct route (for iOS text
        // fields it is the activation tap that focuses them), so take it in any mode.
        if let rec, button == .left, count == 1, flags.isEmpty, target.x == nil,
           rec.node.untransformedFrame || (!mode.foreground && !AXWalker.textRoles.contains(rec.node.role)),
           rec.node.actions.contains(kAXPressAction) {
            // AXPress needs no screen coordinate. Validate only its cosmetic marker,
            // before the action can remove the target or change the window.
            let marker = indicatorPoint(s, rec.index)
            // Bring a rotated Simulator element into
            // view first; an off-screen iOS text area acknowledges AXPress without taking focus.
            if rec.node.untransformedFrame, rec.node.actions.contains("AXScrollToVisible") {
                if AXUIElementPerformAction(rec.node.element, "AXScrollToVisible" as CFString) == .success {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            let err = AXUIElementPerformAction(rec.node.element, kAXPressAction as CFString)
            if err == .success {
                if marker == nil {
                    Diagnostics.shared.record(level:"warning",kind:"indicator_suppressed",detail:"AXPress acknowledged; invalid/offscreen marker geometry. element=\(rec.index) frame=\(String(describing:rec.node.frame)) window=\(s.lastWindowFrame) offscreen=\(rec.node.offscreen). No pointer event sent.",fields:["session":recordings[s.pid]?.id ?? "","app":s.displayName])
                }
                await signal(marker, .click)
                // A background app's menu can open a moment after AXPress returns; the settle loop may
                // see two identical reads first. Wait (never re-press: a late-opening menu would close)
                // until the menu shows items; a title click should return the open menu.
                if rec.node.role == "AXMenuBarItem" {
                    var opened = false
                    for _ in 0..<20 where !opened {
                        opened = ((AX.attr(rec.node.element, kAXChildrenAttribute) as [AXUIElement]?) ?? []).contains { menu in
                            guard let f = AX.frame(menu), f.width > 0, f.height > 0 else { return false }
                            return !((AX.attr(menu, kAXVisibleChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty
                        }
                        if !opened { try await Task.sleep(nanoseconds: 50_000_000) }
                    }
                    if !opened { return "pressed [\(rec.index)] via accessibility; the menu did not open within 1 s (not re-pressed; read the state)" }
                }
                return "pressed [\(rec.index)] via accessibility" + (marker == nil ? "; location indicator hidden: accessibility coordinates are unreliable" : "")
            }
            // A timeout/error is not proof that AXPress was rejected. A Save
            // can finish and destroy its button before the AX reply arrives.
            // Only an explicitly unsupported action permits pointer fallback;
            // otherwise a second click could repeat an already-applied action.
            // kAXErrorCannotComplete: SwiftUI commonly replaces a control while its action runs (a toggle
            // swapping icon, Save closing an editor), so the press often applied. Report the raw result as uncertain and let the caller verify; never re-press.
            if err == .cannotComplete {
                await signal(marker, .click)
                return "pressed [\(rec.index)] via accessibility; AX returned cannotComplete (-25204): uncertain — the action may have applied. Verify the state; do not press again"
            }
            guard err == .actionUnsupported else {
                throw LeapError.unsupported("Outcome uncertain: accessibility Press was sent to [\(rec.index)] but returned \(err) (code \(err.rawValue)). The action may already have completed. No coordinate fallback was sent. Read get_app_state and verify the result before deciding whether to retry.")
            }
        }
        if rec != nil {
            Diagnostics.shared.record(level:"warning",kind:"pointer_route",detail:"Using coordinate input instead of semantic press (unsupported AX action or requested input requires pointer delivery). Target geometry will be validated.",fields:["session":recordings[s.pid]?.id ?? "","app":s.displayName])
        }
        // Read live geometry, including enclosing scroll viewports: a row can be
        // inside the window but clipped by its scroll area. AXPress above remains
        // available for offscreen elements and Simulator coordinate quirks.
        if let record = rec, !record.node.role.hasPrefix("AXMenu") {
            if let visible = try visibleClickPoint(s, target) {
                p = visible
            } else {
                Diagnostics.shared.record(level:"warning",kind:"reveal_fallback",detail:"Target not visible; requesting AXScrollToVisible before revalidating. No coordinate click sent yet.")
                let result = AXUIElementPerformAction(record.node.element, "AXScrollToVisible" as CFString)
                guard result == .success else {
                    throw LeapError.unsupported("Element [\(record.index)] is outside the visible viewport and the app could not reveal it with AXScrollToVisible (\(result)). No coordinate click was sent. Scroll it into view, read get_app_state, then retry.")
                }
                // A successful request may animate or be ignored. Revalidate the
                // target identity and wait for two matching, visible positions.
                // Do not retry AXPress here: its earlier failure may be ambiguous.
                var previous: CGPoint?
                var revealed: CGPoint?
                for _ in 0..<12 {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    let current = try visibleClickPoint(s, target)
                    if let current, let previous,
                       abs(current.x - previous.x) < 0.5, abs(current.y - previous.y) < 0.5 {
                        revealed = current
                        break
                    }
                    previous = current
                }
                guard let finalPoint = try visibleClickPoint(s, target),
                      let stablePoint = revealed,
                      abs(finalPoint.x - stablePoint.x) < 0.5, abs(finalPoint.y - stablePoint.y) < 0.5 else {
                    throw LeapError.unsupported("Reveal was requested for element [\(record.index)], but its position did not become visible and stable. No coordinate click was sent. Read get_app_state before retrying.")
                }
                p = finalPoint
            }
        }
        let background = Self.backgroundPointer(role: rec?.node.role ?? Self.roleAt(s, p))
        try await withPointerInput(s, mode, background: background, at: p) { d, extra in
            // Caller-requested modifiers win; otherwise the background preparation's flags apply.
            try Input.click(at: p, button: button, count: count, flags: flags.isEmpty ? extra : flags, d)
        }
        await signal(p, .click)
        return "clicked \(button.rawValue)×\(count) at window (\(Int(p.x - s.lastWindowFrame.minX)),\(Int(p.y - s.lastWindowFrame.minY)))" + (rec.map { " on [\($0.index)]" } ?? "")
    }

    /// Return a usable point only after validating the original element against
    /// the live AX tree. Clip against scroll ancestors, not hit-test ancestry:
    /// decorative overlays may intercept hit tests above valid controls.
    private func visibleClickPoint(_ s: AppSession, _ target: Target) throws -> CGPoint? {
        guard let index = target.elementIndex else { return nil }
        let record = try s.element(index)
        try Engine.requireTransformedFrame(record)
        // Reveal/scroll can move a control without rebuilding the indexed tree.
        // Resolve its live geometry instead of retaining the pre-reveal rectangle.
        guard let frame = AX.frame(record.node.element) else { return nil }
        s.refreshWindowFrame()
        var visible = frame.intersection(s.lastWindowFrame)
        var ancestor: AXUIElement? = AX.attr(record.node.element, kAXParentAttribute)
        for _ in 0..<60 {
            guard let current = ancestor else { break }
            let role: String? = AX.attr(current, kAXRoleAttribute)
            if role == "AXScrollArea", let viewport = AX.frame(current) {
                visible = visible.intersection(viewport)
            }
            if role == "AXWindow" { break }
            ancestor = AX.attr(current, kAXParentAttribute)
        }
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        if let x = target.x, let y = target.y {
            let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
            return visible.contains(point) ? point : nil
        }
        return ClickGeometry.center(frame: frame, visible: visible)
    }

    public func drag(app query: String, from: Target, to: Target, steps: Int = 12, modifiers: String? = nil,
                     mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: from.elementIndex != nil || to.elementIndex != nil)
        let (a, _) = try screenPoint(s, from)
        let (b, _) = try screenPoint(s, to)
        let flags = try modifierFlags(modifiers)
        let steps = max(1, min(steps, 200))
        defer { s.lastActionAt = Date() }
        let background = Self.backgroundPointer(role: Self.roleAt(s, a))
        try await withPointerInput(s, mode, background: background, at: a) { d, extra in
            try Input.drag(from: a, to: b, flags: flags.isEmpty ? extra : flags, steps: steps, d)
        }
        await MainActor.run { Overlay.shared.signalDrag(from: a, to: b) }
        return "dragged"
    }

    public func scroll(app query: String, target: Target, direction: String, pages: Double = 1,
                       pixels: Int? = nil, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: target.elementIndex != nil)
        let (p, rec) = try screenPoint(s, target)
        let extent = rec?.node.frame ?? s.lastWindowFrame
        defer { s.lastActionAt = Date() }
        var dx: Int32 = 0, dy: Int32 = 0
        func bounded(_ v: Double) -> Int32 { Int32(max(-100_000, min(100_000, v.isFinite ? v : 0))) }
        let pages = max(0, min(pages, 50))
        let vertical = bounded(pixels.map { Double($0) } ?? (Double(extent.height) * 0.85 * pages))
        let horizontal = bounded(pixels.map { Double($0) } ?? (Double(extent.width) * 0.85 * pages))
        switch direction.lowercased() {
        case "down", "d": dy = -vertical
        case "up", "u": dy = vertical
        case "right", "r": dx = -horizontal
        case "left", "l": dx = horizontal
        default: throw LeapError.unsupported("direction must be up/down/left/right")
        }
        // macOS page actions describe movement of the content: moving content
        // up reveals the next page below. Prefer them to background wheel events,
        // which SwiftUI can accept without moving its scroll view.
        if pixels == nil, pages >= 1, pages.rounded(.down) == pages,
           let record = rec {
            let action: String
            if dy < 0 { action = "AXScrollUpByPage" }
            else if dy > 0 { action = "AXScrollDownByPage" }
            else if dx < 0 { action = "AXScrollLeftByPage" }
            else { action = "AXScrollRightByPage" }
            var candidate: AXUIElement? = record.node.element
            for _ in 0..<60 {
                guard let element = candidate else { break }
                if AX.actions(element).contains(action) {
                    for page in 0..<Int(pages) {
                        let result = AXUIElementPerformAction(element, action as CFString)
                        guard result == .success else {
                            // Never replay the full request using another path after
                            // some pages have already been applied.
                            throw LeapError.unsupported("Accessibility scroll failed after \(page) of \(Int(pages)) page requests (\(result)). Read get_app_state before retrying.")
                        }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    await signal(p, .scroll)
                    return "requested scroll \(direction), \(Int(pages)) page(s), via accessibility; verify movement in the returned state"
                }
                let role: String? = AX.attr(element, kAXRoleAttribute)
                if role == "AXWindow" { break }
                candidate = AX.attr(element, kAXParentAttribute)
            }
        }
        Diagnostics.shared.record(level:"warning",kind:"scroll_pointer_route",detail:"Using wheel events; semantic page scrolling unavailable or unsuitable for requested scroll. Movement requires verification.")
        try await withPointerInput(s, mode, at: p) { d, _ in try Input.scroll(at: p, dx: dx, dy: dy, d) }
        await signal(p, .scroll)
        return "dispatched scroll \(direction) (wheel events; verify movement in the returned state)"
    }

    public func pressKey(app query: String, key: String, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: false)
        let chord = try Keys.parse(key)
        defer { s.lastActionAt = Date() }
        // Prefer semantic keyboard equivalents: command chords press the matching menu item, Return confirms,
        // Escape cancels. Synthesized keystrokes are the fallback, not the mechanism.
        if !mode.foreground, let done = try axKeyPress(s, chord, key) {
            await signal(indicatorPoint(s, nil), .edit)
            return done
        }
        Diagnostics.shared.record(level:"warning",kind:"keyboard_route",detail:"Using synthesized key input; semantic route unavailable or foreground mode requested. foreground=\(mode.foreground)")
        try await withInput(s, mode) { d in try Input.press(chord, d) }
        await signal(indicatorPoint(s, nil), .edit)
        return "pressed \(key) (synthesized keystroke)"
    }

    /// Try to satisfy a key press through accessibility. Returns a description on success,
    /// nil when nothing in the AX tree handles it (caller falls back to keystrokes).
    func axKeyPress(_ s: AppSession, _ chord: KeyChord, _ key: String) throws -> String? {
        func dispatch(_ element: AXUIElement, _ action: String) throws -> Bool {
            let status = AXUIElementPerformAction(element, action as CFString)
            if status == .success { return true }
            if status == .actionUnsupported { return false }
            throw LeapError.unsupported("Semantic keyboard action returned \(status.name). Outcome uncertain; no synthesized key fallback sent.")
        }
        let focused: AXUIElement? = AX.attr(s.axApp, kAXFocusedUIElementAttribute)
        if chord.flags.contains(.maskCommand), let code = chord.keyCode {
            // Text editing chords: AppKit disables Edit-menu items for a background app (no key
            // window to validate against), so these go through the AX text API instead — the
            // text system handles selectAll: directly, without menu presses.
            let plainCommand = chord.flags.subtracting([.maskCommand, .maskNonCoalesced, .maskNumericPad]).isEmpty
            if plainCommand, let target = focused, let done = try axTextCommand(target, code) { return done }
            if let item = menuItem(s, matching: chord) {
                let enabled: Bool = AX.attr(item.element, kAXEnabledAttribute) ?? true
                if enabled, try dispatch(item.element, kAXPressAction) {
                    return "pressed menu item \"\(item.path)\" for \(key) via accessibility"
                }
                if !enabled {
                    return "menu item \"\(item.path)\" for \(key) is disabled while the app is in the background; nothing was done"
                }
            }
            return nil
        }
        guard chord.flags.isEmpty, let code = chord.keyCode else { return nil }
        if code == 53, let menu = openMenu(s) { // Escape closes an open menu-bar menu
            if try dispatch(menu, kAXCancelAction) {
                return "closed the open menu via accessibility (Escape)"
            }
        }
        guard let target = focused else { return nil }
        let actions = AX.actions(target)
        switch code {
        case 36, 76: // Return / Enter
            if actions.contains("AXConfirm"), try dispatch(target, "AXConfirm") {
                return "confirmed focused element via accessibility (Return)"
            }
        case 53: // Escape
            if actions.contains("AXCancel"), try dispatch(target, "AXCancel") {
                return "cancelled focused element via accessibility (Escape)"
            }
        default: break
        }
        return nil
    }

    /// ⌘A / ⌘C / ⌘V / ⌘X on the focused text element through the accessibility text API.
    func axTextCommand(_ target: AXUIElement, _ code: CGKeyCode) throws -> String? {
        let selectedRange: CFTypeRef? = AX.attr(target, kAXSelectedTextRangeAttribute)
        guard selectedRange != nil else { return nil } // not a text element
        let length: Int = AX.attr(target, kAXNumberOfCharactersAttribute) ?? ((AX.attr(target, kAXValueAttribute) as String?)?.utf16.count ?? 0)
        func selectAll() throws -> Bool {
            var range = CFRange(location: 0, length: length)
            guard let v = AXValueCreate(.cfRange, &range) else { return false }
            let status = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, v)
            var observed = CFRange(location: -1, length: -1)
            if let actual: CFTypeRef = AX.attr(target, kAXSelectedTextRangeAttribute), CFGetTypeID(actual) == AXValueGetTypeID() {
                AXValueGetValue(actual as! AXValue, .cfRange, &observed)
                if observed.location == 0 && observed.length == length { return true }
            }
            throw LeapError.unsupported("Select All did not establish the requested selection (\(status.name)). No keyboard fallback sent; inspect selection before typing.")
        }
        func replaceSelection(_ text: String, description: String) throws -> String? {
            switch AX.insertText(target, text, replaceAll: false) {
            case .verified: return "\(description) via accessibility (readback verified)"
            case .unchanged, .notText: return nil
            case .uncertain(let why): throw LeapError.unsupported("Text shortcut outcome uncertain: \(why). No keyboard fallback sent.")
            }
        }
        switch code {
        case 0: // A
            return try selectAll() ? "selected all text (\(length) characters) via accessibility" : nil
        case 8: // C
            let text: String = AX.attr(target, kAXSelectedTextAttribute) ?? ""
            guard !text.isEmpty else { return "nothing selected to copy" }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return "copied \(text.count) characters to the clipboard via accessibility"
        case 9: // V
            guard let text = NSPasteboard.general.string(forType: .string) else { return "clipboard has no text" }
            return try replaceSelection(text, description: "pasted")
        case 7: // X
            let text: String = AX.attr(target, kAXSelectedTextAttribute) ?? ""
            guard !text.isEmpty else { return "nothing selected to cut" }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return try replaceSelection("", description: "cut selected text")
        default:
            return nil
        }
    }

    /// The AXMenu of a menu-bar title that is currently open (non-zero frame, visible items).
    func openMenu(_ s: AppSession) -> AXUIElement? {
        guard let bar: AXUIElement = AX.attr(s.axApp, kAXMenuBarAttribute),
              let items: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute) else { return nil }
        for item in items {
            for menu in (AX.attr(item, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let f = AX.frame(menu), f.width > 0, f.height > 0 { return menu }
            }
        }
        return nil
    }

    struct MenuHit { let element: AXUIElement; let path: String }

    /// Find the menu item whose key equivalent matches the chord (Edit › Select All for ⌘A).
    /// AXMenuItemCmdModifiers bits: 1 shift, 2 option, 4 control, 8 = no command key.
    func menuItem(_ s: AppSession, matching chord: KeyChord) -> MenuHit? {
        guard let code = chord.keyCode else { return nil }
        var want = 0
        if chord.flags.contains(.maskShift) { want |= 1 }
        if chord.flags.contains(.maskAlternate) { want |= 2 }
        if chord.flags.contains(.maskControl) { want |= 4 }
        let wantChar = Keys.character(for: code).map { String($0).uppercased() }
        guard let bar: AXUIElement = AX.attr(s.axApp, kAXMenuBarAttribute) else { return nil }
        func search(_ el: AXUIElement, _ path: [String], _ depth: Int) -> MenuHit? {
            guard depth < 6, let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) else { return nil }
            for kid in kids {
                let a = AX.attrs(kid, [kAXRoleAttribute, kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey"])
                let role = a[kAXRoleAttribute] as? String ?? ""
                let title = a[kAXTitleAttribute] as? String ?? ""
                if role == "AXMenuItem" {
                    let mods = (a["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? 8
                    let cmdChar = (a["AXMenuItemCmdChar"] as? String ?? "").uppercased()
                    let vkey = (a["AXMenuItemCmdVirtualKey"] as? NSNumber)?.intValue
                    let charHit = wantChar != nil && !cmdChar.isEmpty && cmdChar == wantChar
                    let keyHit = vkey != nil && vkey == Int(code)
                    if (charHit || keyHit) && (mods & 7) == want && (mods & 8) == 0 {
                        return MenuHit(element: kid, path: (path + [title]).joined(separator: " › "))
                    }
                }
                if let hit = search(kid, role == "AXMenu" ? path : path + [title].filter { !$0.isEmpty }, depth + 1) { return hit }
            }
            return nil
        }
        return search(bar, [], 0)
    }

    public func typeText(app query: String, text: String, elementIndex: Int? = nil, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: elementIndex != nil)
        defer { s.lastActionAt = Date() }
        if let i = elementIndex {
            let rec = try s.element(i)
            // Background-safe path: insert through the text system so bindings/notifications fire.
            if !mode.foreground {
                switch AX.insertText(rec.node.element, text, replaceAll: false) {
                case .verified:
                    await signal(indicatorPoint(s, i), .edit)
                    return "inserted \(text.count) characters into [\(i)] via accessibility (verified)"
                case .uncertain(let why):
                    throw LeapError.unsupported("Outcome uncertain: the insert into [\(i)] changed the field but \(why). Not retried, to avoid duplicating text; read the state and decide.")
                case .unchanged, .notText:
                    Diagnostics.shared.record(level:"warning",kind:"text_value_fallback",detail:"AX text insertion unavailable or unchanged; attempting supported value edit before keystrokes. Text omitted.")
                    break
                }
            }
            // Simulator multiline AXValue readback can match without updating the binding.
            let unsafeValue = AppResolver.isSimulatorHost(s.app) && rec.node.role == "AXTextArea"
            if !mode.foreground, !unsafeValue, rec.node.settable,
               let _ = try AX.appendValue(rec.node.element, text, placeholder: rec.node.placeholder) {
                await signal(indicatorPoint(s, i), .edit)
                return "appended \(text.count) characters to [\(i)] via accessibility value (readback matched; persistence unverified)"
            }
        }
        Diagnostics.shared.record(level:"warning",kind:"text_keyboard_route",detail:"Using synthesized text input; not verified. foreground=\(mode.foreground). Text omitted.")
        try await withInput(s, mode) { d in
            if let i = elementIndex { try self.requireTextFocus(try s.element(i).node.element, session: s) }
            try Input.type(text, requirePhysical: AppResolver.isSimulatorHost(s.app), d)
        }
        await signal(indicatorPoint(s, elementIndex), .edit)
        return "typed \(text.count) characters (keystrokes dispatched; not verified)"
    }

    public func setValue(app query: String, elementIndex: Int, value: String, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: true)
        let rec = try s.element(elementIndex)
        defer { s.lastActionAt = Date() }
        // Writing the same value changes nothing app-side (no binding fires), so an expectation that
        // depends on a change would fail; say so instead of claiming a set.
        if let current = AX.string(AX.attr(rec.node.element, kAXValueAttribute) as CFTypeRef?), current == value {
            return "value unchanged: [\(elementIndex)] already holds this value; nothing sent (the app sees no edit)"
        }
        // 1. Text elements: replace the selection through the text system (fires change notifications,
        //    so SwiftUI/AppKit bindings update — a raw kAXValue write often does not).
        switch AX.insertText(rec.node.element, value, replaceAll: true) {
        case .verified:
            await signal(indicatorPoint(s, elementIndex), .edit)
            return "replaced text of [\(elementIndex)] via accessibility selection (verified)"
        case .uncertain(let why):
            throw LeapError.unsupported("Outcome uncertain: [\(elementIndex)] changed but \(why). Not retried; read the state and decide.")
        case .unchanged, .notText:
            break
        }
        // A provider can accept AXValue and change its displayed text without updating
        // the application binding. Simulator TextEditor reproduced this: immediate
        // readback matched, but save/reopen lost the notes. Respect the provider's
        // capability instead of probing an unsupported write or guessing keyboard focus.
        let unsafeSimulatorTextValue = AppResolver.isSimulatorHost(s.app) && rec.node.role == "AXTextArea"
        guard !unsafeSimulatorTextValue, AX.isSettable(rec.node.element, kAXValueAttribute) else {
            Diagnostics.shared.record(level:"warning",kind:"set_value_not_settable",detail:"Direct AX value replacement refused: unsupported value capability or Simulator multiline binding risk. No value write or keyboard fallback sent. Text omitted.")
            throw LeapError.unsupported("[\(elementIndex)] requires normal text input: direct value replacement is unsupported or unsafe for this multiline editor, and selection replacement was unavailable or unchanged. Direct value write was not sent. Focus the editable control, use type_text, and verify the saved result by reopening it.")
        }
        Diagnostics.shared.record(level:"warning",kind:"set_value_fallback",detail:"Selection-based value replacement unavailable or unchanged; attempting supported direct AX value. Readback does not prove application persistence. Value omitted.")
        // 2. Generic settable value (sliders, checkboxes, steppers, non-text fields). Numeric
        //    controls want a number, not a string.
        let current: CFTypeRef? = AX.attr(rec.node.element, kAXValueAttribute)
        var payload: CFTypeRef = value as CFTypeRef
        if let n = current as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID() || CFGetTypeID(n) == CFBooleanGetTypeID() {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                switch value.lowercased() {
                case "1", "true", "on", "yes": payload = kCFBooleanTrue
                case "0", "false", "off", "no": payload = kCFBooleanFalse
                default: throw LeapError.unsupported("[\(elementIndex)] holds a boolean; pass true/false (or on/off).")
                }
            } else if let d = Double(value) {
                payload = NSNumber(value: d)
            } else {
                throw LeapError.unsupported("[\(elementIndex)] holds a number (\(n)); the supplied value (\(value.count) characters) is not numeric.")
            }
        }
        let err = AXUIElementSetAttributeValue(rec.node.element, kAXValueAttribute as CFString, payload)
        if err == .success {
            // Read back before claiming success: iOS Simulator fields answer success and keep
            // the old text for some writes (an empty string, for one).
            usleep(80_000)
            let after = AX.string(AX.attr(rec.node.element, kAXValueAttribute) as CFTypeRef?) ?? ""
            let numericMatch = (payload as? NSNumber).map { n in (Double(after) ?? .nan) == n.doubleValue || after == n.stringValue } ?? false
            if after == value || numericMatch || (value.isEmpty && after == rec.node.placeholder) {
                await signal(indicatorPoint(s, elementIndex), .edit)
                return "set value of [\(elementIndex)]"
            }
            throw LeapError.unsupported("Value write returned success but readback did not match. Outcome uncertain; no keyboard replacement sent. Inspect the retained state before another edit.")
        }
        guard AXWalker.textRoles.contains(rec.node.role) else {
            throw LeapError.axFailure("set value", err)
        }
        // Failed writes can still have side effects; do not overwrite changed/unknown state.
        let afterFailure: CFTypeRef? = AX.attr(rec.node.element, kAXValueAttribute)
        guard let current, let afterFailure, CFEqual(current, afterFailure) else {
            throw LeapError.unsupported("Failed value write left changed or unreadable state. No keyboard fallback sent.")
        }
        try await withInput(s, mode) { d in
            try self.requireTextFocus(rec.node.element, session: s)
            try Input.press(KeyChord(keyCode: 0, flags: .maskCommand), d) // ⌘A
            try Input.type(value, requirePhysical: AppResolver.isSimulatorHost(s.app), d)
        }
        return "AX set failed (\(err.name)); focused [\(elementIndex)], selected all and typed instead"
    }

    public func performAction(app query: String, elementIndex: Int, action: String) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: true)
        let rec = try s.element(elementIndex)
        let wanted = action.lowercased().replacingOccurrences(of: " ", with: "")
        guard let name = rec.node.actions.first(where: {
            let n = $0.lowercased()
            return n == wanted || n == "ax" + wanted || n.dropFirst(2) == wanted
                || AX.actionName($0).lowercased().replacingOccurrences(of: " ", with: "") == wanted
        }) else {
            throw LeapError.unsupported("element [\(elementIndex)] does not expose \"\(action)\"; available: \(rec.node.actions.map(AX.actionName).joined(separator: ", "))")
        }
        defer { s.lastActionAt = Date() }
        let err = AXUIElementPerformAction(rec.node.element, name as CFString)
        guard err == .success else { throw LeapError.axFailure(name, err) }
        await signal(indicatorPoint(s, elementIndex), .click)
        return "performed \(name) on [\(elementIndex)]"
    }

    public func paste(app query: String, text: String, html: String? = nil, mode: InputMode = .init()) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: false)
        defer { s.lastActionAt = Date() }
        // Plain text into a focused text element: insert through the accessibility text API and
        // read it back, like press_key super+v. A background app's Edit menu is disabled, so a
        // posted ⌘V is often ignored (a paste can time out waiting for the clipboard read there).
        // Rich (html) content and non-text focus keep the pasteboard + ⌘V route.
        if html == nil, !mode.foreground, let focused: AXUIElement = AX.attr(s.axApp, kAXFocusedUIElementAttribute) {
            switch AX.insertText(focused, text, replaceAll: false) {
            case .verified:
                await signal(indicatorPoint(s, nil), .edit)
                return "pasted \(text.count) characters into the focused element via accessibility (verified; clipboard untouched)"
            case .uncertain(let why):
                throw LeapError.unsupported("Outcome uncertain: the paste changed the focused field but \(why). Not retried; read the state and decide.")
            case .unchanged, .notText:
                break
            }
        }
        try await withInput(s, mode) { d in try Input.paste(text, html: html, d) }
        await signal(indicatorPoint(s, nil), .edit)
        return "paste of \(text.count) characters dispatched (⌘V posted; check the state to verify insertion)"
    }

    public enum SelectionType: String { case text, cursorBefore = "cursor_before", cursorAfter = "cursor_after" }

    /// Select `text` inside an editable element (or place the caret before/after it), through
    /// the accessibility selected-text range.
    public func selectText(app query: String, elementIndex: Int, text: String, prefix: String? = nil,
                           suffix: String? = nil, selection: SelectionType = .text) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: true)
        let rec = try s.element(elementIndex)
        let el = rec.node.element
        guard AX.isSettable(el, kAXSelectedTextRangeAttribute) else {
            throw LeapError.unsupported("[\(elementIndex)] \(rec.node.role.dropFirst(2)) has no selectable text range; select_text needs a text field/area.")
        }
        let value: String = AX.attr(el, kAXValueAttribute) ?? ""
        let needle = (prefix ?? "") + text + (suffix ?? "")
        let hits = value.ranges(of: needle)
        guard let hit = hits.first else {
            throw LeapError.unsupported("\"\(needle)\" does not occur in [\(elementIndex)] (value is \"\(value.prefix(120))\").")
        }
        if hits.count > 1 {
            throw LeapError.unsupported("\"\(needle)\" occurs \(hits.count) times in [\(elementIndex)]; add prefix/suffix to disambiguate.")
        }
        let utf16 = value.utf16
        let start = utf16.distance(from: utf16.startIndex, to: hit.lowerBound.samePosition(in: utf16)!) + (prefix ?? "").utf16.count
        let length = text.utf16.count
        var range: CFRange
        switch selection {
        case .text: range = CFRange(location: start, length: length)
        case .cursorBefore: range = CFRange(location: start, length: 0)
        case .cursorAfter: range = CFRange(location: start + length, length: 0)
        }
        defer { s.lastActionAt = Date() }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(60_000)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            throw LeapError.axFailure("set selected text range", .cannotComplete)
        }
        // Verify.
        var got = CFRange(location: -1, length: -1)
        if let v: CFTypeRef = AX.attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cfRange, &got)
        }
        guard got.location == range.location, got.length == range.length else {
            throw LeapError.unsupported("[\(elementIndex)] accepted the selection but reports range \(got.location)+\(got.length) instead of \(range.location)+\(range.length).")
        }
        await signal(indicatorPoint(s, elementIndex), .edit)
        switch selection {
        case .text: return "selected \"\(text)\" in [\(elementIndex)] (characters \(start)–\(start + length))"
        case .cursorBefore: return "placed the caret before \"\(text)\" in [\(elementIndex)]"
        case .cursorAfter: return "placed the caret after \"\(text)\" in [\(elementIndex)]"
        }
    }

    /// Resolve a human label (title / description / value / placeholder) to an element index
    /// in the latest state. Exact (case-insensitive) matches win; otherwise a unique substring
    /// match; otherwise an error listing the candidates so the model can pick.
    public enum WaitCondition: String { case appears, disappears, enabled, disabled, valueContains = "value_contains" }

    /// Block until a labelled element satisfies `condition`, re-reading the tree every 300 ms,
    /// up to `timeout` seconds. Returns a description; throws on deadline so a batch stops.
    /// "The tree stopped changing" is not "the operation finished" — this is the explicit form.
    public func waitFor(app query: String, label: String, condition: WaitCondition, value: String? = nil,
                        timeout: TimeInterval) async throws -> String {
        try requireAX()
        let s = try await actionSession(query, needsElements: false)
        let timeout = max(0.1, min(timeout, 60))
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let started = Date()
        let grace=min(max(0,settleDelay-Date().timeIntervalSince(s.lastActionAt)),timeout/2)
        if grace>0 {try await Task.sleep(nanoseconds:UInt64(grace*1_000_000_000))}
        var lastSeen = "not present"
        var hadCompleteObservation=false
        while true {
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            guard remaining>0 else {
                throw LeapError.unsupported(hadCompleteObservation ? "Expectation unmet by deadline; last observed: \(lastSeen). No input retry." : "Expectation unknown: observation deadline exhausted; input is not retried")
            }
            let window = try await waitForWindow(s,timeout:remaining)
            guard let snap = walker.snapshot(window:window,app:s.axApp,timeout:max(0.01,deadline-ProcessInfo.processInfo.systemUptime)) else {
                if ProcessInfo.processInfo.systemUptime < deadline {continue}
                throw LeapError.unsupported("Expectation unknown: accessibility observation unavailable")
            }
            _ = try recordSnapshot(snap, session: s)
            let needle = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { throw LeapError.unsupported("Expectation needs a nonempty label") }
            let exact = snap.nodes.filter { $0.exactLabels.contains(needle) }
            let nodes = exact.isEmpty ? snap.nodes.filter { $0.visibleLabels.contains { $0.contains(needle) } } : exact
            let hits = nodes.map { ElementRecord(index: s.indexByKey[$0.key] ?? 0, node: $0) }
            guard hits.count <= 1 else { throw LeapError.unsupported("Expectation unknown: label matches multiple elements; use a more specific label") }
            let incomplete = !snap.supportsStateChecks
            if incomplete || ProcessInfo.processInfo.systemUptime > deadline {
                if ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds:UInt64(min(0.3,max(0,deadline-ProcessInfo.processInfo.systemUptime))*1_000_000_000));continue
                }
                throw LeapError.unsupported("Expectation unknown: incomplete or late observation; no input retry. Read failures=\(snap.readFailures)")
            }
            hadCompleteObservation=true
            let met: Bool
            switch condition {
            case .appears: met = !hits.isEmpty
            case .disappears: met = hits.isEmpty
            case .enabled: met = hits.contains { $0.node.enabled }
            case .disabled: met = !hits.isEmpty && hits.allSatisfy { !$0.node.enabled }
            case .valueContains:
                let want = (value ?? "").lowercased()
                met = hits.contains { ($0.node.value ?? "").lowercased().contains(want) }
            }
            if let h = hits.first {
                lastSeen = (h.index > 0 ? "[\(h.index)] " : "[new node; use the returned state for its index] ") + "\(h.node.role.dropFirst(2))" + (h.node.enabled ? "" : " [disabled]") + (h.node.value.map { " value=\"\($0.prefix(60))\"" } ?? "")
            } else { lastSeen = "not present" }
            if met {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                return "condition met after \(ms) ms: \"\(label)\" \(condition.rawValue)\(value.map { " \"\($0)\"" } ?? "") (\(lastSeen))"
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw LeapError.unsupported("wait_for timed out after \(Int(timeout)) s: \"\(label)\" did not become \(condition.rawValue)\(value.map { " \"\($0)\"" } ?? ""); last seen: \(lastSeen). This wait sent no input; earlier actions may already have been applied.")
            }
            try await Task.sleep(nanoseconds: UInt64(min(0.3,max(0,deadline-ProcessInfo.processInfo.systemUptime))*1_000_000_000))
        }
    }

    /// Elements whose title/description/value/placeholder/identifier equals `label`, or failing
    /// that, whose visible text contains it.
    static func matching(_ s: AppSession, label: String) -> [ElementRecord] {
        let needle = label.trimmingCharacters(in: .whitespaces).lowercased()
        let all = s.elements.values.sorted { $0.index < $1.index }
        let exact = all.filter { $0.node.exactLabels.contains(needle) }
        return exact.isEmpty ? all.filter { $0.node.visibleLabels.contains { $0.contains(needle) } } : exact
    }

    public func findElement(app query: String, label: String, fresh: Bool = false) async throws -> Int {
        try requireAX()
        let s = try await actionSession(query, needsElements: true)
        let needle = label.trimmingCharacters(in: .whitespaces).lowercased()
        var all = s.elements.values.sorted { $0.index < $1.index }
        // The stored state can predate an earlier step of the same call (a batch that closed a
        // dialog or loaded a page). Without an exact match, read the window once more.
        if fresh || !all.contains(where: { $0.node.exactLabels.contains(needle) }),
           let window = try? await waitForWindow(s), let snap = walker.snapshot(window: window, app: s.axApp) {
            s.refreshElements(snap)
            all = s.elements.values.sorted { $0.index < $1.index }
        }
        var exact = all.filter { $0.node.exactLabels.contains(needle) }
        if exact.count == 1 { return exact[0].index }
        // A button "Library" and a heading "LIBRARY" both match exactly; the one that can be
        // acted on is what a caller giving a label means.
        if exact.count > 1 {
            // "Release notes" vs a "RELEASE NOTES" heading: an exact-case match is the stronger signal.
            let raw = label.trimmingCharacters(in: .whitespaces)
            let cased = exact.filter { [$0.node.title, $0.node.description, $0.node.value, $0.node.placeholder, $0.node.identifier].contains(raw) }
            if cased.count == 1 { return cased[0].index }
            if !cased.isEmpty { exact = cased }
            let actionable = exact.filter { $0.node.actions.contains(kAXPressAction) || $0.node.settable }
            if actionable.count == 1 { return actionable[0].index }
            if !actionable.isEmpty { exact = actionable }
        }
        let partial = exact.isEmpty ? all.filter { $0.node.visibleLabels.contains { $0.contains(needle) } } : exact
        if partial.count == 1 { return partial[0].index }
        if partial.isEmpty { throw LeapError.unsupported("No element labelled \"\(label)\" in the latest state of \(s.displayName).") }
        let list = partial.prefix(8).map { "[\($0.index)] \($0.node.role.dropFirst(2)) \($0.node.title ?? $0.node.description ?? $0.node.value ?? "")" }
        throw LeapError.unsupported("\"\(label)\" is ambiguous (\(partial.count) matches): " + list.joined(separator: "; ") + ". Use element_index.")
    }

    /// Frame of the app's key window in screen points (used for window-center defaults).
    public func windowFrame(app query: String) async throws -> CGRect {
        try requireAX()
        let s = try await session(for: query)
        let window = try await waitForWindow(s)
        guard let frame = AX.frame(window) else { throw LeapError.noWindow(s.displayName) }
        return frame
    }

    /// Every normal window on screen, front to back, from window-server metadata (no pixels),
    /// plus each display's usable area. For arranging windows without screenshots.
    public func windowLayout() -> String {
        let names = Dictionary(NSWorkspace.shared.runningApplications.map { (AppResolver.pid(of: $0), $0.localizedName ?? "pid \($0.processIdentifier)") },
                               uniquingKeysWith: { a, _ in a })
        let front = NSWorkspace.shared.frontmostApplication.map { AppResolver.pid(of: $0) }
        var text = "## Windows, front to back (screen points, top-left origin)\n"
        let windows = WindowInfo.onScreen().filter { $0.layer == 0 && $0.bounds.width > 40 && $0.bounds.height > 40 }
        for (i, w) in windows.enumerated() {
            let b = w.bounds
            var line = "\(i + 1). \(names[w.pid] ?? "pid \(w.pid)") pid=\(w.pid)"
            if let t = w.title, !t.isEmpty { line += " \"\(t)\"" }
            line += " \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)),\(Int(b.minY)))"
            if w.pid == front { line += " [frontmost app]" }
            text += line + "\n"
        }
        if windows.isEmpty { text += "(none; window titles need Screen Recording permission)\n" }
        // NSScreen uses a bottom-left origin; convert to the top-left space windows use.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for (i, screen) in NSScreen.screens.enumerated() {
            let v = screen.visibleFrame
            text += "Display \(i + 1): \(Int(screen.frame.width))x\(Int(screen.frame.height)); usable \(Int(v.width))x\(Int(v.height)) at (\(Int(v.minX)),\(Int(mainHeight - v.maxY)))\n"
        }
        return text
    }

    /// Move and/or resize the app's target window through accessibility (no activation).
    /// Returns the frame read back, since apps may clamp sizes.
    public func setWindowFrame(app query: String, window: String?, x: CGFloat?, y: CGFloat?,
                               width: CGFloat?, height: CGFloat?) async throws -> String {
        try requireAX()
        let s = try await session(for: query)
        if let window { s.pinnedWindow = window.isEmpty ? nil : window }
        let target = try await waitForWindow(s)
        guard let old = AX.frame(target) else { throw LeapError.unsupported("Could not read the window's frame; nothing was changed.") }
        if width != nil || height != nil {
            var size = CGSize(width: width ?? old.width, height: height ?? old.height)
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, v)
            }
        }
        if x != nil || y != nil {
            var origin = CGPoint(x: x ?? old.minX, y: y ?? old.minY)
            if let v = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, v)
            }
        }
        // Apps finish resizing (and may adjust the size) after the request; read back once two
        // successive readings agree, up to a second.
        var now = AX.frame(target)
        for _ in 0..<10 {
            usleep(100_000)
            let next = AX.frame(target)
            if let a = now, let b = next, a.approximatelyEquals(b, tolerance: 0.5) { break }
            now = next
        }
        guard let now else { throw LeapError.unsupported("Frame set; could not read it back.") }
        s.refreshWindowFrame()
        func fmt(_ r: CGRect) -> String { "\(Int(r.width))x\(Int(r.height)) at (\(Int(r.minX)),\(Int(r.minY)))" }
        var text = "\(s.displayName) window: \(fmt(old)) → \(fmt(now))"
        let wanted = CGRect(x: x ?? old.minX, y: y ?? old.minY, width: width ?? old.width, height: height ?? old.height)
        if !now.approximatelyEquals(wanted) { text += " (the app adjusted the request \(fmt(wanted)))" }
        return text
    }

    public func activate(app query: String) async throws -> String {
        let s = try await session(for: query)
        try requireAX()
        try await activate(s)
        Diagnostics.shared.record(level:"info",kind:"activation_verified",detail:"Target app is frontmost after activation",fields:["app":s.displayName])
        return "activated \(s.displayName); verified frontmost"
    }

    public func screenshot(app query: String, region: CGRect? = nil, scale: CGFloat = 1.0, png: Bool = false,
                           window: String? = nil) async throws -> Screenshot {
        try requireAX()
        let s = try await session(for: query)
        if let window { s.pinnedWindow = window.isEmpty ? nil : window }
        let win = try await waitForWindow(s)
        guard let frame = AX.frame(win) else { throw LeapError.noWindow(s.displayName) }
        let title: String? = AX.attr(win, kAXTitleAttribute)
        guard let info = WindowInfo.match(pid: s.pid, frame: frame, title: title) else {
            throw LeapError.capture("window is not on screen")
        }
        await ShareIndicator.shared.hold(info.id)
        return try await Capture.window(info, scale: scale, jpegQuality: png ? nil : 0.85, region: region)
    }

    func modifierFlags(_ text: String?) throws -> CGEventFlags {
        guard let text, !text.isEmpty else { return [] }
        var flags: CGEventFlags = []
        for part in text.split(separator: "+") {
            guard let f = Keys.modifiers[part.trimmingCharacters(in: .whitespaces).lowercased()] else {
                throw LeapError.unsupported("unknown modifier \"\(part)\"")
            }
            flags.insert(f)
        }
        return flags
    }
}
