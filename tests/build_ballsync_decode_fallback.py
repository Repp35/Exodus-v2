"""Exercise binary ball packets with and without the game's decoder."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:3])
source = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
source = source.replace('Vector3.new(', 'testVector3(').replace('require(module)', 'testRequire(module)')
source = source.replace('return GameInfo\n', 'return GameInfo, function(u) utils = u end\n')
script = r'''
function testVector3(x,y,z) return {X=x,Y=y,Z=z} end
local module=nil
local folder={IsA=function() return false end, FindFirstChild=function(_,name) return name=="BallReplicator" and module end}
local ts={FindFirstChild=function(_,name) return name=="BallReplicator" and folder end}
local storage={FindFirstChild=function(_,name) return name=="TS" and ts end}
function testRequire(value)
 if value.failure then error("not ready") end
 return value.export
end
local info,inject=assert(loadstring(SOURCE))()
inject({getReplicatedStorage=function() return storage end})
local function packet(seq,target,flags)
 local b=buffer.create(92)
 buffer.writeu8(b,0,flags or 0); buffer.writeu16(b,1,seq); buffer.writef64(b,3,1234.5)
 buffer.writef32(b,11,10); buffer.writef32(b,15,20); buffer.writef32(b,19,30)
 buffer.writef32(b,23,1); buffer.writef32(b,35,600); buffer.writef32(b,39,7); buffer.writef32(b,43,600)
 buffer.writef64(b,55,target); buffer.writef64(b,63,42); buffer.writef64(b,83,7)
 return b
end
local b=packet(65535,7,47)
local d=info.decodeBallPacket(b)
assert(d.Sequence==65535 and d.ServerTime==1234.5 and d.TargetPlayerID==7 and d.HighlightTargetPlayerID==42)
assert(d.RealPosition.X==10 and d.RealPosition.Y==20 and d.RealPosition.Z==30 and d.Speed==600)
assert(d.Teleported and d.Locked and d.Grace and d.OldGrace and d.PossessorId==7)
assert(info.applyPacket(info.decodeBallPacket(packet(65535,7))), "fallback packet must update state")
assert(info.applyPacket(info.decodeBallPacket(packet(0,42))), "wrapped next packet must update state")
assert(not info.applyPacket(info.decodeBallPacket(packet(65534,7))), "out-of-order packets must be ignored")
assert(info.decodeBallPacket(buffer.create(91))==nil and info.decodeBallPacket({})==nil)
local bad=packet(1,7); buffer.writef32(bad,35,0/0); assert(info.decodeBallPacket(bad)==nil)
bad=packet(1,7); buffer.writef32(bad,15,math.huge); assert(info.decodeBallPacket(bad)==nil)
bad=packet(1,7); buffer.writef32(bad,35,-1); assert(info.decodeBallPacket(bad)==nil)
module={IsA=function() return true end,failure=true}
assert(info.decodeBallPacket(packet(3,42)).Sequence==3, "unavailable module should use fallback")
assert(info.getSyncSequence()==0, "a require failure must not break subsequent packet processing")
module={IsA=function() return true end,export={BallReplicator={}}}
assert(info.decodeBallPacket(packet(4,42)).Sequence==4, "missing Decode should use fallback")
module={IsA=function() return true end,export={BallReplicator={Decode=function() error("unavailable") end}}}
assert(info.decodeBallPacket(packet(5,42)).Sequence==5, "failing Decode should use fallback")
module={IsA=function() return true end,export={BallReplicator={Decode=function() return {seq=6,serverTime=1,targetId=99,speed=20} end}}}
assert(info.decodeBallPacket(packet(5,42)).TargetPlayerID==99, "game decoder should remain preferred")
print("BallSync decoder fallback: PASS")
'''
output.write_text(script.replace('SOURCE', '[========[' + source + ']========]', 1))
