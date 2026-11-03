"""Generate a Luau test for immediate parries and target changes."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
output = Path(sys.argv[2])
source=(root / 'exodus hub/modules/logic/autoparry.luau').read_text().replace('return os.clock()','return currentTime',1).replace('return AutoParry\n','return {state=R, heartbeat=onHeartbeat, event=AutoParry.onBallSync, setDeps=function(a,b,c) Remote=a; GameInfo=b; Utils=c end}\n')
pre='''local currentTime=1
local mt={}
mt.__index=function(t,k) if k=="Magnitude" then return math.abs(t.x) elseif k=="Dot" then return function(a,b) return a.x*b.x end end end
mt.__add=function(a,b) return setmetatable({x=a.x+b.x},mt) end
mt.__sub=function(a,b) return setmetatable({x=a.x-b.x},mt) end
mt.__mul=function(a,b) return setmetatable({x=a.x*b},mt) end
mt.__div=function(a,b) return a*(1/b) end
local function vec(x) return setmetatable({x=x},mt) end
local Vector3={zero=vec(0)}
local function typeof(x) if getmetatable(x)==mt then return "Vector3" elseif type(x)=="table" and x.instance then return "Instance" else return type(x) end end
local queued={}
local task={defer=function(f,...) table.insert(queued,{f,...}) end}
local function module()\n'''
post='''
end
local t=module(); local R=t.state
local fires=0; local target=42; local snapshotSeq
local ball={instance=true,Parent={},Position=vec(-10),AssemblyLinearVelocity=vec(0),IsA=function() return true end}
local player={UserId=42, GetNetworkPing=function() return 0 end,GetAttribute=function() return 8.5 end}
local char={Parent={}}; local root={Parent={},Position=vec(0)}
local sync={TargetPlayerID=42,Speed=100,Teleported=false}
local info={getBallSpeedLimits=function() return 16,600 end,getDeflectRange=function() return 8.5 end,getLocalPing=function() return 0 end,getBallPosition=function(b) return b.Position end,getBallVelocity=function(b) return b.AssemblyLinearVelocity end,getRootPosition=function(r) return r.Position end,getSyncData=function() return sync end,getSnapshot=function() return {ball=ball,targeted=target==42,targetId=target,position=ball.Position,syncSequence=snapshotSeq} end,isSnapshotValid=function() return true end,getBall=function() return ball end,getTargetId=function() return target end}
local utils={getConfig=function() return {AutoParry=true} end,isActive=function() return true end,isSpamActive=function() return false end}
t.setDeps({fireParry=function() fires+=1; return true end},info,utils)
R.player=player; R.root=root; R.character=char; R.bound=true; R.alive=true; R.generation=1
local function frame(x) currentTime+=0.01; ball.Position=vec(x); t.heartbeat(char,root,0.01,1) end
frame(-10); frame(-9)
assert(fires==1,"valid target should fire in the detection frame")
for _=1,15 do frame(ball.Position.x + 0.1) end
assert(fires==1,"must not click twice for the same target")
target=7; sync.TargetPlayerID=7; t.event(sync)
target=42; sync.TargetPlayerID=42; t.event(sync)
frame(-7)
assert(fires==2,"target leaving and returning must rearm")
for _=1,15 do frame(ball.Position.x + 0.05) end
assert(fires==2,"second target cycle must also stay locked")
target=7; sync.TargetPlayerID=7; frame(-7)
assert(fires==2,"must not fire for another target")
target=42; sync.TargetPlayerID=42; frame(-8); frame(-7)
assert(fires==3,"frame-observed return must rearm")
target=7; sync.TargetPlayerID=7; frame(-8); frame(-7)
assert(fires==3,"tracking another target must not fire")
target=42; sync.TargetPlayerID=42; frame(-6)
assert(fires==4,"return to local target must use already observed movement in the same frame")
frame(-5.9); assert(fires==4,"the same target must remain locked after an immediate parry")
target=7; sync.TargetPlayerID=7; frame(-6); frame(-5)
target=42; sync.TargetPlayerID=42; frame(-5)
assert(fires==4,"stationary ball on target change must not reuse old velocity")
frame(-4); assert(fires==5,"motion after a stationary target change must fire")
snapshotSeq=9; t.event({Sequence=10,TargetPlayerID=7}); frame(-3)
assert(fires==5,"a stale snapshot must not fire after the authoritative target changed")
t.event({Sequence=11,TargetPlayerID=42}); snapshotSeq=11; frame(-2)
assert(fires==6,"quick target cycle must rearm on the reliable packets")
t.event({Sequence=10,TargetPlayerID=7}); frame(-1.9)
assert(fires==6 and R.firedForTarget,"old packets must not rearm a new target")
print("AP same-frame dispatch and target cycles: PASS")
'''
output.write_text(pre+source+post)
