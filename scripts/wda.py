#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GIGNIT LLC and the Leap contributors
"""Build and start a pinned WebDriverAgent for Leap's `wda` backend on a booted iOS Simulator.

Commands:
  build UDID              clone WebDriverAgent at the pinned revision and build it for the device
  start UDID [--port N]   start the runner (default port 8100) and wait until it answers
  status UDID             show the runner's endpoint and state

UDIDs come from `xcrun simctl list devices booted`. The device is never booted, erased or reset.
Downloads, build output and logs stay under artifacts/ (ignored). Pass the printed endpoint to
`session_open(backend: "wda", endpoint: ...)`. The runner must keep running while a session uses
it; a background job runner such as runner-mcp is convenient for that.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REV = '1892efc71cc6e5bc8a20b083acc2753ea2288b62'
SOURCE = ROOT / 'artifacts/downloads/WebDriverAgent'
OUT = ROOT / 'artifacts/test-runs/wda'

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('action', choices=['build', 'start', 'status'])
    parser.add_argument('udid')
    parser.add_argument('--port', type=int, default=8100)
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))
    hits = [d for values in devices['devices'].values() for d in values if d['udid'] == args.udid]
    if len(hits) != 1 or hits[0]['state'] != 'Booted':
        parser.error('Select one existing booted Simulator UDID; this script never boots/resets devices implicitly')
    if not 1024 <= args.port <= 65535:
        parser.error('Port must be 1024..65535')
    output = OUT / args.udid
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / 'endpoint.json'
    if args.action == 'status':
        info = json.loads(manifest.read_text())
        with urllib.request.urlopen(info['endpoint']+'/status', timeout=5) as r:
            info['status'] = json.load(r)
        print(json.dumps(info, indent=2)); return
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git','clone','https://github.com/appium/WebDriverAgent.git',str(SOURCE)],check=True)
        subprocess.run(['git','-C',str(SOURCE),'checkout',REV],check=True)
    revision = subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip()
    if revision != REV:
        parser.error(f'Reference must be pinned to {REV}; found {revision}; existing checkout preserved')
    command = ['xcodebuild','-project',str(SOURCE/'WebDriverAgent.xcodeproj'),'-scheme','WebDriverAgentRunner',
               '-destination',f'platform=iOS Simulator,id={args.udid}', '-derivedDataPath',str(output/'DerivedData'),
               'CODE_SIGNING_ALLOWED=NO']
    if args.action == 'build':
        with (output/'build.log').open('w') as log:
            done = subprocess.run(command+['build-for-testing'],stdout=log,stderr=subprocess.STDOUT)
        print(json.dumps({'exit':done.returncode,'log':str(output/'build.log'),'revision':REV}))
        raise SystemExit(done.returncode)
    endpoint = f'http://127.0.0.1:{args.port}'
    try:
        urllib.request.urlopen(endpoint+'/status', timeout=1)
    except Exception:
        pass
    else:
        parser.error('Endpoint already responds; refusing to take over another runner')
    env = dict(os.environ, USE_PORT=str(args.port), SIMCTL_CHILD_USE_PORT=str(args.port))
    with (output/'runner.log').open('a') as log:
        p = subprocess.Popen(command+['test-without-building'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    info = {'udid':args.udid,'device':hits[0]['name'],'endpoint':endpoint,'pid':p.pid,'revision':REV,'log':str(output/'runner.log'),'ready':False}
    manifest.write_text(json.dumps(info,indent=2))
    for _ in range(60):
        if p.poll() is not None:
            raise SystemExit(f'Runner exited {p.returncode}; inspect {info["log"]}')
        try:
            with urllib.request.urlopen(endpoint+'/status',timeout=1) as r:
                info['status'] = json.load(r)
            info['ready'] = True; break
        except Exception:
            time.sleep(0.5)
    manifest.write_text(json.dumps(info,indent=2))
    print(json.dumps(info,indent=2))
    if not info['ready']:
        raise SystemExit('Runner still starting; use status and inspect log. Do not launch a duplicate.')

if __name__ == '__main__':
    main()
