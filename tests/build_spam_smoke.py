"""Generate a Luau test for CPS/CPF cadence and input-service reuse."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/spam.luau").read_text()
quoted = "[========[" + source + "]========]"
script = r'''
local frame
local presses, releases, lookups = 0, 0, 0
local now, enabled = 0, true
local config = {SpamRateMode = "CPS", CPS = 23.5, CPF = 10}
local input = {SendMouseButtonEvent = function(self, x, y, button, down)
    if down then presses += 1 else releases += 1 end
end}
game = {GetService = function(self, name)
    if name == "VirtualInputManager" then lookups += 1; return input end
    error(name)
end}
local signal = {Connect = function(self, callback)
    frame = callback
    return {Disconnect = function() end}
end}
local utils = {
    now = function() return now end,
    isActive = function() return enabled end,
    isSpamActive = function() return enabled end,
    isManualSpamActive = function() return enabled end,
    isAutoSpamActive = function() return false end,
    getConfig = function() return config end,
    getRunService = function() return {RenderStepped = signal} end,
    trackGlobal = function() end,
    untrackGlobal = function() end,
    recordTransition = function() end,
    recordError = function(_, message) error(message) end,
}
local spam = assert(loadstring(SOURCE))()
assert(spam.setup({
    Remote = {fireParry = function() end}, Utils = utils,
    GameInfo = {getDeflectCD = function() return 0 end},
    AutoParry = {getStatus = function() return {} end, getRadius = function() return {} end},
    AutoClash = {getTargetSwitch = function() return nil end, getDashData = function() return {} end},
}))
local function advance(dt, frames)
    for _ = 1, frames do now += dt; frame(dt) end
end
advance(1/60, 120)
assert(presses == 47 and releases == 47, "CPS 23.5 / 120 frames: " .. presses)
assert(lookups == 1, "VirtualInputManager lookup repeated: " .. lookups)
config.CPS = 7500
local before = presses
advance(1/60, 1)
assert(presses - before == 125, "high CPS capped: " .. (presses-before))
config.SpamRateMode = "CPF"
before = presses
advance(1/60, 120)
assert(presses - before == 1200, "CPF 10 at 60 FPS: " .. (presses-before))
before = presses
advance(1/30, 30)
assert(presses - before == 600, "CPF compensation at 30 FPS: " .. (presses-before))
enabled = false
before = presses
advance(1/60, 10)
assert(presses == before and presses == releases)
spam.teardown()
print("Spam CPS/CPF cadence: PASS")
'''
output.write_text(script.replace("SOURCE", quoted, 1))
