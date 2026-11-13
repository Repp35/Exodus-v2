"""Offline simulation of shared cooldown and game-context classification."""
import ctypes
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
source = (Path(__file__).resolve().parents[2] / 'modules/logic/aux/gameinfo.luau').read_text()
def run(name, script):
    state = lib.luaL_newstate(); lib.luaL_openlibs(state)
    status = lib.luaL_loadstring(state, script.encode())
    if not status: status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status: raise RuntimeError(name + ': ' + lib.lua_tolstring(state, -1, None).decode())
    print('PASS', name)
context = source[source.index('function GameInfo.getGameContext()'):source.index('function GameInfo.areAbilitiesEnabled()')]
run('match, spectator, lobby, training and unknown', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local attrs={MatchStatus=6,CurGamemode=3}; local pa={Lives=1,Playing=true,AFK=false}
local world={GetAttribute=function(_,k) return attrs[k] end}
local player={GetAttribute=function(_,k) return pa[k] end}; local players={LocalPlayer=player}
local game={PlaceId=12979690461}; local training=false; local function inTrainingArea() return training end
local GameInfo={}
'''+context+'''
local x=GameInfo.getGameContext(); assert(x.area=='match' and x.inMatch and x.modeName=='Zero Abilities')
pa.Lives=0; x=GameInfo.getGameContext(); assert(x.area=='lobby' and x.roundActive and not x.inMatch)
training=true; x=GameInfo.getGameContext(); assert(x.area=='training' and not x.inMatch)
attrs.MatchStatus=1; training=false; x=GameInfo.getGameContext(); assert(x.area=='lobby' and x.roundActive==false)
game.PlaceId=9876; x=GameInfo.getGameContext(); assert(x.area=='unknown')
attrs.MatchStatus=nil; x=GameInfo.getGameContext(); assert(x.inMatch==nil and x.roundActive==nil)
''')
cooldown_source = (Path(__file__).resolve().parents[2] / 'modules/logic/aux/cooldown.luau').read_text()
cooldown = cooldown_source[cooldown_source.index('function Cooldown.recordDeflectAttempt'):cooldown_source.index('-- lifecycle')]
run('server cooldown, prediction, miss deadline and parry', '''
local t=10; os.clock=function() return t end
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local CONFIG={MISS_NOOB_EXTRA=0.15,COOLDOWN_RETRY=0.5,HELD_COOLDOWN_INTERVAL=0.05}
local cooldown={known=false,rawActive=false,lastEventAt=-math.huge,lastParriedAt=-math.huge}
local deflectAttempt,observedAbility,blockingSince,previousBlocking,cooldownEpisode; local cooldownConnection,parriedConnection; local signalAt,heldAt,missingAt,warningAt=0,0,nil,0
local ability={Cooldown=0}; local press=0; local trainingLockoutUntil
local cdCallback,parryCallback; local conn={Connected=true,Disconnect=function() end}
local signals={cooldown={Connect=function(_,f) cdCallback=f; return conn end},parried={Connect=function(_,f) parryCallback=f; return conn end}}
local utils={trackGlobal=function() end}; local function disconnect() end; local function report() end
local Cooldown={}
local gameInfo={getDeflectAbility=function() return ability end}
Cooldown.getDeflectServerEvents=function() return signals end; Cooldown.decodeDeflectServerEvent=function(_,_,value) return value>0 and 'started' or 'reset',value end; Cooldown.getHeldDeflectServerCooldown=function() return nil end
'''+cooldown+'''
local c=Cooldown.getDeflectCooldownState(); assert(not c.miss)
press=10; ability.PendingPressAt=10; ability.PendingPredictUntil=10.5; ability.Cooldown=1; cdCallback(1,1,1); c=Cooldown.getDeflectCooldownState(); assert(c.blocking and c.serverRemaining==1 and c.phase=='reversible')
t=10.3; press=10.3; c=Cooldown.getDeflectCooldownState(); assert(c.pressAt==10 and c.phase=='reversible', 'rejected spam click reset attempt')
ability.Cooldown=0; ability.PredictedResetUntil=11; c=Cooldown.getDeflectCooldownState(); assert(not c.blocking and c.serverRemaining>0 and c.phase=='predicted_reset', 'predicted reset ignored')
parryCallback(); c=Cooldown.getDeflectCooldownState(); assert(c.outcome=='parried' and not c.miss and not c.blocking)
t=12; press=12; ability.PendingPressAt=12; ability.PendingPredictUntil=12.2; ability.PredictedResetUntil=0; ability.Cooldown=0.8; c=Cooldown.getDeflectCooldownState(); assert(c.phase=='reversible')
t=12.2; c=Cooldown.getDeflectCooldownState(); assert(c.miss and c.phase=='miss_cooldown', 'window expiry should become miss immediately')
t=12.8; ability.PendingPredictUntil=nil; ability.Cooldown=0; c=Cooldown.getDeflectCooldownState(); assert(c.miss and c.phase=='miss_finished' and c.lastClearedAt==12.8)
t=14; ability.PendingPressAt=14; ability.PendingPredictUntil=14.7; ability.Cooldown=0.3; c=Cooldown.getDeflectCooldownState(); assert(c.phase=='reversible' and c.blockingSince==14)
t=14.1; ability.Cooldown=0; c=Cooldown.getDeflectCooldownState(); assert(c.lastClearedAt==14.1 and not c.blocking)
t=14.2; ability.Cooldown=0.1; c=Cooldown.getDeflectCooldownState(); assert(c.blockingSince==14.2, 'restored cooldown kept old start time')
t=14.7; ability.PendingPredictUntil=nil; conn.Connected=false; c=Cooldown.getDeflectCooldownState(); assert(c.miss and c.phase=='miss_cooldown', 'local miss must not require server signal')

''')
autospam = (Path(__file__).resolve().parents[2] / 'modules/logic/autospam.luau').read_text()
policy = autospam[autospam.index('local function deactivationReason('):autospam.index('local function checkDeactivation(')]
run('AutoSpam follows local cooldown appearance and disappearance', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local cd={blocking=false}; local gameInfo={getBallFrozen=function() return false end}; local cooldownInfo={getDeflectCooldownState=function() return cd end}
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local function returnTimeout() return 1 end
local function cooldownTimeout() return 0.2 end
local function cooldownOpponentOutside() return true end
local state={activatedAt=10}
'''+policy+'''
assert(deactivationReason(state,nil,10)==nil)
cd.blocking=true; cd.blockingSince=10; assert(deactivationReason(state,nil,10)==nil)
assert(deactivationReason(state,nil,10.19)==nil)
assert(deactivationReason(state,nil,10.21)=='deflect_cooldown_timeout')
cd.blocking=false; assert(deactivationReason(state,nil,10.22)==nil and state.deflectCooldownSince==nil)
cd.blocking=true; cd.blockingSince=10.23; assert(deactivationReason(state,nil,10.3)==nil, 'new cooldown reused old elapsed time')
assert(deactivationReason(state,nil,10.44)=='deflect_cooldown_timeout')
''')
run('cooldown module lifecycle and training events', '''
local t=10; os.clock=function() return t end
local eventCallbacks={}; local connections={}
local function signal(name)
 return {Connect=function(_,fn) local c={Connected=true}; function c:Disconnect() self.Connected=false end; eventCallbacks[name]=fn; connections[#connections+1]=c; return c end}
end
local trainingEvent={OnClientEvent=signal('training'),IsA=function(_,k) return k=='RemoteEvent' end}
local remotes={FindFirstChild=function(_,name) if name=='Event' then return trainingEvent end end}
local training={FindFirstChild=function(_,name) if name=='Remotes' then return remotes end end}
local storage={FindFirstChild=function(_,name) if name=='Training' then return training end end}
local heartbeat={Heartbeat=signal('heartbeat')}; local tracked=0
local u={getReplicatedStorage=function() return storage end,getRunService=function() return heartbeat end,getLocalPlayer=function() return {UserId=42} end,trackGlobal=function() tracked=tracked+1 end,untrackGlobal=function() tracked=tracked-1 end,recordError=function(_,e) error(e) end}
local ability={Cooldown=0}; local g={getDeflectAbility=function() return ability end}
local mod=(function()\n'''+cooldown_source+'''\nend)()
assert(mod.setup({Utils=u,GameInfo=g})); assert(eventCallbacks.training and eventCallbacks.heartbeat)
mod.recordTrainingDeflectAttempt(t); assert(mod.getTrainingCooldownState().blocking)
t=11.5; assert(not mod.getTrainingCooldownState().blocking)
eventCallbacks.training('Lockout',0.4); assert(mod.getTrainingCooldownState().blocking)
eventCallbacks.training('Parry',99); assert(mod.getTrainingCooldownState().blocking)
eventCallbacks.training('Parry',42); assert(not mod.getTrainingCooldownState().blocking)
mod.teardown(); assert(tracked==0); for _,c in ipairs(connections) do assert(not c.Connected) end
''')
