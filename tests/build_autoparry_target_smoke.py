"""Generate a Luau test for scheduled parries and target changes."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
output = Path(sys.argv[2])
source=(root / 'exodus hub/modules/logic/autoparry.luau').read_text().replace('return os.clock()','return currentTime',1).replace('return AutoParry\n','return {state=R, heartbeat=onHeartbeat, setDeps=function(a,b,c) Remote=a; GameInfo=b; Utils=c end}\n')
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
local fires=0; local target=42
local ball={instance=true,Parent={},Position=vec(-10),AssemblyLinearVelocity=vec(0),IsA=function() return true end}
local player={UserId=42, GetNetworkPing=function() return 0 end,GetAttribute=function() return 8.5 end}
local char={Parent={}}; local root={Parent={},Position=vec(0)}
local sync={TargetPlayerID=42,Speed=100,Teleported=false}
local info={getDeflectRange=function() return 8.5 end,getLocalPing=function() return 0 end,getBallPosition=function(b) return b.Position end,getBallVelocity=function(b) return b.AssemblyLinearVelocity end,getRootPosition=function(r) return r.Position end,getSyncData=function() return sync end,getSnapshot=function() return {ball=ball,targeted=target==42,targetId=target,position=ball.Position} end,isSnapshotValid=function() return true end,getBall=function() return ball end,getTargetId=function() return target end}
local utils={getConfig=function() return {AutoParry=true} end,isActive=function() return true end,isSpamActive=function() return false end}
t.setDeps({fireParry=function() fires+=1; return true end},info,utils)
R.player=player; R.root=root; R.character=char; R.bound=true; R.alive=true; R.generation=1
local function frame(x) currentTime+=0.01; ball.Position=vec(x); t.heartbeat(char,root,0.01,1) end
frame(-10); frame(-9)
assert(#queued==1,"expected scheduled parry")
target=7; sync.TargetPlayerID=7
local p=table.remove(queued,1); p[1](p[2],p[3],p[4]); assert(fires==0,"stale target fired")
target=42; sync.TargetPlayerID=42
frame(-8)
assert(#queued==1,"expected rearmed parry")
p=table.remove(queued,1); p[1](p[2],p[3],p[4]); assert(fires==1,"valid target did not fire")
print("AP scheduled dispatch and target change: PASS")
'''
output.write_text(pre+source+post)
