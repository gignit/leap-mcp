# Notes for coding agents

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing behavior.
- `python3 scripts/test.py` runs the tests; `python3 scripts/install.py` installs your build.
  Restart the MCP client afterwards: it loads tools and skills at startup.
- When tool behavior changes, update `skills/` in the same change.
- No emojis in code, docs, comments or logs.
