#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GIGNIT LLC and the Leap contributors
"""Build, install, verify and remove Leap on this Mac.

Commands (default: install):
  install [--no-build] [--identity ID]   build and sign dist/Leap.app, then install or update it
  build [--identity ID]                  only build and sign dist/Leap.app
  check                                  verify the installation; changes nothing
  skills                                 refresh the agent skills only
  uninstall [--purge]                    remove Leap; --purge also removes settings and logs

Install copies the signed app to ~/Applications/Leap.app, installs each skill to
~/.claude/skills/<name>, creates ~/.config/leap/leap.json if needed, registers the `leap` server
with Claude Code (when the `claude` CLI exists), and asks macOS for Leap's permissions.
Installing is idempotent: re-run it after `git pull` to update; it repairs anything missing or
stale and finishes with the same checks as `check`. Restart your MCP client afterwards.

Signing: the first "Developer ID Application" or "Apple Development" identity is used, else an
ad-hoc signature (works, but macOS asks for permissions again after every rebuild).
"""
import argparse
import filecmp
import importlib.util
import json
import plistlib
import re
import time
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST_APP = os.path.join(ROOT, "dist", "Leap.app")
DIST_SERVER = os.path.join(DIST_APP, "Contents", "MacOS", "leap")

INSTALL_APP = os.path.expanduser("~/Applications/Leap.app")
INSTALLED_SERVER = os.path.join(INSTALL_APP, "Contents", "MacOS", "leap")

SKILLS_DIR = os.path.join(ROOT, "skills")
SKILLS_DST_ROOTS = [os.path.expanduser("~/.claude/skills")]


MARKER = ".leap-installed"  # skills carrying this file were installed by Leap and may be replaced


def run(cmd, check=True, stream=False):
    print("$ " + " ".join(cmd), flush=True)
    if stream:
        p = subprocess.run(cmd)
    else:
        p = subprocess.run(cmd, capture_output=True, text=True)
        out = (p.stdout + p.stderr).strip()
        if out:
            print(out)
    if check and p.returncode != 0:
        print(f"FAILED (exit {p.returncode})")
        sys.exit(1)
    return p


def claude_cli():
    return shutil.which("claude")


def owned(path):
    """True when the path is absent or carries Leap's marker (never touch a user's own skill)."""
    return not os.path.lexists(path) or os.path.exists(os.path.join(path, MARKER))


def _rm(path):
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.remove(path)


def each_skill():
    """(name, repo_src, installed_dst) for every skills/<name>/ that has a SKILL.md."""
    if not os.path.isdir(SKILLS_DIR):
        return
    for name in sorted(os.listdir(SKILLS_DIR)):
        src = os.path.join(SKILLS_DIR, name)
        if os.path.isdir(src) and os.path.exists(os.path.join(src, "SKILL.md")):
            for destination in SKILLS_DST_ROOTS:
                yield name, src, os.path.join(destination, name)


LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
              "/Support/lsregister")
SCREEN_PANE = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"


def project_bundle_id():
    """The bundle id this source tree builds (bundle/Info.plist)."""
    with open(os.path.join(ROOT, "bundle", "Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def bundle_id(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except OSError:
        return None


# Screen Recording registration on current macOS (verified on macOS 27):
#
# - The permission is never granted from a dialog. A request from the app adds it to System
#   Settings > Privacy & Security > Screen & System Audio Recording (switched off); the user turns
#   it on there and restarts the MCP client.
# - The request must come from Leap itself. Run from a terminal or an MCP client, macOS charges it
#   to that parent app, so it is launched through LaunchServices (`open`).
# - The alert agent (universalAccessAuthWarn, a long-running per-user process) caches the bundle
#   identity of an app path and remembers paths it already warned about. If a different bundle id
#   was installed at that path, or a stale Leap server is still running, requests are recorded
#   under that other id, which System Settings hides because no installed app has it. Leap then never
#   appears in the list and "+" does nothing. The repair clears that cache, restarts the agent,
#   resets the stale permission records and unregisters other copies of the app.
# - `tccutil reset` only accepts a bundle id that LaunchServices can resolve; records for an id no
#   longer installed are reset through a temporary stub bundle carrying that id.
# Background: docs/ARCHITECTURE.md, "Permissions and identity".

WARNED_PREFS = os.path.expanduser("~/Library/Preferences/com.apple.universalaccessAuthWarning.plist")


def stop_running_servers():
    """A running server keeps the identity it started with; stop it so the client starts the
    installed one."""
    for path in (INSTALLED_SERVER, DIST_SERVER):
        subprocess.run(["pkill", "-f", path], capture_output=True)


def registered_copies(ids):
    """Paths LaunchServices has registered for any of the given bundle ids."""
    if not os.path.exists(LSREGISTER):
        return []
    dump = subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True).stdout
    paths = []
    for block in dump.split("\n-----"):
        path = ident = None
        for line in block.splitlines():
            if line.startswith("path:"):
                path = line.split(":", 1)[1].strip().rsplit(" (0x", 1)[0]
            elif line.startswith("identifier:"):
                ident = line.split(":", 1)[1].strip()
        if path and ident in ids and path.endswith(".app"):
            paths.append(path)
    return sorted(set(paths))


def reset_tcc(bundle, services=("ScreenCapture",)):
    """tccutil reset for a bundle id, even when no installed app carries it any more."""
    for service in services:
        if subprocess.run(["tccutil", "reset", service, bundle], capture_output=True).returncode == 0:
            continue
        stub = os.path.join(os.path.dirname(INSTALL_APP), ".leap-tcc-reset.app")
        _rm(stub)
        try:
            subprocess.run(["ditto", INSTALL_APP if os.path.exists(INSTALL_APP) else DIST_APP, stub], check=True)
            subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle}",
                            os.path.join(stub, "Contents", "Info.plist")], check=True)
            subprocess.run(["codesign", "-f", "-s", "-", "--identifier", bundle, stub], capture_output=True)
            subprocess.run([LSREGISTER, "-f", stub], capture_output=True)
            time.sleep(1)
            subprocess.run(["tccutil", "reset", service, bundle], capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            pass
        finally:
            subprocess.run([LSREGISTER, "-u", stub], capture_output=True)
            _rm(stub)


def repair_screen_recording(ids):
    """Clear macOS's cached identity for the install path and the given ids, then reset records."""
    print("repairing Screen Recording registration (cached identity: " + ", ".join(sorted(ids)) + ")")
    try:
        with open(WARNED_PREFS, "rb") as f:
            warned = plistlib.load(f)
        stale = [k for k in warned if any(i in k for i in ids) or INSTALL_APP in k]
        for k in stale:
            del warned[k]
        with open(WARNED_PREFS, "wb") as f:
            plistlib.dump(warned, f)
        subprocess.run(["killall", "cfprefsd"], capture_output=True)
    except (OSError, plistlib.InvalidFileException):
        pass
    subprocess.run(["killall", "universalAccessAuthWarn"], capture_output=True)  # launchd restarts it
    for path in registered_copies(ids):
        if path != INSTALL_APP:
            subprocess.run([LSREGISTER, "-u", path], capture_output=True)
            print(f"unregistered other copy: {path}")
    for bundle in ids:
        reset_tcc(bundle)
    subprocess.run([LSREGISTER, "-f", INSTALL_APP], capture_output=True)


def forget_install():
    """Uninstall: stop servers, remove Leap's permission records and LaunchServices registration."""
    stop_running_servers()
    current = bundle_id(INSTALL_APP)
    if current:
        reset_tcc(current, ("ScreenCapture", "Accessibility"))
    if os.path.exists(LSREGISTER) and os.path.exists(INSTALL_APP):
        subprocess.run([LSREGISTER, "-u", INSTALL_APP], capture_output=True)


def ask_once():
    out = "/tmp/leap-permissions.out"
    _rm(out)
    run(["open", "-W", "-n", "--stdout", out, INSTALL_APP, "--args", "--request-permissions"], check=False)
    try:
        with open(out) as f:
            return f.read().strip().splitlines()[-1]
    except (OSError, IndexError):
        return ""


def request_permissions(replaced_ids=()):
    """Ask macOS for Leap's own Accessibility and Screen Recording grants.

    Register and ask. If the app replaced at the install path had a different bundle id, repair
    first. If Screen Recording is still missing after asking, repair once and ask again. An
    existing grant is never reset.
    """
    current = bundle_id(INSTALL_APP)
    if os.path.exists(LSREGISTER):
        subprocess.run([LSREGISTER, "-f", INSTALL_APP], capture_output=True)
    stale = {i for i in replaced_ids if i and i != current}
    if stale:
        repair_screen_recording(stale)
    status = ask_once()
    if "screen_recording=MISSING" in status and current:
        repair_screen_recording(stale | {current})
        status = ask_once()
    print(status)
    if "screen_recording=MISSING" in status:
        time.sleep(1)
        subprocess.run(["open", SCREEN_PANE])
    return status


def install_app():
    # `ditto` copies an app bundle preserving the code signature and extended attributes,
    # so the installed copy keeps its Developer ID identity (and therefore its TCC grants).
    os.makedirs(os.path.dirname(INSTALL_APP), exist_ok=True)
    replaced = bundle_id(INSTALL_APP)
    stop_running_servers()
    _rm(INSTALL_APP)
    run(["ditto", DIST_APP, INSTALL_APP])
    if not os.path.exists(INSTALLED_SERVER):
        print(f"install failed: {INSTALLED_SERVER} missing after copy")
        sys.exit(1)
    print(f"app:   {INSTALL_APP}")
    # Only the installed copy may be registered under Leap's id: other copies (other builds, backups)
    # confuse permission attribution.
    current = bundle_id(INSTALL_APP)
    if os.path.exists(LSREGISTER) and current:
        for path in registered_copies({current}):
            if os.path.realpath(path) != os.path.realpath(INSTALL_APP):
                subprocess.run([LSREGISTER, "-u", path], capture_output=True)
                print(f"unregistered other copy: {path}")
        subprocess.run([LSREGISTER, "-f", INSTALL_APP], capture_output=True)
    return replaced


def install_skills():
    for destination in SKILLS_DST_ROOTS:
        os.makedirs(destination, exist_ok=True)
    for name, src, dst in each_skill():
        with open(os.path.join(src, "SKILL.md")) as f:
            assert f.read(64).startswith("---\nname: " + name), f"{name}/SKILL.md frontmatter name mismatch"
        if not owned(dst):
            print(f"skipped skill: {dst} exists and was not installed by Leap; remove it to install ours")
            continue
        _rm(dst)
        shutil.copytree(src, dst)
        open(os.path.join(dst, MARKER), "w").close()
        print(f"skill: {dst}")


CONFIG_DIR = os.path.expanduser("~/.config/leap")
LOG_DIR = os.path.expanduser("~/.leap/logs")


def config_problem(path):
    """None when the settings file is valid (same rules as the server), else the reason."""
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as error:
        return f"not valid JSON ({error})"
    if not isinstance(data, dict):
        return "must be a JSON object"
    for key, field, valid in (("logging", "level", lambda v: v in ("debug", "info", "warning", "error")),
                              ("insights", "enabled", lambda v: isinstance(v, bool))):
        section = data.get(key, {})
        if not isinstance(section, dict):
            return f"{key} must be an object"
        if field in section and not valid(section[field]):
            return f"{key}.{field} has an invalid value"
    return None


def install_config():
    """Create defaults once; never overwrite valid settings. An invalid file (which blocks every
    tool call) is kept as a timestamped backup and replaced with defaults."""
    directory = CONFIG_DIR
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, "leap.json")
    if os.path.exists(path):
        problem = config_problem(path)
        if problem:
            backup = f"{path}.invalid-{time.strftime('%Y%m%d-%H%M%S')}"
            os.rename(path, backup)
            print(f"settings were invalid ({problem}); kept as {backup}, defaults restored")
    try:
        with open(path, "x") as stream:
            json.dump({"logging": {"level": "info"}}, stream, indent=2)
            stream.write("\n")
        os.chmod(path, 0o600)
        print(f"config: {path}")
    except FileExistsError:
        print(f"config preserved: {path}")


# ---------------------------------------------------------------------------------------------
# Build

def build(identity=None):
    """swift build -c release, assemble dist/Leap.app with bundle/Info.plist, sign and verify."""
    run(["swift", "build", "-c", "release"], stream=True)
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
    binary = os.path.join(bin_dir, "leap")
    _rm(DIST_APP)
    os.makedirs(os.path.join(DIST_APP, "Contents", "MacOS"))
    shutil.copy2(binary, DIST_SERVER)
    shutil.copy2(os.path.join(ROOT, "bundle", "Info.plist"), os.path.join(DIST_APP, "Contents", "Info.plist"))
    with open(os.path.join(DIST_APP, "Contents", "PkgInfo"), "w") as f:
        f.write("APPL????")
    bundle = project_bundle_id()
    if not identity:
        ids = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
        m = re.search(r'"(Developer ID Application: [^"]+)"', ids) or re.search(r'"(Apple Development: [^"]+)"', ids)
        identity = m.group(1) if m else "-"
        if not m:
            print("No Developer ID or Apple Development identity found: signing ad-hoc. macOS will treat each\n"
                  "rebuild as a new app and ask for permissions again.")
    print(f"signing {DIST_APP} ({bundle}) with: {identity}")
    run(["codesign", "--force", "--deep", "--options", "runtime", "--timestamp=none",
         "--identifier", bundle, "--sign", identity, DIST_APP])
    run(["codesign", "--verify", "--deep", "--strict", DIST_APP])
    # Keep the build output from being registered as a second Leap app (Spotlight indexing
    # registers it with LaunchServices); only the installed copy should be.
    open(os.path.join(os.path.dirname(DIST_APP), ".metadata_never_index"), "w").close()
    if os.path.exists(LSREGISTER):
        subprocess.run([LSREGISTER, "-u", DIST_APP], capture_output=True)
    print(f"built: {DIST_APP}")


# ---------------------------------------------------------------------------------------------
# Verification (install.py check, and the end of every install)

def same_tree(a, b):
    """True when directory b has every file of a with identical content (b may add the marker)."""
    cmp = filecmp.dircmp(a, b, ignore=[MARKER, ".DS_Store"])
    if cmp.left_only or cmp.right_only or cmp.funny_files:
        return False
    if filecmp.cmpfiles(a, b, cmp.common_files, shallow=False)[1:] != ([], []):
        return False
    return all(same_tree(os.path.join(a, d), os.path.join(b, d)) for d in cmp.common_dirs)


def mcp_handshake(server):
    """Start the installed server over stdio MCP, list its tools, call `permissions`."""
    spec = importlib.util.spec_from_file_location("leap_mcp", os.path.join(ROOT, "scripts", "mcp.py"))
    mcp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mcp)
    import io, contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        client = mcp.Client([server])
        try:
            reply = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                  "clientInfo": {"name": "leap-install-check", "version": "1"}}, timeout=30)
            client.notify("notifications/initialized")
            tools = client.request("tools/list", {}, timeout=30)["result"]["tools"]
            perms = client.request("tools/call", {"name": "permissions", "arguments": {}}, timeout=30)["result"]
        finally:
            client.close()
    version = reply["result"]["serverInfo"].get("version", "?")
    text = "".join(c.get("text", "") for c in perms.get("content", []))
    return len(tools), version, text.splitlines()[0] if text else ""


def check_installation(require_permissions=True):
    """Verify every part of the installation. Read-only. Returns True when nothing failed."""
    results = []

    def report(status, item, detail=""):
        results.append(status)
        print(f"{status:5} {item}" + (f": {detail}" if detail else ""))

    expected_id = project_bundle_id()
    installed_id = bundle_id(INSTALL_APP)
    if not installed_id:
        report("FAIL", "app", f"{INSTALL_APP} is not installed")
        print("\nNot installed. Run python3 scripts/install.py")
        return False
    report("PASS" if installed_id == expected_id else "FAIL", "app bundle id", f"{installed_id} (expected {expected_id})")
    signed = subprocess.run(["codesign", "--verify", "--deep", "--strict", INSTALL_APP], capture_output=True)
    report("PASS" if signed.returncode == 0 else "FAIL", "code signature", (signed.stderr.decode().strip() or "valid")[:200])
    if os.path.exists(DIST_SERVER):
        current = filecmp.cmp(DIST_SERVER, INSTALLED_SERVER, shallow=False)
        report("PASS" if current else "WARN", "installed build", "matches dist/Leap.app" if current
               else "differs from dist/Leap.app; re-run install.py to update")
    if os.path.exists(LSREGISTER):
        copies = registered_copies({installed_id})
        others = [p for p in copies if os.path.realpath(p) not in (os.path.realpath(INSTALL_APP), os.path.realpath(DIST_APP))]
        if INSTALL_APP not in copies:
            report("FAIL", "LaunchServices", "installed app is not registered")
        elif others:
            report("FAIL", "LaunchServices", "other copies registered with the same id: " + ", ".join(others))
        else:
            report("PASS", "LaunchServices", "only the installed app is registered")
    try:
        tools, version, perms = mcp_handshake(INSTALLED_SERVER)
        report("PASS" if tools > 0 else "FAIL", "MCP server", f"version {version}, {tools} tools")
    except Exception as error:  # report, never crash the check
        report("FAIL", "MCP server", f"handshake failed: {error}")
    if claude_cli():
        got = subprocess.run(["claude", "mcp", "get", "leap"], capture_output=True, text=True)
        ok = got.returncode == 0 and INSTALLED_SERVER in got.stdout
        report("PASS" if ok else "FAIL", "Claude Code registration",
               "leap -> installed app" if ok else "missing or pointing elsewhere")
    else:
        report("INFO", "Claude Code registration", "`claude` CLI not found; register leap with your MCP client")
    for name, src, dst in each_skill():
        if not os.path.isdir(dst):
            report("FAIL", f"skill {name}", "not installed")
        elif not owned(dst):
            report("WARN", f"skill {name}", "a different skill with this name exists; left untouched")
        elif not same_tree(src, dst):
            report("FAIL", f"skill {name}", "out of date")
        else:
            report("PASS", f"skill {name}", "current")
    config = os.path.join(CONFIG_DIR, "leap.json")
    if not os.path.exists(config):
        report("FAIL", "settings", f"{config} missing")
    else:
        problem = config_problem(config)
        report("FAIL" if problem else "PASS", "settings", f"{config}: {problem}" if problem else config)
    status = subprocess.run([INSTALLED_SERVER, "--permissions"], capture_output=True, text=True).stdout.strip()
    for grant, label in (("accessibility", "Accessibility"), ("screen_recording", "Screen Recording")):
        granted = f"{grant}=granted" in status
        report("PASS" if granted else ("FAIL" if require_permissions else "WARN"), f"permission {label}",
               "granted" if granted else "not granted: turn on Leap in System Settings > Privacy & Security")
    failed = results.count("FAIL")
    print(f"\n{len(results)} checks: {results.count('PASS')} passed, {results.count('WARN')} warnings, {failed} failed")
    return failed == 0


def check_uninstalled(purge):
    """Verify nothing Leap installed remains. Returns True when clean."""
    leftovers = []
    if os.path.lexists(INSTALL_APP):
        leftovers.append(INSTALL_APP)
    for name, _src, dst in each_skill():
        if os.path.lexists(os.path.join(dst, MARKER)):
            leftovers.append(dst)
    if claude_cli() and subprocess.run(["claude", "mcp", "get", "leap"], capture_output=True).returncode == 0:
        leftovers.append("Claude Code registration `leap`")
    if os.path.exists(LSREGISTER) and INSTALL_APP in registered_copies({project_bundle_id()}):
        leftovers.append("LaunchServices registration of the installed app")
    if subprocess.run(["pgrep", "-f", INSTALLED_SERVER], capture_output=True).returncode == 0:
        leftovers.append("running Leap server")
    if purge:
        leftovers += [p for p in (CONFIG_DIR, os.path.dirname(LOG_DIR)) if os.path.lexists(p)]
    for item in leftovers:
        print(f"FAIL  still present: {item}")
    if not leftovers:
        print("PASS  nothing installed by Leap remains" + ("" if purge else " (settings and logs kept; use --purge)"))
    return not leftovers


def uninstall(purge):
    if claude_cli():
        run(["claude", "mcp", "remove", "leap", "-s", "user"], check=False)
    forget_install()
    _rm(INSTALL_APP)
    print(f"removed {INSTALL_APP}")
    for _name, _src, dst in each_skill():
        if os.path.lexists(dst) and owned(dst):
            _rm(dst)
            print(f"removed {dst}")
    if purge:
        for path in (CONFIG_DIR, os.path.dirname(LOG_DIR)):
            if os.path.lexists(path):
                _rm(path)
                print(f"removed {path}")
    print()
    clean = check_uninstalled(purge)
    print("Uninstalled. Remove `leap` from any other MCP client configuration and restart it.")
    return clean


def install(no_build, identity):
    if not no_build:
        build(identity)
    if not os.path.exists(DIST_SERVER):
        print(f"built app missing: {DIST_SERVER}; run without --no-build")
        sys.exit(1)
    replaced_id = install_app()
    install_skills()
    install_config()
    if claude_cli():
        run(["claude", "mcp", "remove", "leap", "-s", "user"], check=False)
        run(["claude", "mcp", "add", "--scope", "user", "leap", "--", INSTALLED_SERVER])
    else:
        print("`claude` CLI not found; register the server with your MCP client, for example OpenCode:")
        print(f'  "mcp": {{ "leap": {{ "type": "local", "command": ["{INSTALLED_SERVER}"] }} }}')
    # Ask for Leap's own grants now, as "Leap" (not the terminal). No-op when already granted.
    request_permissions([replaced_id])
    print("\nVerifying the installation:")
    ok = check_installation(require_permissions=False)
    print("\nPermissions: turn on \"Leap\" under System Settings > Privacy & Security > Accessibility and")
    print("> Screen & System Audio Recording, restart your MCP client, then run install.py check.")
    return ok


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    p_install = sub.add_parser("install", help="build (unless --no-build), install or update")
    p_install.add_argument("--no-build", action="store_true", help="install the existing dist/Leap.app")
    p_install.add_argument("--identity", help='codesign identity ("-" = ad-hoc)')
    p_build = sub.add_parser("build", help="only build and sign dist/Leap.app")
    p_build.add_argument("--identity", help='codesign identity ("-" = ad-hoc)')
    sub.add_parser("check", help="verify the installation without changing anything")
    sub.add_parser("skills", help="refresh the agent skills only")
    p_uninstall = sub.add_parser("uninstall", help="remove Leap")
    p_uninstall.add_argument("--purge", action="store_true", help="also remove settings and logs")
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0].startswith("-") and argv[0] not in ("-h", "--help"):
        argv = ["install", *argv]
    args = parser.parse_args(argv)
    if args.command == "build":
        build(args.identity)
    elif args.command == "check":
        sys.exit(0 if check_installation() else 1)
    elif args.command == "skills":
        install_skills()
    elif args.command == "uninstall":
        sys.exit(0 if uninstall(args.purge) else 1)
    else:
        sys.exit(0 if install(args.no_build, args.identity) else 1)


if __name__ == "__main__":
    main()
