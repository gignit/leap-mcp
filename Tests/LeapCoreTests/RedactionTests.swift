// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import XCTest
@testable import LeapCore

final class RedactionTests: XCTestCase {
    /// Typed text can be a password; a readback mismatch must not echo it into errors, diagnostics or evidence.
    func testReadbackMismatchNeverEchoesTypedText() {
        let secret = "hunter2-correct-horse"
        let message = AX.mismatchDescription(after: "hunter2-", expected: secret)
        XCTAssertFalse(message.contains("hunter2"))
        XCTAssertTrue(message.contains("\(secret.count)"))
    }
}
