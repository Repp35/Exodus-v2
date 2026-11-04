"""Test recent AP measurements and bounded AC return-window adaptation."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
parry = (root / "exodus hub/modules/logic/autoparry.luau").read_text()
parry = parry.replace("return os.clock()", "return testTime", 1)
parry = parry.replace("return AutoParry\n", "return AutoParry, R, observeTarget\n")
clash = (root / "exodus hub/modules/logic/autoclash.luau").read_text()
clash = clash.replace("return AutoClash\n", "return AutoClash, getReturnWindow, function(ap, info, utils) AutoParry=ap; GameInfo=info; Utils=utils end\n")
pre = '''local testTime=10
local Vector3={zero={}}
local function parryModule()
'''
middle = '''
end
local function clashModule()
'''
post = '''
end
local ap, state, observe=parryModule()
state.player={UserId=42}
for i=1,3 do
 observe(7); testTime+=0.1; observe(42)
 table.insert(state.pressureClicks,{at=testTime,factor=0.1,configured=0.5,speed=400})
end
local pressure=ap.getPressure()
assert(pressure.samples==3 and pressure.returnSamples==3 and math.abs(pressure.level-0.8)<1e-6)
assert(pressure.cps==1 and math.abs(pressure.averageReturnTime-0.1)<1e-6 and pressure.averageSpeed==400)
local clash, window, inject=clashModule()
inject(ap,{getBallSpeedLimits=function() return 16,600 end},{})
local elevated=window(400)
assert(clash.getStatus().returnWindowBonus==0.5, 'late AP with fast returns should expand window')
local elevatedBonus=clash.getStatus().returnWindowBonus
testTime+=4
pressure=ap.getPressure(); assert(pressure.samples==0 and pressure.level==nil, 'old data must expire')
local baseline=window(400)
assert(clash.getStatus().returnWindowBonus==0 and math.abs(elevated-baseline*(1+elevatedBonus))<1e-6, 'window must return to baseline')
inject({getPressure=function() return {level=0.9,averageReturnTime=0.8} end},{getBallSpeedLimits=function() return 16,600 end},{})
window(400); assert(clash.getStatus().returnWindowBonus==0, 'slow return must not trigger adaptation')
inject({getPressure=function() error('unavailable') end},{getBallSpeedLimits=function() return 16,600 end},{})
window(400); assert(clash.getStatus().returnWindowBonus==0, 'unavailable measurements must fail safely')
print('AP pressure and AC return window: PASS')
'''
output.write_text(pre + parry + middle + clash + post)
