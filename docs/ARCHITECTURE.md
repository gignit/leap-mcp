# Architecture

Leap is one Swift executable that speaks MCP over stdio, one process per client connection. On macOS it
reads apps through the macOS Accessibility API, acts through accessibility actions and events
posted to the target process, and keeps evidence in a project-local SQLite store. This document
states how it works and why the less obvious decisions are what they are.

## Permissions and identity

**Leap is an app bundle, not a bare binary.** macOS attributes Accessibility and Screen Recording
to the *responsible* process. For a binary launched by an MCP client that is the client, so the
grant would be labelled and keyed as the client. On launch the signed `Leap.app` re-executes
itself with `responsibility_spawnattrs_setdisclaim` and `POSIX_SPAWN_SETEXEC`
(`Sources/leap/Disclaim.swift`): the process becomes its own responsible process while keeping
its pid and the stdio pipes MCP runs over. System Settings then lists **Leap**, and with a stable
signature (Developer ID or Apple Development) the grant survives rebuilds. An ad-hoc signature
changes with every build, so macOS treats each build as a new app.

A bare `swift build` binary does not disclaim; it runs under the client's grants, which keeps
development runs working. `LEAP_NO_DISCLAIM=1` does the same for the bundle.

**Screen Recording registration.** macOS never grants Screen Recording from a dialog. A request
from the app adds it to Privacy & Security > Screen & System Audio Recording, switched off, and
the user turns it on. The request must come from Leap itself, so the installer launches
`Leap.app --request-permissions` through LaunchServices (`open`), not from the terminal; while
asking, the process runs briefly as a regular app because macOS only adds an entry for an app the
user is interacting with. tccd logging `does not allow prompting` for this service is normal.

The per-user agent that adds apps to that list, `universalAccessAuthWarn`, caches the bundle
identity of an app path and remembers paths it has warned about. If a different bundle id was
installed at `~/Applications/Leap.app`, or a stale Leap server is still running, requests are
recorded under that other id; System Settings hides records for ids no installed app carries, so
Leap never appears and "+" does nothing. The installer repairs this automatically and never
resets a working grant:

1. stop running Leap servers;
2. remove the install path and the other ids from
   `~/Library/Preferences/com.apple.universalaccessAuthWarning.plist`, restart `cfprefsd` and
   `universalAccessAuthWarn`;
3. unregister other copies of Leap from LaunchServices and re-register the installed one;
4. `tccutil reset ScreenCapture <id>` for the affected ids (an id no installed app carries is
   reset through a temporary stub bundle, because `tccutil` only accepts resolvable ids);
5. request again and open the Screen Recording pane.

To see which id a request is recorded under, watch
`log stream --predicate 'process == "tccd" AND eventMessage CONTAINS "Publishing"'`. Never run
`tccutil reset ScreenCapture` without an id; it resets every app.

Two private interfaces are used, both looked up with `dlsym` so a missing symbol produces an
explicit error instead of a crash: `responsibility_spawnattrs_setdisclaim` (above) and
`CGEventSetWindowLocation` (below).

## Observation

`get_app_state` walks the target window's accessibility tree and renders it as indexed text:

```
## Calculator — window "Calculator" 230x408 at screen (414,559) [background] — state #1
[7] StaticText value="0" desc="Edit field"
[21] Button desc="2" id=Two
```

- **Indices are content-addressed and never renumbered.** An index is keyed by the element's
  accessibility path, so it keeps pointing at the same element for the life of the session even
  though the API returns fresh element objects after a window moves.
- **Indices are validated before use.** SwiftUI and iOS reuse element objects for new content,
  and a look-alike sibling can inherit a path after a row disappears. Before acting, the live
  role, label and (for non-text roles) value must still match what the agent was shown;
  otherwise the action is refused with "the UI changed since the last state" and nothing is sent.
  An app that relaunched (new process) is refused the same way until the state is read again.
- **Later reads are diffs** (`+` added, `~` changed, removed indices listed compactly), and each
  state names its baseline, so a caller that missed one asks for the full tree.
- **Reads settle.** After an action the tree is polled until two reads agree (about 1 s plus up to
  5 s while it is still changing). "Stopped changing" is not "finished", so the header reports
  whether it settled and `wait_for` exists for explicit conditions.
- **Partial reads are labelled and never prove absence.** Each accessibility call has a timeout
  so a hung app returns an error instead of hanging the server.
- Chromium and Electron apps build their tree only for assistive clients, so Leap sets
  `AXEnhancedUserInterface` and `AXManualAccessibility` on every app it reads; other apps
  ignore them.
- Screenshots are window-scoped (ScreenCaptureKit) and opt-in.

## Acting without taking over the Mac

The user keeps their cursor, keyboard focus and frontmost app. Each action uses the least
intrusive route and reports which one ran:

1. **Accessibility**: `AXPress`, value writes and selected-text inserts. They work from the
   background and need no focus, so they are preferred. Text is written through the text system
   and read back; a mismatch is reported by length only, never echoing what was typed.
2. **Events posted to the target process** (`CGEvent.postToPid`). Pointer events carry the target
   window's id and window-relative location (`CGEventSetWindowLocation`), which AppKit hit-testing
   and SwiftUI gestures need. A background click holds Command so an inactive window's control
   operates without the click being consumed as window activation; targets where Command would
   change meaning (text, links, selection) use a synthetic activation notification instead. A
   mouse move precedes clicks for hover-armed controls. Keys go to the app's key window; if the
   caller pinned another window, Leap makes it key through accessibility or refuses.
3. **`foreground: true`**, an explicit opt-in for apps that ignore posted events, activates the
   app. macOS ignores activation requests from a background process, so Leap does not pretend to
   restore the user's app afterwards.

Nothing goes to the system-wide event stream unless `foreground` is set. Tool calls run strictly
one after another, even when a client sends them in parallel, so inputs never interleave.

**Uncertain input is never resent.** An accessibility call that times out or returns
`cannotComplete` may still have applied (SwiftUI often replaces a control while its action runs).
Leap reports the dispatch as `uncertain` and leaves the decision to the agent, which reads the
state. Any error after input states whether input was sent. A failed observation after a
successful action is reported as an observation failure, not a failed action.

**Visible activity.** A click-through overlay draws a coloured pointer wedge and ripple where Leap
acts (`LEAP_OVERLAY=0` hides it). While a window is being operated Leap holds a ScreenCaptureKit
stream on it, discarding the frames, because that is what makes macOS show its recording
indicator naming the window; single screenshots do not. The stream is released after 90 s idle
(`LEAP_SHARE_INDICATOR=0` disables it). The server exits after `LEAP_IDLE_TIMEOUT_SECONDS`
(default 1800) without a call, so an orphaned server cannot hold a capture session that makes
other servers' screenshots hang.

## Workflows

`ui_perform(session_id, steps)` runs up to 50 steps (`action`, `wait`, `assert`, `observe`,
`capture`), each with an optional selector, a `before` condition and an `expect` condition.

- Every step is validated before any input is sent, and each target is resolved again from a
  fresh read immediately before its input.
- Each step reports **execution** (completed, failed, skipped), **dispatch** (not sent, attempted,
  uncertain) and **verification** (passed, failed, unknown, not evaluated) separately.
- If an input's delivery is uncertain but its expected result is observed, the step completes and
  the workflow continues; otherwise later steps are skipped. Inputs are never resent.

Two backends, with no silent fallback between them: `mac_ax` for Mac apps, and `wda` for apps in
an iOS Simulator through a local WebDriverAgent runner (`scripts/wda.py`). The WebDriverAgent
client accepts only local endpoints without credentials and never retries input.

## Evidence and diagnostics

- **Project store**, `<project>/.leap/leap.db`: snapshots, inputs, outcomes and failure captures,
  created by `bind_project`, `recording_start` or `session_open` and added to
  `.git/info/exclude`. One server at a time writes to a project (`.leap/writer.lock`). Tool
  arguments, including text to type, are not stored; field values seen in snapshots are, except
  secure fields, which are masked. A session left open by a server that exited is marked as an
  unobserved gap, not treated as continuous.
- **Diagnostics**, `~/.leap/logs/diagnostics.db`: Leap's own errors, warnings and fallbacks, per
  user and available before any project is bound. Details are capped at 1200 characters and
  never include argument values or UI trees. If diagnostics cannot be written before an input,
  the input is not sent.
- Neither store is pruned automatically. Evidence tools only read; they never repeat input.

## Configuration

`~/.config/leap/leap.json` (created by the installer):

```json
{ "logging": { "level": "info" }, "insights": { "enabled": true } }
```

`logging.level` is `debug`, `info`, `warning` or `error`; events below it are not stored.
`insights.enabled` turns the automatic recording around actions on or off; explicit observations
and checks still run. An invalid file blocks every tool call with an explicit error rather than
being ignored; the installer keeps it as a backup and restores defaults.

Environment variables, set in the MCP client's server definition: `LEAP_ALLOWED_APPS`
(comma-separated names, bundle ids or paths; any other app is refused before it is launched or
touched), `LEAP_IDLE_TIMEOUT_SECONDS`, `LEAP_OVERLAY=0`, `LEAP_SHARE_INDICATOR=0`,
`LEAP_NO_DISCLAIM=1`.

## Source map

```
Sources/leap/        main.swift (entry, --permissions, --request-permissions), Tools.swift (tool
                     schemas and dispatch), Disclaim.swift, CompatibleTransport.swift, Inactivity.swift
Sources/LeapCore/    Engine.swift (sessions, interactive actions), AXTree.swift and AppSession.swift
                     (tree walk, indices, rendering, diffs), Input.swift, Keys.swift, TextKeyPlan.swift
                     (events), AutomationEngine.swift and AutomationModel.swift (workflows),
                     WDAClient.swift, Recording.swift, Engine+Recording.swift, Evidence.swift,
                     Diagnostics.swift, Overlay.swift, ShareIndicator.swift, and small helpers
Tests/               LeapCoreTests (XCTest, no permissions needed), scenarios (real apps)
scripts/             install.py, test.py, mcp.py, wda.py; each has --help
skills/              leap and leap-xcode agent skills, installed by install.py
bundle/Info.plist    bundle id and version
```
