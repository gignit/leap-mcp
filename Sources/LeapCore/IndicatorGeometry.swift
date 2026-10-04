// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation

/// Cosmetic markers must not imply a precise location when AX geometry is unusable.
enum IndicatorGeometry {
    static func point(frame: CGRect?, window: CGRect, offscreen: Bool) -> CGPoint? {
        guard !offscreen, let frame,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
               window.origin.x, window.origin.y, window.size.width, window.size.height].allSatisfy({ $0.isFinite }),
              frame.width > 0, frame.height > 0, window.width > 0, window.height > 0,
              window.contains(frame) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
