"""Generate behavioral tests for the Auto Deflexo Feroz controller."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/extras/autofierce.luau").read_text()
source = source.replace("return AutoFierce\n", "return {api=AutoFierce, step=step, generation=function() return generation end}\n")
pre = '''local mt={}
mt.__index=function(t,k) if k=="Magnitude" then return math.abs(t.x) elseif k=="Dot" then return function(a,b) return a.x*b.x end end end
mt.__sub=function(a,b) return setmetatable({x=a.x-b.x},mt) end
local function vec(x) return setmetatable({x=x},mt) end
local Vector3={zero=vec(0)}
local function typeof(x) if getmetatable(x)==mt then return "Vector3" end return type(x) end
local function module()
'''
post = '''
end
local function scenario()
 local t=10; local mod=module(); local calls={}; local manual=true; local automatic=true
 local config={AutoFierceDeflect=true,AutoClash=true,ClashBallVisible=true}
 local cooldown={known=true,active=true,blocking=true,lastEventAt=9.5,endsAt=10.95,attempt={expired=true,deadline=9.9}}
 local ball={targetId=42,targeted=true,teleported=false,syncSequence=3,position=vec(-78.5),velocity=vec(100)}
 local ability={IsAvailable=function() return true end,IsOwnerAlive=function() return true end}
 local root={Parent={},Position=vec(0)}; local character={Parent={},FindFirstChild=function() return root end}
 local signal={Connect=function(_,fn) return {Disconnect=function() end} end}
 local utils={isActive=function() return true end,getConfigValue=function(k) return config[k] end,getLocalPlayer=function() return {UserId=42} end,
  getRunService=function() return {PostSimulation=signal} end,now=function() return t end,
  setConfig=function(p) calls[#calls+1]="config"; for k,v in pairs(p) do config[k]=v end; if config.afterStop then config.afterStop() end; return true end,
  stopAllSpam=function() calls[#calls+1]="stop"; manual=false; automatic=false end,
  isSpamActive=function() return manual or automatic end,recordError=function(_,e) error(e) end,trackCharacter=function() end,untrackCharacter=function() end}
 local info={getDeflectCooldownState=function() return cooldown end,getDeflectUICooldown=function() return .95 end,getSyncData=function() return {Teleported=false} end,
  getSnapshot=function() return ball end,isSnapshotValid=function(s) return s~=nil end,getSyncSequence=function() return 3 end,
  getRootPosition=function(r) return r.Position end,getBallSpeedLimits=function() return 16,600 end,getLocalPing=function() return .05 end,
  getFierceDeflectAbility=function() return ability end,noteFierceDeflectActivation=function() end,activateFierceDeflect=function(a)
   assert(a==ability and not utils.isSpamActive() and config.AutoClash==true, "must stop spam without disabling AutoClash")
   calls[#calls+1]="fierce"; return true
  end}
 local parry={getTiming=function(s) return {approaching=s.velocity.x>0,distance=math.abs(s.position.x),speed=math.abs(s.velocity.x),parryRadius=45,noWindowParryRadius=8.5} end}
 local clash={stopSpam=function() calls[#calls+1]="clash"; if config.afterStop then config.afterStop() end end}
 local spam={resetState=function() calls[#calls+1]="invalidate" end}
 mod.api.setup({Utils=utils,GameInfo=info,AutoParry=parry,AutoClash=clash,Spam=spam}); assert(mod.api.bindCharacter(character))
 local function step() mod.step(root,mod.generation()) end
 local function packet() mod.api.onBallSync({Source="packet",TargetPlayerID=42}) end
 return {step=step,packet=packet,calls=calls,config=config,cooldown=cooldown,ball=ball,ability=ability,info=info,parry=parry,advance=function(v) t=v end}
end
do
 local s=scenario(); s.step()
 assert(table.concat(s.calls,",")=="stop,invalidate,clash,fierce", "stop order")
 assert(s.config.AutoClash==true, "Fierce must preserve the AutoClash setting")
 assert(s.config.ClashBallVisible==true, "mini visibility changed")
 s.step(); assert(#s.calls==4, "duplicate ability request")
end
do local s=scenario(); s.info.getDeflectUICooldown=function() return 0 end; s.step(); assert(#s.calls==0,"ready UI must not spend ability") end
do local s=scenario(); s.info.getDeflectUICooldown=function() return nil end; s.step(); assert(#s.calls==0,"unavailable UI must not spend ability") end
do local s=scenario(); s.cooldown.attempt=nil; s.info.getDeflectUICooldown=function() return .18 end; s.step(); assert(#s.calls==0,"UI cooldown ending in time must not spend ability") end
do local s=scenario(); s.cooldown.attempt={expired=false,deadline=11}; s.step(); assert(#s.calls==0,"active normal deflect window could still protect") end
do local s=scenario(); s.cooldown.active=false; s.cooldown.attempt={expired=false,deadline=10.3}; s.packet(); assert(#s.calls==4,"incoming packet should trigger fierce when cooldown exceeds impact") end
do local s=scenario(); s.cooldown.active=false; s.cooldown.attempt=nil; s.packet(); assert(#s.calls==4,"blocking server cooldown must protect on target return without a previous attempt") end
do local s=scenario(); s.cooldown.active=false; s.cooldown.attempt=nil; s.cooldown.endsAt=nil; s.cooldown.remaining=0; s.info.getDeflectUICooldown=function() return 1 end; s.packet(); assert(#s.calls==4,"UI cooldown must take precedence over cooldown estimates") end
do local s=scenario(); s.cooldown.attempt=nil; s.info.getDeflectUICooldown=function() return .1 end; s.packet(); assert(#s.calls==0,"UI cooldown ending before impact must not trigger fierce") end
do local s=scenario(); s.ball.velocity=vec(0); s.parry.getTiming=function() return {approaching=true,distance=78.5,speed=100,velocity=vec(100),parryRadius=45,noWindowParryRadius=8.5} end; s.packet(); assert(#s.calls==4,"measured current velocity must be used when snapshot velocity is stale") end
do local s=scenario(); s.ball.targetId=7; s.step(); assert(#s.calls==0,"different target") end
do local s=scenario(); s.ball.syncSequence=2; s.step(); assert(#s.calls==0,"stale target snapshot") end
do local s=scenario(); s.ball.position=vec(-600); s.step(); assert(#s.calls==0,"impact outside ability duration") end
do local s=scenario(); s.ball.velocity=vec(-100); s.step(); assert(#s.calls==0,"ball moving away") end
do local s=scenario(); s.ball.teleported=true; s.step(); assert(#s.calls==0,"teleport") end
do local s=scenario(); s.ability.IsAvailable=function() return false end; s.step(); assert(#s.calls==0,"ability on cooldown") end
do local s=scenario(); s.config.afterStop=function() s.info.getDeflectUICooldown=function() return 0 end end; s.step(); assert(#s.calls==3,"must recheck after stopping") end
do local s=scenario(); s.config.afterStop=function() s.ball.targetId=7 end; s.step(); assert(#s.calls==3,"target change must cancel ability") end
print("AutoFierce cooldown, threat gates and stop ordering: PASS")
'''
output.write_text(pre + source + post)
