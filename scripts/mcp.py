#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GIGNIT LLC and the Leap contributors
"""Talk to the Leap MCP server over stdio, exactly as an agent does.

Commands:
  tools                       list the tools with their parameters
  call NAME ['{"json":...}']  call one tool and print the result
  script FILE [FILE ...]      run scenario files (JSON lists of calls), each in one server session
  workflow FILE               run a workflow file: {"session": {...session_open args},
                              "steps": [...ui_perform steps], "timeout": 60}

The server is the debug build (`swift build`) unless LEAP_BIN points elsewhere, for example
LEAP_BIN=~/Applications/Leap.app/Contents/MacOS/leap. Images are saved under
artifacts/screenshots/ (ignored). Exits non-zero on transport errors or tool errors.

Scenario steps besides tool calls (see Tests/scenarios/ for examples):
  {"name": "@capture", "arguments": {"pattern": "regex with one group", "var": "x"}}  from the last result
  {"name": "@expect", "arguments": {"var": "x", "value": "..."}}
  {"name": "@absent", "arguments": {"pattern": "regex"}}   the last result must NOT match
  {"name": "@shell", "arguments": {"cmd": "..."}}          run a shell command
  a tool call with "expect_error": "regex"                 must fail with matching text
"""
import argparse
import base64
import json
import shlex
import os
import queue
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "artifacts", "screenshots")


def binary_path():
    # LEAP_BIN overrides the build product, e.g. to exercise dist/Leap.app.
    if os.environ.get("LEAP_BIN"):
        path = os.path.expanduser(os.environ["LEAP_BIN"])
        if not os.path.exists(path):
            print(f"LEAP_BIN not found: {path}")
            sys.exit(1)
        return path
    p = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        print("swift build --show-bin-path failed:\n" + p.stdout + p.stderr)
        sys.exit(1)
    path = os.path.join(p.stdout.strip().splitlines()[-1], "leap")
    if not os.path.exists(path):
        print(f"binary not found at {path}; run swift build first")
        sys.exit(1)
    return path


class Client:
    def __init__(self, cmd):
        print(f"$ {' '.join(cmd)}")
        # Give the AppKit server its own session. With the responsibility-disclaiming
        # re-exec, inheriting Python's session can prevent didFinishLaunching and
        # leave initialization waiting indefinitely under an agent's shell runner.
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, bufsize=1, start_new_session=True, cwd=ROOT)
        assert self.p.stdin and self.p.stdout and self.p.stderr
        self.stdin = self.p.stdin
        self.q = queue.Queue()
        self.err = []
        threading.Thread(target=self._pump, args=(self.p.stdout, self.q.put), daemon=True).start()
        threading.Thread(target=self._pump, args=(self.p.stderr, self.err.append), daemon=True).start()
        self.next_id = 1

    @staticmethod
    def _pump(stream, sink):
        for line in stream:
            sink(line)

    def request(self, method, params=None, timeout=120):
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.stdin.write(json.dumps(msg) + "\n")
        self.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.p.poll() is not None:
                print(f"server exited with code {self.p.returncode}\nstderr:\n{''.join(self.err)}")
                sys.exit(1)
            try:
                line = self.q.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                print("non-JSON line from server:", line.rstrip())
                continue
            if m.get("id") == rid:
                return m
        print(f"TIMEOUT waiting for {method} after {timeout}s\nstderr:\n{''.join(self.err)}")
        self.p.kill()
        sys.exit(1)

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.stdin.write(json.dumps(msg) + "\n")
        self.stdin.flush()

    def close(self):
        self.stdin.close()
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill()
        if self.err:
            print("--- server stderr ---\n" + "".join(self.err).rstrip())


def show_result(label, m):
    if "error" in m:
        print(f"{label} → JSON-RPC ERROR: {json.dumps(m['error'], indent=2)}")
        return False
    res = m["result"]
    ok = not res.get("isError")
    print(f"{label} → {'ok' if ok else 'TOOL ERROR'}")
    for i, part in enumerate(res.get("content", [])):
        if part.get("type") == "text":
            print(part["text"])
        elif part.get("type") == "image":
            ext = "jpg" if "jpeg" in part.get("mimeType", "") else "png"
            os.makedirs(SHOTS, exist_ok=True)
            path = os.path.join(SHOTS, f"{int(time.time())}_{label.replace(' ', '_')}_{i}.{ext}")
            with open(path, "wb") as f:
                f.write(base64.b64decode(part["data"]))
            print(f"[image {part.get('mimeType')} → {path} ({os.path.getsize(path) // 1024} KB)]")
        else:
            print(json.dumps(part)[:2000])
    return ok


def invoke(client, name, arguments, timeout=180):
    """Call a tool whose result is JSON text; raise on any error. Used by workflow and tests."""
    response = client.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
    if "error" in response or response.get("result", {}).get("isError"):
        raise RuntimeError(json.dumps(response))
    return json.loads(next(c["text"] for c in response["result"]["content"] if c["type"] == "text"))


def connect(name="mcp.py"):
    # LEAP_ARGS adds server arguments, so the same client can list another stdio MCP server
    # (LEAP_BIN=<server> LEAP_ARGS=mcp) for comparison.
    client = Client([binary_path()] + shlex.split(os.environ.get("LEAP_ARGS", "")))
    init = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": name, "version": "1"}})
    if "result" not in init:
        print("initialize failed:", json.dumps(init))
        sys.exit(1)
    client.notify("notifications/initialized")
    return client


def run_script(client, path):
    """Run one scenario file in the given session. Returns True when every step passed."""
    with open(path) as f:
        calls = json.load(f)
    # All calls share ONE server session, as with an MCP client: element indices are only
    # meaningful within a single session.
    captured, last_text = {}, ""

    def substitute(value):
        if isinstance(value, str):
            # Longest names first so "$item" never eats the front of "$item2".
            for k in sorted(captured, key=len, reverse=True):
                v = captured[k]
                if value == "$" + k:
                    return int(v) if v.lstrip("-").isdigit() else v
                value = re.sub(r"\$" + re.escape(k) + r"(?![A-Za-z0-9_])", v, value)
            return value
        if isinstance(value, dict):
            return {k: substitute(v) for k, v in value.items()}
        if isinstance(value, list):
            return [substitute(v) for v in value]
        return value

    for i, c in enumerate(calls, 1):
        args = substitute(c.get("arguments", {}))
        assert isinstance(args, dict), f"arguments for {c['name']} must be an object"
        if c["name"] == "@capture":
            pattern, var = str(args["pattern"]), str(args["var"])
            m = re.search(pattern, last_text)
            if not m:
                print(f"@capture FAILED: /{pattern}/ not found in previous result")
                return False
            captured[var] = m.group(1)
            print(f"@capture {var} = {m.group(1)!r}")
            continue
        if c["name"] == "@absent":
            pattern = str(args["pattern"])
            if re.search(pattern, last_text):
                print(f"@absent FAILED: /{pattern}/ found in previous result")
                return False
            print(f"@absent ok: /{pattern}/ not present")
            continue
        if c["name"] == "@expect":
            # Compare as text: substitution may have coerced "$var" to an int.
            var, want = str(args["var"]), str(args["value"])
            got = captured.get(var)
            if got != want:
                print(f"@expect FAILED: {var} is {got!r}, expected {want!r}")
                return False
            print(f"@expect ok: {var} == {want!r}")
            continue
        if c["name"] == "@shell":
            cmd = str(args["cmd"])
            print(f"\n===== [{i}] @shell {cmd}")
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=ROOT)
            print((r.stdout + r.stderr).rstrip())
            if r.returncode != 0:
                print(f"@shell FAILED: exit {r.returncode}")
                return False
            continue
        print(f"\n===== [{i}] {c['name']} {json.dumps(args)}")
        reply = client.request("tools/call", {"name": c["name"], "arguments": args})
        last_text = "\n".join(p.get("text", "") for p in reply.get("result", {}).get("content", []))
        succeeded = show_result(f"{i} {c['name']}", reply)
        if "expect_error" in c:
            pattern = str(c["expect_error"])
            if succeeded or not re.search(pattern, last_text):
                print(f"expect_error FAILED: wanted an error matching /{pattern}/")
                return False
            print(f"expect_error ok: /{pattern}/")
            continue
        if not succeeded:
            return False
    return True


def run_workflow(client, path):
    """session_open + ui_perform + session_close from a workflow file. Returns the result dict."""
    with open(path) as f:
        workflow = json.load(f)
    result, session = {"execution": "failed", "verification": "unknown"}, None
    try:
        session = invoke(client, "session_open", workflow["session"])["session_id"]
        result = invoke(client, "ui_perform", {"session_id": session, "steps": workflow["steps"],
                                               "timeout": workflow.get("timeout", 60)})
        if result.get("omittedFromResponse"):
            with open(result["file"]) as f:
                result = json.load(f)
    except Exception as error:  # report the failure in the result
        result["error"] = str(error)
    finally:
        if session:
            try:
                invoke(client, "session_close", {"session_id": session})
            except Exception as error:
                result["close_error"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("tools", help="list the tools")
    call = sub.add_parser("call", help="call one tool")
    call.add_argument("name")
    call.add_argument("arguments", nargs="?", default="{}", help="JSON object")
    script = sub.add_parser("script", help="run scenario files")
    script.add_argument("files", nargs="+")
    workflow = sub.add_parser("workflow", help="run a ui_perform workflow file")
    workflow.add_argument("file")
    args = parser.parse_args()

    ok = True
    if args.command == "script":
        results = []
        for path in args.files:
            print(f"\n##### {path}")
            client = connect()
            try:
                passed = run_script(client, path)
            finally:
                client.close()
            results.append((path, passed))
        print()
        for path, passed in results:
            print(f"{'PASS' if passed else 'FAIL'}  {path}")
        sys.exit(0 if all(p for _, p in results) else 1)
    client = connect()
    try:
        if args.command == "tools":
            tools = client.request("tools/list", {})["result"]["tools"]
            for t in tools:
                props = list(t.get("inputSchema", {}).get("properties", {}).keys())
                print(f"- {t['name']}({', '.join(props)})\n    {t.get('description', '')}")
            # What a client sends the model: every name, description and schema.
            size = len(json.dumps(tools, separators=(",", ":")))
            print(f"\n{len(tools)} tools, {size} bytes of tool definitions (about {size // 4} tokens)")
        elif args.command == "call":
            ok = show_result(args.name, client.request("tools/call", {"name": args.name,
                                                                      "arguments": json.loads(args.arguments)}))
        elif args.command == "workflow":
            result = run_workflow(client, args.file)
            print(json.dumps(result, indent=2))
            ok = result.get("execution") == "completed" and result.get("verification") == "passed"
    finally:
        client.close()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
