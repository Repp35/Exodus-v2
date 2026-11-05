"""Exercise actual Auto Clash runtime state, events and heartbeat transitions."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/autoclash.luau').read_text()
pre = r'''
local function module()
'''
post = r'''
end
local mt={}
mt.__index=function(a,k) if k=='Magnitude' then return math.abs(a.X) elseif k=='Dot' then return function(x,y) return x.X*y.X end end end
mt.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=0,Z=0},mt) end
local function v(x) return setmetatable({X=x,Y=0,Z=0},mt) end
local function typeof(x) return getmetatable(x)==mt and 'Vector3' or type(x) end
local heartbeat
local signal={Connect=function(_,fn) return {Disconnect=function() end} end}
local run={Heartbeat={Connect=function(_,fn) heartbeat=fn; return {Disconnect=function() end} end}}
local parent={}
local root={Parent=parent,Position=v(0),IsA=function() return true end}
local character={Parent=parent,AncestryChanged=signal,FindFirstChild=function() return root end}
local me={UserId=42,Character=character}
local enemyRoot={Parent=parent,Position=v(10)}
local thirdRoot={Parent=parent,Position=v(100)}
local function other(id,r) return {UserId=id,Character={FindFirstChild=function() return r end},GetAttributeChangedSignal=function() return signal end} end
local enemy, third=other(7,enemyRoot),other(9,thirdRoot)
local players={GetPlayerByUserId=function(_,id) return id==7 and enemy or id==9 and third end,
 GetPlayers=function() return {me,enemy,third} end,PlayerAdded=signal,PlayerRemoving=signal}
local t, target, active, manual, seq = 1, 42, false, false, 0
local snapshot={position=v(-20),velocity=v(100),speed=100,syncSpeed=100,targetId=42,targeted=true,teleported=false}
local info={getSnapshotAt=function() return snapshot end,isSnapshotValid=function() return true end,
 getTargetId=function() return target end,getSyncData=function() return {Speed=100} end,getSyncSequence=function() return seq end,
 getLocalPing=function() return 0 end,getBallSpeedLimits=function() return 16,600 end,getDeflectAbility=function() return {DeflectDistance=10} end,
 getDeflectWindow=function() return .3 end}
local utils={now=function() return t end,getPlayers=function() return players end,getRunService=function() return run end,
 getLocalPlayer=function() return me end,isActive=function() return true end,isManualSpamActive=function() return manual end,
 getConfigValue=function(k) return k=='AutoClash' end,setAutoSpamActive=function(x) active=x end,
 stopAllSpam=function() active=false; manual=false end,recordTransition=function() end,recordError=function(_,e) error(e) end,
 trackCharacter=function() end,untrackCharacter=function() end,apiVersion=function() return 1 end}
local parry={getRadius=function(_,factor) return {fullRadius=10+100*.3*(factor or 1)} end}
local dash={setHandler=function() end,tick=function() end}
local f=module
setfenv(f,setmetatable({typeof=typeof},{__index=getfenv()}))
local clash=f()
assert(clash.setup({Utils=utils,GameInfo=info,AutoParry=parry,Dash=dash}))
assert(clash.bindCharacter(character))
local function event(id, dt)
 t+=dt; seq+=1; target=id; snapshot.targetId=id; snapshot.targeted=id==42; snapshot.syncSequence=seq
 clash.onBallSync({Sequence=seq,TargetPlayerID=id,Speed=100,ServerTime=t})
end
local function frame(dt) t+=dt; heartbeat() end
event(42,0); event(7,.01); event(42,.1)
assert(clash.isActive() and active,'valid target return should activate')
snapshot.position=v(-60); frame(.01); assert(not clash.isActive() and not active,'exit window should stop')
snapshot.position=v(-20); frame(.01); assert(clash.isActive() and active,'window return should resume')
event(7,.01); frame(.25); assert(clash.isActive() and active,'nearby partner must keep spam even during a long target switch')
event(42,.01); assert(clash.isActive() and active,'return from partner should keep clash')
thirdRoot.Position=v(15); event(9,.01); frame(.25)
assert(clash.isActive() and active,'nearby third target must keep spam')
event(7,.01); assert(clash.isActive() and active,'nearby switch from third to partner must keep clash')
thirdRoot.Position=v(100); event(9,.01); assert(not clash.isActive() and not active,'distant redirect should stop immediately')
event(42,.01); frame(.01); assert(not clash.isActive(),'distant redirect must not rearm on next target')
clash.teardown()
print('Auto Clash runtime: PASS')
'''
output.write_text(pre + source + post)
