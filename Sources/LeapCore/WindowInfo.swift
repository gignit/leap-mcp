// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import CoreGraphics
import Foundation

/// Thin wrapper over `CGWindowListCopyWindowInfo` used to map AX windows to
/// CGWindowIDs (needed for ScreenCaptureKit) and to count windows per app.
public struct WindowInfo {
    public var id: CGWindowID
    public var pid: pid_t
    public var bounds: CGRect // screen coords, top-left origin (same as AX)
    public var layer: Int
    public var title: String?

    public static func onScreen() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return WindowInfo(id: id, pid: pid, bounds: rect,
                              layer: d[kCGWindowLayer as String] as? Int ?? 0,
                              title: d[kCGWindowName as String] as? String)
        }
    }

    public static func onScreenWindowCounts() -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for w in onScreen() where w.layer == 0 && w.bounds.width > 1 && w.bounds.height > 1 {
            counts[w.pid, default: 0] += 1
        }
        return counts
    }

    /// Best CGWindowID for an AX window of `pid` with the given frame/title.
    public static func match(pid: pid_t, frame: CGRect, title: String?) -> WindowInfo? {
        let candidates = onScreen().filter { $0.pid == pid && $0.layer == 0 }
        if let exact = candidates.first(where: { $0.bounds.approximatelyEquals(frame) }) { return exact }
        if let title, let byTitle = candidates.first(where: { $0.title == title }) { return byTitle }
        return candidates.max { a, b in
            a.bounds.intersection(frame).area < b.bounds.intersection(frame).area
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
