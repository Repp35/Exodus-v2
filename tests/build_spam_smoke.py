"""Generate a Luau test for CPS/CPF cadence through the current deflect interface."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/spam.luau").read_text()
quoted = "[========[" + source + "]========]"
script = r'''
local frame
local presses = 0
local now, enabled = 0, true
local config = {SpamRateMode = "CPS", CPS = 23.5, CPF = 10}
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
    Remote = {fireParry = function() presses += 1; return true end, usesGameDeflect = function() return true end}, Utils = utils,
    GameInfo = {getDeflectCD = function() return 0 end},
    AutoParry = {getStatus = function() return {} end, getRadius = function() return {} end},
    AutoClash = {getTargetSwitch = function() return nil end, getDashData = function() return {} end},
}))
local function advance(dt, frames)
    for _ = 1, frames do now += dt; frame(dt) end
end
advance(1/60, 120)
assert(presses == 47, "CPS 23.5 / 120 frames: " .. presses)
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
config.SpamRateMode = "CPS"; config.CPS = 0.25
for _, fps in ipairs({30, 60, 120}) do
    before = presses
    advance(1/fps, 4*fps)
    assert(presses - before == 1, "fractional CPS at " .. fps .. " FPS: " .. (presses-before))
end
config.SpamRateMode = "CPF"; config.CPF = 0.42
for _, fps in ipairs({30, 60}) do
    before = presses
    advance(1/fps, 5*fps)
    assert(presses - before == 126, "fractional CPF at " .. fps .. " FPS: " .. (presses-before))
end
enabled = false
before = presses
advance(1/60, 10)
assert(presses == before)
spam.teardown()
print("Spam CPS/CPF cadence: PASS")
'''
output.write_text(script.replace("SOURCE", quoted, 1))
