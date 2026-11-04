"""Generate movement tests for jump lifecycle and the upward dash."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/movement.luau").read_text(encoding="utf-8")
script = r'''
Enum = {Material = {Air = "Air", Ground = "Ground"}}
Vector3 = {new = function(x, y, z) return {X=x, Y=y, Z=z} end}
local handlers, tracked = {}, {}
local heartbeat = {Connect = function(_, fn)
    local connection = {Connected=true}
    function connection:Disconnect() self.Connected=false end
    handlers[#handlers+1] = {connection, fn}; return connection
end}
local function tick()
    for _, entry in ipairs(handlers) do if entry[1].Connected then entry[2]() end end
end
local function newCharacter()
    local char = {Parent={}}
    local humanoid = {Parent=char, Health=100, FloorMaterial=Enum.Material.Ground, Jump=false}
    function char:FindFirstChildOfClass(name) assert(name=="Humanoid"); return humanoid end
    return char, humanoid
end
local character, humanoid = newCharacter()
local player = {Character=character}
local enabled, active = false, true
local dash = {Dashing=false, MoveDir={X=5,Y=0,Z=0}, Dash=function(self) self.Dashing=true end}
local utils = {
    getConfigValue=function(key) assert(key=="AutoJump"); return enabled end,
    getLocalPlayer=function() return player end,
    getRunService=function() return {Heartbeat=heartbeat} end,
    trackGlobal=function(c) tracked[c]=true end,
    untrackGlobal=function(c) tracked[c]=nil end,
    isActive=function() return active end,
}
local info = {getDashAbility=function() return dash end}
local module = assert(loadstring(SOURCE))()
assert(module.setup({Utils=utils,GameInfo=info})); tick(); assert(not humanoid.Jump)
enabled=true; assert(module.syncJump()); tick(); assert(humanoid.Jump, "grounded jump missing")
humanoid.Jump=false; humanoid.FloorMaterial=Enum.Material.Air; tick(); assert(not humanoid.Jump, "jump fired in air")
humanoid.FloorMaterial=Enum.Material.Ground; humanoid.Health=0; tick(); assert(not humanoid.Jump, "dead humanoid jumped")
local nextCharacter, nextHumanoid=newCharacter(); player.Character=nextCharacter; tick()
assert(nextHumanoid.Jump, "jump failed after respawn")
nextHumanoid.Jump=false; enabled=false; module.syncJump(); tick(); assert(not nextHumanoid.Jump and next(tracked)==nil)
assert(module.upDash()); assert(dash.MoveDir.X==0 and dash.MoveDir.Y==1 and dash.MoveDir.Z==0, "dash direction is not up")
dash.MoveDir={X=3,Y=0,Z=0}; assert(not module.upDash()); assert(dash.MoveDir.X==3, "ongoing dash was changed")
dash.Dashing=false; dash.Dash=function() end; assert(not module.upDash(), "unavailable dash reported success")
dash=nil; assert(not module.upDash(), "missing dash reported success")
enabled=true; module.syncJump(); module.syncJump(); nextHumanoid.Jump=false; tick(); assert(nextHumanoid.Jump)
module.teardown(); nextHumanoid.Jump=false; tick(); assert(not nextHumanoid.Jump and next(tracked)==nil)
print("Auto Jump and Up Dash: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1), encoding="utf-8")
