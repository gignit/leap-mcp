# DeviceInteractionSynthesize commands and hierarchy

Commands can be chained in one call (for example `r right r right r select`). Coordinates are
**device points** from the hierarchy.

| Command | Effect |
|---|---|
| `` (empty) | Capture only |
| `t x y [dur]` | Tap, optional hold duration |
| `d x y` | Double tap |
| `t x1 y1 f x2 y2 [dur]` | Swipe; `t 200 600 f 200 200 0.3` scrolls to content below |
| `drag x1 y1 x2 y2 [hold] [move]` | Press-and-hold drag (reorder, drag and drop) |
| `mt [x y, x y] dur [x y, x y] dur` | Multi-touch keyframes (pinch: fingers move toward each other) |
| `b h` / `b p` / `b u` / `b d` | Home, Power, Volume up, Volume down (`b h b h` opens the app switcher) |
| `sender keyboard kbd <text>` | Type text; must be last in the chain; `\u{000A}` is Return, `\u{0009}` Tab |
| `w secs` | Wait |
| `orientation portrait\|landscapeLeft\|landscapeRight\|portraitUpsideDown\|faceUp\|faceDown` | Rotate (iOS) |
| `r up\|down\|left\|right\|select\|menu\|playpause\|home` | tvOS Siri Remote (focus-based: move focus, then select) |
| `b c` / `b s` / `b a`, `c <turns>` | watchOS crown press, side, Action button; crown rotation |

## Hierarchy file

```
Device orientation: Landscape Right
------------------------
Application bundle identifier: com.example.app
Application UI orientation: Landscape Left
Application, pid: 123, label: ' '
 Window, {{0.0, 0.0}, {1133.0, 744.0}}, hitPoint: {566.5, 372.0}
  Button, {{110, 205}, {30, 20}}, identifier: 'login', label: 'Login', hitPoint: {125.0, 215.0}
```

- `{{x, y}, {w, h}}` is the frame; `hitPoint` is the point to tap. Also `identifier`, `label`,
  `value`, and states such as `Selected` or `Focused`.
- Several apps on screen: lines carry `activationBundleId: <id>`. Pass `activationBundleId` to
  Synthesize (it can be passed with no command) before touching those elements. Activation is
  slow; use it only when needed.
- `isRemoteLeafPlaceholder` elements hide their children (remote/web content): fall back to
  screenshot coordinates, then verify.
- Toggles and switches: act on the nested `Switch`/`Slider`, not the surrounding row.

## Observed timings (Xcode 27.0, iPad Air 11-inch M4, iOS 27)

The first capture after starting a session on a shut-down device took 31.5 s (the device booted).
Later captures took about 1.1 s. A tap plus capture took 1.9 s. The session reported
`applicationState: NotRun` when no app of its own was running. Shut down a device you booted
only for a check (`xcrun simctl shutdown <UDID>`).
