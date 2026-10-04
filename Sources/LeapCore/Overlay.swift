// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import QuartzCore

/// A click-through heads-up overlay showing where leap is acting.
///
/// The pointer is a filled *wedge* — just the tip of an arrow cursor, with no tail — so it
/// reads as a pointer while staying clearly distinct from the user's own black-and-white
/// cursor: it is coloured by the kind of action and pulses slowly like a heartbeat. Its tip
/// sits on the exact action point and the body trails down-and-right, so it never covers the
/// target. Every interaction also fires a single expanding sonar ring at the point.
///
/// Deliberately a *virtual* pointer: the user's real cursor is never moved, so the agent and
/// the user can work at the same time without fighting over the mouse. The window is
/// borderless, ignores mouse events, floats above normal windows, joins every Space, and is
/// ordered in with `orderFrontRegardless()` so showing it never activates this process.
///
/// Environment:
/// - `LEAP_OVERLAY=0`   disable entirely (headless / CI)
@MainActor
public final class Overlay {
    public static let shared = Overlay()

    public enum Ping {
        case click, edit, scroll, drag, observe

        var tint: NSColor {
            switch self {
            case .click: return NSColor(srgbRed: 0.90, green: 0.44, blue: 0.30, alpha: 1)   // coral
            case .edit: return NSColor(srgbRed: 0.30, green: 0.74, blue: 0.62, alpha: 1)    // teal
            case .scroll: return NSColor(srgbRed: 0.40, green: 0.58, blue: 0.90, alpha: 1)  // blue
            case .drag: return NSColor(srgbRed: 0.74, green: 0.52, blue: 0.90, alpha: 1)    // violet
            case .observe: return NSColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1) // neutral
            }
        }

        var radius: CGFloat {
            switch self {
            case .click: return 56
            case .edit: return 44
            case .scroll: return 40
            case .drag: return 34
            case .observe: return 0 // reading is silent: the wedge moves, no ring
            }
        }
    }

    public private(set) var isAvailable = false
    private var window: NSWindow?
    private var root: CALayer?
    private var pointer: CALayer?
    private var wedge: CAShapeLayer?
    private var fadeTask: Task<Void, Never>?

    /// Seconds of inactivity after which the pointer fades away.
    public var idleTimeout: TimeInterval = 10

    // Wedge geometry, in the pointer layer's own (y-up) coordinates. The tip is the hotspot
    // at (0, height); the body fills down-and-right so it trails off the target like a cursor.
    private let wedgeSize = CGSize(width: 26, height: 32)

    private init() {}

    private static var enabled: Bool { ProcessInfo.processInfo.environment["LEAP_OVERLAY"] != "0" }

    // MARK: - Public API

    /// Move the wedge so its tip is on a screen point (top-left origin, as AX and CGEvent
    /// report), colour it for the action, and fire one sonar ring there.
    public func signal(at point: CGPoint, ping: Ping) {
        guard Self.enabled, ensureWindow() else { return }
        movePointer(to: point, tint: ping.tint)
        if ping.radius > 0 { ripple(at: point, ping: ping) }
        scheduleFade()
    }

    /// Slide the wedge along a drag and ring both ends.
    public func signalDrag(from: CGPoint, to: CGPoint) {
        guard Self.enabled, ensureWindow() else { return }
        movePointer(to: from, tint: Ping.drag.tint)
        ripple(at: from, ping: .drag)
        guard let pointer, let window else { return }
        let end = convert(to, in: window)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: pointer.position)
        move.toValue = NSValue(point: end)
        move.duration = 0.45
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pointer.position = end
        pointer.add(move, forKey: "drag")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            self.ripple(at: to, ping: .drag)
        }
        scheduleFade()
    }

    public func hide() {
        fadeTask?.cancel()
        pointer?.opacity = 0
    }

    // MARK: - Window

    private func ensureWindow() -> Bool {
        if window != nil { return true }
        // No window server (ssh / daemon): don't try, and don't crash.
        guard NSScreen.screens.first != nil else { return false }

        var union = CGRect.null
        for screen in NSScreen.screens { union = union.union(screen.frame) }
        guard !union.isNull else { return false }

        let w = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: union.size))
        view.wantsLayer = true
        let layer = CALayer()
        layer.frame = view.bounds
        view.layer = layer
        w.contentView = view
        w.orderFrontRegardless() // shows without activating this process

        window = w
        root = layer
        pointer = makePointer()
        if let pointer { layer.addSublayer(pointer) }
        isAvailable = true
        return true
    }

    /// Screen point (top-left origin) → overlay-window coordinates (bottom-left origin).
    private func convert(_ point: CGPoint, in window: NSWindow) -> CGPoint {
        // The primary screen has origin (0,0); global AppKit Y is measured up from its bottom.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x - window.frame.minX,
                       y: (primaryMaxY - point.y) - window.frame.minY)
    }

    // MARK: - Pointer (the wedge)

    private func makePointer() -> CALayer {
        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: wedgeSize)
        // Anchor at the tip (top-left in y-up coords) so `position` places the tip on the target
        // and the pulse scales out from the tip, keeping the hotspot pinned.
        container.anchorPoint = CGPoint(x: 0, y: 1)
        container.opacity = 0

        let shape = CAShapeLayer()
        shape.frame = container.bounds
        shape.path = wedgePath()
        shape.lineJoin = .round
        shape.lineWidth = 2
        shape.strokeColor = NSColor.white.cgColor
        // Drop shadow keeps the wedge legible over any UI.
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.5
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 1, height: -1.5)
        container.addSublayer(shape)
        wedge = shape
        setTint(Ping.observe.tint)

        // One slow pulse, then rest — a heartbeat, not a rock and not a double beat.
        let beatTimes: [NSNumber] = [0, 0.18, 0.40, 1.0]
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.18, 1.0, 1.0]
        pulse.keyTimes = beatTimes
        pulse.duration = 1.8
        pulse.repeatCount = .infinity
        pulse.timingFunctions = Array(repeating: ease, count: beatTimes.count - 1)
        container.add(pulse, forKey: "pulse")
        return container
    }

    /// The arrowhead wedge: tip at the top-left hotspot, a straight left edge down, then a
    /// diagonal back up to the right. No tail — this is only the tip of the cursor.
    private func wedgePath() -> CGPath {
        let h = wedgeSize.height
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: h))          // tip (hotspot)
        p.addLine(to: CGPoint(x: 0, y: h - 24))  // straight down the left edge
        p.addLine(to: CGPoint(x: 17, y: h - 20)) // diagonal out to the right
        p.closeSubpath()
        return p
    }

    private func setTint(_ color: NSColor) {
        guard let wedge else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wedge.fillColor = color.cgColor
        CATransaction.commit()
    }

    private func movePointer(to point: CGPoint, tint: NSColor) {
        guard let pointer, let window else { return }
        setTint(tint)
        let target = convert(point, in: window)
        CATransaction.begin()
        if pointer.opacity < 0.5 {
            // First appearance: no slide across the screen.
            CATransaction.setDisableActions(true)
            pointer.position = target
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
        } else {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            pointer.position = target
        }
        pointer.opacity = 1
        CATransaction.commit()
    }

    // MARK: - Sonar ring

    /// One ring, centred exactly on the action point, expanding and fading.
    private func ripple(at point: CGPoint, ping: Ping) {
        guard let root, let window else { return }
        let center = convert(point, in: window)
        let r = ping.radius

        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        ring.position = center
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = ping.tint.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        ring.shadowColor = ping.tint.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 4
        root.insertSublayer(ring, at: 0)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.12
        scale.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.15, 1]
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = 5
        thin.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade, thin]
        group.duration = 0.8
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "sonar")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            ring.removeFromSuperlayer()
        }
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        let timeout = idleTimeout
        fadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            self.pointer?.opacity = 0
            CATransaction.commit()
        }
    }
}
