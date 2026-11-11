from pathlib import Path
import subprocess
import os
import shutil
import tempfile
import unittest
root=Path(__file__).resolve().parents[2]
pre='''local time = 10
local os = { clock = function() return time end }
local function signal()
 local s = { callbacks = {} }
 function s:Connect(f) table.insert(self.callbacks,f); return { Disconnect=function() end, Connected=true } end
 function s:fire() for _,f in self.callbacks do f(1/60) end end
 return s
end
local V = {}; V.__index = function(v,k) if k == "Magnitude" then return math.abs(v.x) end; return V[k] end
local function vec(x) return setmetatable({x=x},V) end
V.__sub=function(a,b) return vec(a.x-b.x) end
function V:Dot(b) return self.x*b.x end
local Vector3 = {zero=vec(0)}
local function typeof(v) if getmetatable(v)==V then return "Vector3" end; return type(v) end
local post, heart = signal(), signal()
local root = {Parent=true,Position=vec(0),IsA=function() return true end}
local char = {Parent=true,AncestryChanged=signal(),ChildAdded=signal(),FindFirstChild=function() return root end,FindFirstChildOfClass=function() return {Health=100} end,GetChildren=function() return {} end}
local player = {UserId=1,Character=char,CharacterAdded=signal()}
local players = {GetPlayers=function() return {} end, GetPlayerByUserId=function() return player end, PlayerAdded=signal(),PlayerRemoving=signal()}
local spam, blocked, rejected, clicks, lastClick = false,false,false,0,0
local config = {AutoParry=true,AutoSpam=true}
local utils = {getLocalPlayer=function() return player end,getRunService=function() return {PostSimulation=post,Heartbeat=heart} end,getPlayers=function() return players end,getConfigValue=function(k) return config[k] end,isActive=function() return true end,isSpamActive=function() return spam end,isManualSpamActive=function() return false end,setAutoSpamActive=function(v) spam=v end,trackCharacter=function() end,untrackCharacter=function() end,recordTransition=function() end,recordError=function() end,now=function() return time end}
local snapshot = {ball={Parent=true},position=vec(30),velocity=vec(-100),speed=100,syncSpeed=100,targetId=1,syncSequence=1,syncAt=time,mode="match"}
local function geom(_,_,factor) return {fullRadius=100,noWindowParryRadius=10,deflectWindow=.1,effectiveWindow=.1,leadTime=.1,resilienceBonus=0,pureRadius=10,pingRadius=0} end
local gi = {getSnapshotAt=function() return snapshot end,isSnapshotValid=function() return true end,getDeflectCooldownState=function() return {blocking=blocked,remaining=0} end,getRootPosition=function() return root.Position end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=geom,getDeflectGeometry=geom,getProjectedDeflectRadius=function() return 20 end,getAutoSpamDelay=function() return 0 end,getLastDeflectPressAt=function() return lastClick end,getBallFrozen=function() return false end,isTrainingArea=function() return false end,getTargetId=function() return snapshot.targetId end,getBallSpeedLimits=function() return 16,600 end,getDeflectRangeParameters=function() return 10,2,.1 end,getPlayerDeflectRange=function() return 10 end,getPlayerRawRadius=function() return 10 end,getPlayerMotion=function() return vec(5) end,getPlayerDistance=function() return 5 end,isPlayerDashing=function() return false end,getHaunterEvent=function() return nil end,isClientDeflectResetLate=function() return false end,getClashContext=function() return nil end}
local remote = {fireParry=function(_,guard) if rejected or not guard() then return false end; clicks+=1; lastClick=time; return true end}
'''
ap=(root/'modules/logic/autoparry.luau').read_text()
sp=(root/'modules/logic/autospam.luau').read_text()
tests='''
assert(AP.setup({Utils=utils,GameInfo=gi,Remote=remote})); assert(AP.bindCharacter(char))
post:fire()
time+=.1; snapshot.position=vec(10); post:fire()
local p=AP.getPressure()
assert(math.abs(p.expectedClickAt-10.05)<.0001,"crossing time interpolated")
assert(math.abs(p.latestDelay-.05)<.0001,"actual minus expected")
assert(not p.high,"one late sample must not unlock spam")
local function resetAP()
 post.callbacks={}; AP.bindCharacter(char); snapshot.targetId=1; snapshot.syncSequence+=1; snapshot.position=vec(10); snapshot.locked=false
end
resetAP(); blocked=true; post:fire(); time+=.12; post:fire()
p=AP.getPressure(); assert(p.high and p.samples==0 and p.pendingDelay>=.119,"cooldown delay creates live pressure")
blocked=false; post:fire(); assert(AP.getPressure().samples==1,"accepted click recorded")
time+=4; assert(not AP.getPressure().high and AP.getPressure().samples==0,"old pressure expires")
resetAP(); rejected=true; post:fire(); time+=.12; post:fire(); assert(AP.getPressure().high,"failed click retains due time")
rejected=false; time+=.1; post:fire(); assert(AP.getPressure().latestDelay>=.219,"retry keeps original deadline")
resetAP(); blocked=true; post:fire(); time+=.12; snapshot.locked=true; post:fire(); assert(not AP.getPressure().high,"locked ball clears pressure")
blocked=false; resetAP(); snapshot.position=vec(10); post:fire(); assert(AP.getPressure().latestDelay==0,"on-time click has zero pressure")
-- Exercise AutoSpam through its public packet and lifecycle APIs.
local high=false
local pressure={getPressure=function() return {high=high} end}
local stats={get=function() return nil end,observe=function() end,finish=function() end,waitForNextClash=function() end}
local seq=100
local function freshSpam()
 spam=false; heart.callbacks={}; assert(SP.setup({Utils=utils,GameInfo=gi,AutoParry=pressure,ClashStats=stats})); assert(SP.bindCharacter(char))
end
local function packet(target,distance,locked)
 seq+=1; time+=.01; snapshot.targetId=target; snapshot.position=vec(distance); snapshot.syncAt=time; snapshot.locked=locked==true
 SP.onBallSync({Source="packet",Sequence=seq,TargetPlayerID=target,Speed=100,Locked=snapshot.locked})
end
freshSpam(); high=false; packet(2,8); packet(1,8); assert(not SP.isActive(),"nearby without pressure must not bypass exchange")
freshSpam(); high=true; packet(2,8.5); packet(1,8.5); assert(SP.isActive(),"high pressure uses 90 percent radius and permits nearby switch")
freshSpam(); high=true; packet(2,15); packet(1,15); assert(not SP.isActive(),"window-only proximity must not activate")
packet(1,8); assert(not SP.isActive(),"entering radius later must not create nearby switch")
freshSpam(); high=true; packet(2,8); packet(1,8,true); assert(not SP.isActive(),"locked ball cannot activate")
freshSpam(); high=true; packet(2,9.5); packet(1,9.5); assert(not SP.isActive(),"pressure increase remains bounded")
freshSpam(); high=false; packet(1,30); packet(2,30); packet(1,7); assert(SP.isActive(),"confirmed fast return still activates")
print("PASS: pressure timing, cooldown, retry, expiry, lock, low/high pressure, radius-only switch, bounded sensitivity and normal exchange")
'''
class PressureBehavior(unittest.TestCase):
    def test_pressure_and_activation(self):
        binary = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not binary:
            self.skipTest("Set LUAU_BIN to run Luau behavioral regressions")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "behavior.luau"
            path.write_text(pre+'\nlocal AP = (function()\n'+ap+'\nend)()\nlocal SP = (function()\n'+sp+'\nend)()\n'+tests)
            subprocess.run([binary, str(path)], check=True, capture_output=True, text=True)

if __name__ == "__main__":
    unittest.main()
