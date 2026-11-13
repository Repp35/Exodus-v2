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
cooldown = source[source.index('function GameInfo.recordDeflectAttempt'):source.index('function GameInfo.isClientDeflectResetLate')]
run('server cooldown, prediction, miss deadline and parry', '''
local t=10; os.clock=function() return t end
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local CONFIG={MISS_NOOB_EXTRA=0.15,COOLDOWN_RETRY=0.5,HELD_COOLDOWN_INTERVAL=0.05}
local cooldown={known=false,rawActive=false,lastEventAt=-math.huge,lastParriedAt=-math.huge}
local deflectAttempt,observedAbility,blockingSince,previousBlocking; local cooldownConnection,parriedConnection; local signalAt,heldAt,missingAt,warningAt=0,0,nil,0
local ability={Cooldown=0}; local press=0; local trainingLockoutUntil
local cdCallback,parryCallback; local conn={Connected=true,Disconnect=function() end}
local signals={cooldown={Connect=function(_,f) cdCallback=f; return conn end},parried={Connect=function(_,f) parryCallback=f; return conn end}}
local utils={trackGlobal=function() end}; local function disconnect() end; local function report() end
local GameInfo={getDeflectWindow=function() return 0.5 end,getLocalPing=function() return 0 end,getDeflectServerEvents=function() return signals end,decodeDeflectServerEvent=function(_,_,value) return value>0 and 'started' or 'reset',value end,getHeldDeflectServerCooldown=function() return nil end,getDeflectAbility=function() return ability end,getLastDeflectPressAt=function() return press end}
'''+cooldown+'''
local c=GameInfo.getDeflectCooldownState(); assert(not c.missEstimated)
press=10; ability.PendingPressAt=10; ability.PendingPredictUntil=10.5; ability.Cooldown=1; cdCallback(1,1,1); c=GameInfo.getDeflectCooldownState(); assert(c.blocking and c.serverRemaining==1 and c.outcome=='pending')
t=10.3; press=10.3; c=GameInfo.getDeflectCooldownState(); assert(c.pressAt==10 and c.phase=='reversible', 'rejected spam click reset attempt')
t=10.6; ability.PendingPredictUntil=nil; c=GameInfo.getDeflectCooldownState(); assert(not c.missEstimated)
ability.Cooldown=0; ability.PredictedResetUntil=11; c=GameInfo.getDeflectCooldownState(); assert(not c.blocking and c.serverRemaining>0 and c.source=='local', 'server signal overrode local predicted reset')
ability.Cooldown=0.4
t=10.7; ability.PredictedResetUntil=11; c=GameInfo.getDeflectCooldownState(); assert(not c.missEstimated and c.predictedReset)
ability.PredictedResetUntil=0; c=GameInfo.getDeflectCooldownState(); assert(c.missEstimated and c.outcome=='miss_estimated')
parryCallback(); ability.Cooldown=0; c=GameInfo.getDeflectCooldownState(); assert(c.outcome=='parried' and not c.missEstimated and not c.blocking)
t=12; press=12; GameInfo.recordDeflectAttempt(12); t=13; c=GameInfo.getDeflectCooldownState(); assert(not c.missEstimated, 'no cooldown is not proof of a miss')
t=14; press=14; GameInfo.recordDeflectAttempt(14); ability.Cooldown=0.4; c=GameInfo.getDeflectCooldownState(); assert(c.blocking and c.localRemaining==0.4)
t=14.7; ability.Cooldown=0; c=GameInfo.getDeflectCooldownState(); assert(c.missEstimated and not c.blocking, 'miss cooldown did not end locally')
t=16; ability.PendingPressAt=16; ability.PendingPredictUntil=16.5; ability.Cooldown=0.3; c=GameInfo.getDeflectCooldownState(); assert(c.phase=='reversible' and c.blockingSince==16)
t=16.1; ability.Cooldown=0; c=GameInfo.getDeflectCooldownState(); assert(c.lastClearedAt==16.1 and not c.blocking, 'local disappearance missed')
t=16.2; ability.Cooldown=0.1; c=GameInfo.getDeflectCooldownState(); assert(c.blockingSince==16.2, 'restored cooldown kept old start time')
t=16.7; ability.PendingPredictUntil=nil; conn.Connected=false; c=GameInfo.getDeflectCooldownState(); assert(not c.missEstimated and c.phase=='unknown', 'missing parry signal classified as a miss')

''')
autospam = (Path(__file__).resolve().parents[2] / 'modules/logic/autospam.luau').read_text()
policy = autospam[autospam.index('local function deactivationReason('):autospam.index('local function checkDeactivation(')]
run('AutoSpam follows local cooldown appearance and disappearance', '''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local cd={blocking=false}; local gameInfo={getBallFrozen=function() return false end,getDeflectCooldownState=function() return cd end}
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
