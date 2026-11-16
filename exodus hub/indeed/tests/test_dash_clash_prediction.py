"""Simulation of dash clash prediction and its rejection gates."""
import unittest
from test_raw_target_parry import ROOT, run_lua

class DashClashPrediction(unittest.TestCase):
    def test_incoming_self_and_invalid_evidence(self):
        source=(ROOT/'autospam.luau').read_text()
        model=source[source.index('local function dashPrediction('):source.index('local function evaluate(')]
        run_lua('''
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.sqrt(t.x*t.x+t.y*t.y) end return V[k] end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x,y=a.y-b.y},V) end
V.__mul=function(a,b) return setmetatable({x=a.x*b,y=a.y*b},V) end
function V:Dot(b) return self.x*b.x+self.y*b.y end
local function v(x,y) return setmetatable({x=x,y=y or 0},V) end
function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
RaycastParams={new=function() return {} end}; Enum={RaycastFilterType={Exclude=1}}
local wall=false; local utils={getWorkspace=function() return {Raycast=function() return wall and {} or nil end} end}
local localPlayer={UserId=42}; local players={GetPlayerByUserId=function() return {Character={}} end}
local other=v(40); local gameInfo={getPlayerMotion=function() return other end,getPlayerRawRadius=function() return 8 end}
local function compensatedRadius() return 8 end
local function geometry() return {effectiveWindow=.4,deflectWindow=.4} end
local function snapshotSpeed(s) return s.speed end
local function playerIsAlive() return true end
local function freshSnapshot(s) return s and s.valid end
local CONFIG={ACTIVATION={DASH_MAX_SNAPSHOT_AGE=.15,DASH_WINDOW_FACTOR=.4,DASH_MIN_ALIGNMENT=.6,DASH_MIN_CPS=4,DASH_MIN_SCORE=75}}
local opponentDash={signalActive=true,observedAt=10,position=v(40),velocity=v(-120),normalModel={estimatedRemaining=.15}}
local selfDash={signalActive=true,observedAt=10,position=v(0),velocity=v(120),normalModel={estimatedRemaining=.15}}
local a,b=opponentDash,nil; local dashInfo={getEstimate=function(id) if id==99 then return a else return b end end}
local state={dashExchangePartner=99,dashExchangeAt=10.05,root={Position=v(0)},character={}}
local snap={valid=true,targetId=42,syncAt=10.05,ball={},position=v(5),velocity=v(-600),speed=600}
''' + model + '''
local r=dashPrediction(state,snap,10.05); assert(r and r.reason=='dash_incoming' and r.score>=75)
a=nil; b=selfDash; r=dashPrediction(state,snap,10.05); assert(r and r.reason=='dash_self')
selfDash.velocity=v(-120); assert(not dashPrediction(state,snap,10.05)); selfDash.velocity=v(120)
wall=true; assert(not dashPrediction(state,snap,10.05)); wall=false
snap.syncAt=9; assert(not dashPrediction(state,snap,10.05)); snap.syncAt=10.05
snap.targetId=77; assert(not dashPrediction(state,snap,10.05)); snap.targetId=42
state.dashExchangeAt=9; assert(not dashPrediction(state,snap,10.05)); state.dashExchangeAt=10.05
selfDash.signalActive=false; assert(not dashPrediction(state,snap,10.05)); selfDash.signalActive=true
snap.teleported=true; assert(not dashPrediction(state,snap,10.05))
''')

if __name__ == '__main__': unittest.main()
