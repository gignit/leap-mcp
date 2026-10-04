// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Darwin
import Foundation

/// Make this process its own TCC "responsible process".
///
/// macOS attributes privacy permissions (Accessibility, Screen Recording, …) to the
/// *responsible* process — normally the MCP client that spawned us — so the
/// permission prompts and System Settings entries are labelled with the parent's name and
/// its grants may not even apply to our binary. `responsibility_spawnattrs_setdisclaim`
/// is the (private, widely used — for example by LLDB and Chromium) libSystem call that
/// resets the responsibility chain for a spawned child. Combined with
/// `POSIX_SPAWN_SETEXEC` the child *replaces* this process image, so the pid and the
/// inherited stdio pipes — which is what the MCP transport runs over — survive intact.
///
/// The trade-off is deliberate: disclaiming severs inherited grants, so this app must be
/// granted Accessibility (and Screen Recording) under its own identity, once. Signed with a
/// Developer ID, that grant persists across rebuilds.
///
/// Environment:
/// - `LEAP_DISCLAIMED=1`   set on the re-exec'd process; prevents looping.
/// - `LEAP_NO_DISCLAIM=1`  opt out (e.g. to debug attribution).
func disclaimResponsibilityIfNeeded() {
    let env = ProcessInfo.processInfo.environment
    guard env["LEAP_DISCLAIMED"] == nil, env["LEAP_NO_DISCLAIM"] == nil else { return }
    // Only the signed .app has an identity worth owning. A bare `swift build` binary that
    // disclaimed would land under an unsigned identity with no grants and break dev runs,
    // so it keeps running under the parent MCP client's TCC identity instead.
    guard Bundle.main.bundleIdentifier != nil else { return }

    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                             "responsibility_spawnattrs_setdisclaim") else {
        fputs("leap: responsibility_spawnattrs_setdisclaim unavailable; running under parent's TCC identity\n", stderr)
        return
    }
    let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

    var attrs: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attrs) == 0 else { return }
    defer { posix_spawnattr_destroy(&attrs) }
    guard posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETEXEC)) == 0,
          setDisclaim(&attrs, 1) == 0 else {
        fputs("leap: could not configure disclaim; running under parent's TCC identity\n", stderr)
        return
    }

    guard let executable = Bundle.main.executablePath else { return }
    var newEnv = env
    newEnv["LEAP_DISCLAIMED"] = "1"
    let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = newEnv.map { strdup("\($0.key)=\($0.value)") } + [nil]

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, executable, nil, &attrs, argv, envp)
    // With SETEXEC a successful call never returns. Reaching here means exec failed.
    fputs("leap: disclaiming re-exec failed (posix_spawn rc=\(rc), errno=\(errno)); continuing under parent's TCC identity\n", stderr)
    for p in argv { free(p) }
    for p in envp { free(p) }
}
