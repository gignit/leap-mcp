// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import ScreenCaptureKit

/// Holds a ScreenCaptureKit stream on the window the agent is working in.
///
/// Why: macOS shows its screen-recording indicator in the menu bar (Control Center's
/// "AudioVideoModule" item) for as long as any process streams a window with SCStream, and
/// the indicator's menu names the capturing app and the window. That is the system-level
/// "this window is being watched" signal the user expects while an agent operates a window. Single screenshots via
/// SCScreenshotManager never light it. The item appears within a second of starting a stream
/// and disappears when it stops.
///
/// The frames themselves are discarded; the stream exists for the indicator. It is released
/// after `idleTimeout` without activity, and always when the server exits.
public actor ShareIndicator {
    public static let shared = ShareIndicator()
    public static var enabled: Bool { ProcessInfo.processInfo.environment["LEAP_SHARE_INDICATOR"] != "0" }
    public var idleTimeout: TimeInterval = 90

    private var stream: SCStream?
    private var windowID: CGWindowID?
    private var lastTouch = Date.distantPast
    private var reaper: Task<Void, Never>?
    private final class Sink: NSObject, SCStreamOutput {
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
    }
    private let sink = Sink()

    /// Start (or keep) the indicator on `windowID`; switching windows moves it.
    public func hold(_ id: CGWindowID) async {
        guard Self.enabled, Permissions.screenRecordingGranted() else { return }
        lastTouch = Date()
        if windowID == id, stream != nil { return }
        await release()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let win = content.windows.first(where: { $0.windowID == id }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = 64; cfg.height = 64 // tiny: the frames are thrown away
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "leap.share-indicator"))
            try await s.startCapture()
        } catch {
            return // cosmetic; never fail the caller
        }
        stream = s
        windowID = id
        if reaper == nil {
            reaper = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self?.reapIfIdle()
                }
            }
        }
    }

    private func reapIfIdle() async {
        guard stream != nil, Date().timeIntervalSince(lastTouch) > idleTimeout else { return }
        await release()
    }

    public func release() async {
        guard let s = stream else { return }
        stream = nil
        windowID = nil
        try? await s.stopCapture()
    }
}
