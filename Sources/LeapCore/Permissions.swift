// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum Permissions {
    /// Accessibility (TCC "Accessibility") — required for reading AX trees and
    /// performing AX actions. Pass `prompt: true` to raise the system dialog.
    public static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Screen Recording (TCC "Screen Recording") — required for window screenshots.
    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Request Screen Recording. macOS does not grant it from a dialog: the request adds Leap to the
    /// Screen & System Audio Recording list (switched off) and the user turns it on there, so
    /// optionally open that pane. The request must come from Leap itself (launched through
    /// LaunchServices, as the installer does), not from a terminal or MCP client.
    @discardableResult
    public static func requestScreenRecording(openSettings: Bool = true) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if openSettings {
            NSWorkspace.shared.open(screenRecordingPane)
            // Let Settings show the pane before the request; wait for its window.
            let settings = "com.apple.systempreferences"
            for _ in 0..<20 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: settings).first?.isFinishedLaunching == true { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        if CGRequestScreenCaptureAccess() { return true }
        // On recent macOS, CGRequestScreenCaptureAccess() from an agent app may only post a
        // notification ("does not allow prompting"). Asking ScreenCaptureKit for shareable content
        // is what registers the app in the Screen & System Audio Recording list and raises the
        // system prompt.
        let done = DispatchSemaphore(value: 0)
        SCShareableContent.getWithCompletionHandler { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
        return CGPreflightScreenCaptureAccess()
    }

    public static func summary() -> String {
        let ax = accessibilityTrusted() ? "granted" : "MISSING"
        let sr = screenRecordingGranted() ? "granted" : "MISSING"
        return "accessibility=\(ax) screen_recording=\(sr)"
    }
}
