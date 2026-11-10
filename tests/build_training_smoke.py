from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:3])
source=(root/'exodus hub/modules/logic/gameinfo.luau').read_text().replace('typeof(', 'testTypeof(')
source=source.replace('return GameInfo\n','return GameInfo, function(u,p,w,s) utils=u; players=p; world=w; trainingState=s end\n')
remote=(root/'exodus hub/modules/logic/remote.luau').read_text()
script=r'''
local V={}
V.__index=function(v,k) if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end return V[k] end
V.__add=function(a,b) return setmetatable({X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z},V) end
V.__mul=function(a,n) return setmetatable({X=a.X*n,Y=a.Y*n,Z=a.Z*n},V) end
V.__div=function(a,n) return a*(1/n) end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},V) end
function testTypeof(v) if getmetatable(v)==V then return "Vector3" elseif type(v)=="table" and v.instance then return "Instance" end return typeof(v) end
local function node(c) return {FindFirstChild=function(_,n) return c[n] end} end
local root={Parent=true,Position=vec(0)}
local char={FindFirstChild=function(_,n) if n=="HumanoidRootPart" then return root end end}
local player={UserId=42,Character=char,GetAttribute=function() return 0 end}
local players={LocalPlayer=player}
local trainingBall={instance=true,Parent=true,IsA=function(_,n) return n=="BasePart" end}
local zone={Size=vec(100,100,100),CFrame={PointToObjectSpace=function(_,p) return p end},IsA=function(_,n) return n=="BasePart" end}
local training=node({Areas=node({Zone=zone}),TrainingClient=node({TrainingBall=trainingBall})})
local sent=0
local block={IsA=function(_,n) return n=="RemoteEvent" end,FireServer=function(_,position,look) sent+=1; assert(position.X==2 and look.Z==1) end}
local receiver
local signal={Connect=function(_,fn) receiver=fn; return {Connected=true,Disconnect=function() end} end}
local ballRemote={instance=true,Parent=true,IsA=function(_,n) return n=="UnreliableRemoteEvent" end,OnClientEvent=signal}
local storage=node({Training=node({Remotes=node({Block=block,BallState=ballRemote})})})
local world={FindFirstChild=function(_,n) if n=="Training" then return training end end,GetAttribute=function() return nil end,GetServerTimeNow=function() return 100 end,CurrentCamera={CFrame={Position=vec(2),LookVector=vec(0,0,1)}}}
local info,inject=assert(loadstring(SOURCE_INFO))(); inject({getReplicatedStorage=function() return storage end,now=os.clock,trackGlobal=function() end,untrackGlobal=function() end},players,world,nil)
info.bindBallSync(function() end); assert(receiver, "training ball listener must connect")
receiver(vec(10),vec(-20),99.9,42,nil,20)
assert(info.isTrainingArea())
local snap=info.getSnapshotAt(os.clock()); assert(snap.mode=="training" and snap.targeted and snap.targetId==42 and math.abs(snap.position.X-8)<.001 and info.isSnapshotValid(snap))
assert(math.abs(info.getMinimumSpamInterval()-1/16)<.0001)
local remote=assert(loadstring(SOURCE_REMOTE))(); assert(remote.setup({GameInfo=info}) and remote.fireParry() and sent==1)
receiver(vec(10),vec(-20),99.91,0,"target",20); snap=info.getSnapshotAt(os.clock()); assert(snap.targetId==-1 and not snap.targeted)
assert(info.getSnapshotAt(os.clock()+1)==nil, "stale ball must not be used")
root.Position=vec(100); assert(not info.isTrainingArea() and not info.fireTrainingParry())
print("Training snapshot and parry: PASS")
'''
out.write_text(script.replace('SOURCE_REMOTE','[========['+remote+']========]',1).replace('SOURCE_INFO','[========['+source+']========]',1))
