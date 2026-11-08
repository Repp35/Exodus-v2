"""Build motion/sequence scenarios for the actual GameInfo module."""
from pathlib import Path
import sys
root = Path(sys.argv[1]); out = Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
pre = r'''
local testClock=0
local os=setmetatable({clock=function() return testClock end},{__index=os})
local mt={}
mt.__index=function(v,k) if k=='Magnitude' then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end end
mt.__add=function(a,b) return setmetatable({X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z},mt) end
mt.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},mt) end
mt.__mul=function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},mt) end
mt.__div=function(a,b) return a*(1/b) end
math.clamp=function(v,a,b) return math.max(a,math.min(b,v)) end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},mt) end
local Vector3={zero=vec(0)}
local function typeof(value) if getmetatable(value)==mt then return 'Vector3' elseif type(value)=='table' and value.instance then return 'Instance' elseif type(value)=='table' and value.kind=='Color3' then return 'Color3' end return type(value) end
local parent={}
local ball={instance=true,Parent=parent,Name='GameBall',Position=vec(0),AssemblyLinearVelocity=vec(0),IsA=function(_,kind) return kind=='BasePart' end}
local sync={TargetPlayerID=42,HighlightTargetPlayerID=42,Speed=100,Teleported=false,OldGrace=true}
local pingValue, rangeValue=.5,8.5
local highlight={Enabled=false}
local char={FindFirstChild=function(_,name) if name=='PlayerBallHighlight' then return highlight end end}
local player={UserId=42,Character=char,GetAttribute=function() return rangeValue end,GetNetworkPing=function() return pingValue end}
local frameCallback
local heartbeat={Connect=function(_,fn) frameCallback=fn; return {Disconnect=function() end} end}
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
assert(info.setup({Utils={now=os.clock,apiVersion=function() return 1 end,getPlayers=function() return {LocalPlayer=player} end,getReplicatedStorage=function() return storage end,getWorkspace=function() return workspace end,getRunService=function() return {Heartbeat=heartbeat} end,trackGlobal=function() end,untrackGlobal=function() end}}))
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
local packet=info.decodeBallPacket({seq=102,serverTime=123.5,teleported=false,locked=true,grace=false,oldGrace=true,targetId=7,highlightId=7,position=vec(5),speed=100})
assert(packet.Sequence==102 and packet.ServerTime==123.5 and packet.TargetPlayerID==7 and packet.OldGrace and packet.Locked, 'packet mapping')
assert(not info.isSnapshotValid({ball=ball,position=vec(0),velocity=vec(0),speed=0/0,targetId=42,targeted=true}), 'NaN speed accepted')
local newest={Sequence=102,TargetPlayerID=7,Speed=100,Teleported=false,Locked=true}
assert(info.applyPacket(newest), 'new packet should be accepted immediately')
assert(info.getTargetId()==7 and info.getSyncSequence()==102 and info.getSnapshotAt(1.3).targetId==7, 'snapshot must use the newest packet before provider refresh')
assert(info.getSnapshotAt(1.3).locked == true, 'locked packet was lost')
assert(not info.applyPacket({Sequence=101,TargetPlayerID=42}), 'older packets must not replace the target')
provider.lastSeq=102; sync.TargetPlayerID=7
assert(info.getSyncData()==sync and info.getSyncSequence()==102, 'provider should resume when it catches up')
provider.lastSeq=65535
assert(info.applyPacket({Sequence=0,TargetPlayerID=42,Speed=100}), 'wrapped sequence must be accepted')
assert(info.getTargetId()==42, 'wrapped packet must update target')
local meanGeometry=info.getDeflectGeometry(100, .2, .4, false, .08)
local rawGeometry=info.getDeflectGeometry(100, .2, .4, false)
assert(math.abs(meanGeometry.pingRadius-3.2)<.0001 and math.abs(rawGeometry.pingRadius-20)<.0001, 'ping override must only affect callers that provide it')
rangeValue=16
local withRes=info.getDeflectGeometry(600,.2,.8,false,.1)
local noRes=info.getDeflectGeometry(600,.2,.8,false,.1,{resilience=false})
local noPing=info.getDeflectGeometry(600,.2,.8,false,.1,{resilience=false,ping=false})
local legacyFlag=info.getDeflectGeometry(600,.2,.8,true,.1)
assert(math.abs(withRes.fullRadius-160)<.001 and math.abs(noRes.fullRadius-152.5)<.001, 'physical radius or resilience was scaled')
assert(math.abs(legacyFlag.fullRadius-withRes.fullRadius)<.001, 'legacy flag must not scale the physical radius')
assert(math.abs(noPing.fullRadius-104.5)<.001 and noPing.pingRadius==0, 'ping exclusion')
assert(math.abs(info.getProjectedDeflectRadius(noRes,100)-32.5)<.001, 'projected closing speed')
local close=info.getDeflectGeometry(600,0,1,false,.1,{resilience=false})
assert(math.abs(close.fullRadius-68.5)<.001, 'zero-window geometry')
rangeValue=8.5
local slow=info.getDeflectGeometry(16,'ap',.4,false,0)
local fast=info.getDeflectGeometry(600,'ap',.4,false,0)
assert(math.abs(slow.effectiveWindow-.18)<.0001 and math.abs(fast.effectiveWindow-.10)<.0001, 'AP window must remain unchanged')
local clashGeometry=info.getDeflectGeometry(600,'game',.8,false,0)
local exactGame=info.getDeflectGeometry(600,'game',.8,false,0,{minimumWindow=0})
assert(math.abs(clashGeometry.deflectWindow-.25)<.0001 and math.abs(exactGame.deflectWindow-.2)<.0001, 'window minimum and override')
testClock=1; sync.TargetPlayerID=42; sync.HighlightTargetPlayerID=42
assert(info.getSnapshotAt(2).targetId==42, 'authoritative target')
sync.TargetPlayerID=-1; sync.HighlightTargetPlayerID=7
local uncertain=info.getSnapshotAt(2)
assert(uncertain.targetId==42 and uncertain.targetUncertain, 'weak target changed in first observation')
assert(info.getSnapshotAt(2).targetId==42, 'weak target changed twice in one frame')
frameCallback()
local confirmed=info.getSnapshotAt(2)
assert(confirmed.targetId==7 and not confirmed.targetUncertain, 'stable highlight did not update')
sync.TargetPlayerID=42; sync.Locked=true
local locked=info.getSnapshotAt(2)
assert(locked.targeted and locked.locked and not locked.ballCanMove, 'locked is not target identity')
sync.TargetPlayerID=-1; sync.HighlightTargetPlayerID=-1; sync.Locked=false; highlight.Enabled=true
ball.Color={kind='Color3',R=1,G=0,B=0}
local pending=info.getSnapshotAt(2)
assert(pending.targetSignals.redBall and pending.targetSignals.visualTargeted, 'visual evidence missing')
frameCallback()
assert(info.getSnapshotAt(2).targetId==42, 'stable visual highlight missing')
highlight.Enabled=false; testClock=2
frameCallback()
assert(info.getSnapshotAt(2).targetId==-1, 'red color alone must not fabricate a target')
pingValue=.1; testClock=2.5; local p1,raw1,n1=info.getAveragePing()
pingValue=.2; testClock=2.76; local p2,raw2,n2=info.getAveragePing()
assert(math.abs(p2-(.5+.1+.2)/3)<.0001 and raw1==.1 and raw2==.2 and n2==3, 'rolling mean not used')
assert(n1==2 and p1>.1, 'average discarded previous sample')
print('GameInfo motion and packet scenarios: PASS')
'''
out.write_text(pre+source+post, encoding='utf-8')

