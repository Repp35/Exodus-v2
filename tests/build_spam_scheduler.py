"""Verify cadence, missed deadlines and cancellation of the real spam worker."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/spam.luau').read_text().replace('os.clock()', 'clock')
pre = r'''
local clock, worker = 0, nil
local task = {spawn=function(f) worker=coroutine.create(f); local ok,e=coroutine.resume(worker); assert(ok,e) end,
 wait=function() coroutine.yield() end, defer=function(f) f() end}
local function module()
'''
post = r'''
end
local spam=module()
local enabled, clicks, observer = true, 0, nil
local cfg={SpamRateMode='CPS', CPS=10}
local utils={getConfig=function() return cfg end,isActive=function() return true end,isSpamActive=function() return enabled end,
 observeSpam=function(f) observer=f; return {Disconnect=function() end} end,
 observeConfig=function() return {Disconnect=function() end} end,trackGlobal=function() end,untrackGlobal=function() end,
 recordError=function(_,e) error(e) end}
local remote={fireParry=function(_,guard) if guard() then clicks+=1; return true end end}
assert(spam.setup({Utils=utils,Remote=remote})); assert(clicks==1,'first press')
local function step(t) clock=t; local ok,e=coroutine.resume(worker); assert(ok,e) end
step(.05); assert(clicks==1,'not yet due')
step(.1); assert(clicks==2,'regular cadence')
step(1.05); assert(clicks==3,'delayed scheduler must not burst')
step(1.06); assert(clicks==3,'missed clicks must not be replayed')
enabled=false; observer(); step(1.1); assert(clicks==3,'cancellation')
spam.teardown()
print('Spam scheduler: PASS')
'''
output.write_text(pre + source + post)
