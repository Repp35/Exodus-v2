"""Exercise the live timeout using locally observed paired target changes."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:3])
source = (root / 'exodus hub/modules/logic/autospam.luau').read_text()
source = source.replace('typeof(', 'testTypeof(')
source = source.replace('return AutoSpam\n', '''return AutoSpam, shouldDeactivate, inspectTarget, start, applyDeactivation,
    function(s,u,g,p) current=s; utils=u; gameInfo=g; localPlayer=p end
''')
script = r'''
local V={}
V.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end return V[k] end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x) return setmetatable({X=x,Y=0,Z=0},V) end
local function vec3(x,y,z) return setmetatable({X=x,Y=y,Z=z},V) end
function testTypeof(v) if getmetatable(v)==V then return "Vector3" end return typeof(v) end
local clock=10
local auto=false
local manual=true
local root={Parent={},Position=vec(0)}
local s={root=root,active=false,target=42,exchangeReadyAt=10,exchangePartner=7,connections={}}
local snap={position=vec(5),velocity=vec(600),targetId=42,syncSpeed=600,syncAt=10}
local u={now=function() return clock end,isActive=function() return true end,
 getConfigValue=function(k) return k=="AutoSpam" end,isManualSpamActive=function() return manual end,
 setAutoSpamActive=function(v) auto=v end,setManualSpamActive=function(v) manual=v end,recordTransition=function() end}
local distance=7
local g={getBallFrozen=function() return false end,getBallSpeedLimits=function() return 16,600 end,
 getDeflectRangeParameters=function() return 8.5,7.5 end,getPlayerDeflectRange=function() return 8.5 end,
 getPlayerMotion=function() return vec(distance) end,getPlayerDistance=function() return distance end,
 getDeflectGeometry=function() return {fullRadius=8.5,deflectWindow=.32} end,
 isSnapshotValid=function(v) return v.valid~=false end,getSnapshotAt=function() return snap end,
 getDashAbility=function() return nil end,getClashContext=function() return nil end}
local mod,reason,inspect,start,apply,inject=assert(loadstring(SOURCE))()
inject(s,u,g,{UserId=42})
local function check(t, target)
 clock=t; snap.syncAt=t; snap.targetId=target or s.target
 return reason(s,snap,t,nil,snap.targetId~=s.target)
end
start(s,"return_target",7,clock,nil,snap)
assert(auto and s.returnWatchAt==10)
assert(check(10.09)==nil, "the first 100ms must not stop spam")
assert(check(10.101)=="return_timeout", "after the grace period an overdue 30ms leg must stop")
assert(apply(s,snap,clock,nil,false) and not auto and manual, "timeout must stop only auto spam")
-- A real paired switch rearms the clock, repeated snapshots do not.
s.active=true; s.partner=7; s.target=42; s.activatedAt=20; s.returnWatchAt=20; clock=20.1; snap.syncAt=clock; snap.targetId=7
inspect(s,7,clock,snap,nil); assert(s.returnWatchAt==clock)
assert(check(20.125,7)==nil); inspect(s,7,20.18,snap,nil); assert(s.returnWatchAt==20.1)
assert(check(20.131,7)=="return_timeout")
-- A late target packet must not erase the overdue interval before checking it.
assert(check(20.132,42)=="return_timeout")
-- At low speed allow a longer flight.
s.returnWatchAt=30; s.target=42; snap.syncSpeed=16
assert(check(30.079)==nil); assert(check(30.081)=="return_timeout")
-- Intermediate speed follows the game's window curve, not a fixed 85ms.
s.returnWatchAt=35; snap.syncSpeed=308
assert(check(35.048)==nil); assert(check(35.051)=="return_timeout")
-- Alternation at 25 complete cycles per second has two switches per cycle.
snap.syncSpeed=600; s.target=42; s.activatedAt=36; s.returnWatchAt=36
for i=1,20 do
 local t=36+i*.02; local nextTarget=i%2==1 and 7 or 42
 assert(check(t,nextTarget)==nil, "normal 25 CPS clash stopped")
 inspect(s,nextTarget,t,snap,nil)
end
-- Missing, stale, uncertain and locked samples must not manufacture a timeout.
snap.syncSpeed=600; s.returnWatchAt=40; snap.valid=false
assert(check(40.2)==nil and s.returnWatchAt==nil)
snap.valid=true; s.returnWatchAt=41; snap.targetUncertain=true
assert(check(41.2)==nil and s.returnWatchAt==nil)
snap.targetUncertain=false; s.returnWatchAt=42; snap.locked=true
assert(check(42.2)==nil and s.returnWatchAt==nil, "locked flag alone must not stop automatic spam")
snap.locked=false; s.returnWatchAt=43; snap.syncAt=43
assert(reason(s,snap,43.2,nil,false)==nil and s.returnWatchAt==43, "short snapshot gaps must preserve the target-switch clock")
assert(reason(s,snap,43.51,nil,false)==nil and s.returnWatchAt==nil, "a long blackout must clear the clock")
-- A late fresh sample must still detect an overdue return at lower speed.
s.returnWatchAt=43.6; snap.syncAt=43.6; snap.syncSpeed=16; s.target=42
assert(reason(s,snap,43.75,nil,false)==nil and s.returnWatchAt==43.6)
assert(check(43.83,42)=="return_timeout", "a brief gap lost the return timeout")
-- Only fresh evidence can trigger spatial stops.
s.returnWatchAt=nil; s.target=42; s.partner=7; s.active=true; s.activatedAt=44
snap.syncSpeed=600; snap.position=vec(5); snap.targetId=42; snap.syncAt=44
distance=56
assert(reason(s,snap,44.2,nil,false)==nil, "stale data must not trigger distance stop")
assert(check(44.21)=="opponent_distance", "distant opponent must stop auto spam")
distance=30; snap.position=vec(56)
assert(check(44.22)=="ball_distance", "distant ball must stop auto spam")
distance=7; snap.position=vec(56)
assert(check(44.23)==nil, "close clash must not stop on ball distance alone")
distance=20; snap.position=vec3(-10,20,0); snap.velocity=vec3(0,100,0)
assert(check(44.24)==nil, "diversion needs confirmation")
assert(check(44.29)=="ball_diverted", "confirmed diversion must stop")
snap.velocity=vec(600); snap.position=vec(5); distance=7
assert(check(44.30,99)=="distant_target", "new opponent must stop the old clash")
-- A locked packet is not itself a reason to stop automatic spam.
s.active=true; s.partner=7; s.target=42; s.activatedAt=44; auto=true; clock=44.4
snap.valid=false; snap.targetId=-1
mod.onBallSync({Source="packet",Sequence=1,TargetPlayerID=-1,Speed=600,Locked=true})
assert(auto and s.active, "locked packet without target must not stop auto spam")
snap.valid=true; snap.targetId=42; snap.locked=false
g.getBallFrozen=function() return true end
assert(apply(s,snap,clock,nil,false) and not auto and s.reason=="frozen", "freezing ability must still stop auto spam")
g.getBallFrozen=function() return false end
-- A fresh paired packet re-arms after a blackout, even without a target change.
s.active=true; s.partner=7; s.target=42; s.activatedAt=44.4; s.returnWatchAt=nil; auto=true; clock=44.5
mod.onBallSync({Source="packet",Sequence=2,TargetPlayerID=42,Speed=600,Locked=false})
assert(auto and s.returnWatchAt==clock, "fresh same-target packet must rearm the timer")
-- Non-paired targets and teleports do not arm a return watch.
s.target=42; s.active=true; s.partner=7; s.returnWatchAt=44; snap.targetId=99; snap.syncAt=44.01
inspect(s,99,44.01,snap,nil); assert(s.returnWatchAt==nil)
s.target=42; s.active=true; s.partner=7; s.returnWatchAt=45; auto=true; clock=45.01; mod.onBallSync({Source="packet",Teleported=true})
assert(s.returnWatchAt==nil and auto and s.active, "teleport must reset tracking without stopping auto spam")
print("Auto Spam return timeout: PASS")
'''
output.write_text(script.replace('SOURCE', '[========[' + source + ']========]', 1))
