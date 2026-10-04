// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation

enum ClickGeometry {
    /// Do not substitute the center of a clipped sliver for the control's center.
    static func center(frame: CGRect, visible: CGRect) -> CGPoint? {
        guard [frame.minX, frame.minY, frame.width, frame.height,
               visible.minX, visible.minY, visible.width, visible.height].allSatisfy({ $0.isFinite }),
              frame.width > 0, frame.height > 0, !visible.isNull,
              visible.width > 0, visible.height > 0 else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return visible.contains(center) ? center : nil
    }
}
