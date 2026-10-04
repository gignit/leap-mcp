// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import Logging
import MCP

/// The SDK currently decodes experimental client capabilities as [String: String],
/// although MCP clients may send arbitrary JSON values (e.g. codex/auth-change: {}).
/// Leap uses none of these extensions. Ignore unsupported values at initialization
/// rather than rejecting the entire connection. Remove when the SDK supports them.
actor CompatibleTransport: Transport {
    private let base = StdioTransport()
    nonisolated var logger: Logger { base.logger }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.normalizeInitialize(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func normalizeInitialize(_ data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any]
        else { return data }

        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return data }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
