"""Generate movement tests for jump lifecycle and the upward dash."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/extras/autojump.luau").read_text(encoding="utf-8")
script = r'''
Enum = {Material = {Air = "Air", Ground = "Ground"}, HumanoidStateType = {Jumping = "Jumping", Landed = "Landed"}}
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
    local humanoid = {Parent=char, Health=100, FloorMaterial=Enum.Material.Ground, Jump=false, State=Enum.HumanoidStateType.Landed, JumpCount=0}
    function humanoid:GetState() return self.State end
    function humanoid:ChangeState(state) assert(state == Enum.HumanoidStateType.Jumping); self.State=state; self.JumpCount=self.JumpCount+1 end
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
assert(module.setup({Utils=utils})); tick(); assert(humanoid.JumpCount==0)
enabled=true; assert(module.sync()); tick(); assert(humanoid.JumpCount==1, "grounded jump missing")
humanoid.Jump=false; tick(); assert(humanoid.JumpCount==1, "repeated jumping state")
humanoid.FloorMaterial=Enum.Material.Air; humanoid.State=Enum.HumanoidStateType.Landed; tick(); assert(humanoid.JumpCount==1, "jump fired in air")
humanoid.FloorMaterial=Enum.Material.Ground; tick(); assert(humanoid.JumpCount==2, "jump failed after landing")
humanoid.State=Enum.HumanoidStateType.Landed; humanoid.Health=0; tick(); assert(humanoid.JumpCount==2, "dead humanoid jumped")
local nextCharacter, nextHumanoid=newCharacter(); player.Character=nextCharacter; tick()
assert(nextHumanoid.JumpCount==1, "jump failed after respawn")
nextHumanoid.State=Enum.HumanoidStateType.Landed; enabled=false; module.sync(); tick(); assert(nextHumanoid.JumpCount==1 and next(tracked)==nil)
enabled=true; module.sync(); module.sync(); nextHumanoid.State=Enum.HumanoidStateType.Landed; tick(); assert(nextHumanoid.JumpCount==2)
module.teardown(); nextHumanoid.State=Enum.HumanoidStateType.Landed; tick(); assert(nextHumanoid.JumpCount==2 and next(tracked)==nil)
print("Auto Jump: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1), encoding="utf-8")
