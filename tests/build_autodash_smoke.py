"""Exercise dash reactions and character lifecycle."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/extras/autodash.luau").read_text()
script = r'''
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
    return V[k]
end
V.__sub = function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
V.__unm = function(a) return setmetatable({X=-a.X,Y=-a.Y,Z=-a.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x,y,z) return setmetatable({X=x,Y=y,Z=z},V) end
local heartbeat, callback, ticks, up, toward = nil, nil, 0, 0, 0
local alive, enabled, auto, upEnabled = true, true, true, true
local partner = 7
local me = {UserId=42}
local enemy = {Character={Parent={},FindFirstChildOfClass=function() return {Health=alive and 100 or 0} end}}
local players = {GetPlayerByUserId=function(_,id) if id==7 then return enemy end end}
local rootPart = {Parent={}, Position=vec(0,0,0), IsA=function(_,v) return v=="BasePart" end}
local character = {FindFirstChild=function(_,name) if name=="HumanoidRootPart" then return rootPart end end}
local tracked = {}
local signal = {Connect=function(_, fn)
    local c={Connected=true}; function c:Disconnect() self.Connected=false end
    heartbeat={connection=c, run=fn}; return c
end}
local utils = {
    getPlayers=function() return players end, getLocalPlayer=function() return me end,
    getRunService=function() return {Heartbeat=signal} end,
    getConfigValue=function(k) if k=="AutoSpam" then return auto else return upEnabled end end,
    isActive=function() return enabled end, now=function() return 1 end,
    trackCharacter=function(c) tracked[c]=true end, untrackCharacter=function(c) tracked[c]=nil end,
}
local game = {areAbilitiesEnabled=function() return true end, getClashContext=function() return nil end}
local dash = {setHandler=function(fn) callback=fn end, tick=function() ticks=ticks+1 end}
local movement = {upDash=function() up=up+1 end, dashToward=function(v) toward=toward+1; assert(v.X>0) end}
local spam = {getActivationContext=function() return {active=true,partner=partner} end}
local module = assert(loadstring(SOURCE))()
assert(module.setup({Utils=utils,GameInfo=game,Dash=dash,Movement=movement,AutoSpam=spam}))
assert(module.bindCharacter(character))
heartbeat.run(); assert(ticks==1)
callback({userId=7, position=vec(20,0,0), velocity=vec(100,0,0)}); assert(toward==1)
callback({userId=8, position=vec(20,0,0), velocity=vec(100,0,0)}); assert(toward==1)
alive=false
callback({userId=7, position=vec(20,0,0), velocity=vec(100,0,0)}); assert(toward==1)
alive=true
callback({userId=7, position=vec(20,0,0), velocity=vec(0,100,0)}); assert(up==1)
upEnabled=false
callback({userId=7, position=vec(20,0,0), velocity=vec(0,100,0)}); assert(up==1)
enabled=false
callback({userId=7, position=vec(20,0,0), velocity=vec(100,0,0)}); assert(toward==1)
local c=heartbeat.connection
module.detachCharacter(); assert(not c.Connected and next(tracked)==nil)
callback({userId=7, position=vec(20,0,0), velocity=vec(100,0,0)}); assert(toward==1)
module.teardown(); assert(callback==nil)
print("Auto Dash: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1))
