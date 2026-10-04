// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct Screenshot {
    public var data: Data
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Multiply screenshot pixel coordinates by this to get window points.
    public var pointsPerPixel: CGFloat
    public var windowFrame: CGRect
}

public enum Capture {
    /// Window-scoped screenshot via ScreenCaptureKit. By default the image is rendered
    /// at 1 pixel per point so its pixel coordinates equal window-relative points.
    public static func window(_ info: WindowInfo, scale: CGFloat = 1.0, jpegQuality: CGFloat? = 0.85,
                              region: CGRect? = nil) async throws -> Screenshot {
        guard Permissions.screenRecordingGranted() else {
            throw LeapError.permission("Screen Recording permission is missing for this process; grant it in System Settings › Privacy & Security › Screen Recording (or use include_screenshot=false).")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw LeapError.capture(error.localizedDescription)
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == info.id }) else {
            throw LeapError.capture("window \(info.id) is not shareable (closed or on another Space?)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        let pixelScale = CGFloat(filter.pointPixelScale)
        let effective = max(0.1, min(scale, 1.0)) // 1.0 == 1 px per point; SCK caps at native scale
        config.width = max(1, Int((rect.width * effective).rounded()))
        config.height = max(1, Int((rect.height * effective).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true
        if let region {
            // Region is in window points; SCK sourceRect is in points of the content rect. Same
            // transform as the full window: 1 px per point at scale 1, so crop pixels map back
            // to window points with the same pointsPerPixel.
            config.sourceRect = region
            config.width = max(1, Int((region.width * effective).rounded()))
            config.height = max(1, Int((region.height * effective).rounded()))
        }
        _ = pixelScale
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw LeapError.capture(error.localizedDescription)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let encoded: Data?
        let mime: String
        if let q = jpegQuality {
            encoded = rep.representation(using: .jpeg, properties: [.compressionFactor: q]); mime = "image/jpeg"
        } else {
            encoded = rep.representation(using: .png, properties: [:]); mime = "image/png"
        }
        guard let data = encoded else { throw LeapError.capture("could not encode image") }
        let ppp = (region?.width ?? rect.width) / CGFloat(image.width)
        return Screenshot(data: data, mimeType: mime, pixelWidth: image.width, pixelHeight: image.height,
                          pointsPerPixel: ppp, windowFrame: info.bounds)
    }
}
