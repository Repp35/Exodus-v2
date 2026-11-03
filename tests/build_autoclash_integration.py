"""Build executable integration scenarios for AutoClash and its spam handoff."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])
def quote(path):
    return '[========[' + (root / path).read_text(encoding='utf-8') + ']========]'

script = r'''
local now = 1
local ping = 0
local heartbeatCallback, renderCallback, dashCallback
local autoSpam, manualSpam, hubActive, clashEnabled = false, false, true, true
local presses, ticks = 0, 0
local snapshotFailure, validationFailure = false, false
local errors = {}
local myId, enemyId, thirdId = 42, 7, 8
local nextSeq = 1
local signal = function(setter)
    return {Connect=function(_, fn)
        setter(fn)
        return {Disconnect=function() setter(nil) end}
    end}
end
local mt = {}
mt.__index = function(v, key)
    if key == 'Magnitude' then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    if key == 'Dot' then return function(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end end
    error(tostring(key) .. ' is not a valid member of Vector3')
end
mt.__add = function(a,b) return setmetatable({X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z},mt) end
mt.__sub = function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},mt) end
mt.__mul = function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},mt) end
mt.__div = function(a,b) return a*(1/b) end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0}, mt) end
typeof = function(x) if getmetatable(x) == mt then return 'Vector3' end return type(x) end
local parent = {}
local ownRoot = {Parent=parent, Position=vec(0), AssemblyLinearVelocity=vec(0)}
local opponentRoot = {Parent=parent, Position=vec(40), AssemblyLinearVelocity=vec(0)}
local function char(root)
    return {Parent=parent, AncestryChanged=signal(function() end),
        FindFirstChild=function(_,name) if name=='HumanoidRootPart' then return root end end,
        WaitForChild=function(_,name) if name=='HumanoidRootPart' then return root end end}
end
local ownCharacter, opponentCharacter = char(ownRoot), char(opponentRoot)
local player = {UserId=myId, Parent=parent, Character=ownCharacter}
local opponent = {UserId=enemyId, Parent=parent, Character=opponentCharacter}
local third = {UserId=thirdId, Parent=parent, Character=char({Parent=parent,Position=vec(90),AssemblyLinearVelocity=vec(0)})}
local players = {GetPlayerByUserId=function(_,id) if id==enemyId then return opponent elseif id==thirdId then return third end end}
local ball = {Parent=parent, AssemblyLinearVelocity=vec(100)}
local snapshot = {ball=ball, position=vec(-20), velocity=vec(100), speed=100, syncSpeed=100, targetId=myId, targeted=true, teleported=false}
local seq
local info = {
    getSnapshotAt=function() if snapshotFailure then error('raw snapshot failure') end return snapshot end,
    getSnapshot=function() return snapshot end,
    isSnapshotValid=function(s) if validationFailure then error('raw validation failure') end return type(s)=='table' and s.ball and s.ball.Parent ~= nil end,
    getTargetId=function() return snapshot.targetId end,
    getLocalPing=function() return ping end,
    getSyncSequence=function() return seq end,
    getSyncData=function() return nil end,
}
local utils = {
    now=function() return now end, apiVersion=function() return 1 end,
    getConfig=function() return {AutoClash=clashEnabled,SpamRateMode='CPS',CPS=24} end,
    getConfigValue=function(key) local c={AutoClash=clashEnabled,SpamRateMode='CPS',CPS=24}; return c[key] end,
    getRunService=function() return {Heartbeat=signal(function(fn) heartbeatCallback=fn end),RenderStepped=signal(function(fn) renderCallback=fn end)} end,
    getPlayers=function() return players end, getLocalPlayer=function() return player end,
    isActive=function() return hubActive end, isManualSpamActive=function() return manualSpam end,
    isAutoSpamActive=function() return autoSpam end, isSpamActive=function() return manualSpam or autoSpam end,
    setAutoSpamActive=function(v) autoSpam=v end,
    trackCharacter=function() end, untrackCharacter=function() end,
    trackGlobal=function() end, untrackGlobal=function() end, recordTransition=function() end,
    recordError=function(source,message) errors[#errors+1]={source=source,message=message} end,
}
local parry = {
    getRadius=function(_,factor,speed) return {fullRadius=8.5+speed*0.2*(factor or .5),noWindowParryRadius=8.5} end,
    getStatus=function() return {ping={oneWay=ping}} end,
}
local dash = {setHandler=function(fn) dashCallback=fn end, tick=function() ticks+=1 end}
local remote = {fireParry=function() presses+=1; return true end}
local clash = assert(loadstring(CLASH_SOURCE))()
local spam = assert(loadstring(SPAM_SOURCE))()
assert(spam.setup({Utils=utils,Remote=remote}))
assert(clash.setup({AutoParry=parry,GameInfo=info,Dash=dash,Utils=utils}))
assert(clash.bindCharacter(ownCharacter))
local function setTarget(id)
    snapshot.targetId=id; snapshot.targeted=id==myId
end
local function event(id, dt, serverTime, sequence)
    now += dt or 0
    setTarget(id)
    seq = sequence or nextSeq
    nextSeq = (seq+1)%65536
    snapshot.syncSequence=seq
    clash.onBallSync({Sequence=seq,ServerTime=serverTime,TargetPlayerID=id,Speed=snapshot.syncSpeed})
end
local function step(dt)
    now += dt or 0
    assert(heartbeatCallback, 'heartbeat not bound')
    heartbeatCallback(dt or 0)
end
local function expect(value, message)
    if not value then error(message .. ': ' .. tostring(clash.getStatus().lastGate), 2) end
end
local function fresh()
    clash.detachCharacter(); autoSpam=false; manualSpam=false; hubActive=true; clashEnabled=true; ping=0
    seq=nil; snapshot.syncSequence=nil; snapshot.teleported=false; snapshotFailure=false; validationFailure=false
    snapshot.speed=100; snapshot.syncSpeed=100; snapshot.velocity=vec(100); snapshot.position=vec(-20)
    ball.Parent=parent; opponentRoot.Position=vec(40); opponentRoot.AssemblyLinearVelocity=vec(0)
    nextSeq=1; now=1
    assert(clash.bindCharacter(ownCharacter))
end
-- A full return enters clash; spam receives control through the shared Utils state.
fresh(); event(myId,0,10); step(.01); event(enemyId,.01,10.01); event(myId,.1,10.11)
expect(clash.isActive() and autoSpam, 'valid return must start clash on the event when its snapshot is ready')
local before=presses
for _=1,60 do now+=1/60; renderCallback(1/60) end
expect(presses-before==24, 'active clash must schedule the configured 24 CPS')
-- Redirection away from both participants stops it; no automatic reactivation.
event(enemyId,.01,11); event(thirdId,.01,11.01)
expect(not clash.isActive() and not autoSpam, 'third target must stop clash')
event(myId,.01,11.02); step(.001)
expect(not clash.isActive(), 'third-party redirection must not be a matching return')
-- A direct redirect ends the old clash; a quick return can start a new one.
fresh(); event(myId,0,12); step(.01); event(enemyId,.01,12.01); event(myId,.05,12.06)
expect(clash.isActive(), 'setup for direct redirection')
event(thirdId,.01,12.07)
expect(not clash.isActive() and not autoSpam, 'direct redirection must stop the previous clash')
event(myId,.05,12.12)
expect(clash.isActive() and autoSpam, 'quick return from new opponent must start a new clash')
-- Unrelated targets may not complete the previous outbound pass.
fresh(); event(myId,0,20); step(.01); event(enemyId,.01,20.01); event(thirdId,.01,20.02); event(myId,.01,20.03); step(.001)
expect(not clash.isActive(), 'mismatched partner activated clash')
-- A return recognized while the ball is far stays pending until it enters range.
fresh(); snapshot.position=vec(-100); event(myId,0,30); step(.01); event(enemyId,.01,30.01); event(myId,.05,30.06); step(.001)
expect(not clash.isActive() and clash.getStatus().returnPending, 'far return should remain pending')
snapshot.position=vec(-20); step(.03)
expect(clash.isActive(), 'pending return should activate inside radius')
-- Event sequence handles duplicates, stale packets and wraparound.
fresh(); event(myId,0,40,65534); step(.01); event(enemyId,.01,40.01,65535)
clash.onBallSync({Sequence=65534,TargetPlayerID=myId,Speed=100})
expect(clash.getStatus().lastTarget==enemyId, 'stale packet overwrote target')
event(myId,.05,40.06,0); step(.001)
expect(clash.isActive(), 'sequence wraparound must preserve return')
clash.onBallSync({Sequence=65535,Teleported=true})
expect(clash.isActive(), 'stale teleport must be ignored')
clash.onBallSync({Sequence=1,TeleportSequence=1,Teleported=true})
expect(not clash.isActive() and not autoSpam, 'fresh teleport must stop clash')
-- Server event time avoids treating delivery jitter as a slow return.
fresh(); ping=.2; event(myId,0,50); step(.01); event(enemyId,.01,50.01)
for _=1,27 do step(1/60) end
event(myId,0,50.11); step(.001)
expect(clash.isActive(), 'server-time return lost to packet delay')
fresh(); event(myId,0,60); step(.01); event(enemyId,.01,60.01); event(myId,.02,60.60); step(.001)
expect(not clash.isActive(), 'late server-time return was accepted')
-- Snapshot must not override a newer event; contradictory target fields cannot activate.
fresh(); event(myId,0,70,10); step(.01); event(enemyId,.01,70.01,11)
snapshot.targetId=myId; snapshot.targeted=true; snapshot.syncSequence=10; step(.01)
expect(clash.getStatus().lastTarget==enemyId and not clash.isActive(), 'stale snapshot overwrote event')
snapshot.syncSequence=12; snapshot.targetId=enemyId; snapshot.targeted=true
clash.onBallSync({Sequence=12,ServerTime=70.04,TargetPlayerID=myId,Speed=100}); step(.001)
expect(not clash.isActive(), 'contradictory snapshot targeted=true overrode targetId')
-- Invalid explicit target cannot fall back to the previous target.
fresh(); event(myId,0,80); step(.01); event(enemyId,.01,80.01); event(myId,.05,80.06); step(.001)
expect(clash.isActive(), 'setup for invalid-target scenario')
seq=nextSeq; nextSeq+=1; snapshot.syncSequence=seq
clash.onBallSync({Sequence=seq,TargetPlayerID=-1,HighlightTargetPlayerID=0})
expect(not clash.isActive() and not autoSpam, 'explicit no-target must stop clash')
-- Detect a dash outside the current detection radius when its projected approach enters it.
fresh(); event(myId,0,90); step(.01); event(enemyId,.01,90.01)
local initialWindow=clash.getStatus().returnWindow
opponentRoot.Position=vec(40); opponentRoot.AssemblyLinearVelocity=vec(-120)
dashCallback({player=opponent,userId=enemyId,position=opponentRoot.Position,velocity=vec(-120),detectedAt=now})
local pending=clash.getDashData(); expect(pending and not pending.dangerous, 'approaching dash should be tracked before reaching radius')
opponentRoot.Position=vec(30); step(.02)
pending=clash.getDashData(); expect(pending and pending.dangerous, 'approaching dash was not confirmed')
expect(clash.getStatus().returnWindow>initialWindow, 'dash must extend the outbound return window')
-- The 180 ms setting is the low-speed return window, not a fixed cap at every speed.
fresh(); snapshot.speed=60; snapshot.syncSpeed=60; snapshot.velocity=vec(60); snapshot.position=vec(-10)
event(myId,0,110); step(.01); event(enemyId,.01,110.01)
expect(math.abs(clash.getStatus().returnWindow-.18)<1e-8, 'low-speed return window changed')
event(myId,.02,110.189); step(.001); expect(clash.isActive(), 'return within 180 ms was rejected')
fresh(); snapshot.speed=60; snapshot.syncSpeed=60; snapshot.velocity=vec(60); snapshot.position=vec(-10)
event(myId,0,120); step(.01); event(enemyId,.01,120.01); event(myId,.02,120.191); step(.001)
expect(not clash.isActive(), 'return outside 180 ms was accepted')
-- Snapshot sequences recover missed events without overwriting newer events.
fresh(); snapshot.syncSequence=10; setTarget(myId); step(.01)
snapshot.syncSequence=11; setTarget(enemyId); step(.02)
snapshot.syncSequence=12; setTarget(myId); step(.04)
expect(clash.isActive(), 'sequenced snapshots failed to recover a return')
snapshot.syncSequence=13; setTarget(-1); step(.01)
expect(not clash.isActive() and not autoSpam, 'snapshot no-target must stop clash')
-- The opponent moving away cannot cancel a clash while the ball is targeting us.
fresh(); event(myId,0,130); step(.01); event(enemyId,.01,130.01); event(myId,.05,130.06); step(.001)
expect(clash.isActive(), 'setup for opponent escape')
opponentRoot.Position=vec(20); opponentRoot.AssemblyLinearVelocity=vec(120)
dashCallback({player=opponent,userId=enemyId,position=opponentRoot.Position,velocity=vec(120),detectedAt=now})
for _=1,5 do opponentRoot.Position += vec(3); step(.025) end
expect(clash.isActive(), 'opponent dash away stopped spam while targeted')
-- A brief visual hit-stop while targeted must not end the clash.
snapshot.speed=0; snapshot.velocity=vec(0); step(.02)
expect(clash.isActive() and autoSpam, 'stopped ball ended clash while still targeted')
snapshot.speed=100; snapshot.velocity=vec(100)
-- Invalid or missing ball must turn automatic spam off.
ball.Parent=nil; step(.01); expect(not clash.isActive() and not autoSpam, 'missing ball did not stop spam'); ball.Parent=parent
-- An internal API error is reported with its source, stops spam, and can recover.
fresh(); event(myId,0,140); step(.01); event(enemyId,.01,140.01); event(myId,.05,140.06)
expect(clash.isActive(), 'setup for snapshot failure')
snapshotFailure=true; step(.01)
expect(not clash.isActive() and not autoSpam, 'snapshot failure did not stop automatic spam')
expect(errors[#errors] and errors[#errors].source=='GameInfo.getSnapshot' and string.find(errors[#errors].message,'raw snapshot failure',1,true), 'snapshot failure was not reported')
local errorCount=#errors; step(.01); step(.01)
expect(#errors==errorCount, 'same API error should not flood the log each frame')
snapshotFailure=false; event(myId,.01,140.08); event(enemyId,.01,140.09); event(myId,.05,140.14)
expect(clash.isActive(), 'clash failed to recover after snapshot error')
validationFailure=true; step(.01)
expect(not clash.isActive() and errors[#errors] and errors[#errors].source=='GameInfo.isSnapshotValid' and string.find(errors[#errors].message,'raw validation failure',1,true), 'validation failure was not reported')
validationFailure=false
-- Disabling or manually taking over must clear automatic spam without rearming itself.
fresh(); event(myId,0,100); step(.01); event(enemyId,.01,100.01); event(myId,.05,100.06); step(.001)
expect(clash.isActive(), 'setup for manual takeover')
manualSpam=true; step(.01); expect(not clash.isActive() and not autoSpam, 'manual takeover must stop auto spam')
manualSpam=false; step(.2); expect(not clash.isActive(), 'manual takeover must not generate a return')
clashEnabled=false; step(.01); expect(not clash.isActive(), 'disabled clash stayed active')
clash.teardown(); spam.teardown()
print('AutoClash integration scenarios: PASS')
'''
out.write_text(script.replace('CLASH_SOURCE', quote('exodus hub/modules/logic/autoclash.luau')).replace('SPAM_SOURCE', quote('exodus hub/modules/logic/spam.luau')), encoding='utf-8')
