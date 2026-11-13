"""Simulate grace emergencies and manual Fierce activation without Roblox."""
import ctypes, re
from pathlib import Path
lib = ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.luaL_loadstring.restype = ctypes.c_int
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
lib.lua_pcallk.restype = ctypes.c_int
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lib.lua_tolstring.restype = ctypes.c_char_p
root = Path(__file__).resolve().parents[2] / 'modules/logic'
def run(name, script):
    state=lib.luaL_newstate(); lib.luaL_openlibs(state)
    status=lib.luaL_loadstring(state, script.encode())
    if not status: status=lib.lua_pcallk(state,0,0,0,0,None)
    if status: raise RuntimeError(name+': '+lib.lua_tolstring(state,-1,None).decode())
    print('PASS',name)
def translate(source):
    return re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',source)
fierce=translate((root/'extras/autofierce.luau').read_text())
run('Fierce grace danger and manual ability hook', '''
local t=10; os.clock=function() return t end
local frame; local connection={Connected=true,Disconnect=function(self) self.Connected=false end}
local h={Connect=function(_,f) frame=f; return connection end}
local active=true; local fired,manual,begun=0,0,0; local distance=1; local approaching=false; local fresh=true
local ball={}; local snap={ball=ball,mode='match',targetId=42,grace=false,serverTime=10,syncAt=10}
local cooldown={blocking=false,phase='ready',episode=0,miss=false}; local frozen=false
local ability={Cooldown=0}; function ability:ActivateAndBlock() manual=manual+1 end
local original=ability.ActivateAndBlock
local u={isActive=function() return true end,getConfigValue=function() return active end,getLocalPlayer=function() return {UserId=42} end,getRunService=function() return {Heartbeat=h} end,trackGlobal=function() end,untrackGlobal=function() end}
local g={areAbilitiesEnabled=function() return true end,getFierceDeflectAbility=function() return ability end,getDefensePhysics=function() return {grace=0.2,ping=0.02,serverNow=t} end,getSnapshotAt=function() if fresh then snap.syncAt=t end; return snap end,isSnapshotValid=function(x) return x~=nil end,getBallFrozen=function() return frozen end}
local a={getTiming=function() return {approaching=approaching,distance=distance,triggerDistance=20,noWindowParryRadius=8.5} end,beginFierce=function() begun=begun+1; return {id=begun} end,cancelFierce=function() end}
local r={fireFierce=function(guard) if not guard() then return false end; fired=fired+1; ability:ActivateAndBlock(); return true end}
local mod=(function()\n'''+fierce+'''\nend)(); assert(mod.setup({Utils=u,GameInfo=g,Remote=r,AutoParry=a,Cooldown={getDeflectCooldownState=function() return cooldown end}}))
frame(); assert(fired==0,'no grace triggered Fierce')
snap.grace=true; snap.serverTime=10.02; t=10.1; frame(); assert(fired==0,'used too early in grace')
t=10.16; ability.Cooldown=4; frame(); assert(fired==0,'used unavailable Fierce')
ability.Cooldown=0; cooldown.predictedReset=true; frame(); assert(fired==0,'ignored predicted parry')
cooldown.predictedReset=false; cooldown.phase='reversible'; cooldown.missDeadline=11; frame(); assert(fired==0,'ignored active normal defense')
cooldown.phase='ready'; distance=20; frame(); assert(fired==0,'used outside deflect range')
distance=1; snap.targetId=99; frame(); assert(fired==0,'used on another target')
snap.targetId=42; snap.grace=false; snap.serverTime=10.16; frame()
snap.grace=true; snap.serverTime=10.18; t=10.29; frame(); assert(fired==0,'used before safety margin')
t=10.31; frame(); assert(fired==1,'failed emergency at one stud'); frame(); assert(fired==1,'repeated within grace')
snap.grace=false; snap.serverTime=t; frame(); snap.grace=true; snap.serverTime=t+0.01; t=t+0.02; frozen=true; frame(); assert(fired==1)
frozen=false; snap.targetUncertain=true; frame(); assert(fired==1); snap.targetUncertain=false
fresh=false; t=t+0.3; frame(); assert(fired==1,'stale grace triggered Fierce')
active=false; local before=begun; ability:ActivateAndBlock(); assert(begun==before+1,'manual Fierce not detected when feature disabled')
mod.teardown(); assert(ability.ActivateAndBlock==original,'manual hook not restored'); assert(not connection.Connected)
''')
ap=translate((root/'autoparry.luau').read_text())
run('AutoParry waits for active Fierce and recovers on expiry', '''
local t=10; os.clock=function() return t end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
V.__mul=function(a,b) return setmetatable({x=a.x*b},V) end
function V:Dot(b) return self.x*b.x end
local function v(x) return setmetatable({x=x},V) end
Vector3={zero=v(0)}
function typeof(x) if getmetatable(x)==V then return 'Vector3' elseif type(x)=='table' and x.instance then return 'Instance' else return type(x) end end
local cb; local function signal() return {Connect=function(_,fn) if not cb then cb=fn end; return {Disconnect=function() end} end} end
local player={UserId=42}; local root={Parent=true,Position=v(0),IsA=function() return true end}
local character={Parent=true,AncestryChanged=signal(),FindFirstChild=function() return root end}
local ball={Parent=true,instance=true,IsA=function() return true end}
local snap={mode='match',ball=ball,position=v(50),realPosition=v(50),velocity=v(-100),speed=100,syncSpeed=100,targetId=42,targetUncertain=false,syncSequence=1,teleported=false,locked=false}
local cd={blocking=false,source='local'}; local fires=0; local ability={}
local u={getLocalPlayer=function() return player end,getRunService=function() return {PostSimulation=signal(),Heartbeat=signal()} end,isActive=function() return true end,getConfigValue=function() return true end,isSpamActive=function() return false end,trackCharacter=function() end,untrackCharacter=function() end,trackGlobal=function() end,untrackGlobal=function() end,recordTransition=function() end,recordError=function() end}
local g={getDeflectAbility=function() return ability end,getDeflectCooldownState=function() return cd end,recordDeflectAttempt=function() end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end,getRootPosition=function() return root.Position end,getTargetId=function() return snap.targetId end,isTrainingArea=function() return false end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return snap.syncSequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function() return {noWindowParryRadius=8,triggerPadding=0,leadTime=0.2,effectiveWindow=0.2,deflectWindow=0.5,fullRadius=28} end,getProjectedDeflectRadius=function(g,c) return g.noWindowParryRadius+math.max(0,c)*g.effectiveWindow end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}
local mod=(function()\n'''+ap+'''\nend)(); assert(mod.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(mod.bindCharacter(character))
cb(0.02); assert(fires==0)
local manualCalls=0; local fAbility={Cooldown=0}; function fAbility:ActivateAndBlock() manualCalls=manualCalls+1; ability.LastDeflectCallAt=t end
local original=fAbility.ActivateAndBlock
g.getFierceDeflectAbility=function() return fAbility end; g.areAbilitiesEnabled=function() return true end
g.getDefensePhysics=function() return {grace=0.2,serverNow=t,ping=0} end; g.getBallFrozen=function() return false end
local fmod=(function()\n'''+fierce+'''\nend)(); assert(fmod.setup({Utils=u,GameInfo=g,Remote=r,AutoParry=mod,Cooldown=g}))
fAbility:ActivateAndBlock(); assert(manualCalls==1, 'manual Fierce did not execute')
snap.position=v(10); t=10.1; snap.syncSequence=2; mod.onBallSync({Sequence=2,TargetPlayerID=42}); cb(0.02); assert(fires==0,'clicked alongside Fierce')
t=14.9; cb(0.02); assert(fires==0,'clicked while Fierce remains active')
t=15.1; cb(0.02); assert(fires==1,'failed to recover when Fierce expired')
fmod.teardown(); assert(fAbility.ActivateAndBlock==original); mod.teardown(); cb=nil; t=20; snap.position=v(50); snap.syncSequence=1
assert(mod.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(mod.bindCharacter(character)); cb(0.02)
local token=mod.beginFierce(); mod.cancelFierce(token); snap.position=v(10); t=20.1; cb(0.02); assert(fires==2,'cancelled Fierce left AP blocked')
mod.teardown(); cb=nil; t=30; snap.position=v(50); snap.syncSequence=1; ability.LastDeflectCallAt=nil
assert(mod.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(mod.bindCharacter(character)); cb(0.02)
t=30.1; ability.LastDeflectCallAt=t; cd.predictedReset=true; snap.position=v(10); cb(0.02); assert(fires==2,'fallback duplicated a manual click')
cd.predictedReset=false; cd.miss=true; cd.pressAt=30.1; t=30.2; cb(0.02); assert(fires==3,'fallback did not recover after a miss')
mod.teardown(); cb=nil; t=40; snap.position=v(50); snap.syncSequence=1; cd.miss=false; cd.lastParriedAt=nil; ability.LastDeflectCallAt=nil
assert(mod.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=g})); assert(mod.bindCharacter(character)); cb(0.02); mod.beginFierce()
t=40.1; cd.lastParriedAt=t; cb(0.02)
t=40.2; snap.targetId=99; snap.syncSequence=2; cb(0.02)
t=40.3; snap.targetId=42; snap.syncSequence=3; snap.position=v(10); cb(0.02); assert(fires==4,'AP did not rearm for the next ball after Fierce parry')
''')
