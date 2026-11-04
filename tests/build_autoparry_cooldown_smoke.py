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
events = gameinfo[gameinfo.index("function GameInfo.getDeflectServerEvents()") : gameinfo.index("function GameInfo.getDashAbility()")].replace("os.clock()", "currentTime")

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
 local sync
 local function getDecodedSyncData() return sync end
 local deflectState = {known=false,active=false,readyRevision=0,lastEventAt=-math.huge}
 local deflectConnection; local nextDeflectSignalCheck=0; local nextHeldCooldownCheck=0
 local function locateDeflectAbility() return heldAbility end
 GAMEINFO_EVENTS
 local ball = {instance=true, Parent={}, Position=vec(-10), AssemblyLinearVelocity=vec(100), IsA=function() return true end}
 local root = {Parent={}, Position=vec(0)}; local char={Parent={}}
 local player = {UserId=42}; sync={Speed=100, TargetPlayerID=42, Teleported=false}
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
-- Reentry while the parry request reads shared state must keep the lock.
do
 local s=newScenario(); s.frame(1.01,-100); local original=s.info.getDeflectCooldownState; local calls=0
 s.info.getDeflectCooldownState=function()
  calls+=1; if calls==2 then s.frame(1.03,-10) end; return original()
 end
 s.frame(1.02,-10); assert(s.count()==1, "shared-state reentry must not double click")
end
-- A local click cannot rearm from an early server cooldown reset.
do
 local s=newScenario(); s.frame(1.01); s.info.noteDeflectPress()
 local deadline=s.info.getDeflectCooldownState().normalizingUntil
 s.cd:emit(1,SET,1.45); s.cd:emit(1,SET,0)
 s.frame(deadline-0.001); assert(s.count()==1, "early reset must not double click")
 s.frame(deadline+0.001); assert(s.count()==1, "unconfirmed cooldown must not rearm the same target")
end
-- Pending normalization itself must not block an otherwise valid first parry.
do
 local s=newScenario(); s.info.noteDeflectPress(); s.frame(1.01)
 assert(s.count()==1, "pending normalization must not block the normal AP")
end
-- Grace extends the variable server window and the 50 ms margin.
do
 local s=newScenario(); s.frame(1.01); s.info.noteDeflectPress()
 local firstDeadline=s.info.getDeflectCooldownState().normalizingUntil
 s.cd:emit(1,SET,1.45); s.cd:emit(1,SET,0)
 s.frame(1.1); s.info.noteDeflectPress()
 s.frame(firstDeadline+0.01); assert(s.count()==1, "old cooldown reset must not rearm a newer click")
end
do
 local normal=newScenario(); normal.frame(1.01); normal.info.noteDeflectPress()
 local withoutGrace=normal.info.getDeflectCooldownState().normalizingUntil
 local grace=newScenario(); grace.sync.Grace=true; grace.frame(1.01); grace.info.noteDeflectPress()
 local withGrace=grace.info.getDeflectCooldownState().normalizingUntil
 assert(math.abs(withGrace-withoutGrace-0.125)<0.001, "grace must add ping plus 75 ms")
 grace.cd:emit(1,SET,1.45); grace.frame(withGrace-0.001)
 assert(not grace.info.getDeflectCooldownState().active, "cooldown must remain unconfirmed until normalization")
 grace.frame(withGrace+0.001); assert(grace.info.getDeflectCooldownState().active, "persistent cooldown must be confirmed")
 grace.cd:emit(1,STOP); grace.frame(withGrace+0.01); assert(grace.count()==2, "confirmed cooldown clearing must rearm")
end
-- The game's window shrinks with speed and honors its prediction deadline.
do
 local slow=newScenario(); slow.sync.Speed=16; slow.frame(1.01); slow.info.noteDeflectPress()
 local slowDeadline=slow.info.getDeflectCooldownState().normalizingUntil
 local fast=newScenario(); fast.sync.Speed=600; fast.frame(1.01); fast.info.noteDeflectPress()
 local fastDeadline=fast.info.getDeflectCooldownState().normalizingUntil
 assert(fastDeadline<slowDeadline, "normalization must follow ball speed")
 local predicted=newScenario({PredictedResetUntil=3}); predicted.frame(1.01); predicted.info.noteDeflectPress()
 assert(predicted.info.getDeflectCooldownState().normalizingUntil>=3.05, "prediction deadline and 50 ms margin")
end
-- A server cooldown must stop; observing its start alone is not a miss.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.frame(3)
 assert(math.abs(s.info.getDeflectCooldownState().endsAt-2.46)<0.001, "server duration must be retained")
 assert(s.count()==1, "running server cooldown must remain locked")
	 s.cd:emit(1,STOP); s.frame(3.01); assert(s.count()==2, "expired miss must retry")
	 assert(s.info.getDeflectCooldownState().endsAt==nil, "stopped cooldown must clear end estimate")
	 s.frame(3.07); s.frame(4); assert(s.count()==2, "retry must lock again")
	 s.cd:emit(1,SET,1.45); s.frame(5.5); s.cd:emit(1,STOP); s.frame(5.56)
 assert(s.count()==3, "a second confirmed miss can also recover")
end
-- A cancelled cooldown is ready, even when the last parry was confirmed.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.cd:emit(1,SET,0)
 s.frame(1.02); assert(s.count()==2, "cancelled cooldown must immediately allow retry")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.parried:emit(); s.cd:emit(1,SET,0)
	 s.frame(2); assert(s.count()==2, "confirmed parry must not prevent recovery when cooldown is clear")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45); s.cd:emit(1,SET,0); s.parried:emit()
 s.frame(2); assert(s.count()==2, "parry confirmation after reset must not restore the lock")
end
-- A new cooldown before the next frame prevents a retry.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.cd:emit(1,STOP); s.cd:emit(1,SET,0.38); s.frame(1.02)
 assert(s.count()==1, "renewal must cancel the pending retry")
 s.cd:emit(1,STOP); s.frame(1.03); assert(s.count()==2, "retry after the renewed cooldown stops")
end
-- A cooldown that began before the AP press is still known to the listener.
do
 local s=newScenario(); s.frame(1.01,-100); s.cd:emit(1,SET,1.45)
 s.frame(2.4,-10); assert(s.count()==0, "AP must wait when the server cooldown is already active")
 s.frame(2.41); s.cd:emit(1,STOP); s.frame(2.42)
 assert(s.count()==1, "first AP click after existing cooldown stops")
end
do
 local s=newScenario({HeldServerCooldown=1.45, HeldServerCooldownAt=0.5})
 s.frame(1.01); assert(s.count()==0 and s.info.getDeflectCooldownState().active, "restore the game's held server cooldown")
 s.frame(2); s.cd:emit(1,STOP); s.frame(2.06)
 assert(s.count()==1, "a held server cooldown can recover after stopping")
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
-- A cooldown caused by spam remains visible even without an AP attempt.
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.spam(true); s.frame(1.2); s.frame(2.5); s.cd:emit(1,STOP)
 s.spam(false); s.frame(2.51); assert(s.count()==2, "AP must rearm after cooldown expires during spam")
end
do
 local s=newScenario(); s.spam(true); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.spam(false); s.frame(1.02); assert(s.count()==0, "spam cooldown must block the AP even without an earlier AP click")
 s.cd:emit(1,STOP); s.frame(1.03); assert(s.count()==1, "AP must fire when spam cooldown ends")
end
do
 local s=newScenario(); s.frame(1.01); s.cd:emit(1,SET,1.45)
 s.sync.Teleported=true; s.ap.event(s.sync); s.frame(2.5); s.cd:emit(1,STOP)
 assert(s.count()==1, "teleport must cancel recovery")
end
print("AutoParry authoritative cooldown recovery: PASS")
'''
output.write_text(pre + auto + post.replace("GAMEINFO_EVENTS", events))
