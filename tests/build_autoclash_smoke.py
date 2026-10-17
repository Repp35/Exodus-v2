"""Generate a Luau test for event target transitions and stale snapshots."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/autoclash.luau").read_text()
quoted = "[========[" + source + "]========]"
script = r'''
local time = 1
local heartbeat
local signal = {Connect = function(self, fn)
    heartbeat = fn
    return {Disconnect = function() end}
end}
local ancestrySignal = {Connect = function() return {Disconnect = function() end} end}
local root = {Parent = {}, Position = {X = 0, Y = 0, Z = 0}}
local character = {Parent = {}, AncestryChanged = ancestrySignal,
    FindFirstChild = function(self, name) return name == "HumanoidRootPart" and root or nil end}
local utils = {
    now = function() return time end, getConfig = function() return {AutoClash = true} end,
    getRunService = function() return {Heartbeat = signal} end,
    getPlayers = function() return {} end,
    getLocalPlayer = function() return {UserId = 42} end,
    recordTransition = function() end, setAutoSpamActive = function() end,
    trackCharacter = function() end, untrackCharacter = function() end,
    isActive = function() return true end, isManualSpamActive = function() return false end,
    apiVersion = function() return 1 end,
}
local clash = assert(loadstring(SOURCE))()
assert(clash.setup({
    AutoParry = {getRadius = function() return {} end, getStatus = function() return {} end},
    Dash = {setHandler = function() end, tick = function() end},
    GameInfo = {
        getTargetId = function() return -1 end,
        getSnapshot = function() return {targetId = 42} end,
        isSnapshotValid = function() return true end,
    },
    Utils = utils,
}))
assert(clash.bindCharacter(character))
clash.onBallSync({TargetPlayerID = 42})
assert(clash.getStatus().lastTarget == 42)
time += 0.05
clash.onBallSync({TargetPlayerID = 7})
assert(clash.getStatus().lastTarget == 7, "partner target ignored")
time += 0.05
heartbeat()
assert(clash.getStatus().lastTarget == 7, "stale snapshot overwrote event target")
time += 0.05
clash.onBallSync({TargetPlayerID = 42})
local status = clash.getStatus()
assert(status.returnPending == true and status.clashPartnerId == 7,
    "return transition not armed: " .. tostring(status.lastGate))
clash.teardown()
print("AutoClash target transitions: PASS")
'''
output.write_text(script.replace("SOURCE", quoted, 1))
