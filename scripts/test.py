#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GIGNIT LLC and the Leap contributors
"""Run Leap's tests.

Suites (default: unit installer protocol workflow; these need no permissions and drive no apps):
  unit        swift test (XCTest unit tests)
  installer   install.py logic with every system call mocked: argument handling, missing
              `claude` CLI, user skills preserved, permission-repair decisions
  protocol    MCP handshake with several client capability sets against the debug build
  workflow    ui_perform contract against a fake WebDriverAgent endpoint: a failed check stops
              later input, an uncertain click is never repeated, history is retained
  scenarios   run Tests/scenarios/*.json against real apps (needs Leap's permissions)
  lifecycle   DESTRUCTIVE end-to-end installer test on this Mac: uninstall --purge, install,
              re-install, damage, repair. Removes settings, logs and permission records. Needs --yes.

Examples:
  python3 scripts/test.py
  python3 scripts/test.py protocol workflow
  LEAP_BIN=~/Applications/Leap.app/Contents/MacOS/leap python3 scripts/test.py scenarios
  python3 scripts/test.py lifecycle --yes
"""
import argparse
import contextlib
import glob
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(name):
    spec = importlib.util.spec_from_file_location(f"leap_{name}", os.path.join(ROOT, "scripts", f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Failure(Exception):
    pass


def expect(condition, message):
    if not condition:
        raise Failure(message)


# ------------------------------------------------------------------------------------------------

def suite_unit(_args):
    subprocess.run(["swift", "test"], cwd=ROOT, check=True)


def suite_installer(_args):
    installer = load("install")
    quiet = contextlib.redirect_stdout(io.StringIO())

    # Help, unknown and conflicting arguments exit before any side effect.
    for argv, code in ([["--help"], 0], [["--unknown"], 2], [["uninstall", "--bogus"], 2], [["check", "extra"], 2]):
        with quiet, contextlib.redirect_stderr(io.StringIO()), patch.object(installer, "install_app") as app, \
                patch.object(installer, "install_skills") as skills, patch.object(installer, "run") as run, \
                patch.object(installer, "_rm") as remove, patch.object(installer, "build") as build:
            try:
                installer.main(argv)
            except SystemExit as error:
                expect(error.code == code, f"{argv}: exit {error.code}, expected {code}")
            else:
                raise Failure(f"{argv}: expected a parser exit")
            for op in (app, skills, run, remove, build):
                expect(not op.called, f"{argv}: side effect {op}")
    print("ok   help, unknown and conflicting arguments have no side effects")

    # Without the `claude` CLI, install and uninstall complete without invoking it.
    with quiet, patch.object(installer, "claude_cli", return_value=None), patch.object(installer.os.path, "exists", return_value=True), \
            patch.object(installer, "install_app"), patch.object(installer, "install_skills"), patch.object(installer, "install_config"), \
            patch.object(installer, "request_permissions"), patch.object(installer, "check_installation", return_value=True), \
            patch.object(installer, "run") as run:
        expect(installer.install(no_build=True, identity=None), "install without claude CLI")
        expect(all(c.args[0][0] != "claude" for c in run.call_args_list), "claude CLI invoked")
    with quiet, patch.object(installer, "claude_cli", return_value=None), patch.object(installer, "forget_install"), \
            patch.object(installer, "check_uninstalled", return_value=True), patch.object(installer, "run") as run, \
            patch.object(installer, "_rm"):
        expect(installer.uninstall(purge=False), "uninstall without claude CLI")
        expect(not run.called, "claude CLI invoked on uninstall")
    print("ok   missing `claude` CLI is handled")

    # A skill directory without Leap's marker is never replaced.
    with tempfile.TemporaryDirectory() as d:
        expect(installer.owned(os.path.join(d, "absent")), "absent path is replaceable")
        os.makedirs(os.path.join(d, "user-skill"))
        expect(not installer.owned(os.path.join(d, "user-skill")), "user skill must be preserved")
        marked = os.path.join(d, "leap")
        os.makedirs(marked)
        open(os.path.join(marked, installer.MARKER), "w").close()
        expect(installer.owned(marked), "a Leap-installed skill can be replaced")
    print("ok   user skills are preserved")

    # Permission requests: a new install asks without repairing; a different replaced bundle id repairs first;
    # a still-missing grant repairs once and asks again; an existing grant is never reset.
    def scenario(replaced, statuses, current="com.example.leap"):
        with quiet, patch.object(installer, "bundle_id", return_value=current), patch.object(installer.os.path, "exists", return_value=False), \
                patch.object(installer, "ask_once", side_effect=statuses) as ask, \
                patch.object(installer, "repair_screen_recording") as repair, \
                patch.object(installer.subprocess, "run"), patch.object(installer.time, "sleep"):
            installer.request_permissions(replaced)
            return ask.call_count, [sorted(c.args[0]) for c in repair.call_args_list]
    granted, missing = "accessibility=granted screen_recording=granted", "accessibility=granted screen_recording=MISSING"
    expect(scenario([None], [granted]) == (1, []), "new install")
    expect(scenario(["com.example.leap"], [granted]) == (1, []), "same id, granted")
    expect(scenario(["com.other.leap"], [granted]) == (1, [["com.other.leap"]]), "different replaced id")
    expect(scenario([None], [missing, granted]) == (2, [["com.example.leap"]]), "still missing")
    expect(scenario(["com.other.leap"], [missing, missing]) == (2, [["com.other.leap"], ["com.example.leap", "com.other.leap"]]),
           "different replaced id and still missing")
    print("ok   permission repair decisions")


def suite_protocol(_args):
    mcp = load("mcp")
    cases = [
        {},
        {"roots": {"listChanged": True}},
        {"elicitation": {"form": {}, "url": {}}, "experimental": {"codex/auth-change": {}}},
        {"experimental": {"object": {"nested": [1, True]}, "string": "supported", "bool": True,
                          "null": None, "array": [], "number": 1}},
    ]
    for capabilities in cases:
        with contextlib.redirect_stdout(io.StringIO()):
            client = mcp.Client([mcp.binary_path()])
            try:
                reply = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": capabilities,
                                                      "clientInfo": {"name": "leap-test", "version": "1"}})
                expect("result" in reply, f"initialize failed: {reply}")
                client.notify("notifications/initialized")
                tools = {t["name"] for t in client.request("tools/list", {})["result"]["tools"]}
                reply = client.request("tools/call", {"name": "permissions", "arguments": {}})
            finally:
                client.close()
        expect("result" in reply and not reply["result"].get("isError"), f"permissions call failed: {reply}")
        expect({"get_app_state", "click", "ui_perform"} <= tools, "core tools missing")
        print(f"ok   initialize, {len(tools)} tools, permissions call with capabilities {json.dumps(capabilities)}")


def suite_workflow(_args):
    """ui_perform against a fake WebDriverAgent whose click applies but loses its acknowledgement."""
    mcp = load("mcp")
    state = {"clicks": 0, "label": "Save"}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.reply()

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.reply()

        def reply(self):
            status, path = 200, self.path
            if path == "/session":
                value = {"sessionId": "fixture"}
            elif path.endswith("/wda/device/info"):
                value = {"uuid": "fixture-device"}
            elif path.endswith("/wda/activeAppInfo"):
                value = {"bundleId": "fixture.app"}
            elif path.endswith("/orientation"):
                value = "PORTRAIT"
            elif path.endswith("/rotation"):
                value = {"x": 0, "y": 0, "z": 0}
            elif path.endswith("/wda/deviceOrientation"):
                value = "UIDeviceOrientationPortrait"
            elif path.endswith("/source?format=json"):
                value = {"type": "Application", "rect": {"x": 0, "y": 0, "width": 800, "height": 600},
                         "children": [{"type": "Button", "rawIdentifier": "save", "label": state["label"], "isEnabled": "1",
                                       "rect": {"x": 100, "y": 100, "width": 50, "height": 30}}]}
            elif path.endswith("/elements"):
                value = [{"ELEMENT": "save"}]
            elif path.endswith("/element/save/click"):
                state["clicks"] += 1
                state["label"] = "Saved"
                status, value = 500, {"error": "unknown error", "message": "lost acknowledgement after the app applied it"}
            elif path.endswith("/screenshot"):
                value = "aW1hZ2U="
            else:
                status, value = 404, {"error": "unknown command", "message": path}
            body = json.dumps({"value": value}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    project = tempfile.mkdtemp(prefix="leap-workflow-")
    subprocess.run(["git", "init", "-q", project], check=True)  # its own store, not the repository's
    with contextlib.redirect_stdout(io.StringIO()):
        client = mcp.connect("leap-test")
    try:
        opened = mcp.invoke(client, "session_open", {"project": project, "app": "fixture.app", "backend": "wda",
                                                     "endpoint": f"http://127.0.0.1:{server.server_port}"})
        sid = opened["session_id"]
        result = mcp.invoke(client, "ui_perform", {"session_id": sid, "steps": [
            {"type": "assert", "expect": {"selector": {"label": "Missing"}, "condition": "exists"}},
            {"type": "action", "action": "click", "selector": {"identifier": "save"}}]})
        expect(state["clicks"] == 0 and result["verification"] == "failed"
               and result["steps"][1]["execution"] == "skipped", "a failed check must stop later input")
        print("ok   a failed check stops later input")
        try:
            mcp.invoke(client, "ui_perform", {"session_id": sid, "steps": [
                {"type": "action", "action": "click", "selector": {"identifier": "save"}},
                {"type": "action", "action": "click", "selector": {"identifier": "save"}, "arguments": {"modifiers": "shift"}}]})
            rejected = False
        except RuntimeError:
            rejected = True
        expect(rejected and state["clicks"] == 0, "an invalid later step must be rejected before any input")
        print("ok   invalid steps are rejected before any input")
        # Each click applies but loses its acknowledgement. A step whose expectation is then observed
        # completes; a step without one stays uncertain, so the workflow stops. No input is resent.
        result = mcp.invoke(client, "ui_perform", {"session_id": sid, "steps": [
            {"type": "action", "action": "click", "selector": {"identifier": "save"},
             "expect": {"selector": {"label": "Saved"}, "condition": "exists"}},
            {"type": "action", "action": "click", "selector": {"identifier": "save"}},
            {"type": "action", "action": "click", "selector": {"identifier": "save"}}]})
        steps = [(st["execution"], st["dispatch"]) for st in result["steps"]]
        expect(state["clicks"] == 2 and steps == [("completed", "uncertain"), ("failed", "uncertain"), ("skipped", "not_sent")],
               f"uncertain input handling: clicks={state['clicks']} steps={steps}")
        print("ok   uncertain clicks are sent once; an observed expectation continues, otherwise later steps are skipped")
        history = mcp.invoke(client, "session_history", {"session_id": sid})
        expect(len(history["items"]) == 2, "both workflow results are retained")
        snapshot = mcp.invoke(client, "ui_observe", {"session_id": sid, "snapshot": opened["snapshot"],
                                                     "selector": {"identifier": "save"}})
        expect(snapshot["items"][0]["label"] == "Save", "retained snapshots are immutable")
        print("ok   history and snapshots are retained")
    finally:
        with contextlib.redirect_stdout(io.StringIO()):
            client.close()
        server.shutdown()
        shutil.rmtree(project, ignore_errors=True)


def suite_scenarios(_args):
    files = sorted(glob.glob(os.path.join(ROOT, "Tests", "scenarios", "*.json")))
    expect(files, "no scenarios in Tests/scenarios")
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "mcp.py"), "script", *files], check=True)


def suite_lifecycle(args):
    if not args.yes:
        raise Failure("lifecycle removes and reinstalls Leap on this Mac; pass --yes")
    install = os.path.join(ROOT, "scripts", "install.py")
    app = os.path.expanduser("~/Applications/Leap.app")
    skill = os.path.expanduser("~/.claude/skills/leap/SKILL.md")
    config = os.path.expanduser("~/.config/leap/leap.json")
    stray = os.path.expanduser("~/Applications/.leap-lifecycle-stray.app")
    lsregister = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
                  "/Support/lsregister")
    has_claude = shutil.which("claude") is not None

    def installer(*argv):
        p = subprocess.run([sys.executable, install, *argv], capture_output=True, text=True)
        print(p.stdout + p.stderr)
        return p.returncode, p.stdout + p.stderr

    def failed(out):  # permissions are granted by the user, not by the installer
        return [l for l in out.splitlines() if l.startswith("FAIL") and "permission" not in l]

    print("--- uninstall --purge")
    code, _ = installer("uninstall", "--purge")
    expect(code == 0, "uninstall leaves nothing behind")
    for path in (app, os.path.dirname(skill), os.path.dirname(config), os.path.expanduser("~/.leap")):
        expect(not os.path.lexists(path), f"{path} removed")
    code, out = installer("check")
    expect(code != 0 and "Not installed" in out, "check reports not installed")

    print("--- fresh install")
    _, out = installer("install") if not args.no_build else installer("install", "--no-build")
    expect(not failed(out), "fresh install passes its checks")
    expect(os.path.exists(config), "default settings created")

    print("--- re-install without changes")
    before = os.stat(config).st_mtime
    _, out = installer("install", "--no-build")
    expect(not failed(out) and os.stat(config).st_mtime == before, "re-install changes nothing that is valid")

    print("--- damage the installation")
    with open(skill, "a") as f:
        f.write("\nlocal drift\n")
    with open(config, "w") as f:
        f.write('{"logging": {"level": "loud"}}\n')
    subprocess.run(["ditto", app, stray], check=True)
    subprocess.run([lsregister, "-f", stray], capture_output=True)
    if has_claude:
        subprocess.run(["claude", "mcp", "remove", "leap", "-s", "user"], capture_output=True)
        subprocess.run(["claude", "mcp", "add", "--scope", "user", "leap", "--", "/nonexistent/leap"], capture_output=True)
    server = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "leap")], stdin=subprocess.PIPE,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(2)
    code, out = installer("check")
    found = "\n".join(failed(out))
    expect(code != 0, "check fails on the damaged installation")
    for item in ("skill leap", "settings", "LaunchServices") + (("Claude Code registration",) if has_claude else ()):
        expect(item in found, f"check detects: {item}")

    print("--- update repairs everything")
    _, out = installer("install", "--no-build")
    shutil.rmtree(stray, ignore_errors=True)
    expect(not failed(out), "re-install repairs the installation")
    expect(any(n.startswith("leap.json.invalid-") for n in os.listdir(os.path.dirname(config))), "invalid settings backed up")
    expect(server.poll() is not None, "stale server stopped")
    code, out = installer("check")
    expect(not failed(out), "final check passes")
    for name in os.listdir(os.path.dirname(config)):
        if name.startswith("leap.json.invalid-"):
            os.remove(os.path.join(os.path.dirname(config), name))


SUITES = {"unit": suite_unit, "installer": suite_installer, "protocol": suite_protocol,
          "workflow": suite_workflow, "scenarios": suite_scenarios, "lifecycle": suite_lifecycle}
DEFAULT = ["unit", "installer", "protocol", "workflow"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("suites", nargs="*", metavar="SUITE", help="one or more of: " + ", ".join(SUITES))
    parser.add_argument("--yes", action="store_true", help="confirm the destructive lifecycle suite")
    parser.add_argument("--no-build", action="store_true", help="lifecycle: install the existing dist/Leap.app")
    args = parser.parse_args()
    unknown = [s for s in args.suites if s not in SUITES]
    if unknown:
        parser.error(f"unknown suite(s): {', '.join(unknown)}; choose from {', '.join(SUITES)}")
    results = []
    for name in args.suites or DEFAULT:
        print(f"\n=== {name} ===", flush=True)
        try:
            SUITES[name](args)
            results.append((name, None))
        except (Failure, subprocess.CalledProcessError, AssertionError) as error:
            print(f"FAIL {error}")
            results.append((name, str(error)))
    print()
    for name, error in results:
        print(f"{'PASS' if error is None else 'FAIL'}  {name}" + (f": {error}" if error else ""))
    sys.exit(1 if any(e for _, e in results) else 0)


if __name__ == "__main__":
    main()
