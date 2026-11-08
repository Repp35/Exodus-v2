"""Generate an Auto Dark frame and lifecycle test with mocked game APIs."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/extras/autodark.luau").read_text(encoding="utf-8")
script = r'''
local sends, errors, tracked = {}, {}, {}
local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            local connection = {Connected = true}
            function connection:Disconnect() self.Connected = false end
            handlers[#handlers + 1] = {connection, fn}
            return connection
        end,
        Fire = function(_, ...)
            for _, entry in ipairs(handlers) do if entry[1].Connected then entry[2](...) end end
        end,
    }
end
local function player()
    return {dark = false, GetAttribute = function(self, name) assert(name == "DarkSealed"); return self.dark end}
end
local me, other, newcomer = player(), player(), player()
local playerList = {me, other}
local players = {
    PlayerAdded = signal(), PlayerRemoving = signal(),
    GetPlayers = function() return playerList end,
}
local heartbeat = signal()
local enabled, active, equipped, pauseAbility = false, true, true, false
local cameraFrame = {}
local ability = {SendEvent = function(self, id, frame) sends[#sends + 1] = {self, id, frame} end}
local utils = {
    getConfigValue = function(key) assert(key == "AutoDark"); return enabled end,
    getWorkspace = function() return {CurrentCamera = {CFrame = cameraFrame}} end,
    getPlayers = function() return players end,
    getLocalPlayer = function() return me end,
    getRunService = function() return {Heartbeat = heartbeat} end,
    trackGlobal = function(c) tracked[c] = true end,
    untrackGlobal = function(c) tracked[c] = nil end,
    isActive = function() return active end,
    recordError = function(source, message) errors[#errors + 1] = {source, message} end,
}
local info = {getDarkSealAbility = function() if pauseAbility then coroutine.yield() end; return equipped and ability or nil end}
local module = assert(loadstring(SOURCE))()
local function tick(count) for _ = 1, count or 1 do heartbeat:Fire() end end
assert(module.setup({Utils = utils, GameInfo = info}))
tick(); assert(#sends == 0, "disabled auto dark sent an event")
enabled = true; assert(module.sync())
tick(3); assert(#sends == 3, "expected exactly one attempt per frame")
assert(sends[1][1] == ability and sends[1][2] == 2.4141700243704228e76 and sends[1][3] == cameraFrame, "incorrect ability event")
other.dark = true; tick(3); assert(#sends == 3, "another player has Dark Seal")
other.dark = false; tick(); assert(#sends == 4, "did not resume after other Dark Seal expired")
me.dark = true; tick(); assert(#sends == 5, "own Dark Seal incorrectly blocked attempts")
newcomer.dark = true; playerList[#playerList + 1] = newcomer; players.PlayerAdded:Fire(newcomer)
tick(); assert(#sends == 5, "new player's active Dark Seal was ignored")
players.PlayerRemoving:Fire(newcomer); table.remove(playerList); tick()
assert(#sends == 6, "did not resume after player left")
equipped = false; tick(2)
assert(#sends == 6 and #errors == 1, "missing ability must warn once")
equipped = true; tick(); assert(#sends == 7, "equipped ability was not rediscovered")
pauseAbility = true
local running = coroutine.create(function() heartbeat:Fire() end)
assert(coroutine.resume(running)); tick(); assert(#sends == 7, "overlapping frame sent an event")
other.dark = true; pauseAbility = false
assert(coroutine.resume(running)); assert(#sends == 7, "Dark activated while ability lookup yielded")
other.dark = false; tick(); assert(#sends == 8, "failed to resume after yielding lookup")
enabled = false; module.sync(); tick(); assert(#sends == 8 and next(tracked) == nil, "disable did not disconnect")
enabled = true; module.sync(); module.sync(); tick()
assert(#sends == 9, "repeated sync created duplicate handlers")
module.teardown(); tick(); assert(#sends == 9 and next(tracked) == nil, "teardown did not disconnect")
module.setup({Utils = utils, GameInfo = info}); tick()
assert(#sends == 10, "saved enabled setting was not resumed")
active = false; tick(); assert(#sends == 10, "hub stop did not stop attempts")
print("Auto Dark frame, Dark Seal priority and lifecycle: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1), encoding="utf-8")
