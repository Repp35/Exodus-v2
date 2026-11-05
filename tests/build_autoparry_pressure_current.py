"""Check current Auto Parry pressure with a recent successful sample."""
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / 'exodus hub/modules/logic/autoparry.luau').read_text()
source = s[s.index('function AutoParry.getPressure()'):s.index('function AutoParry.getStatus()')]
pre = r'''
local AutoParry={}
local now=10
local function clock() return now end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local state={clicks={{at=10,factor=.3,configured=.5,speed=100}}, returns={}}
'''
post = r'''
local p=AutoParry.getPressure()
assert(math.abs(p.currentLevel-.4)<1e-6 and p.factorDrop==nil, 'one recent successful parry should expose current effort')
now=11.01; assert(AutoParry.getPressure().currentLevel==nil, 'stale effort must not activate clash')
print('Auto Parry current pressure: PASS')
'''
out.write_text(pre + source + post)
