// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import ApplicationServices
import AppKit
import Foundation

/// One rendered accessibility element. `key` is stable across snapshots of the
/// same window so the model's `element_index` values survive UI changes.
public struct AXNode {
    public let element: AXUIElement
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let identifier: String?
    public let placeholder: String?
    public let frame: CGRect? // screen coords, top-left origin
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool
    public let actions: [String]
    /// Whether kAXValue can be written (text fields, sliders, checkboxes, ...).
    public let settable: Bool
    /// Frame lies outside the window. Kept (not dropped) because some hosts — notably the iOS
    /// Simulator after a rotation — report frames in an untransformed space while the element
    /// is perfectly visible and pressable via accessibility actions.
    public let offscreen: Bool
    public let depth: Int
    public var key: String
    public var capturedValue: String? = nil
    public var valueLimited: Bool = false
    public var unavailableFields: [String] = []
    /// Inside a landscape iOS Simulator device, the host reports descendant frames in
    /// the device's unrotated portrait space: they can land inside the window on the
    /// wrong control. Coordinates are unusable; AX actions still work.
    public var untransformedFrame: Bool = false
    /// Rows of a long table/list that were not read (off screen); absence cannot be claimed for them.
    public var omittedChildren: Int = 0
}

extension AXNode {
    /// Lowercased texts a `label` argument matches exactly: what the user sees plus the
    /// developer identifier (`id=status`).
    var exactLabels: [String] {
        [title, description, value, placeholder, identifier].compactMap { $0?.lowercased() }
    }
    /// Lowercased visible texts for substring matching. Identifiers are excluded so a short
    /// label does not match every element whose generated id happens to contain it.
    var visibleLabels: [String] {
        [title, description, value, placeholder].compactMap { $0?.lowercased() }
    }
}

public struct AXWindowSnapshot {
    public let window: AXUIElement
    public let title: String?
    public let frame: CGRect
    public let focusedElement: AXUIElement?
    public let nodes: [AXNode]
    public let truncated: Bool
    public var retainedEarlierObservation: Bool = false
    public var readFailures: Int = 0
    public var advisoryReadFailures: Int = 0
    public var blockingReadFailures: Int { max(0, readFailures - advisoryReadFailures) }
    public var supportsStateChecks: Bool { blockingReadFailures == 0 && !deadlineExceeded && !truncated }
    public var batchReadRetries: Int = 0
    public var batchReadRecoveries: Int = 0
    public var readFailureDetails: [[String: String]] = []
    public var readFailureDetailsOmitted: Int = 0
    public var deadlineExceeded: Bool = false
    public var captureStarted: Double = 0
    public var captureEnded: Double = 0
}

final class AXReadBudget {
    let started = ProcessInfo.processInfo.systemUptime
    let deadline: Double
    var failures = 0
    var advisoryFailures = 0
    var batchRetries = 0
    var batchRecoveries = 0
    var failureDetails: [[String: String]] = []
    var metadataFailures: [CFHashCode:Set<String>] = [:]
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
    init(seconds: Double) { deadline = ProcessInfo.processInfo.systemUptime + max(0.01,seconds) }
}

enum AX {
    static func withBudget<T>(_ seconds:Double,_ body:() throws -> T) rethrows -> T {
        let previous=Thread.current.threadDictionary["leap.readBudget"]
        Thread.current.threadDictionary["leap.readBudget"]=AXReadBudget(seconds:seconds)
        defer {Thread.current.threadDictionary["leap.readBudget"]=previous}
        return try body()
    }
    static var budget: AXReadBudget? { Thread.current.threadDictionary["leap.readBudget"] as? AXReadBudget }
    static func prepare(_ el: AXUIElement) -> Bool {
        guard let budget else { return true }
        guard !budget.expired else {return false}
        AXUIElementSetMessagingTimeout(el,Float(min(0.25,max(0.01,budget.deadline-ProcessInfo.processInfo.systemUptime))))
        return true
    }
    /// Attributes that describe only the element itself. A provider failure on one of these
    /// makes that node's field unknown (reported as unavailableFields, so selectors that
    /// depend on it become uncertain) without blinding the whole observation.
    /// Role, children and transport errors (timeouts, invalid elements) stay blocking:
    /// they can hide structure, so absence could not be established.
    static let nodeScopedAttributes: Set<String> = [kAXSubroleAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        // A label relation (used to fold title elements into their controls); a
        // failure loses the folding, not structure. Device Hub buttons fail it with -25200.
        "AXServesAsTitleForUIElements"]
    static func advisoryFailure(attribute: String, role: String?) -> Bool {
        nodeScopedAttributes.contains(attribute)
    }
    static func note(_ result: AXError, attribute: String, element: AXUIElement, role: String? = nil) {
        // Unsupported/missing attributes are legitimate; transport/element failures are not absence.
        if result != .success && ![-25205,-25212].contains(Int(result.rawValue)), let budget {
            budget.failures += 1
            let advisory = result == .failure && advisoryFailure(attribute: attribute, role: role)
            if advisory {
                budget.advisoryFailures += 1
                budget.metadataFailures[CFHash(element),default:[]].insert(attribute)
            }
            // No diagnostic AX reads: they could block or recursively add failures.
            // This hash correlates reads within an observation, never a durable target identity.
            if budget.failureDetails.count < 8 {
                budget.failureDetails.append(["attribute": attribute, "errorCode": String(result.rawValue),
                    "error": String(describing: result), "elementHash": String(CFHash(element)),
                    "role": role ?? "unknown", "impact": advisory ? "optional metadata" : "state coverage"])
            }
        }
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        guard prepare(el) else {return nil}
        defer {if budget != nil {AXUIElementSetMessagingTimeout(el,AppSession.messagingTimeout)}}
        var v: CFTypeRef?
        let result=AXUIElementCopyAttributeValue(el, name as CFString, &v);note(result, attribute: name, element: el)
        guard result == .success, let v else { return nil }
        return v as? T
    }

    static func attrs(_ el: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        guard prepare(el) else {return [:]}
        defer {if budget != nil {AXUIElementSetMessagingTimeout(el,AppSession.messagingTimeout)}}
        var out: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, [], &out)
        var dict: [String: CFTypeRef] = [:]
        if status == .success, let values = out as? [CFTypeRef?] {
            for (name, value) in zip(names, values) {
                guard let value else {continue}
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                    var error=AXError.success
                    AXValueGetValue(value as! AXValue,.axError,&error)
                    // A provider may reject one field in a successful batch but support
                    // its individual getter. Retry reads only, once, within the same budget.
                    if error == .failure && prepare(el) {
                        budget?.batchRetries += 1
                        var recovered: CFTypeRef?
                        let retry = AXUIElementCopyAttributeValue(el, name as CFString, &recovered)
                        if retry == .success || retry == .attributeUnsupported || retry == .noValue {
                            budget?.batchRecoveries += 1
                        }
                        if retry == .success, let recovered { dict[name] = recovered }
                        note(retry, attribute: name, element: el, role: dict[kAXRoleAttribute] as? String)
                    } else {
                        note(error, attribute: name, element: el, role: dict[kAXRoleAttribute] as? String)
                    }
                    continue
                }
                dict[name] = value
            }
            return dict
        }
        // Chromium/Electron (VS Code, browsers) reject the batched call for many
        // elements while answering single-attribute reads fine; without this fallback their
        // web content walks as an empty group.
        // A rejected batch can be fully recovered by individual reads. Count their failures, not the recovered batch.
        for name in names {
            guard prepare(el) else {break}
            var v: CFTypeRef?
            let result=AXUIElementCopyAttributeValue(el, name as CFString, &v);note(result, attribute: name, element: el)
            if result == .success, let v { dict[name] = v }
        }
        return dict
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func string(_ v: CFTypeRef?, limit: Int = 240) -> String? {
        guard let v else { return nil }
        var s: String
        if let str = v as? String { s = str }
        else if let n = v as? NSNumber { s = n.stringValue }
        else if let attributed = v as? NSAttributedString { s = attributed.string }
        else if let url = v as? URL { s = url.absoluteString }
        else if CFGetTypeID(v) == AXValueGetTypeID() {
            if let p = point(v) { s = "(\(Int(p.x)),\(Int(p.y)))" }
            else if let sz = size(v) { s = "\(Int(sz.width))x\(Int(sz.height))" }
            else { return nil }
        } else { return nil }
        s = s.replacingOccurrences(of: "\n", with: "⏎")
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s.isEmpty ? nil : s
    }

    static func actions(_ el: AXUIElement) -> [String] {
        guard prepare(el) else {return []}
        defer {if budget != nil {AXUIElementSetMessagingTimeout(el,AppSession.messagingTimeout)}}
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }

    /// Custom accessibility actions arrive as "Name:pin\nTarget:0x0\nSelector:(null)".
    /// Show the name; performAction accepts either form.
    static func actionName(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw }
        return String(raw.dropFirst(5).prefix { $0 != "\n" })
    }

    enum InsertOutcome {
        case verified          // the field now holds exactly the expected result
        case unchanged         // nothing happened; a fallback may try
        case uncertain(String) // the field changed, but not into the expected result: do NOT retry
        case notText           // element has no text API
    }

    /// Insert `text` at the element's selection (or replace all of its text) through the
    /// accessibility text API, and verify the *edit* — not merely that the text occurs.
    ///
    /// The expected result is computed from the value and selection read beforehand: for a
    /// replace-all it is `text`; for an insert it is the old value with the selected range
    /// replaced by `text`. If the write reports success but the field still holds the old
    /// value the outcome is `.unchanged`; if it holds something else the outcome is
    /// `.uncertain`, and callers must not fall through to another method (that is how text
    /// gets duplicated). Chromium/Electron editors answer success and ignore the write, which
    /// is why the return code alone is never trusted.
    static func insertText(_ el: AXUIElement, _ text: String, replaceAll: Bool) -> InsertOutcome {
        let probe: CFTypeRef? = attr(el, kAXSelectedTextRangeAttribute)
        guard probe != nil || isSettable(el, kAXSelectedTextAttribute) else { return .notText }
        // Many fields (SwiftUI especially) only accept selection edits while focused.
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(60_000)
        let before: String = attr(el, kAXValueAttribute) ?? ""
        var selection = CFRange(location: before.utf16.count, length: 0)
        if let v: CFTypeRef = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cfRange, &selection)
        }
        if replaceAll {
            var range = CFRange(location: 0, length: before.utf16.count)
            if let axRange = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange)
            }
        }
        let expected: String
        if replaceAll {
            expected = text
        } else {
            let u = Array(before.utf16)
            let lo = max(0, min(selection.location, u.count))
            let hi = max(lo, min(selection.location + selection.length, u.count))
            expected = String(utf16CodeUnits: Array(u[..<lo]), count: lo) + text + String(utf16CodeUnits: Array(u[hi...]), count: u.count - hi)
        }
        let status = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        usleep(80_000)
        let after: String = attr(el, kAXValueAttribute) ?? ""
        if after == expected && (status == .success || after != before) { return .verified }
        if after == before { return .unchanged }
        return .uncertain(Self.mismatchDescription(after: after, expected: expected))
    }

    /// Describes a readback mismatch by length only: typed text (possibly a secret) is never
    /// echoed into responses, diagnostics or recorded evidence.
    static func mismatchDescription(after: String, expected: String) -> String {
        "the field now holds \(after.count) characters, expected \(expected.count); read the state to compare"
    }

    /// Append `text` to a settable element's value (current + text) and verify by reading back.
    /// A value equal to the placeholder counts as empty (iOS reports the placeholder as the value).
    static func appendValue(_ el: AXUIElement, _ text: String, placeholder: String?) throws -> String? {
        guard isSettable(el, kAXValueAttribute) else { return nil }
        guard var current: String = attr(el, kAXValueAttribute) else { return nil }
        let original = current
        if let placeholder, current == placeholder { current = "" }
        let wanted = current + text
        _ = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, wanted as CFTypeRef)
        usleep(80_000)
        let after: String = attr(el, kAXValueAttribute) ?? ""
        if after == wanted { return after }
        guard let observed: String = attr(el, kAXValueAttribute), observed == original else {
            throw LeapError.unsupported("Append value write left changed or unreadable text. Outcome uncertain; no keyboard fallback sent.")
        }
        return nil
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        guard prepare(el) else {return false}
        defer {if budget != nil {AXUIElementSetMessagingTimeout(el,AppSession.messagingTimeout)}}
        var settable: DarwinBoolean = false
        let result=AXUIElementIsAttributeSettable(el,name as CFString,&settable);note(result, attribute: name, element: el)
        return result == .success && settable.boolValue
    }

    /// SwiftUI leaks mangled type names into AXIdentifier
    /// ("SwiftUI.ModifiedContent<...>-1-AppWindow-1"); they cost tokens and carry no meaning.
    static func usefulIdentifier(_ id: String?) -> String? {
        guard let id else { return nil }
        if id.contains("SwiftUI.") || id.contains("ModifiedContent<") || id.count > 64 { return nil }
        if id.hasPrefix("_NS:") { return nil } // AppKit nib object numbers, meaningless to a reader
        return id
    }

    static func pid(of el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        let a = attrs(el, [kAXPositionAttribute, kAXSizeAttribute])
        guard let p = point(a[kAXPositionAttribute]), let s = size(a[kAXSizeAttribute]) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// Elements already walked in one snapshot, by accessibility identity (CFEqual).
final class VisitedElements {
    private var buckets: [CFHashCode: [AXUIElement]] = [:]
    /// False when the element was already visited.
    func insert(_ el: AXUIElement) -> Bool {
        let h = CFHash(el)
        if buckets[h]?.contains(where: { CFEqual($0, el) }) == true { return false }
        buckets[h, default: []].append(el)
        return true
    }
}

public struct AXWalker {
    public var maxNodes = 1500
    public var maxDepth = 60
    /// Only render elements intersecting the window (menus/popovers are captured separately).
    public var clipToWindow = true
    public init() {}

    /// Container roles that are elided when they carry no information of their own.
    static let containerRoles: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement",
        "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXWebArea", "AXSection", "AXToolbar",
        "AXTabGroup", "AXSplitter", "AXMatte", "AXGrowArea", "AXRuler", "AXBusyIndicator",
    ]

    // AXShowMenu is omitted because Chromium/Electron stamps it on every element; it stays
    // invocable through perform_action, which matches against the live action list.
    static let hiddenActions: Set<String> = ["AXPress", "AXScrollToVisible", "AXRaise", "AXShowMenu", "AXPick"]

    /// Roles where a synthesized click (which places the caret) beats the AX Press action.
    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField",
    ]

    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXIncrementor", "AXPopUpButton", "AXColorWell", "AXDateField", "AXTimeField",
        "AXSecureTextField", "AXSwitch", "AXToggle", "AXStepper",
    ]

    /// Keys index the element table; two nodes sharing a key would share an index and an action on
    /// one would reach the other (reported: an alert press labelled Cancel pressed Create). Keys are
    /// unique by construction; this makes that an invariant even when a provider breaks the pattern.
    static func makeKeysUnique(_ nodes: inout [AXNode]) {
        var seen: [String: Int] = [:]
        for i in nodes.indices {
            let k = nodes[i].key
            if let n = seen[k] {
                seen[k] = n + 1
                nodes[i].key = k + "~\(n + 1)"
                Diagnostics.shared.record(level: "warning", kind: "duplicate_key", detail: "Two elements produced one key; the later is \(nodes[i].key)")
            } else { seen[k] = 1 }
        }
    }
    static let visibleRowsThreshold = 60
    static let rowContainerRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXGrid"]
    static let batchAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXSelectedAttribute, kAXChildrenAttribute, "AXServesAsTitleForUIElements",
    ]

    /// The key window of `app`, falling back to main / first window.
    public func keyWindow(of app: AXUIElement) -> AXUIElement? {
        if let w: AXUIElement = AX.attr(app, kAXFocusedWindowAttribute) { return w }
        if let w: AXUIElement = AX.attr(app, kAXMainWindowAttribute) { return w }
        if let ws: [AXUIElement] = AX.attr(app, kAXWindowsAttribute) { return ws.first }
        return nil
    }

    public func snapshot(window: AXUIElement, app: AXUIElement, timeout: Double = 3) -> AXWindowSnapshot? {
        let budget=AXReadBudget(seconds:timeout)
        let previous=Thread.current.threadDictionary["leap.readBudget"]
        Thread.current.threadDictionary["leap.readBudget"]=budget
        defer {Thread.current.threadDictionary["leap.readBudget"]=previous}
        guard let frame = AX.frame(window) else { return nil }
        let title: String? = AX.attr(window, kAXTitleAttribute)
        let focused: AXUIElement? = AX.attr(app, kAXFocusedUIElementAttribute)
        var nodes: [AXNode] = []
        var count = 0
        var truncated = false
        let visited = VisitedElements()
        walk(window, depth: 0, parentKey: "w", siblingOrdinal: 0, windowFrame: frame, visited: visited,
             nodes: &nodes, count: &count, truncated: &truncated)
        if let bar: AXUIElement = AX.attr(app, kAXMenuBarAttribute) {
            walkMenuBar(bar, nodes: &nodes, count: &count, truncated: &truncated)
        }
        AXWalker.makeKeysUnique(&nodes)
        return AXWindowSnapshot(window: window, title: title, frame: frame, focusedElement: focused,
                                nodes: nodes, truncated: truncated, readFailures:budget.failures, advisoryReadFailures:budget.advisoryFailures, batchReadRetries:budget.batchRetries, batchReadRecoveries:budget.batchRecoveries, readFailureDetails:budget.failureDetails, readFailureDetailsOmitted:max(0,budget.failures-budget.failureDetails.count), deadlineExceeded:budget.expired, captureStarted:budget.started, captureEnded:ProcessInfo.processInfo.systemUptime)
    }

    /// The app's menu bar: its titles always, and the items of any menu that is currently open.
    ///
    /// The menu bar is listed in every full tree and, after clicking a menu title, that menu's
    /// items are returned — that is how an agent switches Simulator device windows
    /// (Window › "iPhone 16 – iOS 18.0") and quits apps (Quit MyApp). AXPress on a title opens
    /// the menu even for a background app and leaves the frontmost app alone (verified);
    /// a closed menu has a zero-size frame and no visible children, an open one has both.
    private func walkMenuBar(_ bar: AXUIElement, nodes: inout [AXNode], count: inout Int, truncated: inout Bool) {
        guard let items: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute), !items.isEmpty else { return }
        let barKey = "mb"
        nodes.append(AXNode(element: bar, role: "AXMenuBar", subrole: nil, title: nil, value: nil, description: nil,
                            identifier: nil, placeholder: nil, frame: AX.frame(bar), enabled: true, focused: false,
                            selected: false, actions: [], settable: false, offscreen: false, depth: 0, key: barKey))
        count += 1
        for (i, item) in items.enumerated() {
            if count >= maxNodes { truncated = true; return }
            let a = AX.attrs(item, [kAXTitleAttribute, kAXSelectedAttribute, kAXEnabledAttribute, kAXChildrenAttribute])
            let title = AX.string(a[kAXTitleAttribute]) ?? ""
            if title == "Apple" { continue } // the system menu, not the app's
            let selected = (a[kAXSelectedAttribute] as? Bool) ?? false
            let key = "\(barKey)/AXMenuBarItem[\(title)]#\(i)"
            nodes.append(AXNode(element: item, role: "AXMenuBarItem", subrole: nil, title: title.isEmpty ? nil : title,
                                value: nil, description: nil, identifier: nil, placeholder: nil, frame: AX.frame(item),
                                enabled: (a[kAXEnabledAttribute] as? Bool) ?? true, focused: false, selected: selected,
                                actions: AX.actions(item), settable: false, offscreen: false, depth: 1, key: key))
            count += 1
            // Only an open menu is worth rendering; closed ones are reachable by clicking the title.
            for menu in (a[kAXChildrenAttribute] as? [AXUIElement]) ?? [] {
                guard let mf = AX.frame(menu), mf.width > 0, mf.height > 0,
                      let visible: [AXUIElement] = AX.attr(menu, kAXVisibleChildrenAttribute), !visible.isEmpty else { continue }
                walk(menu, depth: 2, parentKey: key, siblingOrdinal: 0, windowFrame: mf,
                     nodes: &nodes, count: &count, truncated: &truncated)
            }
        }
    }

    private func walk(_ el: AXUIElement, depth: Int, parentKey: String, siblingOrdinal: Int,
                      windowFrame: CGRect, untransformed: Bool = false, prefetched: [String: CFTypeRef]? = nil,
                      visited: VisitedElements? = nil,
                      nodes: inout [AXNode], count: inout Int, truncated: inout Bool) {
        if AX.budget?.expired == true || count >= maxNodes || depth > maxDepth { truncated = true; return }
        // Xcode 27 Device Hub exposes the guest app's content group under two parents (the same
        // AXUIElement, CFEqual). Render each element once, at its first position.
        if let visited, !visited.insert(el) { return }
        count += 1
        let a = prefetched ?? AX.attrs(el, AXWalker.batchAttributes)
        let role = (a[kAXRoleAttribute] as? String) ?? "AXUnknown"
        let subrole = a[kAXSubroleAttribute] as? String
        let title = AX.string(a[kAXTitleAttribute])
        // Never surface what is typed into a password field.
        let value = role == "AXSecureTextField" ? (AX.string(a[kAXValueAttribute]) == nil ? nil : "••••••") : AX.string(a[kAXValueAttribute])
        var description = AX.string(a[kAXDescriptionAttribute])
        let ownDescription = description
        // Controls labelled by a separate element (form rows, SwiftUI Toggle/LabeledContent)
        // expose it as AXTitleUIElement; screen readers use it as the label. Some providers
        // fail AXDescription outright for such controls.
        // Relations read: AXTitleUIElement, AXLabelUIElements.
        if title == nil, description == nil,
           let labelElement: AXUIElement = AX.attr(el, kAXTitleUIElementAttribute)
               ?? (AX.attr(el, "AXLabelUIElements") as [AXUIElement]?)?.first {
            let l = AX.attrs(labelElement, [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            description = AX.string(l[kAXTitleAttribute]) ?? AX.string(l[kAXDescriptionAttribute]) ?? AX.string(l[kAXValueAttribute])
        }
        let identifier = AX.usefulIdentifier(AX.string(a[kAXIdentifierAttribute], limit: 200))
        let placeholder = AX.string(a[kAXPlaceholderValueAttribute])
        var frame: CGRect?
        if let p = AX.point(a[kAXPositionAttribute]), let s = AX.size(a[kAXSizeAttribute]) {
            frame = CGRect(origin: p, size: s)
        }
        let enabled = (a[kAXEnabledAttribute] as? Bool) ?? true
        let focused = (a[kAXFocusedAttribute] as? Bool) ?? false
        let selected = (a[kAXSelectedAttribute] as? Bool) ?? false
        var children = (a[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        // Long tables/outlines/lists (mail, notes, file lists) can hold thousands of rows that
        // take tens of seconds to read. Read the rows on screen, keep headers/columns, and
        // record how many rows were not read so absence is never claimed for them.
        var omittedChildren = 0
        if children.count > AXWalker.visibleRowsThreshold, AXWalker.rowContainerRoles.contains(role) {
            let rows: [AXUIElement] = AX.attr(el, kAXRowsAttribute) ?? children
            let visible: [AXUIElement]? = AX.attr(el, kAXVisibleRowsAttribute) ?? AX.attr(el, kAXVisibleChildrenAttribute)
            if let visible, visible.count < rows.count {
                let rowSet = Set(rows.map(CFHash)), visibleSet = Set(visible.map(CFHash))
                children = children.filter { !rowSet.contains(CFHash($0)) || visibleSet.contains(CFHash($0)) }
                omittedChildren = rows.count - visible.count
            }
        }

        // Zero-size subtrees are skipped (hidden tabs, collapsed panes). Off-window elements are
        // kept and flagged: their coordinates are untrustworthy but AX actions on them work.
        var offscreen = untransformed
        // The device content group itself carries true screen geometry.
        let rotatedDevice = subrole == "iOSContentGroup" && frame.map { $0.width > $0.height } == true
        if clipToWindow, let f = frame, depth > 0 {
            if f.width <= 0 || f.height <= 0 { return }
            offscreen = untransformed || !f.intersects(windowFrame.insetBy(dx: -1, dy: -1))
            // Do not prune subtrees based on hit-testing. SwiftUI overlays can
            // intercept every sampled point while the underlying controls remain
            // visible and accessible (e.g. a zoomed canvas overlay).
            // Returning extra inactive-tab nodes is preferable to losing live UI.
        }

        // Keys use the element's own attributes, exactly as the parent computed its ordinal;
        // a labelled-by title is for display and matching only, never identity.
        let label = identifier ?? title ?? ownDescription ?? placeholder ?? ""
        if role == "AXMenuItem" && title == nil && description == nil && value == nil { return } // separator
        let key = "\(parentKey)/\(role)[\(label)]#\(siblingOrdinal)"
        let actions = AX.actions(el)
        let settable = (value != nil || AXWalker.editableRoles.contains(role)) && AX.isSettable(el, kAXValueAttribute)
        let informative = title != nil || value != nil || description != nil || identifier != nil
            || placeholder != nil || focused || selected
            || !actions.filter { !AXWalker.hiddenActions.contains($0) }.isEmpty
        let render = depth == 0 || !AXWalker.containerRoles.contains(role) || informative

        var unavailableFields:[String]=[]
        let missing=AX.budget?.metadataFailures[CFHash(el)] ?? []
        // Description/identifier failures that persist through the individual retry are how
        // several providers (SwiftUI TextEditor, unlabeled switches) report "none"; treating
        // them as unknown made every label-only absence check on such screens unknowable.
        // They stay in diagnostics. A failed title/placeholder/state read remains unknown.
        if missing.contains(kAXTitleAttribute)
            || (title == nil && description == nil && missing.contains(kAXPlaceholderValueAttribute)) {unavailableFields.append("label")}
        if missing.contains(kAXValueAttribute) {unavailableFields.append("value")}
        if missing.contains(kAXEnabledAttribute) {unavailableFields.append("enabled")}
        if missing.contains(kAXSelectedAttribute) {unavailableFields.append("selected")}
        if missing.contains(kAXFocusedAttribute) {unavailableFields.append("focused")}
        if missing.contains(kAXPositionAttribute) || missing.contains(kAXSizeAttribute) {unavailableFields.append("frame")}
        var childDepth = depth
        if render {
            nodes.append(AXNode(element: el, role: role, subrole: subrole, title: title, value: value,
                                description: description, identifier: identifier, placeholder: placeholder,
                                frame: frame, enabled: enabled, focused: focused, selected: selected,
                                actions: actions, settable: settable, offscreen: offscreen, depth: depth, key: key,
                                capturedValue: role == "AXSecureTextField" ? nil : (a[kAXValueAttribute] as? String).map {String($0.prefix(65536))},
                                valueLimited: role != "AXSecureTextField" && ((a[kAXValueAttribute] as? String)?.count ?? 0)>65536, unavailableFields:unavailableFields, untransformedFrame: untransformed, omittedChildren: omittedChildren))
            childDepth = depth + 1
        }

        // Ordinal among siblings that would produce the same key prefix keeps keys stable
        // when unrelated siblings are inserted or removed.
        var ordinals: [String: Int] = [:]
        // Read each child's full batch once: it keys the ordinal here and is reused by the child.
        var batches = children.map { AX.attrs($0, AXWalker.batchAttributes) }
        // Title association: an element that only titles
        // sibling controls is removed and its text moves onto them, so a labelled control and its
        // label do not render as two elements with one label.
        var skip = Set<Int>()
        for (i, batch) in batches.enumerated() {
            guard let targets = batch["AXServesAsTitleForUIElements"] as? [AXUIElement], !targets.isEmpty else { continue }
            let siblingIndices = targets.compactMap { t in children.firstIndex { CFEqual($0, t) } }
            guard siblingIndices.count == targets.count, !siblingIndices.contains(i) else { continue }
            let text = AX.string(batch[kAXTitleAttribute]) ?? AX.string(batch[kAXDescriptionAttribute]) ?? AX.string(batch[kAXValueAttribute])
            guard let text else { continue }
            for j in siblingIndices where AX.string(batches[j][kAXTitleAttribute]) == nil && AX.string(batches[j][kAXDescriptionAttribute]) == nil {
                batches[j][kAXDescriptionAttribute] = text as CFString
            }
            skip.insert(i)
        }
        for (i, child) in children.enumerated() where !skip.contains(i) {
            let ca = batches[i]
            let crole = (ca[kAXRoleAttribute] as? String) ?? "AXUnknown"
            // Same label as the child's own key: SwiftUI puts button labels in AXDescription, so
            // title-only signatures made every such sibling share one ordinal sequence and ids
            // shifted whenever an unrelated button appeared.
            let clabel = AX.usefulIdentifier(AX.string(ca[kAXIdentifierAttribute], limit: 200)) ?? AX.string(ca[kAXTitleAttribute])
                ?? AX.string(ca[kAXDescriptionAttribute]) ?? AX.string(ca[kAXPlaceholderValueAttribute]) ?? ""
            let sig = "\(crole)[\(clabel)]"
            let ordinal = ordinals[sig, default: 0]
            ordinals[sig] = ordinal + 1
            walk(child, depth: childDepth, parentKey: key, siblingOrdinal: ordinal, windowFrame: windowFrame,
                 untransformed: untransformed || rotatedDevice, prefetched: ca, visited: visited, nodes: &nodes, count: &count, truncated: &truncated)
            if truncated { return }
        }
    }
}
