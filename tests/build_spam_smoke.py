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
local scheduled = {}
local worker
task = {delay=function(delay, fn, ...) local args=table.pack(...); scheduled[#scheduled+1] = {delay, function() fn(table.unpack(args, 1, args.n)) end} end,
 spawn=function(fn) worker=coroutine.create(fn); local ok,err=coroutine.resume(worker); assert(ok,err) end,
 wait=function() coroutine.yield() end}
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
    for _ = 1, frames do
        now += dt; frame(dt); local ok,err=coroutine.resume(worker); assert(ok,err)
        table.sort(scheduled, function(a,b) return a[1] < b[1] end)
        for _, item in ipairs(scheduled) do item[2]() end
        table.clear(scheduled)
    end
end
advance(1/60, 120)
assert(presses == 47, "CPS 23.5 / 120 frames: " .. presses)
config.CPS = 7500
local before = presses
advance(1/60, 1)
assert(presses - before == 125, "high CPS capped: " .. (presses-before))
config.SpamRateMode = "CPF"; config.CPF = 0.36
local ok,err=coroutine.resume(worker); assert(ok,err)
before=presses
for _=1,10000 do now+=0.001; ok,err=coroutine.resume(worker); assert(ok,err) end
assert(presses-before>=215 and presses-before<=216, "CPF timer must run without RenderStepped: " .. (presses-before))
before=presses; now+=1; ok,err=coroutine.resume(worker); assert(ok,err)
assert(presses-before==1, "stalled timer must not burst")
ok,err=coroutine.resume(worker); assert(ok,err)
assert(presses-before==1, "stalled timer must not queue backlog")
config.SpamRateMode = "CPS"; config.CPS = 0.25
for _, fps in ipairs({30, 60, 120}) do
    before = presses
    advance(1/fps, 4*fps)
    assert(presses - before == 1, "fractional CPS at " .. fps .. " FPS: " .. (presses-before))
end
config.SpamRateMode = "CPS"; config.CPS = 120
before = presses; frame(1/30)
assert(presses-before == 1 and #scheduled == 3, "multiple clicks must be distributed")
assert(scheduled[1][1] > 0 and scheduled[1][1] < scheduled[2][1] and scheduled[2][1] < scheduled[3][1] and scheduled[3][1] < 1/30, "scheduled offsets must be ordered within frame duration")
spam.resetState()
for _, item in ipairs(scheduled) do item[2]() end
table.clear(scheduled)
assert(presses-before == 1, "reset must cancel delayed clicks")
enabled = false
before = presses
advance(1/60, 10)
assert(presses == before)
spam.teardown()
print("Spam CPS/CPF cadence: PASS")
'''
output.write_text(script.replace("SOURCE", quoted, 1))
