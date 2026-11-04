"""Generate an Auto Dark scheduling and lifecycle test with mocked game APIs."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/autodark.luau").read_text(encoding="utf-8")
script = r'''
local workers, sends, errors = {}, {}, {}
task = {
    spawn = function(fn) workers[#workers + 1] = coroutine.create(fn) end,
    wait = function(delay) return coroutine.yield(delay) end,
}
local enabled, active, equipped = false, true, true
local cameraFrame = {}
local ability = {SendEvent = function(self, id, frame) sends[#sends + 1] = {self, id, frame} end}
local utils = {
    getConfigValue = function(key) assert(key == "AutoDark"); return enabled end,
    getWorkspace = function() return {CurrentCamera = {CFrame = cameraFrame}} end,
    isActive = function() return active end,
    recordError = function(source, message) errors[#errors + 1] = {source, message} end,
}
local info = {getDarkSealAbility = function() return equipped and ability or nil end}
local module = assert(loadstring(SOURCE))()
local function tick(index)
    local ok, result = coroutine.resume(workers[index])
    assert(ok, result)
    return result
end
assert(module.setup({Utils = utils, GameInfo = info}))
assert(#workers == 0, "disabled auto dark started a worker")
enabled = true; module.sync()
assert(tick(1) == 0.05 and #sends == 1, "first activation or 50 ms interval missing")
assert(sends[1][1] == ability and sends[1][2] == 2.4141700243704228e76 and sends[1][3] == cameraFrame, "incorrect ability event")
assert(tick(1) == 0.05 and #sends == 2, "second activation missing")
equipped = false; tick(1); tick(1)
assert(#sends == 2 and #errors == 1, "unequipped ability must warn once and continue")
equipped = true; tick(1); assert(#sends == 3, "equipped ability was not rediscovered")
enabled = false; module.sync(); tick(1)
assert(#sends == 3 and coroutine.status(workers[1]) == "dead", "disabled worker sent again")
enabled = true; module.sync(); module.sync()
tick(2); assert(#sends == 3, "old worker was not cancelled")
tick(3); assert(#sends == 4, "re-enabled worker did not start")
module.teardown(); tick(3)
assert(#sends == 4 and coroutine.status(workers[3]) == "dead", "teardown did not stop worker")
enabled = true; module.setup({Utils = utils, GameInfo = info}); tick(4)
assert(#sends == 5, "saved enabled setting was not resumed")
active = false; tick(4); assert(#sends == 5, "hub stop did not stop worker")
print("Auto Dark scheduling and lifecycle: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1), encoding="utf-8")
