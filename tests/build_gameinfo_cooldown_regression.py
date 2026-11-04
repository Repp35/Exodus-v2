"""Exercise the actual cooldown state after an attempt expires or loses its target."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/gameinfo.luau").read_text()
source = source.replace("os.clock()", "testTime")
source = source.replace("return GameInfo\n", "return GameInfo, function(s, players, ability) deflectState=s; Players=players; Utils={getReplicatedStorage=function() return nil end}; locateDeflectAbility=function() return ability end; nextDeflectSignalCheck=math.huge; nextHeldCooldownCheck=math.huge end\n")
pre = '''local testTime=10
local Vector3={zero={}}
local function typeof(v) return type(v) end
local function module()
'''
post = '''
end
local info, inject=module()
local state={known=true, active=false, rawActive=false, retryRevision=0, readyRevision=0,
 lastObservedPressClock=0, attempt={deadline=9}}
inject(state, nil)
local result=info.getDeflectCooldownState()
assert(result.attempt==nil and not result.blocking, "cancelled attempt left cooldown blocking")
local localState={known=false, active=false, rawActive=false, retryRevision=0, readyRevision=0}
inject(localState, nil, {Cooldown=0.7})
result=info.getDeflectCooldownState()
assert(result.known and result.blocking and math.abs(result.remaining-0.7)<1e-6, "observed local cooldown must be available to fierce detection")
print("GameInfo cooldown cancellation: PASS")
'''
output.write_text(pre + source + post)
