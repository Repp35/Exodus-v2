"""Offline regression harness; requires the system Lua 5.4 shared library.

The shim translates compound assignments in the tested Luau modules and mocks
Roblox APIs. It does not validate engine scheduling or server-side outcomes.
Run from any directory: python path/to/parry_runtime_regression.py
"""
import ctypes, pathlib, re
lib = ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.luaL_loadstring.restype = ctypes.c_int
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
lib.lua_pcallk.restype = ctypes.c_int
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ctypes.c_void_p]
root = pathlib.Path(__file__).resolve().parents[2] / 'modules' / 'logic'
def run(name, script):
    state = lib.luaL_newstate(); lib.luaL_openlibs(state)
    status = lib.luaL_loadstring(state, script.encode())
    if not status: status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status:
        msg = lib.lua_tolstring(state, -1, None)
        raise RuntimeError(name + ': ' + (msg.decode() if msg else 'unknown'))
    lib.lua_close(state)
    print('PASS', name)
remote = (root/'aux/remote.luau').read_text()
run('client click acknowledgement', '''
local module = (function()\n'''+remote+'''\nend)()
local ability = {ClickInstances={},did={}}
function ability:Deflect() table.insert(self.ClickInstances, {Time=1}) end
local info = {isTrainingArea=function() return false end, getDeflectAbility=function() return ability end, getLastDeflectPressAt=function() return 0 end}
assert(module.setup({GameInfo=info}))
assert(module.fireParry(1))
assert(module.fireParry(1))
ability.Deflect = function() end
assert(module.fireParry(1) == false)
assert(module.fireParry(1, function() return false end) == false)
''')
gameinfo = (root/'aux/gameinfo.luau').read_text()
target = gameinfo[gameinfo.index('local function targetNumber'):gameinfo.index('local function findBall()')]
run('target precedence and reset', '''
local t=10; os.clock=function() return t end
local function finite(v) return type(v)=='number' and v==v and v > -math.huge and v < math.huge end
local function typeof(v) return type(v) end
local attr=0; local world={GetAttribute=function() return attr end}; local GameInfo={}
local visual={Enabled=true}; local character={FindFirstChild=function() return visual end}
local players={LocalPlayer={UserId=42,Character=character}}
local targetEvidence={}; local targetFrame=0; local targetFrameConnection=true
local CONFIG={TARGET_CONFIRM_INTERVAL=1/60,TARGET_HOLD_TIME=0.1}
'''+target+'''
local ball={}
attr=42
assert(targetId({TargetPlayerID=99,HighlightTargetPlayerID=42},ball)==-1 and targetEvidence.uncertain)
targetFrame=targetFrame+1
assert(targetId({TargetPlayerID=99,HighlightTargetPlayerID=42},ball)==99 and not targetEvidence.uncertain)
assert(targetId({TargetPlayerID=-1,HighlightTargetPlayerID=42},ball)==-1)
assert(targetEvidence.uncertain)
assert(targetId({HighlightTargetPlayerID=42},ball)==42)
assert(targetEvidence.source=='highlight_attribute')
assert(targetId({TargetPlayerID=99,HighlightTargetPlayerID=42},ball)==42 and targetEvidence.uncertain)
assert(targetId({TargetPlayerID=42,HighlightTargetPlayerID=42},ball)==42 and not targetEvidence.uncertain)
attr=99; visual.Enabled=false
assert(targetId({HighlightTargetPlayerID=42},ball)==-1 and targetEvidence.uncertain) -- conflicting signals
assert(targetId({HighlightTargetPlayerID=99},ball)==99) -- two matching fields
attr=0
assert(targetId({HighlightTargetPlayerID=42},ball)==99 and targetEvidence.uncertain)
targetFrame=targetFrame+1
assert(targetId({HighlightTargetPlayerID=42},ball)==42 and not targetEvidence.uncertain)
''')
source=(root/'autoparry.luau').read_text()
# Translate Luau compound assignment into equivalent Lua for this isolated harness.
source=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',source)
run('teleport position and rearming', '''
local tm=10; os.clock=function() return tm end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x,y=a.y-b.y,z=a.z-b.z},V) end
V.__mul=function(a,b) return setmetatable({x=a.x*b,y=a.y*b,z=a.z*b},V) end
function V:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
local function v(x) return setmetatable({x=x,y=0,z=0},V) end
Vector3={zero=v(0)}
function typeof(x) if getmetatable(x)==V then return 'Vector3' elseif type(x)=='table' and x.instance then return 'Instance' else return type(x) end end
local frameCb
local function signal() return {Connect=function(self,fn) if not frameCb then frameCb=fn end; return {Disconnect=function() end} end} end
local player={UserId=42}; local root={Parent=true,Position=v(0),IsA=function() return true end}
local character={Parent=true, AncestryChanged=signal(),FindFirstChild=function() return root end}
local ball={Parent=true,instance=true,IsA=function() return true end}
local snap={mode='match',ball=ball,position=v(100),realPosition=v(100),velocity=v(-100),speed=100,syncSpeed=100,targetId=42,targetUncertain=false,syncSequence=1,teleported=false,locked=false}
local sequence=1; local fires=0; local cd={blocking=false}
local u={getLocalPlayer=function() return player end,getRunService=function() return {PostSimulation=signal()} end,isActive=function() return true end,getConfigValue=function() return true end,isSpamActive=function() return false end,trackCharacter=function() end,untrackCharacter=function() end,recordTransition=function() end,recordError=function() end}
local trainingUntil=0
local g={recordDeflectAttempt=function(at) cd.pressAt=at; cd.seen=false end,recordTrainingDeflectAttempt=function(at) trainingUntil=at+1.45 end,getTrainingCooldownState=function() return {blocking=tm < math.max(trainingUntil,snap.trainingLockoutUntil or 0)} end,getDeflectCooldownState=function() if cd.blocking or (cd.pressAt and cd.lastStartedAt and cd.lastStartedAt >= cd.pressAt) then cd.seen=true end; cd.miss=cd.pressAt and cd.seen and tm > cd.pressAt+0.65 and not cd.predictedReset and (not cd.lastParriedAt or cd.lastParriedAt < cd.pressAt); return cd end,getDeflectWindow=function() return 0.5 end,getLocalPing=function() return 0 end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end, getRootPosition=function() return root.Position end,isTrainingArea=function() return false end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return sequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function() return {noWindowParryRadius=8,triggerPadding=0,leadTime=0.2,effectiveWindow=0.2,deflectWindow=0.5,fullRadius=28} end,getProjectedDeflectRadius=function(g,closing) return g.noWindowParryRadius + math.max(0,closing)*g.effectiveWindow end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}
local ap=(function()\n'''+source+'''\nend)()
assert(ap.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(ap.bindCharacter(character))
ap.onBallSync({Sequence=1,TargetPlayerID=42}); assert(fires==0)
snap.position=v(5); snap.realPosition=v(100); snap.syncSequence=3; sequence=2
ap.onBallSync({Sequence=2,Teleported=true,RealPosition=v(100)})
ap.onBallSync({Sequence=1,TargetPlayerID=42}); assert(fires==0, 'accepted old packet')
sequence=3; ap.onBallSync({Sequence=3,TargetPlayerID=42}); assert(fires==0,'fired from old position')
snap.position=v(100); sequence=4; snap.syncSequence=4; tm=tm+0.02
ap.onBallSync({Sequence=4,TargetPlayerID=42}); assert(fires==0)
snap.position=v(10); snap.realPosition=v(10); sequence=5; snap.syncSequence=5; tm=tm+0.02
ap.onBallSync({Sequence=5,TargetPlayerID=42}); assert(fires==1,'failed to parry new flight')
-- A request alone is not proof of a miss: wait until a cooldown is observed.
tm=tm+0.02; frameCb(0.02); assert(fires==1,'retried before cooldown was observed')
cd.blocking=true; cd.lastStartedAt=tm; tm=tm+0.02; frameCb(0.02); assert(fires==1)
cd.blocking=false; cd.predictedReset=true; tm=tm+0.02; frameCb(0.02); assert(fires==1,'retried during predicted parry')
cd.predictedReset=false; tm=tm+0.02; frameCb(0.02); assert(fires==1,'retried before miss deadline')
tm=tm+0.6; snap.position=v(20); frameCb(0.02); assert(fires==1,'retry used the normal large window')
snap.position=v(10); frameCb(0.02); assert(fires==2,'miss did not retry inside smaller window')
-- A whole server cooldown can occur between two frames. Do not fire while
-- the ball is moving away, but rearm for a later incoming trajectory.
tm=tm+0.01; cd.lastStartedAt=tm; snap.velocity=v(100); tm=tm+0.02; frameCb(0.02); assert(fires==2,'retried with ball moving away')
snap.velocity=v(-100); tm=tm+0.7; frameCb(0.02); assert(fires==3,'did not rearm after a short cooldown')
-- A successful parry keeps the target cycle disarmed even after cooldown.
cd.blocking=true; tm=tm+0.02; cd.lastStartedAt=tm; frameCb(0.02)
cd.blocking=false; tm=tm+0.02; cd.lastParriedAt=tm; frameCb(0.02); assert(fires==3,'retried a confirmed parry')
''')
run('training miss cooldown and lockout', '''
local tm=10; os.clock=function() return tm end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x,y=a.y-b.y,z=a.z-b.z},V) end
V.__mul=function(a,b) return setmetatable({x=a.x*b,y=a.y*b,z=a.z*b},V) end
function V:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
local function v(x) return setmetatable({x=x,y=0,z=0},V) end
Vector3={zero=v(0)}
function typeof(x) if getmetatable(x)==V then return 'Vector3' elseif type(x)=='table' and x.instance then return 'Instance' else return type(x) end end
local frameCb
local function signal() return {Connect=function(self,fn) if not frameCb then frameCb=fn end; return {Disconnect=function() end} end} end
local player={UserId=42}; local root={Parent=true,Position=v(0),IsA=function() return true end}
local character={Parent=true, AncestryChanged=signal(),FindFirstChild=function() return root end}
local ball={Parent=true,instance=true,IsA=function() return true end}
local snap={mode='training',trainingRound=1,serverTime=100,ball=ball,position=v(10),realPosition=v(10),velocity=v(-100),speed=100,syncSpeed=100,targetId=42,targetUncertain=false,syncSequence=1,teleported=false,locked=false}
local sequence=1; local fires=0; local cd={blocking=false}
local u={getLocalPlayer=function() return player end,getRunService=function() return {PostSimulation=signal()} end,isActive=function() return true end,getConfigValue=function() return true end,isSpamActive=function() return false end,trackCharacter=function() end,untrackCharacter=function() end,recordTransition=function() end,recordError=function() end}
local trainingUntil=0
local g={recordDeflectAttempt=function(at) cd.pressAt=at; cd.seen=false end,recordTrainingDeflectAttempt=function(at) trainingUntil=at+1.45 end,getTrainingCooldownState=function() return {blocking=tm < math.max(trainingUntil,snap.trainingLockoutUntil or 0)} end,getDeflectCooldownState=function() if cd.blocking or (cd.pressAt and cd.lastStartedAt and cd.lastStartedAt >= cd.pressAt) then cd.seen=true end; cd.miss=cd.pressAt and cd.seen and tm > cd.pressAt+0.65 and not cd.predictedReset and (not cd.lastParriedAt or cd.lastParriedAt < cd.pressAt); return cd end,getDeflectWindow=function() return 0.5 end,getLocalPing=function() return 0 end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end, getRootPosition=function() return root.Position end,isTrainingArea=function() return true end,getTrainingMissCooldown=function() return 1.45 end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return sequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function() return {noWindowParryRadius=8,triggerPadding=0,leadTime=0.2,effectiveWindow=0.2,deflectWindow=0.5,fullRadius=28} end,getProjectedDeflectRadius=function(g,closing) return g.noWindowParryRadius + math.max(0,closing)*g.effectiveWindow end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}
local ap=(function()\n'''+source+'''\nend)()
assert(ap.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(ap.bindCharacter(character))
frameCb(0.02); assert(fires==1,'training first request missing')
snap.position=v(20)
tm=tm+1.44; frameCb(0.02); assert(fires==1,'training retried before cooldown')
snap.trainingLockoutUntil=tm+0.20; tm=tm+0.02; frameCb(0.02); assert(fires==1,'ignored server training lockout')
tm=tm+0.20; frameCb(0.02); assert(fires==1,'training retried outside smaller window')
snap.position=v(9); frameCb(0.02); assert(fires==2,'training miss did not retry')
-- A new parry event blocks retry until a newer state confirms the return.
snap.trainingParryAt=101; tm=tm+1.5; frameCb(0.02); assert(fires==2,'ignored fresh training parry')
''')
spam=(root/'spam.luau').read_text()
spam=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',spam)
run('spam pacing at 60 and 30 fps (10s simulated)', '''
local now=0; os.clock=function() return now end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local thread; task={spawn=function(fn) thread=coroutine.create(fn) end,wait=function(delay) return coroutine.yield(delay) end,defer=function(fn) fn() end,delay=function(_,fn) end}
local mod=(function()\n'''+spam+'''\nend)()
local count,last=0,-math.huge
local active=true
local u={apiVersion=function() return 1 end,getConfigValue=function(k) return ({SpamRateMode='CPS', CPS=24})[k] end,isActive=function() return active end,isManualSpamActive=function() return true end,isAutoSpamActive=function() return false end,observeSpam=function() return {Disconnect=function() end} end,observeConfig=function() return {Disconnect=function() end} end,trackGlobal=function() end,untrackGlobal=function() end,recordTransition=function() end,recordError=function(_,err) error(err) end}
local g={getMinimumSpamInterval=function() return 0.0301 end,getAutoSpamDelay=function() return math.max(0,0.0301-(now-last)) end}
local r={fireParry=function(_,guard) assert(guard()); count=count+1; last=now; return true end}
for idx,fps in ipairs({60,30}) do
 local origin=(idx-1)*20; now=origin; count=0; last=-math.huge; active=true
 assert(mod.setup({Utils=u,GameInfo=g,Remote=r,AutoSpam={canSend=function() return true end}}))
 for frame=0,10*fps-1 do now=origin+frame/fps; local ok,err=coroutine.resume(thread); assert(ok,err) end
 local metrics=mod.getStatus(); assert(metrics.acceptedLastSecond>=16 and metrics.acceptedLastSecond<=25); assert(metrics.attemptsLastSecond==metrics.acceptedLastSecond)
 local cps=count/10; print(string.format('SIMULATED %d FPS: %.1f requests/s (%d requests)',fps,cps,count)); assert(cps>=16 and cps<=25)
 active=false; mod.teardown()
end
''')
autospam=(root/'autospam.luau').read_text()
deactivation=autospam[autospam.index('local function deactivationReason'):autospam.index('local function checkDeactivation')]
run('fallback requires confirmed target and cooldown works with uncertain snapshots', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local function userId(x) return finite(x) and x>0 and x or nil end
local function typeof(x) return type(x) end
local frozen=false; local blocking=false; local ball={Parent=true,IsA=function() return true end}
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local gameInfo={getBall=function() return ball end,getBallFrozen=function() return frozen end,isSnapshotValid=function() return true end,getDeflectCooldownState=function() return {blocking=blocking} end,getPlayerMotion=function() return nil end}
local CONFIG={SHARED={SNAPSHOT_MAX_AGE=0.5},DEACTIVATION={FIRST_RETURN_TIMEOUT=0.15,DEFLECT_COOLDOWN_TIMEOUT=0.15}}
local localPlayer={UserId=42}; local state={active=true,activatedAt=1,root={Parent=true},partner=99}
local gateReason=nil; local function distanceGate() return gateReason end; local function distanceLimit() return 20 end
local function stationaryTooLong() return false end
local outside=true; local cooldownInfo=gameInfo
local function cooldownOpponentOutside() return outside end
local function cooldownTimeout() return 0.15 end
'''+deactivation+'''
assert(deactivationReason(state,nil,1.149)==nil,'timeout triggered early')
assert(deactivationReason(state,nil,1.151)==nil,'missing packet was treated as a failure')
assert(deactivationReason(state,{syncAt=1.151,targetId=88},1.151)=='target_changed','confirmed departure not detected')
state.firstReturnSeen=true; blocking=true
assert(deactivationReason(state,{targetUncertain=true},2)==nil,'cooldown timeout triggered early')
outside=false; assert(deactivationReason(state,{targetUncertain=true},2.151)==nil,'cooldown stopped with opponent close')
outside=true; assert(deactivationReason(state,{targetUncertain=true},2.151)=='deflect_cooldown_timeout','cooldown timeout was blocked outside range')
blocking=false; state.deflectCooldownSince=nil; state.reason='own_ball_proximity'; gateReason='ball_distance'
assert(deactivationReason(state,{syncAt=2.2,targetId=99},2.2)==nil,'normal outgoing ball ended clash')
assert(deactivationReason(state,{syncAt=2.2,targetId=88},2.2)=='target_changed','confirmed third target did not stop')
frozen=true; assert(deactivationReason(state,nil,2.2)=='ball_frozen')
''')
evaluate=autospam[autospam.index('local function evaluate('):autospam.index('local function watchCharacter')]
run('confirmed target is processed on heartbeat and clash intercept requires incoming ball', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local function userId(x) return finite(x) and x>0 and x or nil end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
function V:Dot(other) return self.x*other.x end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local current={root={Parent=true,Position=v(0)},active=false}; local state=current; local localPlayer={UserId=42}
local snapshot={targetId=42,position=v(9),velocity=v(-100),syncAt=10}; local targets,activations=0,0
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local gameInfo={getSnapshotAt=function() return snapshot end,isSnapshotValid=function() return true end,getBallFrozen=function() return false end,getClashContext=function() return {partnerId=99} end,getPlayerMotion=function() return v(10) end}
local CONFIG={SHARED={SNAPSHOT_MAX_AGE=0.5},ACTIVATION={RADIUS_FACTOR=0.8,INSTANT_TARGET_SWITCH_RADIUS=10,OWN_BALL_OPPONENT_RADIUS=16,OWN_BALL_CANDIDATE_MAX_AGE=0.8}}
local function targetChanged(_,target) targets=targets+1; assert(target==42) end
local function checkDeactivation() return false end
local function sampleOwnDash() end
local function geometry() return {noWindowParryRadius=8,effectiveWindow=0.15} end
local function distanceGate() return nil end
local function activate(_,reason) assert(reason=='clash_intercept'); activations=activations+1; state.active=true end
local function ownBallClose() return false end
local function canActivateReturn() return false end
'''+evaluate+'''
evaluate(state,10,false,nil,snapshot,nil,true); assert(targets==1 and activations==1)
state.active=false; snapshot.position=v(20); snapshot.velocity=v(-600); evaluate(state,10,false,nil,snapshot,nil,true); assert(activations==1,'speed enlarged activation radius')
snapshot.position=v(9); snapshot.velocity=v(100); evaluate(state,10,false,nil,snapshot,nil,true); assert(activations==1,'activated for outgoing ball')
snapshot.velocity=v(-100); snapshot.targetUncertain=true; evaluate(state,10,false,nil,snapshot,nil,true); assert(activations==1,'activated for uncertain target')
''')
stationary=autospam[autospam.index('local function stationaryTooLong'):autospam.index('local function activate(')]
run('stationary timeout requires fresh independent samples', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local function snapshotSpeed(x) return x.syncSpeed end
local CONFIG={DEACTIVATION={STATIONARY_POSITION_EPSILON=0.01,STATIONARY_TIMEOUT=0.1}}
local state={active=true}; local ball={Position=v(4)}; local snapshot={syncSequence=1,syncSpeed=0}
'''+stationary+'''
assert(not stationaryTooLong(state,10,ball,snapshot))
assert(not stationaryTooLong(state,11,ball,snapshot),'single old sample stopped clash')
snapshot.syncSequence=2; assert(not stationaryTooLong(state,11,ball,snapshot),'packet gap treated as stationary')
snapshot.syncSequence=3; assert(not stationaryTooLong(state,11.06,ball,snapshot))
snapshot.syncSequence=4; assert(stationaryTooLong(state,11.12,ball,snapshot),'continuous stationary samples not detected')
snapshot.syncSpeed=20; assert(not stationaryTooLong(state,12,ball,snapshot),'moving ball marked stationary')
''')
activate=autospam[autospam.index('local function activate('):autospam.index('local function deactivate(')]
run('close target switch retries immediately when reactivation cooldown ends', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local function userId(x) return finite(x) and x>0 and x or nil end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
function V:Dot(other) return self.x*other.x end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local current={root={Parent=true,Position=v(0)},active=false,target=42,proximityPartner=99,proximityAt=10,lastDeactivatedAt=10}; local state=current
local localPlayer={UserId=42}; local snapshot={targetId=42,position=v(9),velocity=v(-100),syncAt=10}; local activations=0
local utils={isActive=function() return true end,getConfigValue=function() return true end,setAutoSpamActive=function(x) if x then activations=activations+1 end end,recordTransition=function() end}
local gameInfo={getSnapshotAt=function() return snapshot end,isSnapshotValid=function() return true end,getBallFrozen=function() return false end,getClashContext=function() return nil end,getPlayerMotion=function() return v(10) end,isClientDeflectResetLate=function() end}
local CONFIG={SHARED={SNAPSHOT_MAX_AGE=0.5},ACTIVATION={REACTIVATION_COOLDOWN=0.04,EXCHANGE_READY_TIME=0.5,INSTANT_TARGET_SWITCH_RADIUS=10,OWN_BALL_OPPONENT_RADIUS=16,OWN_BALL_CANDIDATE_MAX_AGE=0.8}}
local clashStats,watchOpponent,lastActivationReason,lastActivationAt
local function playerIsAlive() return true end
local function snapshotSpeed(x) return x.speed end
local function targetChanged() end
local function checkDeactivation() return false end
local function sampleOwnDash() end
local function distanceGate() return nil end
local function ownBallClose() return false end
local function canActivateReturn() return false end
'''+activate+evaluate+'''
evaluate(state,10.02,false,nil,snapshot,nil,true); assert(activations==0,'activated during cooldown')
evaluate(state,10.05,false,nil,snapshot,nil,true); assert(activations==1,'did not retry confirmed close switch')
''')
reasons=autospam[autospam.index('local PROTECTED_REASONS ='):autospam.index('-- helpers')]
stop=autospam[autospam.index('local function deactivate('):autospam.index('local function deactivationReason(')]
run('timeout deactivation locks reactivation', '''
local CONFIG={DEACTIVATION={SYNC_PROTECTION_RADIUS=16,CLOSE_OPPONENT_PROTECTION_RADIUS=10}}
'''+reasons+'''
local current={active=true,partner=99,target=42}; local state=current
local watchOpponent,lastStopReason,lastStopAt
local utils={setAutoSpamActive=function(active) assert(active==false) end,recordTransition=function() end}
local function now() return 1 end
local function closeClashProtected() return true end
local function resetExchange() end
'''+stop+'''
assert(deactivate(state,'deflect_cooldown_timeout',1))
assert(not state.active and state.timeoutBlocked and state.timeoutBlockedTarget==42)
state.active=true; state.partner=99
assert(deactivate(state,'target_changed',2))
assert(not state.active)
''')

cooldownDistance=autospam[autospam.index('local function cooldownOpponentOutside('):autospam.index('local function stationaryTooLong(')]
run('cooldown requires opponent beyond 16 studs', """
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local CONFIG={DEACTIVATION={SYNC_PROTECTION_RADIUS=16}}
local opponent=v(16); local gameInfo={getPlayerMotion=function() return opponent end}
local players={GetPlayerByUserId=function() return nil end}
local state={partner=99,root={Parent=true,Position=v(0)}}
"""+cooldownDistance+"""
assert(not cooldownOpponentOutside(state),'16 studs should protect')
opponent=v(16.01); assert(cooldownOpponentOutside(state),'outside 16 should permit')
opponent=nil; assert(not cooldownOpponentOutside(state),'unknown position should protect')
""")

cooldownTime=autospam[autospam.index('local function cooldownTimeout('):autospam.index('local function listen(')]
run('cooldown timeout scales from 150ms to 100ms', """
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local function snapshotSpeed(x) return x and (x.syncSpeed or x.speed) end
local CONFIG={SHARED={SNAPSHOT_MAX_AGE=0.5},DEACTIVATION={DEFLECT_COOLDOWN_TIMEOUT_BASE=0.15,DEFLECT_COOLDOWN_TIMEOUT_MAX_SPEED=0.10}}
local gameInfo={getBallSpeedLimits=function() return 16,600 end}; local state={}
"""+cooldownTime+"""
local function near(a,b) return math.abs(a-b)<1e-9 end
assert(near(cooldownTimeout({syncSpeed=16},state,10),0.15))
assert(near(cooldownTimeout({syncSpeed=308},state,10),0.125))
assert(near(cooldownTimeout({syncSpeed=600},state,10),0.10))
assert(near(cooldownTimeout({syncSpeed=900},state,10),0.10))
assert(near(cooldownTimeout(nil,state,10),0.10),'missing packet lost last speed')
assert(near(cooldownTimeout({syncSpeed=16,syncAt=1},state,10),0.10),'stale speed replaced current speed')
""")
run('maximum-speed cooldown gate fires at 100ms beyond 16 studs', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local function userId(x) return finite(x) and x>0 and x or nil end
local function snapshotSpeed(x) return x and (x.syncSpeed or x.speed) end
local function typeof(x) return type(x) end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local CONFIG={SHARED={SNAPSHOT_MAX_AGE=0.5},DEACTIVATION={FIRST_RETURN_TIMEOUT=0.15,DEFLECT_COOLDOWN_TIMEOUT_BASE=0.15,DEFLECT_COOLDOWN_TIMEOUT_MAX_SPEED=0.10}}
local gameInfo={getBallSpeedLimits=function() return 16,600 end,getDeflectCooldownState=function() return {blocking=true} end,getBallFrozen=function() return false end,getBall=function() return nil end}
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local cooldownInfo=gameInfo
local function cooldownOpponentOutside() return true end
local state={activatedAt=1,firstReturnSeen=true}; local localPlayer={UserId=42}
'''+cooldownTime+deactivation+'''
local snapshot={syncSpeed=600,targetUncertain=true}
assert(deactivationReason(state,snapshot,1)==nil)
assert(deactivationReason(state,snapshot,1.099)==nil)
assert(deactivationReason(state,snapshot,1.101)=='deflect_cooldown_timeout')
''')
targetTransition=autospam[autospam.index('local function targetChanged('):autospam.index('local function safeToReset(')]
run('activation and subsequent target transitions are tracked', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local state={active=false,target=99,root={Position=v(0)}}; local localPlayer={UserId=42}
local snapshot={position=v(8)}; local utils={getConfigValue=function() return true end}
local gameInfo={getPlayerMotion=function() return v(9) end,isSnapshotValid=function() return true end,getBallFrozen=function() return false end}
local CONFIG={ACTIVATION={EXCHANGE_MAX_INTERVAL=2,INSTANT_TARGET_SWITCH_RADIUS=10,OWN_BALL_OPPONENT_RADIUS=16,REACTIVATION_COOLDOWN=0.04}}
local function watchOpponent() end; local function playerIsAlive() return true end
local function activate(s) s.active=true; s.partner=99; s.firstReturnSeen=false end
local function armReturn() end; local function elapsed() return nil end
'''+targetTransition+'''
targetChanged(state,42,10,snapshot,nil); assert(state.active and state.target==42)
targetChanged(state,99,10.01,snapshot,nil); assert(state.target==99)
targetChanged(state,42,10.02,snapshot,nil); assert(state.target==42)
state.active=false; state.target=42; state.stoppedPartner=99; state.stoppedAt=20
targetChanged(state,99,20.01,snapshot,nil); assert(state.stoppedPartner==nil,'confirmed switch was discarded during cooldown')
''')
returnGate=autospam[autospam.index('local function canActivateReturn('):autospam.index('local function armReturn(')]
run('fast-return gate checks actual closing speed', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
function V:Dot(other) return self.x*other.x end
local function v(x) return setmetatable({x=x},V) end
local function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local localPlayer={UserId=42}; local state={target=42,root={Position=v(0)},pending={partner=99,fastReturn=true}}
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local gameInfo={getBallFrozen=function() return false end}
local function activationGeometry() return {fullRadius=120,noWindowParryRadius=8,effectiveWindow=0.2} end
'''+returnGate+'''
local snapshot={targetId=42,position=v(100),velocity=v(-10)}
assert(not canActivateReturn(state,snapshot,1),'slow closing speed wrongly treated as near impact')
snapshot.velocity=v(-600); assert(canActivateReturn(state,snapshot,1),'fast incoming ball rejected')
snapshot.velocity=v(600); assert(not canActivateReturn(state,snapshot,1),'outgoing ball accepted')
snapshot.velocity=v(-600); snapshot.targetUncertain=true; assert(not canActivateReturn(state,snapshot,1),'uncertain target accepted')
''')


# Fierce only fires for an expired click and an incoming ball in range.
fierce=(root/'extras/autofierce.luau').read_text()
fierce=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',fierce)
run('fierce waits for miss and incoming ball', '''
local t=10; os.clock=function() return t end
local frame; local c={Connected=true,Disconnect=function() end}
local heartbeat={Connect=function(_,fn) frame=fn; return c end}
local signal={Connect=function() return c end}
local press=10; local cooldown={blocking=true,predictedReset=false,pressAt=10,episode=1,miss=false}; local target=42; local distance=50; local approaching=true; local count=0
local u={isActive=function() return true end,getConfigValue=function() return true end,getLocalPlayer=function() return {UserId=42} end,getRunService=function() return {Heartbeat=heartbeat} end,trackGlobal=function() end,untrackGlobal=function() end}
local g={areAbilitiesEnabled=function() return true end,getDeflectServerEvents=function() return {parried=signal} end,getLastDeflectPressAt=function() return press end,getDeflectWindow=function() return 0.5 end,getLocalPing=function() return 0 end,getDeflectCooldownState=function() if press > 0 and press ~= cooldown.pressAt then cooldown.episode=cooldown.episode+1; cooldown.pressAt=press end; cooldown.miss=t > cooldown.pressAt+0.65 and not cooldown.predictedReset and not cooldown.parried; return cooldown end,getSnapshotAt=function() return {syncAt=t,targetId=target} end,isSnapshotValid=function() return true end,getBallFrozen=function() return false end}
local a={getTiming=function() return {approaching=approaching,distance=distance,triggerDistance=20} end,beginFierce=function() return {} end,cancelFierce=function() end}
local r={fireFierce=function(guard) if guard() then count=count+1; return true end return false end}
local mod=(function()\n'''+fierce+'''\nend)(); assert(mod.setup({Utils=u,GameInfo=g,Remote=r,AutoParry=a,Cooldown=g}))
frame(); t=10.6; distance=10; frame(); assert(count==0,'used before deadline')
t=10.66; cooldown.predictedReset=true; frame(); assert(count==0,'used during predicted reset')
cooldown.predictedReset=false; target=99; frame(); assert(count==0,'used against another target')
target=42; approaching=false; frame(); assert(count==0,'used for outgoing ball')
approaching=true; distance=30; frame(); assert(count==0,'used outside window')
distance=10; frame(); assert(count==1,'did not use after miss'); frame(); assert(count==1,'duplicate')
t=11; press=11; frame(); cooldown.parried=true; t=12; press=0; frame(); assert(count==1,'used after parry')
''')

