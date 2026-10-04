// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Darwin
import Foundation

/// Shut the server down after a period with no tool calls.
///
/// A long-lived shared service could rely on client refcounting; leap is one process per MCP connection, so each process owns its own ScreenCaptureKit session and
/// the idle timeout is what keeps an orphan from holding that session forever.
///
/// An orphaned server that keeps its capture session open makes screenshots from other
/// servers hang until it exits.
///
/// `LEAP_IDLE_TIMEOUT_SECONDS=0` disables it; the default is 30 minutes.
enum Inactivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastActivity = Date()

    static var timeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["LEAP_IDLE_TIMEOUT_SECONDS"],
           let value = TimeInterval(raw) {
            return value
        }
        return 30 * 60
    }

    /// Call on every tool invocation.
    static func touch() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    /// Synchronous so the lock is never taken directly in an async context.
    private static func idleSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    static func start() {
        let limit = timeout
        guard limit > 0 else { return }
        // Poll well inside the limit so the shutdown is not up to a full interval late.
        let poll = max(1.0, min(30.0, limit / 2))
        Task.detached(priority: .background) {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                let idle = idleSeconds()
                if idle >= limit {
                    FileHandle.standardError.write(Data(
                        "leap: idle for \(Int(idle))s (limit \(Int(limit))s); exiting so the capture session is released\n".utf8))
                    exit(0)
                }
            }
        }
    }
}
