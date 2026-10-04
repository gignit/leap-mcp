# Verified workflows (ui_perform)

Use for multi-step tasks where each step needs a precondition, an expected outcome and retained
evidence. For quick interactive work the get_app_state/click loop in SKILL.md is lighter.

## Sessions and observation

- `session_open(project, app, backend: mac_ax, window?)`. `project` is an existing absolute
  directory that holds retained evidence. Without `window` the session follows the key window
  (a sheet opening sets `windowChanged`); with `window`, a window change is an error.
  `target_list` lists Mac apps and Simulator devices.
- `backend: wda` targets a guest app on a Simulator through a local WebDriverAgent runner
  (`scripts/wda.py`; `app` is the guest bundle id, coordinates are device points). There is no
  silent fallback between backends.
- `ui_observe(session_id)` returns a snapshot id, `complete`, coordinate space, bounds and
  normalized nodes. Selector keys: `id`, `identifier`, `role`, `label` (exact), `contains`,
  `root` (id-path prefix), `within` (an ancestor's own label, e.g.
  `{"role":"AXTextArea","within":"Notes"}`). `fields`, `depth`, `after`, `limit`,
  `max_bytes` bound output; paginate with the snapshot fixed. `selectorComplete` says whether an
  unreadable attribute could hide a match. IDs are observation handles, not durable locators.
- `ui_inspect(session_id, selector)` shows raw accessibility attributes, actions and parents to
  decide whether odd behavior is the app's or Leap's. Read-only.

## Steps

```json
{"session_id": "<session>", "steps": [
  {"type": "action", "action": "click", "selector": {"role": "button", "label": "Save"},
   "before": {"selector": {"label": "Save"}, "condition": "enabled"},
   "expect": {"selector": {"label": "Saved"}, "condition": "exists"}, "timeout": 5},
  {"type": "capture"}
]}
```

- Step types: `action`, `assert` (once), `wait` (polls), `observe` (returns `matched` and up to 20
  `items`; accepts `fields`), `capture`. Up to 50 steps. Validation names the step and key.
- Conditions: exists, absent, enabled, disabled, selected, value_equals, value_contains, count
  (`value` holds the operand).
- Actions (mac_ax): click/double_click (selector, or x/y + snapshot + space; `button`,
  `modifiers`), type_text/set_value (`arguments.text`), press_key (`arguments.key`), scroll
  (selector or x/y + snapshot + space, direction, pages), drag (from/to + snapshot + space),
  activate, perform_action (selector, `arguments.name`: an action listed on the element, e.g.
  `Confirm`, `ShowMenu`, a custom action), select_text (selector, `text`, optional `prefix`,
  `suffix`, `selection_type` text|cursor_before|cursor_after), paste (`text`, optional `html`; restores
  the clipboard). `foreground: true` may be supplied to input actions. WDA: click, double_click,
  type_text, drag, scroll (selector), press_key (Return/Enter/Backspace/Tab), rotate, activate.

## Outcomes

- Each step reports execution, dispatch (`not_sent`, `attempted`, `uncertain`), the backend
  `input_result` and verification separately. Uncertain input is never replayed.
- Selector actions re-observe while a screen is loading and never send input on an incomplete,
  ambiguous or disabled target. The target is re-resolved just before input; if its id or label
  changed, nothing is sent.
- `ax_result: cannotComplete` with `dispatch: uncertain`: the press may have applied (SwiftUI
  often replaces a control while acting). Let the expectation decide; look for side effects.
- If an input errors but the expected outcome is observed, the step completes with
  `dispatch: uncertain` and `dispatch_error`; the workflow continues.
- `expectation_met_before` flags a check that already held before input; choose an expectation
  only the new state satisfies. A met check does not prove saving: reopen to verify persistence.
- Partial observations: an observed match proves `exists` or a positive state; absence, failing
  states and counts need a complete read and otherwise return `unknown`.
- Several matches: Leap prefers a match inside a modal sheet, then the only enabled match
  (`disambiguated`); otherwise the step fails and lists them. No occlusion inference: SwiftUI
  keeps hidden layers in the tree. `hit_test` notes what the hit-test found at the target's
  center when it is not the target; it is a hint, not proof.
- After a failure or `unknown`, dependent steps are skipped; a failure capture is retained.
- Wait/assert/expect checks poll every 250 ms and keep the deciding read as evidence; they
  return within one poll of the condition holding and end at `timeout`. `check_ms` is the time
  spent judging; a failure screenshot is taken afterwards and is not part of it.
- `hit_test` is reported only when none of five points inside the target (center and four
  interior points) reaches it.

## Coordinates and scrolling

- Coordinate steps need the referenced snapshot's window, bounds, orientation and space to still
  hold. Pointer events go to the front-most app window containing the point (alert sheets).
  Device points and screenshot pixels differ; never mix them without a validated scale.
- Landscape Simulator elements are `[rotated]` (portrait-space frames): act by selector.
- `scroll` returns `scroll_effect` (scoped scrollbar or geometry movement, bounded before/after
  image comparison, up to four delayed looks). `unverified` means no movement was seen; some
  views ignore the wheel, so drag instead and say so. `observation_region` scopes evidence.

## Evidence

`session_history` lists results and retained files (kind narrows it). `evidence_read(session_id,
record, path?, offset?, max_bytes?)` reads raw retained JSON in chunks without touching the UI.
`diagnostic_query` audits backend events by interaction. `session_close` keeps history and leaves
the app running. Live sessions end when the MCP restarts; history remains.
`~/.config/leap/leap.json` `insights.enabled=false` disables automatic recording, deltas, scroll
analysis and failure captures (explicit reads and checks still run); restart after changing it.
