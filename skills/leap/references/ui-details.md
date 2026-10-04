# Detailed native UI operations

Read only for text editing, menus, coordinates, screenshots or Simulator-specific behavior.

## Reading the tree

- `[42] Button "Save" [settable] [selected] [disabled] [focused] actions=ShowMenu,Cancel`.
  Indices are content-keyed within the current window session. Reobserve after state changes;
  label changes and replaced or recycled nodes can change identity. The tool validates targets.
- `disable_diff=true` for a full tree; `include_frames=true` only when you need coordinates.
- Header: `## App — window "Title" WxH at screen (x,y) [background|frontmost]`, then
  `Other windows of App: …` — `get_app_state(window: "iPhone 16")` targets one and sticks.
- Footer: `Focused element: [n]`, `Selected text: "…"` (what the user has selected is often what
  they mean).
- `[offscreen: coords unreliable]` elements are still pressable by index (Simulator after rotation).
- `MenuBar` / `MenuBarItem "Window"` lines are the app's menu bar. Click a title: the menu opens on
  screen without activating the app and the diff lists its `MenuItem`s to click (this is how you
  switch Simulator device windows — Window › "iPhone 16 – iOS 18.0" — or quit: File › Quit).
  `press_key Escape` or `perform_action Cancel` closes it.
- iOS elements: labels in `desc=`, `actions=Cancel` on everything, SF Symbol names as `id=`.
  Only laid-out rows are present on iOS; Mac lists expose all rows.

## Text entry (what actually works)

- Replace: `set_value(element, value)`. Accessibility paths are verified by read-back (clearing
  with `""` works; numeric/boolean controls take numbers / true|false). If a write changed the field
  into something unexpected you get an "Outcome uncertain" error and nothing is retried — read the
  state and decide.
- Append / type: `type_text(element_index, text)`. Accessibility insert (verified) → accessibility
  value append (verified) → keystrokes. The result text says which path ran; the **keystroke path is
  dispatched, not verified**, so confirm it in the returned diff. In the iOS Simulator prefer the
  accessibility paths; keystrokes use the current keyboard layout's physical keys, characters with
  no single-key mapping are refused up front, and an occasional dropped character is possible,
  so read the value back.
- Simulator multi-line text areas refuse direct value writes (readback matched while the app's
  model stayed unchanged); focus the area and use `type_text`.
- Edit inside text: `select_text(element, text, prefix, suffix, selection_type)` then `type_text`
  (replaces the selection) or `selection_type: cursor_after` then type to insert.
- `type_text` sends `\n` as Return and many composers submit on Return: use `set_value` or `paste`
  for multi-line text. `paste(text, html)` restores the user's clipboard afterwards.
- `press_key` ⌘-chords press the matching menu item (File › Quit, Edit › Select All via the AX
  text API); Return → AXConfirm, Escape → AXCancel / close menu; else a keystroke to the focused
  element. Focus the field first (set_value/type_text with element_index) unless it is an
  app-level shortcut. `press_key` targets the app; it cannot fire global shortcuts. With a pinned
  window that is not the app's key window, leap makes it key first or refuses with a clear message
  rather than typing into the wrong window.
- `paste(text)` into a focused text element inserts through accessibility and reads it back
  (verified; clipboard untouched). With `html`, or when focus is not a text element, it posts ⌘V
  and restores the clipboard unless the user copied meanwhile: dispatched, not verified. A
  background app often ignores ⌘V (its Edit menu is disabled), so check the diff.
- Clicking a background app's menu title waits up to 1 s for the menu to open; if it does not, the
  result says so and nothing is re-pressed.

## Errors you will see and what to do

- Permission missing (`permissions` reports `MISSING`) — tell the user to turn on **Leap** under
  Privacy & Security (Accessibility / Screen & System Audio Recording) and restart the MCP client.
  If Leap is not in the Screen Recording list, the fix is re-running
  `python3 scripts/install.py` from the Leap repository (see docs/ARCHITECTURE.md,
  "Permissions and identity"); do not reset permissions yourself.
- `The UI changed since the last state: element [n] …` — the user or the app moved things;
  `get_app_state` and use fresh indices. Nothing was done.
- `<App> was relaunched (new process) since the last state` — quit/crash/reinstall; call
  `get_app_state`, the header says `[new process … indices restart]`.
- `No state has been read for <App> in this session` — call `get_app_state` before using indices.
- `"Label" is ambiguous (N matches): …` — use the listed `element_index`.
- `Ambiguous app "…": several copies share it` — pass the full `.app` path.
- `cannotComplete` — acknowledgement is uncertain. Inspect returned state/check evidence; never repeat input solely because this error occurred.
- `Outcome uncertain: …` — a write changed the field but not into the expected text. Not retried.
- `Batch stopped at step N … Completed steps (already applied)` — resume after the listed steps.
- `Expectation unmet by deadline; last observed: …` (wait_for) — the condition never held; the
  last observed element state is included. Read-only: nothing was sent.
- `Editable control focus could not be verified. No keyboard input sent.` — click the field (fresh
  state) and check it is `[focused]` before typing.
- `(action applied; state unavailable afterwards …)` — the action ran (e.g. Save closed the
  window); only the follow-up read failed. Do not repeat the action; call `get_app_state`.
- `Keyboard input would go to … key window, not to the selected window` — use accessibility edits
  by element_index, or `foreground=true`.
- Screenshot unavailable → the window is minimized or on another Space.

## Capturing screens to files

`screenshot(app, save_path)` writes the window to disk (parent folders created) and returns only
a text confirmation, so you can capture many screens without flooding context; add `embed=true`
to also see one inline. Target a device with `window` (`"iPhone 16"`, `"iPad Air"`). For a
documentation pass, save under `docs/screenshots/<app-version>/<platform>-<screen>-<kind>.png`,
e.g. `docs/screenshots/1.2.0/desktop-home-main.png`, `ipad-settings-main.png`. Navigate to
each screen (click the tab, read the text state to confirm you are there), then capture.

## Coordinates and foreground

- Prefer indices. Use `x,y` (window points; get them from `include_frames=true` or the screenshot,
  which is 1 px per point at scale 1, crops included) for canvases without accessibility: Blender's
  viewport, drawing surfaces, custom-drawn iOS views (charts, maps, game boards), segmented controls with
  no children. Coordinate clicks/drags are posted to the app's process in the background; they are
  **dispatched, not verified** — most apps honour them, some canvases do not, so check the diff or
  a screenshot. Coordinates are re-based on the window's current position at action time.
- `foreground=true` explicitly activates the app when synthesized input is needed. Mouse
  gestures keep the same window-targeted delivery in either mode and never move the real
  cursor. Background clicks are sent as Command-clicks without activation;
  rows, cells, links, text inputs and web content use scoped synthetic window activation.
  Keys and text always go to the target app's process, never system-wide. Announce explicit
  activation because it changes the user's frontmost app.
- **Background limits.** SwiftUI drag gestures (orbiting a 3D view, dragging a board) ignore
  background drags: the call returns `dragged` but nothing changes, while background clicks on the
  same window work. When a drag shows no change in the diff or a screenshot, repeat it once with
  `foreground=true` and say so, or use an accessible control that does the same thing (rotate or
  reset buttons). Never assume a background drag landed.
- **Blender.** View keys work through `press_key`: `KP_1` front, `KP_3` side, `KP_7` top,
  `alt+a` deselects; they act on the region under the last pointer position, so click or move
  in the viewport first. Dragging the navigation gizmo from an estimated position tends to start
  a box select instead. While Blender renders, accessibility reads fail with `cannotComplete`;
  `screenshot` still works. Verify a render by its output file, not the render window's
  (sometimes dimmed) thumbnail.
- Wheel scrolling can be ignored by some views (iOS Simulator lists). If `scroll` shows no
  change, drag the content instead and say so.

## Simulator specifics

- `get_app_state("Simulator", window: "iPhone 16")`; the simulated app's tree is exposed for
  iPhone/iPad. Xcode 27 replaced Simulator.app with Device Hub (`com.apple.dt.Devices`);
  "Simulator" resolves to it when Simulator.app is absent. Show a device with
  `open "devices://device/open?id=<UDID>"`. Device Hub windows also hold its own buttons
  ("Home" id=app.grid.3x3, "Screenshot", "Record", "Rotate Left"); the guest app's Home is
  `id=house`, so scope by role/id when labels repeat. Its Window menu lists devices as
  "iPhone 16 (iOS 18.0)".
- On macOS 27+, prefer the Xcode MCP for guest apps (see the leap-xcode skill). What follows is the
  fallback for older runtimes or when the `xcode` MCP is unavailable. tvOS exposes **no app content** — for Apple TV use screenshots and `press_key`
  Up/Down/Left/Right/Return, and confirm with a second screenshot.
- Rotate / device switching: toolbar `Rotate` button, or the Window menu (see above).
- After reinstalling the app under test, the tree comes back as a fresh subtree; read state again.
