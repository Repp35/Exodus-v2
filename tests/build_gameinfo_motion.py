"""Build motion/sequence scenarios for the actual GameInfo module."""
from pathlib import Path
import sys
root = Path(sys.argv[1]); out = Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
pre = r'''
local mt={}
mt.__index=function(v,k) if k=='Magnitude' then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end end
mt.__add=function(a,b) return setmetatable({X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z},mt) end
mt.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},mt) end
mt.__mul=function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},mt) end
mt.__div=function(a,b) return a*(1/b) end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},mt) end
local Vector3={zero=vec(0)}
local function typeof(value) if getmetatable(value)==mt then return 'Vector3' elseif type(value)=='table' and value.instance then return 'Instance' end return type(value) end
local parent={}
local ball={instance=true,Parent=parent,Name='GameBall',Position=vec(0),AssemblyLinearVelocity=vec(0),IsA=function(_,kind) return kind=='BasePart' end}
local sync={TargetPlayerID=42,HighlightTargetPlayerID=42,Speed=100,Teleported=false,OldGrace=true}
local provider={hasState=true,lastSeq=100,syncData=sync}
provider.Decode=function(_,packet) return packet end
local moduleScript={instance=true,IsA=function(_,kind) return kind=='ModuleScript' end}
local folder={IsA=function() return false end,FindFirstChild=function(_,n) if n=='BallReplicator' then return moduleScript end end}
local ts={FindFirstChild=function(_,n) if n=='BallReplicator' then return folder end end}
local storage={FindFirstChild=function(_,n) if n=='TS' then return ts end end}
local workspace={FindFirstChild=function(_,n) if n=='GameBall' then return ball end end, GetAttribute=function() return nil end}
local function require(object) assert(object==moduleScript); return {BallReplicator=provider} end
local function module()
'''
post=r'''
end
local info=module()
assert(info.setup({Utils={now=os.clock,apiVersion=function() return 1 end,getPlayers=function() return {LocalPlayer={UserId=42}} end,getReplicatedStorage=function() return storage end,getWorkspace=function() return workspace end}}))
local first=info.getSnapshotAt(1)
assert(first.speed==0 and first.targeted and first.syncSequence==100)
assert(info.isSnapshotValid(first))
ball.Position=vec(100/60); local moving=info.getSnapshotAt(1+1/60)
assert(math.abs(moving.speed-100)<0.001 and moving.velocity.X>0, 'motion estimate')
local sameFrame=info.getSnapshotAt(1+1/60+0.001)
assert(math.abs(sameFrame.speed-moving.speed)<0.001, 'same frame changed speed')
ball.Position=vec(1000); local outlier=info.getSnapshotAt(1+2/60)
assert(outlier.speed==0, 'outlier reused as velocity')
ball.Position=vec(1000+100/60); local recovered=info.getSnapshotAt(1+3/60)
assert(math.abs(recovered.speed-100)<0.001, 'failed to recover velocity')
local stopped=info.getSnapshotAt(1+0.2)
assert(stopped.speed==0, 'stale speed retained while stopped')
sync.Teleported=true; provider.lastSeq=101; ball.Position=vec(-50)
local reset=info.getSnapshotAt(1.25)
assert(reset.speed==0 and reset.teleported and reset.syncSequence==101, 'teleport must reset sample')
sync.Teleported=false; ball.Position=vec(-48.333333333)
local after=info.getSnapshotAt(1.25+1/60)
assert(after.speed>99 and after.speed<101, 'movement after teleport blocked')
local packet=info.decodeBallPacket({seq=102,serverTime=123.5,teleported=false,grace=false,oldGrace=true,targetId=7,highlightId=7,position=vec(5),speed=100})
assert(packet.Sequence==102 and packet.ServerTime==123.5 and packet.TargetPlayerID==7 and packet.OldGrace, 'packet mapping')
assert(not info.isSnapshotValid({ball=ball,position=vec(0),velocity=vec(0),speed=0/0,targetId=42,targeted=true}), 'NaN speed accepted')
print('GameInfo motion and packet scenarios: PASS')
'''
out.write_text(pre+source+post, encoding='utf-8')
