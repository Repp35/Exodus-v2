"""Exercise local cooldown duration, target, ability availability, and resets."""
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / "exodus hub/modules/logic/extras/autofierce.luau").read_text()
source = source.replace("os.clock()", "clock")
source = source.replace("return AutoFierce\n", "return AutoFierce, step\n")
pre = "local clock = 0\nlocal function module()\n"
post = r'''
end
local api, step = module()
local enabled, target, fired, stops, speed = true, 42, 0, 0, 100
local deflect = {Cooldown=0,LastCooldown=1.5}
local fierce = {IsOwnerAlive=function() return true end, IsAvailable=function(_, ignoreMode) assert(ignoreMode == false); return true end,
    ActivateAndBlock=function() fired += 1 end}
local heartbeat = {Connect=function(_, f) return {Disconnect=function() end} end}
local utils = {isActive=function() return true end, getConfigValue=function() return enabled end,
    getLocalPlayer=function() return {UserId=42} end, getRunService=function() return {Heartbeat=heartbeat} end,
    stopAllSpam=function() stops += 1 end, trackGlobal=function() end, untrackGlobal=function() end, recordError=function(_, e) error(e) end}
local info = {getDeflectAbility=function() return deflect end, getFierceDeflectAbility=function() return fierce end,
    getDeflectWindow=function(s) assert(s==speed); return .3 end, getSyncData=function() return {Speed=speed} end,
    getTargetId=function() return target end}
assert(api.setup({Utils=utils, GameInfo=info, AutoClash={stopSpam=function() end}, Spam={resetState=function() end}}))
local function tick(t) clock=t; step() end
deflect.Cooldown=1; tick(1); tick(1.29); assert(fired==0, "local prediction fired early")
deflect.Cooldown=0; tick(1.3); deflect.Cooldown=1; tick(2); tick(2.29); assert(fired==0, "reset must start a new window")
target=7; tick(2.5); assert(fired==0, "wrong target")
target=42; fierce.IsAvailable=function() return false end; tick(2.51); assert(fired==0, "ability unavailable")
fierce.IsAvailable=function(_, mode) assert(mode==false); return true end; tick(2.52); tick(2.6); assert(fired==1 and stops==1, "one activation per cooldown")
deflect.Cooldown=0; tick(3); deflect.Cooldown=1; deflect.PredictedResetUntil=4; tick(3.1); tick(3.99); assert(fired==1, "pending prediction")
tick(4.01); assert(fired==2, "persistent cooldown")
enabled=false; tick(5); enabled=true; deflect.PredictedResetUntil=nil; tick(6); tick(6.2); assert(fired==2, "toggle resets observation")
deflect.Cooldown=0; tick(6.21)
deflect.LastCooldown=1; deflect.Cooldown=.95; tick(7)
deflect.Cooldown=.90; tick(7.4); assert(fired==2, "repeated local cooldowns must not be counted as continuous")
deflect.Cooldown=.99; tick(7.41)
deflect.Cooldown=.65; tick(7.72); assert(fired==3, "only a cooldown that individually survives its window may activate")
api.teardown()
print("Auto Fierce window: PASS")
'''
Path(sys.argv[2]).write_text(pre + source + post)
