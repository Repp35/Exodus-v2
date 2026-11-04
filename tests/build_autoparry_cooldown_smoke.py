"""Generate a Luau regression test for server-confirmed parry recovery."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
auto = (root / "exodus hub/modules/logic/autoparry.luau").read_text()
auto = auto.replace("return os.clock()", "return currentTime", 1)
auto = auto.replace(
    "return AutoParry\n",
    "return {state=R, heartbeat=onHeartbeat, event=AutoParry.onBallSync, "
    "setDeps=function(a,b,c) Remote=a; GameInfo=b; Utils=c end}\n",
)
gameinfo = (root / "exodus hub/modules/logic/gameinfo.luau").read_text()
events = gameinfo[gameinfo.index("function GameInfo.getDeflectServerEvents()") : gameinfo.index("function GameInfo.getDashAbility()")]

pre = '''local currentTime = 1
math.clamp = math.clamp or function(v, low, high) return math.max(low, math.min(high, v)) end
local mt = {}
mt.__index = function(t, k)
 if k == "Magnitude" then return math.abs(t.x) end
 if k == "Dot" then return function(a, b) return a.x * b.x end end
end
mt.__sub = function(a, b) return setmetatable({x=a.x-b.x}, mt) end
mt.__add = function(a, b) return setmetatable({x=a.x+b.x}, mt) end
mt.__mul = function(a, b) return setmetatable({x=a.x*b}, mt) end
mt.__div = function(a, b) return a*(1/b) end
local function vec(x) return setmetatable({x=x}, mt) end
local Vector3 = {zero=vec(0)}
local function typeof(v) if getmetatable(v)==mt then return "Vector3" elseif type(v)=="table" and v.instance then return "Instance" end return type(v) end
local function signal()
 local handlers = {}
 return {Connect=function(_, fn)
  local connection = {Connected=true}
  function connection:Disconnect() self.Connected=false end
  handlers[#handlers+1] = {fn, connection}; return connection
 end, emit=function(_, ...)
  for _, item in ipairs(handlers) do if item[2].Connected then item[1](...) end end
 end}
end
local function module()
'''
post = '''
end
local SET = 5.93848805167512e76
local STOP = 6.60750295352893e76
local function newScenario(heldAbility)
 currentTime = 1
 local ap = module(); local R=ap.state
 local cd, parried = signal(), signal()
 local cooldownRemote = {OnClientEvent=cd, IsA=function(_, class) return class=="RemoteEvent" end}
 local parriedRemote = {OnClientEvent=parried, IsA=function(_, class) return class=="RemoteEvent" end}
 local remoteFolder = {FindFirstChild=function(_, name)
  if name=="RE_" .. tostring(5.520474058077904e76) then return cooldownRemote end
  if name=="RE_" .. tostring(9.611859444202098e76) then return parriedRemote end
 end}
 local ts = {FindFirstChild=function(_, name) if name=="GeneratedNetworkRemotes" then return remoteFolder end end}
 local storage = {FindFirstChild=function(_, name) if name=="TS" then return ts end end}
 local Utils = {getReplicatedStorage=function() return storage end}
 local GameInfo = {}
 local function locateDeflectAbility() return heldAbility end
 GAMEINFO_EVENTS
 local ball = {instance=true, Parent={}, Position=vec(-10), AssemblyLinearVelocity=vec(100), IsA=function() return true end}
 local root = {Parent={}, Position=vec(0)}; local char={Parent={}}
 local player = {UserId=42}; local sync={Speed=100, TargetPlayerID=42, Teleported=false}
 local target=42; local spam=false; local fires=0; local ping=0.05
 GameInfo.getBallSpeedLimits=function() return 16,600 end
 GameInfo.getDeflectRange=function() return 8.5 end
 GameInfo.getLocalPing=function() return ping end
 GameInfo.getBallPosition=function(b) return b.Position end
 GameInfo.getBallVelocity=function(b) return b.AssemblyLinearVelocity end
 GameInfo.getRootPosition=function(r) return r.Position end
 GameInfo.getSyncData=function() return sync end
 GameInfo.getBall=function() return ball end
 GameInfo.getTargetId=function() return target end
 GameInfo.getSnapshot=function() return {ball=ball,targetId=target,targeted=target==42,position=ball.Position} end
 GameInfo.isSnapshotValid=function() return true end
 local utils={getConfig=function() return {AutoParry=true} end,isActive=function() return true end,isSpamActive=function() return spam end}
 ap.setDeps({fireParry=function() fires+=1; return true end}, GameInfo, utils)
 R.player=player; R.root=root; R.alive=true; R.bound=true; R.generation=1
 local function frame(at, position, velocity)
  currentTime=at; if position then ball.Position=vec(position) end
  if velocity then ball.AssemblyLinearVelocity=vec(velocity) end
  ap.heartbeat(char,root,0.01,1)
 end
 local function changeTarget(id) target=id; sync.TargetPlayerID=id; ap.event(sync) end
 return {ap=ap,R=R,info=GameInfo,cd=cd,parried=parried,frame=frame,target=changeTarget,ball=ball,sync=sync,
  count=function() return fires end,spam=function(v) spam=v end}
end

-- The game also sets a predicted *local* cooldown; no server signal means no retry.
do
 local s=newScenario(); s.frame(1.01); assert(s.count()==1)
 s.frame(4); assert(s.count()==1, "local or absent cooldown must never be treated as a miss")
 s.cd:emit(2,SET,1.45); s.cd:emit(1,999,1.45); s.frame(5)
 assert(s.count()==1, "unrelated ability/events must not arm a retry")
end
-- Checking the held server value can re-enter; the target lock is already set.
do
 local s=newScenario(); s.frame(1.01,-100); local reenter=true
 s.info.getHeldDeflectServerCooldown=function()
  if reenter then reenter=false; s.frame(1.03,-10) end
 end
 s.frame(1.02,-10); assert(s.count()==1, "held-state reentry must not double click")
end
do
 local s=newScenario(); s.frame(1.01,-100)
 s.info.getHeldDeflectServerCooldown=function() s.spam(true) end
 s.frame(1.02,-10); assert(s.count()==0, "spam taking over during the held check must prevent firing")
end
-- A server cooldown must stop; observing its start alone is not a miss.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.frame(3)
 assert(s.count()==1, "running server cooldown must remain locked")
	 s.cd:emit(1,STOP); s.frame(3.01); assert(s.count()==1, "stop must settle before retry")
	 s.frame(3.06); assert(s.count()==2, "expired miss must retry")
	 s.frame(3.07); s.frame(4); assert(s.count()==2, "retry must lock again")
	 s.cd:emit(1,SET,1.45); s.frame(5.5); s.cd:emit(1,STOP); s.frame(5.56)
 assert(s.count()==3, "a second confirmed miss can also recover")
end
-- SetCooldown(0) and the separate parry acknowledgement are not misses.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.cd:emit(1,SET,0)
 s.cd:emit(1,STOP); s.frame(4); assert(s.count()==1, "server reset must not retry")
 s.parried:emit(); s.frame(5); assert(s.count()==1, "confirmed parry must stay locked")
end
-- The server can renew a queued press right after sending cooldown stopped.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.frame(2.5); s.cd:emit(1,STOP); s.frame(2.51); assert(s.count()==1)
 s.cd:emit(1,SET,0.38); s.frame(2.6); assert(s.count()==1, "renewal must cancel the pending retry")
 s.frame(4); s.cd:emit(1,STOP); s.frame(4.06); assert(s.count()==2, "retry after the renewed cooldown stops")
end
-- Clash cooldown may finish while the original deflection window is still open.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,0.38)
 s.frame(1.39); s.cd:emit(1,STOP); s.frame(1.4)
 assert(s.count()==1, "early cooldown end must not interrupt an active window")
 s.parried:emit(); s.frame(3); assert(s.count()==1, "late success must cancel retry")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,0.38)
 s.frame(1.39); s.cd:emit(1,STOP); s.frame(1.4); assert(s.count()==1)
 s.frame(2.2); assert(s.count()==2, "miss retries after both cooldown and window")
end
-- A cooldown that began before the AP press is still known to the listener.
do
 local s=newScenario(); s.frame(1.01,-100); s.cd:emit(1,SET,1.45)
 s.frame(2.4,-10); assert(s.count()==1)
 s.frame(2.41); s.cd:emit(1,STOP); s.frame(2.42)
 assert(s.count()==1, "wait for the in-flight click to settle")
 s.frame(2.6); assert(s.count()==2, "retry after an existing cooldown stops")
end
do
 local s=newScenario({HeldServerCooldown=1.45, HeldServerCooldownAt=0.5})
 s.frame(1.01); assert(s.count()==1 and s.R.serverCooldownActive, "restore the game's held server cooldown")
 s.frame(2); s.cd:emit(1,STOP); s.frame(2.06)
 assert(s.count()==2, "a held server cooldown can recover after stopping")
end
-- Recovery only runs for the same target and the usual approach/radius gates.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.frame(2.5,-100); s.cd:emit(1,STOP); s.frame(2.56,-100)
 assert(s.count()==1, "outside radius must not retry")
 s.frame(2.57,-10,-100); assert(s.count()==1, "ball moving away must not retry")
 s.frame(2.58,-10,100); assert(s.count()==2, "retry when all original conditions match")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.target(7)
 s.frame(2.5); s.cd:emit(1,STOP); s.frame(2.51)
 assert(s.count()==1, "a different target must cancel pending recovery")
 s.target(42); s.frame(2.52); assert(s.count()==2, "returning target is a new cycle")
end
-- Spam and teleports invalidate pending attempts instead of reviving old ones.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.spam(true); s.frame(1.2); s.frame(2.5); s.cd:emit(1,STOP)
 s.spam(false); s.frame(2.51); assert(s.count()==1, "spam must cancel stale recovery")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.sync.Teleported=true; s.ap.event(s.sync); s.frame(2.5); s.cd:emit(1,STOP)
 assert(s.count()==1, "teleport must cancel recovery")
end
print("AutoParry authoritative cooldown recovery: PASS")
'''
output.write_text(pre + auto + post.replace("GAMEINFO_EVENTS", events))
