"""Exercise distance stops, per-frame evaluation, and reactivation lock."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/autospam.luau").read_text()
source = source.replace(
    "return AutoSpam\n",
    "return AutoSpam, start, evaluate, function(s,u,g,p) current=s; utils=u; gameInfo=g; localPlayer=p end\n",
)
script = r'''
local V = {}
V.__index = function(v,k)
    if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    return V[k]
end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
local function vec(x) return setmetatable({X=x,Y=0,Z=0},V) end
function typeof(v) if getmetatable(v)==V then return "Vector3" end return type(v) end
math.clamp=function(v,a,b) return math.max(a, math.min(b,v)) end
local auto, distance, ball, speed = false, 40, 10, 600
local rootPart={Parent={},Position=vec(0)}
local state={root=rootPart,active=false,target=42,connections={}}
local snapshot={position=vec(ball),syncSpeed=speed,speed=speed,targetId=42}
local utils={
    isActive=function() return true end, getConfigValue=function(k) return k=="AutoSpam" end,
    isManualSpamActive=function() return false end, setAutoSpamActive=function(v) auto=v end,
    setManualSpamActive=function() end, recordTransition=function() end,
}
local info={
    getBallSpeedLimits=function() return 16,600 end,
    getPlayerMotion=function(id) if id==7 then return vec(distance) end end,
    getSnapshotAt=function() snapshot.position=vec(ball); snapshot.syncSpeed=speed; return snapshot end,
    getBallFrozen=function() return false end,
    isSnapshotValid=function() return false end,
}
local module,start,evaluate,inject=assert(loadstring(SOURCE))()
inject(state,utils,info,{UserId=42})
local function frame(t) evaluate(state,t,false,nil,nil,false) end
local function activate(t) start(state,"test",7,t,nil,info.getSnapshotAt()) end
activate(1); assert(state.active and auto)
distance=55; frame(1.01); assert(state.active and auto, "55 studs must stay active")
distance=55.01; frame(1.02); assert(not state.active and not auto and state.reason=="opponent_distance")
distance=54; activate(1.10); assert(not auto, "cooldown bypassed")
distance=56; activate(1.30); assert(not auto, "opponent still too far")
distance=54; ball=56; activate(1.31); assert(not auto, "ball still too far")
ball=54; activate(1.32); assert(auto, "did not rearm after cooldown and approach")
ball=55.01; frame(1.33); assert(not auto and state.reason=="ball_distance", "ball did not stop on frame")
ball=10; speed=16; distance=20; activate(1.54); assert(auto)
distance=20.01; frame(1.55); assert(not auto and state.reason=="opponent_distance")
distance=10; activate(1.76); assert(auto)
snapshot.syncSpeed=nil; snapshot.speed=0; speed=0; frame(1.77)
assert(not auto and state.reason=="distance_unavailable", "missing speed must stop spam")
speed=600; distance=10; ball=10; snapshot.speed=600; activate(2); assert(auto)
snapshot.locked=true; frame(2.01)
assert(not auto and state.reason=="ball_locked", "locked ball must stop auto spam")
activate(2.3); assert(not auto, "locked ball must block activation")
snapshot.locked=false; activate(2.31); assert(auto, "unlocked ball must allow activation")
print("Auto Spam distance gate: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1))

