# Leap

Leap gives any AI agent x-ray vision into desktop apps (native accessibility and screenshots)
along with full mouse and keyboard control. It works in the background without taking over your
screen, using a separate mouse cursor with visual activity effects. Built for building and
testing desktop and iOS apps.

## What it does

- **Sees what you see, and more.** Your agent reads any app's window as a compact tree of
  buttons, fields, lists and values, the way a screen reader does, and takes a screenshot when it
  needs pixels.
- **Clicks, types, scrolls and drags.** Real input delivered straight to the app, so you keep
  your own mouse, keyboard and frontmost window while the agent works.
- **Shows you where it's working.** Its own cursor and activity effects mark every action.
- **Knows what actually happened.** Leap tells the agent what it sent and what it could confirm,
  and never repeats an input whose effect was uncertain.
- **Runs whole test flows.** Multi-step workflows check each step's result, and a project-local
  record lets you review what was observed and done.
- **Drives iOS apps too.** Apps running in the iOS Simulator work the same way.

Leap is an MCP server, so it works with Claude Code, OpenCode and any other MCP client.

## Platform support

| Platform | Status |
|---|---|
| macOS 14 or later (including iOS Simulator apps) | Supported |
| Windows 10 / 11 | Planned, contributions welcome |

## Install (macOS)

You need Swift 6.1+ (Xcode 16.3 or later).

```bash
git clone https://github.com/gignit/leap-mcp.git
cd leap-mcp
python3 scripts/install.py
```

The installer builds and signs `Leap.app`, puts it in `~/Applications`, installs the agent skills,
registers Leap with Claude Code and asks macOS for permissions. Then:

1. Turn on **Leap** in System Settings > Privacy & Security, under **Accessibility** and under
   **Screen & System Audio Recording**.
2. Restart your MCP client.
3. Run `python3 scripts/install.py check` to confirm everything is ready.

To update, `git pull` and run the installer again; it also fixes a broken installation.
`install.py uninstall` removes Leap, and `install.py --help` shows every command.

If you have a Developer ID or Apple Development certificate, the build is signed with it.
Without one it is signed ad-hoc, and macOS asks for permissions again after each rebuild.

**Other MCP clients:** run `~/Applications/Leap.app/Contents/MacOS/leap` over stdio. For OpenCode:

```json
{ "mcp": { "leap": { "type": "local", "command": ["/Users/<you>/Applications/Leap.app/Contents/MacOS/leap"] } } }
```

## Using it

Ask your agent to do something in an app: "open Calculator and add 2 and 3", "fill in this form",
"walk through the onboarding screens of my iOS app and check each one". The `leap` skill installed
alongside teaches the agent how to use the tools ([skills/leap/SKILL.md](skills/leap/SKILL.md)),
and `leap-xcode` covers Apple's Xcode MCP for iOS apps on macOS 27+.

[demos/](demos) has end-to-end tasks to give an agent, such as building a chess game with
Blender assets for macOS and iOS ([demos/chess](demos/chess/INSTRUCTIONS.md)).

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how Leap works, its settings, and why it is
built the way it is.

## Development

```bash
swift build
python3 scripts/test.py                                             # run the tests
python3 scripts/mcp.py call get_app_state '{"app":"Calculator"}'   # talk to Leap like an agent
```

Issues and pull requests are welcome; for anything large, open an issue first. Please report
security problems privately through GitHub's "Report a vulnerability" form.

## License

Copyright (C) 2026 GIGNIT LLC and the Leap contributors. Licensed under GPL-3.0-or-later; see
[LICENSE](LICENSE). Using Leap places no obligations on you or the apps it operates. If you
distribute a modified version, you must publish its source under the same license.
