// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import Darwin
import Foundation

public enum LeapError: Error, CustomStringConvertible {
    case appNotFound(String)
    case launchFailed(String, String)
    case noWindow(String)
    case axFailure(String, AXError)
    case noSuchElement(Int)
    case staleElement(Int, String)
    case unsupported(String)
    case capture(String)
    case permission(String)
    /// The app's process changed under us (quit/crash/reinstall); actions need a fresh state.
    case processChanged(String)
    /// An element_index/label action arrived before any state was read for the app.
    case notActive(String)
    case ambiguousApp(String, [String])

    public var description: String {
        switch self {
        case .processChanged(let name):
            return "\(name) was relaunched (new process) since the last state; nothing was done. Call get_app_state to read the fresh tree before sending more actions — the old indices are void."
        case .notActive(let name):
            return "No state has been read for \(name) in this session; nothing was done. Call get_app_state first so element indices and labels refer to what you have seen."
        case .ambiguousApp(let q, let paths):
            return "Ambiguous app \"\(q)\": several copies share it — " + paths.joined(separator: ", ") + ". Use the full .app path or \"pid:<number>\"."
        case .appNotFound(let q):
            return "No running or installed app matches \"\(q)\". Try a bundle id (list_apps shows them)."
        case .launchFailed(let q, let why): return "Failed to launch \"\(q)\": \(why)"
        case .noWindow(let name): return "\"\(name)\" has no accessible window (is it still launching, or minimized to the Dock?)"
        case .axFailure(let what, let err): return "Accessibility call \(what) failed: \(err.name)"
        case .noSuchElement(let i):
            return "No element with index \(i) in the latest state; call get_app_state and use a fresh index."
        case .staleElement(let i, let why):
            return "The UI changed since the last state: element [\(i)] \(why). Nothing was done. Call get_app_state and act on the fresh tree (the user may have interacted with the app)."
        case .unsupported(let what): return what
        case .capture(let why): return "Screenshot failed: \(why)"
        case .permission(let what): return what
        }
    }
}

extension AXError {
    var name: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement (element went away)"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete (app busy or not responding to AX)"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled (Accessibility permission missing)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(rawValue))"
        }
    }
}

public struct AppInfo: Codable {
    public var name: String
    public var bundleId: String?
    public var pid: Int32?
    public var isRunning: Bool
    public var isActive: Bool
    public var windowCount: Int
    public var path: String?
}

public enum AppResolver {
    /// Resolve by display name, bundle identifier, process name, or .app path.
    /// Launches (without activating) when not running and `launch` is set.
    /// Optional enforcement: `LEAP_ALLOWED_APPS="Notes,com.apple.iphonesimulator,/path/X.app"`
    /// restricts control to those apps (display name, bundle id or path, case-insensitive).
    /// Tool descriptions guide the model; this is the actual control.
    static func enforceAllowList(_ app: NSRunningApplication, query: String) throws {
        try enforceAllowList(identities: [app.localizedName, app.bundleIdentifier, app.bundleURL?.path].compactMap { $0 }, query: query)
    }

    /// Checked before launching too, so a disallowed app is never started.
    static func enforceAllowList(bundleAt url: URL, query: String) throws {
        let bundle = Bundle(url: url)
        let candidates: [String?] = [bundle?.bundleIdentifier,
                                     bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                                     bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                                     url.deletingPathExtension().lastPathComponent, url.path]
        let names = candidates.compactMap { $0 }
        try enforceAllowList(identities: names, query: query)
    }

    static func enforceAllowList(identities: [String], query: String) throws {
        guard let raw = ProcessInfo.processInfo.environment["LEAP_ALLOWED_APPS"], !raw.isEmpty else { return }
        let allowed = Set(raw.split(separator: ",").map { normalized(String($0)) })
        let idents = identities.map(normalized)
        guard idents.contains(where: { allowed.contains($0) }) else {
            throw LeapError.permission("\"\(query)\" is not in LEAP_ALLOWED_APPS (\(raw)); refusing to control it.")
        }
    }

    public static func resolve(_ query: String, launch: Bool = true) async throws -> NSRunningApplication {
        if let running = try findRunning(query) { try enforceAllowList(running, query: query); return running }
        // On Xcode 27 and later the simulator host is Device Hub; "Simulator" resolves to it
        // when Simulator.app is not installed.
        if ["simulator", "com.apple.iphonesimulator"].contains(normalized(query)),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") == nil {
            return try await resolve("com.apple.dt.Devices", launch: launch)
        }
        guard launch else { throw LeapError.appNotFound(query) }
        if !query.contains("/") {
            let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: query)
            if copies.count > 1 { throw LeapError.ambiguousApp(query, copies.map { $0.path }) }
        }
        guard let url = installedURL(for: query) else { throw LeapError.appNotFound(query) }
        try enforceAllowList(bundleAt: url, query: query)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            throw LeapError.launchFailed(query, error.localizedDescription)
        }
        try enforceAllowList(app, query: query)
        // Give the process a moment to register its AX server; callers poll for windows.
        try? await Task.sleep(nanoseconds: 400_000_000)
        return app
    }

    /// Bundle ids of the iOS Simulator host: Simulator.app (Xcode ≤ 26) and Device Hub (Xcode 27).
    public static let simulatorHostBundles: Set<String> = ["com.apple.iphonesimulator", "com.apple.dt.Devices"]
    public static func isSimulatorHost(_ app: NSRunningApplication) -> Bool {
        simulatorHostBundles.contains(app.bundleIdentifier ?? "")
    }

    /// The real process id. Xcode 27's Device Hub is listed by NSRunningApplication with
    /// processIdentifier -1 while its windows and AX server belong to a real process. We
    /// resolve it from proc_pidpath and CGWindowListCopyWindowInfo: the process
    /// whose executable is the app's executable, else the owner of a window named like the app.
    public static func pid(of app: NSRunningApplication) -> pid_t {
        let reported = app.processIdentifier
        if reported > 0 { return reported }
        if let exec = app.executableURL?.resolvingSymlinksInPath().path {
            pidLock.lock(); let cached = pidCache[exec]; pidLock.unlock()
            if let cached, executablePath(cached) == exec { return cached }
            if let found = processes(executable: exec).first {
                pidLock.lock(); pidCache[exec] = found; pidLock.unlock()
                return found
            }
        }
        if let name = app.localizedName,
           let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
           let owner = raw.first(where: { ($0[kCGWindowOwnerName as String] as? String) == name })?[kCGWindowOwnerPID as String] as? pid_t {
            return owner
        }
        return reported
    }
    nonisolated(unsafe) private static var pidCache: [String: pid_t] = [:]
    private static let pidLock = NSLock()

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    static func processes(executable: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { $0 > 0 && executablePath($0) == executable }
    }

    /// Frontmost check that also works for apps reporting processIdentifier -1.
    public static func isFrontmost(_ pid: pid_t) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return self.pid(of: front) == pid
    }

    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix(".app") { t.removeLast(4) }
        return t
    }

    /// Several running copies of one app (e.g. MyApp.app in ~/Applications and a build dir):
    /// the frontmost one wins, else the only one with windows on screen, else it is a genuine
    /// ambiguity and we refuse rather than guess, listing the paths.
    /// Set when a query matched several running processes and one was chosen automatically
    /// (for example a stale copy left running beside a rebuilt app). Shown in the state header
    /// so the caller knows which process it is reading.
    nonisolated(unsafe) public static var choiceNotes: [pid_t: String] = [:]

    static func pickOne(_ candidates: [NSRunningApplication], _ query: String) throws -> NSRunningApplication? {
        if candidates.count <= 1 { return candidates.first }
        func describe(_ app: NSRunningApplication) -> String {
            "pid \(pid(of: app))" + (app.bundleURL.map { " \($0.path)" } ?? "")
        }
        func chosen(_ app: NSRunningApplication, _ why: String) -> NSRunningApplication {
            let others = candidates.filter { $0 != app }.map { "\"pid:\(pid(of: $0))\"" }.joined(separator: " or ")
            choiceNotes[pid(of: app)] = "\(candidates.count) processes match \"\(query)\" ("
                + candidates.map(describe).joined(separator: "; ") + "); using pid \(pid(of: app)) (\(why)). "
                + "Target another with app: \(others)."
            return app
        }
        if let active = candidates.first(where: { $0.isActive }) { return chosen(active, "frontmost") }
        let counts = WindowInfo.onScreenWindowCounts()
        let withWindows = candidates.filter { (counts[pid(of: $0)] ?? 0) > 0 }
        if withWindows.count == 1 { return chosen(withWindows[0], "the only one with a window") }
        throw LeapError.ambiguousApp(query, candidates.map(describe))
    }

    public static func findRunning(_ query: String) throws -> NSRunningApplication? {
        let q = normalized(query)
        let apps = NSWorkspace.shared.runningApplications
        if q.hasPrefix("pid:"), let wanted = pid_t(q.dropFirst(4).trimmingCharacters(in: .whitespaces)) {
            return apps.first { pid(of: $0) == wanted }
        }
        let byBundle = apps.filter { $0.bundleIdentifier?.lowercased() == q }
        if let one = try pickOne(byBundle, query) { return one }
        let byName = apps.filter { normalized($0.localizedName ?? "") == q }
        if let one = try pickOne(byName, query) { return one }
        if query.contains("/") {
            let path = (query as NSString).expandingTildeInPath
            if let byPath = apps.first(where: {
                $0.bundleURL?.path == path || $0.executableURL?.path == path
            }) { return byPath }
        }
        if let byExec = apps.first(where: { normalized($0.executableURL?.lastPathComponent ?? "") == q }) {
            return byExec
        }
        // Loose match: "edge" -> "Microsoft Edge"
        let loose = apps.filter { $0.activationPolicy == .regular }
            .filter { normalized($0.localizedName ?? "").contains(q) }
        return loose.count == 1 ? loose.first : nil
    }

    public static func installedURL(for query: String) -> URL? {
        if query.contains("/") {
            let url = URL(fileURLWithPath: (query as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return url }
        let name = query.hasSuffix(".app") ? query : query + ".app"
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Case-insensitive scan of /Applications as a last resort.
        let q = normalized(query)
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { normalized($0) == q && $0.hasSuffix(".app") }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }

    /// Running GUI apps first (with window counts), then installed apps from /Applications.
    public static func listApps(includeInstalled: Bool) -> [AppInfo] {
        let windowsByPid = WindowInfo.onScreenWindowCounts()
        var seen = Set<String>()
        var result: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            seen.insert(normalized(name))
            result.append(AppInfo(
                name: name, bundleId: app.bundleIdentifier, pid: pid(of: app),
                isRunning: true, isActive: app.isActive,
                windowCount: windowsByPid[pid(of: app)] ?? 0,
                path: app.bundleURL?.path))
        }
        result.sort { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
        guard includeInstalled else { return result }
        for dir in ["/Applications", "/System/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard !seen.contains(normalized(name)) else { continue }
                seen.insert(normalized(name))
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let bundleId = Bundle(url: url)?.bundleIdentifier
                result.append(AppInfo(name: name, bundleId: bundleId, pid: nil, isRunning: false,
                                      isActive: false, windowCount: 0, path: url.path))
            }
        }
        return result
    }
}
