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
local ability = {ClickInstances={}}
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
local g={getDeflectCooldownState=function() return cd end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end, getRootPosition=function() return root.Position end,isTrainingArea=function() return false end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return sequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function() return {noWindowParryRadius=8,triggerPadding=0,leadTime=0,effectiveWindow=0,fullRadius=20} end,getProjectedDeflectRadius=function() return 20 end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}
local ap=(function()\n'''+source+'''\nend)()
assert(ap.setup({Utils=u,GameInfo=g,Remote=r})); assert(ap.bindCharacter(character))
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
cd.predictedReset=false; tm=tm+0.02; frameCb(0.02); assert(fires==2,'miss did not retry when cooldown ended')
-- A whole server cooldown can occur between two frames. Do not fire while
-- the ball is moving away, but rearm for a later incoming trajectory.
tm=tm+0.01; cd.lastStartedAt=tm; snap.velocity=v(100); tm=tm+0.02; frameCb(0.02); assert(fires==2,'retried with ball moving away')
snap.velocity=v(-100); tm=tm+0.02; frameCb(0.02); assert(fires==3,'did not rearm after a short cooldown')
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
local g={getDeflectCooldownState=function() return cd end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end, getRootPosition=function() return root.Position end,isTrainingArea=function() return true end,getTrainingMissCooldown=function() return 1.45 end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return sequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function() return {noWindowParryRadius=8,triggerPadding=0,leadTime=0,effectiveWindow=0,fullRadius=20} end,getProjectedDeflectRadius=function() return 20 end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}
local ap=(function()\n'''+source+'''\nend)()
assert(ap.setup({Utils=u,GameInfo=g,Remote=r})); assert(ap.bindCharacter(character))
frameCb(0.02); assert(fires==1,'training first request missing')
tm=tm+1.44; frameCb(0.02); assert(fires==1,'training retried before cooldown')
snap.trainingLockoutUntil=tm+0.20; tm=tm+0.02; frameCb(0.02); assert(fires==1,'ignored server training lockout')
tm=tm+0.20; frameCb(0.02); assert(fires==2,'training miss did not retry')
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
 assert(mod.setup({Utils=u,GameInfo=g,Remote=r}))
 for frame=0,10*fps-1 do now=origin+frame/fps; local ok,err=coroutine.resume(thread); assert(ok,err) end
 local metrics=mod.getStatus(); assert(metrics.acceptedLastSecond>=16 and metrics.acceptedLastSecond<=25); assert(metrics.attemptsLastSecond==metrics.acceptedLastSecond)
 local cps=count/10; print(string.format('SIMULATED %d FPS: %.1f requests/s (%d requests)',fps,cps,count)); assert(cps>=16 and cps<=25)
 active=false; mod.teardown()
end
''')
