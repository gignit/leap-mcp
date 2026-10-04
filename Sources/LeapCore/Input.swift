// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import CoreGraphics
import Foundation
import Darwin

public enum MouseButton: String, Codable {
    case left, right, middle

    public init?(alias: String) {
        switch alias.lowercased() {
        case "left", "l": self = .left
        case "right", "r": self = .right
        case "middle", "m", "center": self = .middle
        default: return nil
        }
    }

    var down: CGEventType {
        switch self { case .left: return .leftMouseDown; case .right: return .rightMouseDown; case .middle: return .otherMouseDown }
    }
    var up: CGEventType {
        switch self { case .left: return .leftMouseUp; case .right: return .rightMouseUp; case .middle: return .otherMouseUp }
    }
    var dragged: CGEventType {
        switch self { case .left: return .leftMouseDragged; case .right: return .rightMouseDragged; case .middle: return .otherMouseDragged }
    }
    var cgButton: CGMouseButton {
        switch self { case .left: return .left; case .right: return .right; case .middle: return .center }
    }
}

/// Where synthesized events are delivered.
public enum Delivery {
    /// `CGEvent.postToPid` — the target app receives the event even when it is not
    /// frontmost, and the user's cursor/focus are left alone. Default.
    case app(pid_t, window: WindowInfo? = nil)
    /// System delivery — session tap for keys, HID tap for pointers; requires foreground.
    /// Escape hatch for apps that ignore posted events.
    case system
}

/// Synthesizes mouse and keyboard input. All coordinates are global screen points
/// with a top-left origin (the same space AX reports).
public enum Input {
    static let source = CGEventSource(stateID: .combinedSessionState)
    static let clickGap: UInt32 = 25_000
    static let keyGap: UInt32 = 8_000
    static var mouseEventNumber = 0
    // WindowServer carries a separate window-relative position alongside the
    // public screen location. Resolve this SPI dynamically for OS compatibility.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    static func appKeyboardDelivery(pid: pid_t, window: WindowInfo) throws -> Delivery {
        guard pid > 0, window.pid == pid else {
            throw LeapError.unsupported("Keyboard process/window ownership mismatch; no input sent")
        }
        return .app(pid, window: window)
    }

    static func routedEvent(_ event: CGEvent, _ delivery: Delivery) throws -> CGEvent {
        switch delivery {
        case .app(let pid, let window):
            var routed = event
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .mouseMoved,
                 .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                guard let window, let type = NSEvent.EventType(rawValue: UInt(event.type.rawValue)), let setWindowLocation else {
                    throw LeapError.unsupported("Targeted mouse event requires a window and window-location routing; no generic fallback")
                }
                do {
                    let point = event.location
                    let local = NSPoint(x: point.x - window.bounds.minX,
                                        y: point.y - window.bounds.minY)
                    // Build the actual AppKit event, including its window identity
                    // and tracking metadata. Copying a factory event's location into
                    // a generic CGEvent was insufficient for SwiftUI gestures.
                    let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
                        || event.type == .otherMouseDown
                    let isUp = event.type == .leftMouseUp || event.type == .rightMouseUp
                        || event.type == .otherMouseUp
                    if isDown { mouseEventNumber += 1 }
                    guard let appKit = NSEvent.mouseEvent(
                        with: type, location: point,
                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: Int(window.id), context: nil,
                        eventNumber: mouseEventNumber,
                        clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                        pressure: isUp || event.type == .mouseMoved ? 0 : 1)?.cgEvent else {
                        throw LeapError.unsupported("Could not create targeted AppKit mouse event; no generic fallback")
                    }
                    do {
                        routed = appKit
                        routed.location = point
                        routed.setIntegerValueField(.mouseEventButtonNumber,
                            value: event.getIntegerValueField(.mouseEventButtonNumber))
                        routed.setIntegerValueField(.mouseEventSubtype, value: 3)
                        routed.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
                        routed.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
                        setWindowLocation(routed, local)
                    }
                }
            case .scrollWheel:
                // Wheel events need both screen and window-relative positions,
                // just like mouse gestures. Window IDs alone leave AppKit's
                // hit testing pointed outside the intended scroll view.
                // Preserve the original wheel event and its pixel deltas.
                guard let window, let setWindowLocation else {
                    throw LeapError.unsupported("Targeted scroll requires a window and window-location routing")
                }
                do {
                    let point = event.location
                    // Field 51 carries the target window ID for wheel routing.
                    // This wheel routing field is distinct from the two public
                    // mouse-window fields and from the local hit-test position.
                    if let wheelWindow = CGEventField(rawValue: 51) {
                        event.setIntegerValueField(wheelWindow, value: Int64(window.id))
                    }
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
                    setWindowLocation(event, CGPoint(x: point.x - window.bounds.minX,
                                                     y: point.y - window.bounds.minY))
                }
            default: break
            }
            routed.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            return routed
        case .system: return event
        }
    }

    static func post(_ event: CGEvent, _ delivery: Delivery) throws {
        let routed = try routedEvent(event, delivery)
        routed.timestamp = DispatchTime.now().uptimeNanoseconds
        switch delivery {
        case .app(let pid, _): routed.postToPid(pid)
        case .system: routed.post(tap: keyboardEvent(routed) ? .cgSessionEventTap : .cghidEventTap)
        }
    }

    /// How a background (non-frontmost) app is prepared for a pointer gesture.
    enum BackgroundPointer {
        /// Default: hold Command on the gesture and send no
        /// activation — Command-clicking an inactive window operates its controls without
        /// bringing it forward, while a plain first click is often consumed as activation
        /// (SwiftUI buttons, for example, ignore a plain background click).
        case commandClick
        /// Synthetic window activation around the gesture: for targets where a Command-click
        /// would change meaning (selection, links, text) and for wheel events.
        case activateWindow
    }

    /// Shared preparation/cleanup for a complete native pointer gesture. The body receives the
    /// extra modifier flags the gesture needs. Real activation is managed separately by Engine.
    static func withPointerGesture<T>(_ delivery: Delivery, background: BackgroundPointer = .activateWindow,
                                      _ body: (CGEventFlags) throws -> T) throws -> T {
        guard case .app(let pid, let window) = delivery, let window else {
            throw LeapError.unsupported("Pointer input requires a resolved target window. Read get_app_state and retry.")
        }
        guard setWindowLocation != nil else {
            throw LeapError.unsupported("This macOS version does not provide window-targeted pointer routing. No input was sent.")
        }
        let isBackground = !AppResolver.isFrontmost(pid)
        if isBackground, case .commandClick = background { return try body(.maskCommand) }
        let needsSyntheticFocus = isBackground
        if needsSyntheticFocus {
            let activation = try activationEvent(windowID: window.id, active: true)
            activation.postToPid(pid)
            usleep(clickGap)
        }
        defer {
            // If the user really activates the app during the gesture, preserve it.
            if needsSyntheticFocus, !AppResolver.isFrontmost(pid) {
                do { try activationEvent(windowID: window.id, active: false).postToPid(pid) }
                catch { Diagnostics.shared.record(level:"error",kind:"synthetic_focus_cleanup_failed",detail:String(describing:error)) }
            }
        }
        return try body([])
    }

    public static func moveMouse(to p: CGPoint, _ delivery: Delivery) throws {
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { throw LeapError.unsupported("Could not construct input event; inspect state before retrying") }
        try post(e, delivery)
    }

    /// Build/route the entire gesture before its first event. Allocation failure
    /// must not leave a mouse button held or silently substitute a generic event.
    static func sendPrepared(_ events:[(CGEvent,UInt32)], _ delivery:Delivery) {
        for (event,pause) in events {
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            switch delivery {
            case .app(let pid,_): event.postToPid(pid)
            case .system: event.post(tap:keyboardEvent(event) ? .cgSessionEventTap : .cghidEventTap)
            }
            if pause > 0 {usleep(pause)}
        }
    }

    public static func click(at p: CGPoint, button: MouseButton = .left, count: Int = 1,
                             flags: CGEventFlags = [], _ delivery: Delivery) throws {
        var events:[(CGEvent,UInt32)]=[]
        // Hover-driven UIs (Blender, games, web hover menus) only arm a control after the pointer
        // moves onto it; a click without a preceding mouseMoved leaves such controls cold.
        // A process-directed move does not move the user's cursor.
        if let move=CGEvent(mouseEventSource:source,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:button.cgButton) {
            move.flags=flags
            events.append((try routedEvent(move,delivery),clickGap))
        }
        for i in 1...max(1,count) {
            for type in [button.down,button.up] {
                guard let event=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:p,mouseButton:button.cgButton) else {
                    throw LeapError.unsupported("Could not construct click; no click events sent")
                }
                event.flags=flags;event.setIntegerValueField(.mouseEventClickState,value:Int64(i))
                events.append((try routedEvent(event,delivery),clickGap))
            }
        }
        if case .system = delivery {try moveMouse(to:p,delivery);usleep(clickGap)}
        sendPrepared(events,delivery)
    }

    public static func drag(from a: CGPoint, to b: CGPoint, button: MouseButton = .left,
                            flags: CGEventFlags = [], steps: Int = 12, _ delivery: Delivery) throws {
        var events:[(CGEvent,UInt32)]=[]
        func append(_ type:CGEventType,_ point:CGPoint,_ pause:UInt32) throws {
            guard let event=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:button.cgButton) else {
                throw LeapError.unsupported("Could not construct drag; no drag events sent")
            }
            event.flags=flags
            events.append((try routedEvent(event,delivery),pause))
        }
        try append(button.down,a,60_000)
        let count=max(1,min(steps,200))
        for i in 1...count {
            let t=CGFloat(i)/CGFloat(count)
            try append(button.dragged,CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t),i == count ? 76_000 : 16_000)
        }
        try append(button.up,b,0)
        if case .system = delivery {try moveMouse(to:a,delivery);usleep(clickGap)}
        sendPrepared(events,delivery)
    }

    /// AppKit activation notification targets the selected window. This does not activate the app in WindowServer.
    static func activationEvent(windowID:CGWindowID, active:Bool) throws -> CGEvent {
        guard let event = NSEvent.otherEvent(with:.appKitDefined, location:.zero,
            modifierFlags: active ? NSEvent.ModifierFlags(rawValue:0xc0000) : [],
            timestamp:0, windowNumber:active ? Int(windowID) : 0, context:nil,
            subtype:active ? 1 : 2, data1:0, data2:0)?.cgEvent else {
            throw LeapError.unsupported("Could not create synthetic application focus notification")
        }
        return event
    }

    /// Scroll by pixel deltas at a point (positive dy scrolls content up / wheel down).
    public static func scroll(at p: CGPoint, dx: Int32, dy: Int32, _ delivery: Delivery) throws {
        // Chunk large scrolls so apps with per-event clamping still travel the full distance.
        var remainingX = dx, remainingY = dy
        while remainingX != 0 || remainingY != 0 {
            let stepX = max(-120, min(120, remainingX)), stepY = max(-120, min(120, remainingY))
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: stepY, wheel2: stepX, wheel3: 0) else { throw LeapError.unsupported("Could not construct input event; inspect state before retrying") }
            e.location = p
            try post(e, delivery)
            remainingX -= stepX; remainingY -= stepY
            usleep(12_000)
        }
    }

    public static func press(_ chord: KeyChord, _ delivery: Delivery) throws {
        if let code = chord.keyCode {
            let events = try keyboardSequence(code: code, flags: chord.flags)
                .map { (try routedEvent($0, delivery), keyGap) }
            sendPrepared(events, delivery)
        } else if let text = chord.unicodeFallback {
            try type(text, flags: chord.flags, delivery)
        }
    }

    private static func keyboardEvent(_ event: CGEvent) -> Bool {
        event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged
    }

    /// Modifier masks with the physical key that produces each (Carbon kVK_* codes).
    static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59), (.maskSecondaryFn, 63),
    ]

    /// Emit what a hardware keyboard emits: one flagsChanged per modifier actually
    /// pressed or released, each carrying that modifier's own keycode, around the
    /// key's down/up. Unmodified keys get no flagsChanged at all.
    /// Keycode 0 is kVK_ANSI_A: flagsChanged events left at keycode 0 made
    /// hardware-forwarding hosts (Simulator) see phantom A presses, dropping or
    /// inserting the letter a. Allocate the complete sequence before dispatch so
    /// construction failure cannot leave a modifier/key held.
    static func keyboardSequence(code: CGKeyCode, flags: CGEventFlags,
                                 unicode: [UniChar]? = nil,
                                 restoring restore: CGEventFlags? = nil) throws -> [CGEvent] {
        let restoredFlags = restore ?? CGEventSource.flagsState(.combinedSessionState)
        guard let keyboardSource = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: keyboardSource, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: keyboardSource, virtualKey: code, keyDown: false) else {
            throw LeapError.unsupported("Could not construct complete keyboard sequence; no keyboard events sent")
        }
        func modifierEvent(_ key: CGKeyCode, _ state: CGEventFlags) throws -> CGEvent {
            guard let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: true) else {
                throw LeapError.unsupported("Could not construct complete keyboard sequence; no keyboard events sent")
            }
            event.type = .flagsChanged; event.flags = state
            return event
        }
        let pressed = modifierKeys.filter { flags.contains($0.0) && !restoredFlags.contains($0.0) }
        var state = restoredFlags
        var begin: [CGEvent] = []
        for (mask, key) in pressed { state.insert(mask); begin.append(try modifierEvent(key, state)) }
        var end: [CGEvent] = []
        for (mask, key) in pressed.reversed() { state.remove(mask); end.append(try modifierEvent(key, state)) }
        down.flags = flags; up.flags = flags
        if let unicode {
            unicode.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        return begin + [down, up] + end
    }

    /// Types literal text. Newlines are sent as Return, tabs as Tab.
    public static func type(_ text: String, flags: CGEventFlags = [], requirePhysical: Bool = false, _ delivery: Delivery) throws {
        let plan = try TextKeyPlan.plan(text, layout: TextKeyPlan.layoutMap(), requirePhysical: requirePhysical)
        let events = try textEvents(plan, flags: flags)
            .map { (try routedEvent($0, delivery), keyGap) }
        sendPrepared(events, delivery)
    }

    /// Freeze restoration flags and construct every event before posting any input.
    /// Reading global flags between characters can observe our own in-flight modifiers.
    static func textEvents(_ plan: [TextKeyPlan.Stroke], flags: CGEventFlags = [],
                           restoring restore: CGEventFlags? = nil) throws -> [CGEvent] {
        let original = restore ?? CGEventSource.flagsState(.combinedSessionState)
        return try plan.flatMap { stroke in
            try keyboardSequence(code: stroke.code, flags: stroke.flags.union(flags),
                unicode: stroke.text.map { Array($0.utf16) }, restoring: original)
        }
    }

    /// Paste via the pasteboard, then restore whatever the user had on it.
    public static func paste(_ text: String, html: String? = nil, _ delivery: Delivery) throws {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let html { item.setString(html, forType: .html) }
        pb.writeObjects([item])
        let ours = pb.changeCount
        defer {
            // Restore on success or construction failure, unless the user copied.
            if pb.changeCount == ours {
                pb.clearContents()
                if !saved.isEmpty {pb.writeObjects(saved)}
            }
        }
        usleep(50_000)
        try press(KeyChord(keyCode:9,flags:.maskCommand),delivery)
        usleep(350_000)
    }
}
