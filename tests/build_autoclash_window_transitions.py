"""Check that Auto Clash stops and resumes on the deflect-window boundary."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / 'exodus hub/modules/logic/autoclash.luau').read_text()
start = s.index('local function evaluate(s, snapshot, time)')
source = s[start:s.index('    local targeted = target and target == me', start)] + 'end\n'
pre = r'''
local current={bound=true,active=true,partner=7}
local localPlayer={UserId=42}
local inside=false
local function id(v) return v end
local function gate() return true end
local function geometry() return {imminent=inside} end
local function outsideClashRadius() return true end
local function setActive(s, active) s.active=active; if not active then s.partner=-1 end end
'''
post = r'''
local s=current
local ball={targetId=42}
evaluate(s,ball,0); assert(not s.active and s.windowPaused and s.windowPartner==7, 'exit must stop immediately')
inside=true; evaluate(s,ball,1); assert(not s.active and s.windowPaused, 'window return alone must not resume')
s.active=true; s.windowPaused=false; s.partner=7; inside=false; evaluate(s,ball,2); assert(not s.active, 'second exit must stop immediately')
ball.targetId=8; evaluate(s,ball,3); assert(not s.windowPaused and not s.active, 'redirect must clear rearm')
print('Auto Clash window transitions: PASS')
'''
output.write_text(pre + source + post)
