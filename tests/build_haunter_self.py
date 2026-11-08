from pathlib import Path
import sys
root, output=Path(sys.argv[1]),Path(sys.argv[2])
source=(root/'exodus hub/modules/logic/autospam.luau').read_text()
script=r'''
local V={}
V.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end return V[k] end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},V) end
local function cf(x) return {kind="CFrame",Position=vec(x)} end
function typeof(v) if getmetatable(v)==V then return "Vector3" elseif type(v)=="table" and v.kind=="CFrame" then return "CFrame" end return type(v) end
math.clamp=function(v,a,b) return math.min(b,math.max(a,v)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local function signal()
 local s={}; function s:Connect(fn) local c={Connected=true,fn=fn}; function c:Disconnect() self.Connected=false end; self.connection=c; return c end
 function s:emit(...) if self.connection and self.connection.Connected then self.connection.fn(...) end end
 return s
end
local now=1; local automatic=false; local target=7
local rootPart={Parent={},Position=vec(-100),IsA=function(_,x) return x=="BasePart" end}
local char={Parent={},AncestryChanged=signal(),ChildAdded=signal()}
function char:FindFirstChild(n) if n=="HumanoidRootPart" then return rootPart end end
function char:FindFirstChildOfClass() return nil end
function char:GetChildren() return {} end
local humanoid={Health=100}
local otherChar={Parent={},ChildAdded=signal()}
function otherChar:FindFirstChildOfClass() return humanoid end
function otherChar:GetChildren() return {} end
local me={UserId=42,Name="me",Character=char,CharacterAdded=signal()}
local enemy={UserId=7,Name="enemy",Character=otherChar,CharacterAdded=signal()}
local players={PlayerAdded=signal()}
function players:GetPlayers() return {me,enemy} end
function players:GetPlayerByUserId(id) if id==7 then return enemy elseif id==42 then return me end end
local heartbeat=signal(); local haunter={Parent={},OnClientEvent=signal()}
local snap={position=vec(7),velocity=vec(0),syncSpeed=600,speed=600,targetId=7,syncAt=1}
local utils={
 now=function() return now end,getPlayers=function() return players end,getLocalPlayer=function() return me end,
 getRunService=function() return {Heartbeat=heartbeat} end,isActive=function() return true end,
 getConfigValue=function(k) return k=="AutoSpam" end,isManualSpamActive=function() return false end,
 setManualSpamActive=function() end,setAutoSpamActive=function(v) automatic=v end,recordTransition=function() end,
 trackCharacter=function() end,untrackCharacter=function() end,
}
local info={
 getHaunterEvent=function() return haunter end,getTargetId=function() return target end,
 getPlayerMotion=function(id) if id==7 then return vec(7) elseif id==42 then return rootPart.Position end end,
 getPlayerDistance=function() return (vec(7)-rootPart.Position).Magnitude end,
 getSnapshotAt=function() snap.targetId=target; return snap end,isSnapshotValid=function() return true end,
 getBallSpeedLimits=function() return 16,600 end,getLocalPing=function() return 0 end,
 getDeflectGeometry=function() return {fullRadius=8.5} end,
 getBallFrozen=function() return false end,areAbilitiesEnabled=function() return true end,getClashContext=function() return nil end,
}
local mod=assert(loadstring(SOURCE))()
assert(mod.setup({Utils=utils,GameInfo=info,AutoParry={tryRedirectReturn=function() return false end}}))
assert(mod.bindCharacter(char))
haunter.OnClientEvent:emit(cf(-100),cf(0))
assert(not automatic,"must wait for teleport when still far")
rootPart.Position=vec(0); now=1.05; heartbeat:emit()
assert(automatic,"own Haunter must activate after the teleport")
mod.teardown()
automatic=false; target=42; now=2; rootPart.Position=vec(0); snap.syncAt=2
assert(mod.setup({Utils=utils,GameInfo=info,AutoParry={tryRedirectReturn=function() return false end}}))
assert(mod.bindCharacter(char))
haunter.OnClientEvent:emit(cf(70),cf(7))
assert(automatic,"opponent Haunter must still activate")
mod.teardown()
automatic=false; target=42; now=3; rootPart.Position=vec(-100); snap.syncAt=3
assert(mod.setup({Utils=utils,GameInfo=info,AutoParry={tryRedirectReturn=function() return false end}}))
assert(mod.bindCharacter(char))
haunter.OnClientEvent:emit(cf(-100),cf(0))
rootPart.Position=vec(0); now=3.05; heartbeat:emit()
assert(automatic,"own Haunter must activate when target already returned to local player")
mod.teardown()
print("Own and opponent Haunter events: PASS")
'''
output.write_text(script.replace('SOURCE','[========['+source+']========]',1))

