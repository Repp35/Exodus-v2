#!/usr/bin/env python3
"""Bundle standard Roblox ModuleScripts without runtime HTTP or loadstring dependencies."""
import argparse
import re
from pathlib import Path

HUB = Path(__file__).resolve().parents[1]
ROOT = HUB / 'modules/front'
REQUIRE = re.compile(r'require\(script((?:\.[A-Za-z_][A-Za-z_0-9]*)+)\)')

def bundle(entry='library'):
    paths = [ROOT / 'library.luau', ROOT / 'Window.luau']
    paths += sorted((ROOT / 'core').glob('*.luau')) + sorted((ROOT / 'components').glob('*.luau'))
    modules = {p.relative_to(ROOT).with_suffix('').as_posix(): p.read_text() for p in paths}
    def rewrite(name, source):
        def resolve(match):
            # ModuleScripts keep their original location under modules/front.
            parts = name.split('/')
            for part in match[1].split('.')[1:]:
                if part == 'Parent':
                    if not parts: raise ValueError(f'{name}: require escapes package')
                    parts.pop()
                else: parts.append(part)
            target = '/'.join(parts)
            if target not in modules: raise ValueError(f'{name}: unknown module {target}')
            return f'__require("{target}")'
        return REQUIRE.sub(resolve, source)
    output = ['-- Generated for delivery from modules/front by indeed/build_ui.py.', 'local __factories, __cache, __loading = {}, {}, {}', 'local function __require(name)', '  if __cache[name] ~= nil then return __cache[name] end', '  assert(not __loading[name], "Circular module: " .. name)', '  __loading[name] = true', '  local value = __factories[name]()', '  __loading[name] = nil; __cache[name] = value', '  return value', 'end']
    for name, source in sorted(modules.items()):
        output += [f'__factories["{name}"] = function()', rewrite(name, source), 'end']
    output.append(f'return __require("{entry}")')
    return '\n'.join(output) + '\n'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = bundle()
    if args.check:
        if not args.output.exists() or args.output.read_text() != result: raise SystemExit('Bundle is stale; rebuild with indeed/build_ui.py')
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result)
    print(f'{args.output}: {len(result.encode())} bytes')
if __name__ == '__main__': main()
