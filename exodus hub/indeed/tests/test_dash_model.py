"""Check dash profiles and estimates without assuming Roblox physics."""
import re
import unittest
from test_raw_target_parry import ROOT, run_lua

class DashModelTests(unittest.TestCase):
    def test_profile_and_detected_dash(self):
        source=(ROOT/'aux/dash.luau').read_text()
        source=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',source)
        run_lua('''
local now=10
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end return V[k] end
V.__add=function(a,b) return setmetatable({x=a.x+b.x},V) end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
V.__mul=function(a,b) return setmetatable({x=a.x*b},V) end
V.__div=function(a,b) return setmetatable({x=a.x/b},V) end
function V:Dot(b) return self.x*b.x end
local function v(x) return setmetatable({x=x},V) end
function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local function sig() return {Connect=function() return {Disconnect=function() end} end} end
local root={Position=v(0),AssemblyLinearVelocity=v(120),IsA=function() return true end}
local character={Parent=true,FindFirstChild=function() return root end}; root.Parent=character
local player={UserId=7,Parent=true,Character=character,CharacterAdded=sig()}
local players={PlayerAdded=sig(),PlayerRemoving=sig(),GetPlayers=function() return {player} end,GetPlayerByUserId=function(_,id) if id==7 then return player end end}
local utils={getPlayers=function() return players end,now=function() return now end,trackGlobal=function() end,untrackGlobal=function() end}
local dashing=true; local gameInfo={isPlayerDashing=function() return dashing end}
local dash=(function()\n''' + source + '''\nend)()
assert(dash.setup({Utils=utils,GameInfo=gameInfo}))
local profiles=dash.getProfiles(); assert(profiles.normal.nominalDistance==24)
assert(profiles.wind.speed==200 and profiles.wind.configuredSecondSpeed==150 and profiles.wind.appliedSpeed==200)
local event; dash.setHandler(function(e) event=e end); dash.tick(now)
assert(event and event.confirmed and event.estimate.ability=='unknown')
assert(event.estimate.guaranteedRemainingDistance==0)
assert(math.abs(event.estimate.normalModel.estimatedRemainingDistance-24)<1e-8)
now=10.05; root.Position=v(6); dash.tick(now)
local estimate=dash.getEstimate(7); assert(math.abs(estimate.observedDisplacement-6)<1e-8)
assert(math.abs(estimate.normalModel.estimatedRemainingDistance-18)<1e-8)
now=11; assert(dash.getEstimate(7)==nil,'stale estimate remained available')
dash.teardown(); assert(dash.getEstimate(7)==nil)
''')

if __name__ == '__main__': unittest.main()
