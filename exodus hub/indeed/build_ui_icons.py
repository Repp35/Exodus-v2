"""Update or validate the offline PNG payloads used by the Roblox UI icon adapter."""
from __future__ import annotations

import argparse
import base64
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'modules/front/uiicons.luau'
NAMES = ('settings', 'chevron', 'minimize')


def generated(source: str) -> str:
    fingerprint = hashlib.sha256()
    for name in NAMES:
        image = (ROOT / 'assets/ui' / f'{name}.png').read_bytes()
        if not image.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError(f'{name}: expected a PNG image')
        fingerprint.update(name.encode() + b'\0' + image)
        encoded = base64.b64encode(image).decode()
        pattern = rf'(\b{name}\s*=\s*\{{\s*png\s*=\s*")[^"]*(")'
        source, count = re.subn(pattern, lambda match: match[1] + encoded + match[2], source)
        if count != 1:
            raise ValueError(f'{name}: missing or ambiguous icon payload')
    source, count = re.subn(r'\bVERSION\s*=\s*"[^"]*"',
                            f'VERSION = "{fingerprint.hexdigest()[:12]}"', source)
    if count != 1:
        raise ValueError('Missing or ambiguous icon version')
    return source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    current = MODULE.read_text()
    expected = generated(current)
    if args.check:
        if expected != current:
            raise SystemExit('UI PNG payloads are stale; run indeed/build_ui_icons.py')
        print('UI PNG payloads match their source assets.')
    elif current != expected:
        MODULE.write_text(expected)
        print('Updated embedded UI PNGs and cache version.')
