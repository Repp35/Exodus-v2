"""Exercise Olympia's Shared paths, abilities, ball packets and deflect geometry."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:3])
source = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
source = source.replace('require(module)', 'testRequire(module)').replace('require(network)', 'testRequire(network)').replace('Vector3.new(', 'testVector3(')
source = source.replace('return GameInfo\n', 'return GameInfo, function(u,p,w) utils=u; players=p; world=w end\n')
remote = (root / 'exodus hub/modules/logic/remote.luau').read_text()
script = r'''
function testVector3(x,y,z) return {X=x,Y=y,Z=z} end
function testRequire(module) return module.export end
local function node(children)
 return {FindFirstChild=function(_,name) return children[name] end, WaitForChild=function(_,name) return assert(children[name], name) end, IsA=function() return false end}
end
local function mod(value) return {export=value,IsA=function(_,kind) return kind=="ModuleScript" end} end
local calls=0
local ability={Deflect=function() calls+=1 end,GetParryRange=function() return 8.5 end,ClickInstances={}}
local abilities=mod({Abilities={[1]=ability}})
local ball=mod({GameBall={GetBaseSpeed=function() return 16 end,GetMaxSpeed=function() return 600 end,
 IsInClash=function() return true end,GetClashMinWindow=function() return .32 end}})
local replicator=mod({BallReplicator={syncData={TargetPlayerID=42}}})
local signal={}
local event={IsA=function(_,kind) return kind=="RemoteEvent" end,OnClientEvent=signal}
local netmod=mod({Network={new=function() return {ok=true} end}})
local generated=node({["RE_5.520474058077904e+76"]=event,["RE_9.611859444202098e+76"]=event,["RE_9.150098456648103e+76"]=event})
local shared=node({Abilities=node({ClientAbilities=abilities}),Gameplay=node({GameBall=ball,BallReplicator=node({BallReplicator=replicator})}),Network=node({GeneratedNetworkRemotes=generated,Network=netmod})})
local legacyAbility=mod({Abilities={[1]={Deflect=function() calls+=10 end}}})
local legacy=node({ClientAbilities=legacyAbility})
local currentRoot=shared
local storage={FindFirstChild=function(_,name) if name=="Shared" then return currentRoot==shared and shared or nil elseif name=="TS" then return currentRoot==legacy and legacy or nil end end}
local player={UserId=42,GetAttribute=function(_,name) if name=="DeflectRange" then return 16 end end}
local opponent={UserId=7,GetAttribute=function(_,name) if name=="DeflectRange" then return 16 end end}
local players={LocalPlayer=player,GetPlayerByUserId=function(_,id) if id==42 then return player elseif id==7 then return opponent end end}
local world={GetAttribute=function() return nil end}
local info,inject=assert(loadstring(SOURCE_INFO))(); inject({getReplicatedStorage=function() return storage end},players,world)
assert(info.getDeflectAbility()==ability, "Shared.Abilities.ClientAbilities must resolve")
local remote=assert(loadstring(SOURCE_REMOTE))(); assert(remote.setup({GameInfo=info})); assert(remote.fireParry() and calls==1, "deflect must use game ability")
assert(info.getSyncData().TargetPlayerID==42, "Shared.Gameplay.BallReplicator must resolve")
assert(info.getHaunterEvent()==event and info.getDeflectServerEvents().cooldown==signal, "Shared.Network events must resolve")
assert(info.createCrateNetwork().ok, "Shared.Network.Network must resolve")
local low,high=info.getBallSpeedLimits(); assert(low==16 and high==600)
assert(math.abs(info.getDeflectWindow(600)-.32)<.0001, "Olympia does not add range to the deflect time")
local _,_,step=info.getDeflectRangeParameters(); assert(step==.1125)
info.getClashContext=function() return {partnerId=7} end
info.getPlayerDistance=function() return 20 end
assert(info.getDeflectRange()==8.5 and info.getPlayerDeflectRange(7)==8.5 and info.getPlayerDeflectRange(42)==8.5, "close rally must use base range")
info.getPlayerDistance=function() return 30 end
assert(info.getDeflectRange()==16 and info.getPlayerDeflectRange(7)==16, "outside close rally retain published range")
ability.ClickInstances={{Time=.95}}
assert(os.clock()-info.getLastDeflectPressAt()<.051, "recent clicks must be tracked without LastPressClock")
ability.ClickInstances={}
local b=buffer.create(96); buffer.writeu16(b,1,21); buffer.writef64(b,3,1234); buffer.writef32(b,35,600); buffer.writef32(b,43,600); buffer.writef64(b,55,7); buffer.writef64(b,63,42); buffer.writef32(b,92,.1)
local packet=info.decodeBallPacket(b); assert(packet.Sequence==21 and packet.TargetPlayerID==7 and packet.Speed==600, "96-byte Olympia packets must decode")
currentRoot=legacy
assert(info.getDeflectAbility()==legacyAbility.export.Abilities[1] and remote.fireParry() and calls==11, "legacy TS layout must still work")
print("Olympia compatibility: PASS")
'''
output.write_text(script.replace('SOURCE_REMOTE', '[========[' + remote + ']========]', 1).replace('SOURCE_INFO', '[========[' + source + ']========]', 1))
