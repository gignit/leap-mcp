---
name: leap-xcode
description: Build, run, test and interact with iOS/iPadOS/tvOS/watchOS apps through the Xcode 27 MCP server (tools named DeviceInteraction*, BuildProject, RunProject, RunAllTests, RenderPreview, GetConsoleOutput, Xcode*). Use on macOS 27+ for testing or operating an app inside a simulator or device (tap, swipe, type, rotate, screenshot, UI hierarchy), for builds, tests and previews, and when the user mentions Xcode, Device Hub or the simulator.
---

# Xcode MCP: build, run and drive apps on devices

Xcode 27 (macOS 27+) replaced Simulator.app with Device Hub and ships an MCP server, registered
as `xcode` (`xcrun mcpbridge`). It is the preferred way to operate apps **inside** a simulated or
physical device: real touches in device points, correct orientation, the device keyboard, and a
UI hierarchy with tap points. Use the leap skill for Mac apps, for Device Hub's own window
chrome, and as the fallback when this route is unavailable (see Limits).

## Setup (once)

- Xcode › Settings › Intelligence › "Allow external agents to use Xcode tools" must be on.
- Registration: `claude mcp add --transport stdio xcode -- xcrun mcpbridge` (Codex:
  `codex mcp add xcode -- xcrun mcpbridge`; OpenCode: `"xcode": {"type":"local","command":["/usr/bin/xcrun","mcpbridge"]}`).
- **Approval:** every tool refuses ("This agent isn't approved…") until the agent calls
  `XcodeOpenWorkspace(path)` or `XcodeNewProject`. That prompts the user to approve the agent and
  the project folder. Open the project first, even for device-only work.
- `xcrun mcp-server status|show-logs|stop` manages the server; `sudo xcrun mcp-server enable`
  turns on headless mode (no Xcode window). Headless, pass `workspaceIdentifier` (from
  `XcodeOpenWorkspace` or `XcodeListWorkspaces`) to each tool.

## Device loop

1. **Start a session early** (a device may boot, and the first capture took about 30 s):
   - `DeviceInteractionStartWorkspaceSession(sessionIdentifier, deviceIdentifier?)` to build and
     install the app you are working on.
   - `DeviceInteractionStartSession(deviceIdentifier, sessionIdentifier)` to drive apps already
     installed.
   - `deviceIdentifier` accepts a UUID, name or OS version. Pass `""` to list eligible devices;
     an ineligible device returns the eligible list.
   - The `sessionIdentifier` you choose ("Verify Login Flow") **is** the session key for later
     calls. A recently used identifier cannot be reused; pick a new one.
2. `DeviceInteractionInstallAndRun(interactionSessionKey)` after every code change. It needs a
   workspace session. Optional `commandLineArguments` / `environmentVariables` apply to one run
   (`"$(inherited)"` keeps the scheme's values).
3. `DeviceInteractionSynthesize(interactSessionKey, interactionCommand)` runs a command, then
   captures. An empty command captures only. It returns **file paths** (hierarchy text, screenshot,
   thumbnail, logs, `applicationState`); read the hierarchy file and look at the screenshot.
4. Tap at the hierarchy's `hitPoint`, never at positions guessed from the screenshot. Capture
   again and verify. Retry once if an element moved during an animation, then report.
5. `DeviceInteractionEndSession(interactionSessionKey)` when done; open sessions are expensive.

Command syntax, hierarchy format and platform notes: [device commands](references/device-commands.md).

## Build, test, debug

`BuildProject`, `GetBuildLog`, `RunProject`/`StopProject`, `GetConsoleOutput` (regex filter),
`RunAllTests`/`RunSomeTests`/`GetTestList`, `RenderPreview` (SwiftUI snapshot), `RunCodeSnippet`,
`InvokeDebuggerCommand` (lldb), `XcodeListRunDestinations`/`XcodeSwitchRunDestination`, and
project edits (`XcodeRead`/`XcodeUpdate`/`XcodeWrite`, build settings, Info.plist, entitlements).
Apple's bundled skills (device-interaction, swiftui-specialist, …) export with
`xcrun agent skills export <absolute dir>`.

## Verifying like a tester

- Before acting, capture and read the hierarchy. After acting, capture again and confirm the change
  from the hierarchy (labels, values, `Selected`) and the screenshot.
- Saved data: a visible value does not prove it was saved. Relaunch or reopen and check again, or
  read the app's data (`devicectl device info files`, the simulator container via `xcrun simctl
  get_app_container`).
- Report functional bugs, layout bugs (overlap, truncation, off-screen), crashes (use
  `GetConsoleOutput` and the process state). Loading spinners and animations are transient: capture again.
- Keep the user's data in mind: confirm before deleting, sending, purchasing or changing settings.

## Limits (fall back to Leap)

- **Runtimes:** only devices on the current SDK's runtime are eligible (iOS 27 with Xcode 27).
  Older runtimes (for example iOS 18) are refused. Use Leap's Device Hub route
  (`get_app_state("Simulator", window: "<device>")`), or create an iOS 27 simulator and install
  the app with a workspace session.
- Xcode must be running with the agent approved (or headless mode enabled).
- Presses are by coordinate. There is no element-identity press, no retained history, and no
  before/after checks. Use Leap's `ui_perform` when a workflow needs retained evidence.
- Mac apps cannot be driven. Even with a Mac scheme active and a workspace session, Xcode answers
  "not supported for Device Interaction. Supported: iOS [Simulator] 27.0+; watchOS [Simulator]
  27.0+; tvOS [Simulator] 27.0+". Physical devices and visionOS are not
  listed either. Scriptable Mac UI via Xcode means an XCUITest UI-test target run with
  `RunSomeTests`. For a Mac app, Xcode can still build, run, test, read console
  output and debug it (`RunProject`, `RunAllTests`, `GetConsoleOutput`, `InvokeDebuggerCommand`);
  use Leap to operate its UI.
