from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
source=(root/'exodus hub/modules/logic/autospam.luau').read_text()
source=source.replace('return AutoSpam\n','return AutoSpam, applyDeactivation, inspectTarget, evaluate, start, function(s,u,g,p,a) current=s; utils=u; gameInfo=g; localPlayer=p; autoParry=a end\n')
script=r'''
local V={}
V.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end return V[k] end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},V) end
function typeof(v) if getmetatable(v)==V then return "Vector3" end return type(v) end
math.clamp=function(v,a,b) return math.min(b,math.max(a,v)) end
local automatic=true
local otherDistance=20
local rootPart={Parent={},Position=vec(0)}
local state={root=rootPart,active=true,partner=7,target=42,lastSwitchAt=100,activatedAt=100,connections={}}
local snap={position=vec(-10,10,0),velocity=vec(0,100,0),targetId=99,syncSpeed=600,speed=600,syncAt=100.01}
local u={
 isActive=function() return true end,getConfigValue=function(k) return k=="AutoSpam" end,
 isManualSpamActive=function() return false end,setAutoSpamActive=function(v) automatic=v end,
 setManualSpamActive=function() end,recordTransition=function() end,now=function() return 100.01 end,
}
local g={
 getBallFrozen=function() return false end,getBallSpeedLimits=function() return 16,600 end,
 getPlayerMotion=function(id) if id==7 then return vec(7) end end,
 getPlayerDistance=function(id) if id==99 then return otherDistance end return 7 end,
 getDeflectWindow=function() return .2 end,
 getDeflectGeometry=function() return {fullRadius=30} end,
 getLocalPing=function() return 0 end,isSnapshotValid=function() return true end,
 getClashContext=function() return nil end,getSnapshotAt=function() return snap end,
}
local returnCalls,lastReturnTarget=0,nil
local ap={tryRedirectReturn=function(value) lastReturnTarget=value.targetId; returnCalls=returnCalls+1; return true end}
local mod,apply,inspect,evaluate,start,inject=assert(loadstring(SOURCE))()
inject(state,u,g,{UserId=42},ap)
assert(not apply(state,snap,100.01,nil,true) and automatic, "nearby third target must not stop")
otherDistance=80
assert(apply(state,snap,100.02,nil,true) and not automatic and state.reason=="distant_target", "far target must stop")
inspect(state,99,100.02,snap,nil)
snap.position=vec(-12); snap.velocity=vec(100); snap.syncAt=100.03
evaluate(state,100.03,true,nil,snap,false)
assert(returnCalls==1 and lastReturnTarget==99 and not automatic and state.returnParriedTarget, "return without local target must send one and hold spam")
start(state,"test",7,100.04,nil,snap)
assert(not automatic, "spam reactivated in the same target cycle")
inspect(state,7,100.05,snap,nil)
assert(not state.returnParriedTarget, "next target must release hold")
start(state,"test",7,100.06,nil,snap)
assert(automatic, "spam must be able to reactivate")
local s2={root=rootPart,active=true,partner=7,target=42,lastSwitchAt=101,activatedAt=101,connections={}}
inject(s2,u,g,{UserId=42},ap); automatic=true
snap.targetId=42; snap.position=vec(-10,10); snap.velocity=vec(0,100); snap.syncAt=101.01
assert(apply(s2,snap,101.01,nil,false) and s2.reason=="ball_diverted", "path away from both must stop")
snap.targetId=-1; snap.position=vec(-12); snap.velocity=vec(100); snap.syncAt=104
evaluate(s2,104,true,nil,snap,false)
assert(returnCalls==2 and lastReturnTarget==-1 and not automatic, "late return without target must still parry")
local s3={root=rootPart,active=true,partner=7,target=42,lastSwitchAt=100,activatedAt=100,connections={}}
inject(s3,u,g,{UserId=42},ap); automatic=true; otherDistance=80
snap.targetId=42; snap.position=vec(-10,10); snap.velocity=vec(0,100); snap.syncAt=100
mod.onBallSync({Source="packet",Sequence=50,TargetPlayerID=99,Speed=600})
assert(not automatic and s3.reason=="distant_target", "target packet must stop immediately")
print("Redirect, no-target return and reactivation: PASS")
'''
output.write_text(script.replace('SOURCE','[========['+source+']========]',1))
