"""Exercise the live timeout using locally observed paired target changes."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:3])
source = (root / 'exodus hub/modules/logic/autospam.luau').read_text()
source = source.replace('return AutoSpam\n', '''return AutoSpam, shouldDeactivate, inspectTarget, start, applyDeactivation,
    function(s,u,g,p) current=s; utils=u; gameInfo=g; localPlayer=p end
''')
script = r'''
local V={}
V.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end return V[k] end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x) return setmetatable({X=x,Y=0,Z=0},V) end
function typeof(v) if getmetatable(v)==V then return "Vector3" end return type(v) end
local clock=10
local auto=false
local manual=true
local root={Parent={},Position=vec(0)}
local s={root=root,active=false,target=42,exchangeReadyAt=10,exchangePartner=7,connections={}}
local snap={position=vec(5),velocity=vec(600),targetId=42,syncSpeed=600,syncAt=10}
local u={now=function() return clock end,isActive=function() return true end,
 getConfigValue=function(k) return k=="AutoSpam" end,isManualSpamActive=function() return manual end,
 setAutoSpamActive=function(v) auto=v end,setManualSpamActive=function(v) manual=v end,recordTransition=function() end}
local g={getBallFrozen=function() return false end,getBallSpeedLimits=function() return 16,600 end,
 getDeflectRangeParameters=function() return 8.5,7.5 end,getPlayerDeflectRange=function() return 8.5 end,
 getPlayerMotion=function() return vec(7) end,getPlayerDistance=function() return 7 end,
 getDeflectGeometry=function() return {fullRadius=8.5,deflectWindow=.32} end,
 isSnapshotValid=function(v) return v.valid~=false end,getSnapshotAt=function() return snap end}
local mod,reason,inspect,start,apply,inject=assert(loadstring(SOURCE))()
inject(s,u,g,{UserId=42})
local function check(t, target)
 clock=t; snap.syncAt=t; snap.targetId=target or s.target
 return reason(s,snap,t,nil,snap.targetId~=s.target)
end
start(s,"return_target",7,clock,nil,snap)
assert(auto and s.returnWatchAt==10)
assert(check(10.09)==nil, "the first 100ms must not stop spam")
assert(check(10.101)=="return_timeout", "after the grace period an overdue 85ms leg must stop")
assert(apply(s,snap,clock,nil,false) and not auto and manual, "timeout must stop only auto spam")
-- A real paired switch rearms the clock, repeated snapshots do not.
s.active=true; s.partner=7; s.target=42; s.activatedAt=20; s.returnWatchAt=20; clock=20.1; snap.syncAt=clock; snap.targetId=7
inspect(s,7,clock,snap,nil); assert(s.returnWatchAt==clock)
assert(check(20.18,7)==nil); inspect(s,7,20.18,snap,nil); assert(s.returnWatchAt==20.1)
assert(check(20.186,7)=="return_timeout")
-- A late target packet must not erase the overdue interval before checking it.
assert(check(20.187,42)=="return_timeout")
-- At low speed allow a longer flight.
s.returnWatchAt=30; s.target=42; snap.syncSpeed=16
assert(check(30.22)==nil); assert(check(30.227)=="return_timeout")
-- Intermediate speed follows the game's window curve, not a fixed 85ms.
s.returnWatchAt=35; snap.syncSpeed=308
assert(check(35.135)==nil); assert(check(35.141)=="return_timeout")
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
assert(check(42.2)==nil and s.returnWatchAt==nil)
snap.locked=false; s.returnWatchAt=43; snap.syncAt=43
assert(reason(s,snap,43.2,nil,false)==nil and s.returnWatchAt==nil)
-- Non-paired targets and teleports do not arm a return watch.
s.target=42; s.returnWatchAt=44; snap.targetId=99; snap.syncAt=44.01
inspect(s,99,44.01,snap,nil); assert(s.returnWatchAt==nil)
s.target=42; s.returnWatchAt=45; mod.onBallSync({Source="packet",Teleported=true})
assert(s.returnWatchAt==nil)
print("Auto Spam return timeout: PASS")
'''
output.write_text(script.replace('SOURCE', '[========[' + source + ']========]', 1))
