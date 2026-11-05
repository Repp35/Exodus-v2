"""Build simulations for dash event delivery and lifecycle."""
from pathlib import Path
import sys
root=Path(sys.argv[1]); out=Path(sys.argv[2])
source=(root/'exodus hub/modules/logic/dash.luau').read_text(encoding='utf-8')
pre=r'''
local currentTime=1
local mt={}
mt.__index=function(v,k) if k=='Magnitude' then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end end
mt.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},mt) end
mt.__mul=function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},mt) end
mt.__div=function(a,b) return a*(1/b) end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},mt) end
local function typeof(v) if getmetatable(v)==mt then return 'Vector3' end return type(v) end
local task={spawn=function(fn,...) fn(...) end}
local function signal()
 local result={}
 function result:Connect(fn) self.callback=fn; return {Disconnect=function() end} end
 function result:Fire(...) if self.callback then self.callback(...) end end
 return result
end
local animationPlayed=signal()
local animator={AnimationPlayed=animationPlayed,GetPlayingAnimationTracks=function() return {} end}
local humanoid={FindFirstChildOfClass=function(_,n) if n=='Animator' then return animator end end}
local rootPart={Parent={},Position=vec(40),AssemblyLinearVelocity=vec(0)}
local character={Parent={},FindFirstChildOfClass=function(_,n) if n=='Humanoid' then return humanoid end end,
    FindFirstChild=function(_,n) if n=='HumanoidRootPart' then return rootPart end end}
local player={UserId=7,Parent={},Character=character,CharacterAdded=signal()}
local players={GetPlayers=function() return {player} end,PlayerAdded=signal(),PlayerRemoving=signal()}
local function module()
'''
post=r'''
end
local dash=module(); local seen={}
assert(dash.setup({Utils={now=function() return currentTime end,getPlayers=function() return players end,apiVersion=function() return 1 end}}))
dash.setHandler(function(event) table.insert(seen,event) end)
dash.tick(currentTime)
-- The animation can precede replication of velocity; it must not consume the detection.
local track={IsA=function(_,k) return k=='AnimationTrack' end,Animation={Name='Dash',AnimationId='rbxassetid://123'}}
animationPlayed:Fire(track); assert(#seen==0, 'premature animation triggered a zero-speed dash')
currentTime+=.04; rootPart.AssemblyLinearVelocity=vec(-120); rootPart.Position=vec(35.2); dash.tick(currentTime)
assert(#seen==1 and seen[1].userId==7 and seen[1].velocity.X==-120, 'dash velocity not delivered')
currentTime+=.04; rootPart.Position=vec(30.4); dash.tick(currentTime); assert(#seen==1, 'same dash was duplicated')
currentTime+=.3; rootPart.AssemblyLinearVelocity=vec(0); dash.tick(currentTime)
currentTime+=.04; rootPart.Position=vec(10000); dash.tick(currentTime)
assert(#seen==1, 'position teleport produced a dash')
currentTime+=.04; rootPart.AssemblyLinearVelocity=vec(-120); rootPart.Position=vec(9995.2); dash.tick(currentTime)
assert(#seen==2, 'second dash after debounce was lost')
dash.resetState(); currentTime+=.5; animationPlayed:Fire(track); dash.tick(currentTime)
assert(#seen==2, 'stale character listener survived reset')
print('Dash detection and lifecycle scenarios: PASS')
'''
out.write_text(pre+source+post,encoding='utf-8')
