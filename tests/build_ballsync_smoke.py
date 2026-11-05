"""Generate a Luau test for BallSyncData normalization and provider fallback."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/gameinfo.luau").read_text()
quoted = "[========[" + source + "]========]"
script = r'''
local sync = {TargetPlayerID = 42, Teleported = false}
local moduleScript = {IsA = function(self, name) return name == "ModuleScript" end}
local folder = {FindFirstChild = function(self, name) return name == "BallReplicator" and moduleScript or nil end,
    IsA = function(self) return false end}
local ts = {FindFirstChild = function(self, name) return name == "BallReplicator" and folder or nil end}
local storage = {FindFirstChild = function(self, name) return name == "TS" and ts or nil end}
local workspace = {FindFirstChild = function() return nil end,
    GetAttribute = function(self, name) return name == "GameBallTarget" and 7 or nil end}
require = function(value)
    assert(value == moduleScript)
    return {BallReplicator = {syncData = sync}}
end
local gameInfo = assert(loadstring(SOURCE))()
assert(gameInfo.setup({Utils = {
    now = os.clock, apiVersion = function() return 1 end,
    getPlayers = function() return {LocalPlayer = {UserId = 42}} end,
    getReplicatedStorage = function() return storage end,
    getWorkspace = function() return workspace end,
}}))
assert(gameInfo.applySync(123) == sync, "numeric event should read replicator")
assert(gameInfo.getTargetId() == 42, "stale workspace attribute overrode sync target")
assert(gameInfo.applySync(nil) == sync, "signal-only event should read replicator")
local direct = {TargetPlayerID = 7}
assert(gameInfo.applySync(direct) == direct)
local wrapped = {syncData = {TargetPlayerID = 8}}
assert(gameInfo.applySync(wrapped) == wrapped.syncData)
print("BallSync provider and wrapper: PASS")
'''
output.write_text(script.replace("SOURCE", quoted, 1))
