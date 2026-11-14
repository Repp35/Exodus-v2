#!/usr/bin/env python3
"""Compile real sources and run state/interaction tests in the official Luau CLI."""
import argparse
import subprocess
import tempfile
from pathlib import Path
from build_ui import ROOT, HUB, bundle
parser = argparse.ArgumentParser()
parser.add_argument('--luau', default='luau')
parser.add_argument('--compiler', default='luau-compile')
args = parser.parse_args()
files = sorted(ROOT.rglob('*.luau'))
files += [HUB / 'loader.luau']
for path in files:
    subprocess.run([args.compiler, str(path)], stdout=subprocess.DEVNULL, check=True)
# CLI require isolates globals. Embed the package so the mock can supply Roblox boundaries.
source = bundle().rsplit('return __require("library")', 1)[0]
mock = (HUB / 'indeed/tests/ui/roblox.luau').read_text().rsplit('return Mock', 1)[0]
suite = (HUB / 'indeed/tests/ui/suite.luau').read_text()
host = HUB
adapter = (host / 'modules/front/ui.luau').read_text()
uiconfig = (host / 'modules/front/uiconfig.luau').read_text()
permissions = (host / 'modules/logic/aux/permissions.luau').read_text()
harness = mock + '\nMock.install(getfenv())\n' + source + '\nlocal Library = __require("library")\nlocal Signal = __require("core/Signal")\nlocal Scope = __require("core/Scope")\nlocal Store = __require("core/Store")\n' + '\nlocal Adapter = (function()\n' + adapter + '\nend)()\nlocal UIConfig = (function()\n' + uiconfig + '\nend)()\nlocal Permissions = (function()\n' + permissions + '\nend)()\n' + suite
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp) / 'suite.luau'
    path.write_text(harness)
    subprocess.run([args.luau, str(path)], check=True)
print(f'Compiled {len(files)} source files')
