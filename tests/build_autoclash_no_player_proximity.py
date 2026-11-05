"""Exercise clash activation with a nearby player and a genuine ball return."""
from pathlib import Path
import sys

root, out = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/autoclash.luau').read_text()
source = source.replace('return AutoClash\n', 'return AutoClash, R, FN, evaluateClash, function(u) Utils=u end\n')
pre = '''local mt={}
mt.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end end
local function vec(x) return setmetatable({X=x,Y=0,Z=0},mt) end
local function typeof(v) if getmetatable(v)==mt then return "Vector3" end return type(v) end
local function module()
'''
post = '''
end
local clash, state, fn, evaluate, inject=module()
local enabled=false
inject({setAutoSpamActive=function(v) enabled=v end})
fn.now=function() return 1 end
fn.getRadius=function() return {fullRadius=30} end
state.boundRoot={Parent={},Position=vec(0)}; state.localUserId=42; state.lastTarget=7
state.proximityPartnerId=7; state.clashPartnerId=7
local partnerRoot={Parent={},Position=vec(1)}
state.players={GetPlayerByUserId=function() return {Character={FindFirstChild=function() return partnerRoot end}} end}
local ball={Parent={}}
local snapshot={ball=ball,position=vec(-5),velocity=vec(100),speed=100,targetId=7,targeted=false}
evaluate(1,snapshot)
assert(not clash.isActive() and not enabled, 'a nearby player alone must not start clash')
state.lastTarget=42; state.returnPending=true; snapshot.targetId=42; snapshot.targeted=true
evaluate(1.01,snapshot)
assert(clash.isActive() and enabled, 'a valid ball return must still start clash')
print('AutoClash ignores player proximity and accepts valid returns: PASS')
'''
out.write_text(pre+source+post)
