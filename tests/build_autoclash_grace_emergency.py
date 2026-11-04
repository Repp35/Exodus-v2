"""Grace packets and imminent balls activate clash only for the local target."""
from pathlib import Path
import sys

root, out = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/autoclash.luau').read_text()
source = source.replace('return AutoClash\n', 'return AutoClash, R, FN, evaluateClash, function(u,g) Utils=u; GameInfo=g end\n')
pre = '''local mt={}
mt.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end end
local function vec(x) return setmetatable({X=x,Y=0,Z=0},mt) end
local function typeof(v) if getmetatable(v)==mt then return "Vector3" end return type(v) end
local function module()
'''
post = '''
end
local function scenario()
 local clash,state,fn,evaluate,inject=module(); local enabled=false
 local snapshot={ball={Parent={}},position=vec(-30),velocity=vec(100),speed=100,targetId=42,targeted=true,grace=false,teleported=false}
 local utils={isActive=function() return true end,isManualSpamActive=function() return false end,getConfigValue=function(k) return k=='AutoClash' end,setAutoSpamActive=function(v) enabled=v end}
 inject(utils,{getLocalPing=function() return 0 end}); fn.now=function() return 1 end
 fn.getRadius=function() return {fullRadius=30,noWindowParryRadius=8.5} end
 fn.getSnapshot=function() return snapshot end; fn.isSnapshotValid=function() return true end
 state.bound=true; state.boundRoot={Parent={},Position=vec(0)}; state.localUserId=42; state.lastTarget=42; state.wasMeTarget=true
 return clash,state,evaluate,snapshot,function() return enabled end
end
do local c,s,e,b,active=scenario(); b.grace=true; b.velocity=vec(0)
 c.onBallSync({Sequence=1,TargetPlayerID=42,Grace=true,Source="packet"})
 assert(c.isActive() and active() and c.getStatus().activationReason=='grace', 'same-target grace packet must activate immediately') end
do local c,s,e,b,active=scenario(); b.position=vec(-12); e(1,b)
 assert(c.isActive() and active() and c.getStatus().activationReason=='imminent_impact', 'incoming imminent ball must activate') end
do local c,s,e,b,active=scenario(); b.position=vec(-12); b.velocity=vec(-100); e(1,b)
 assert(not c.isActive() and not active(), 'outgoing ball must not trigger') end
do local c,s,e,b,active=scenario(); b.position=vec(-30); e(1,b)
 assert(not c.isActive() and not active(), 'distant ball must not trigger emergency') end
do local c,s,e,b,active=scenario(); b.grace=true; b.targetId=7; b.targeted=false; s.lastTarget=7; e(1,b)
 assert(not c.isActive() and not active(), 'grace for another player must not trigger') end
do local c,s,e,b,active=scenario(); b.grace=true; b.teleported=true; e(1,b)
 assert(not c.isActive() and not active(), 'teleported snapshot must not trigger') end
print('AutoClash grace and imminent impact: PASS')
'''
out.write_text(pre+source+post)
