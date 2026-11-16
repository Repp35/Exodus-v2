"""Exercise the spam timing and teleport policies with Lua mocks."""
import unittest
from test_raw_target_parry import ROOT, run_lua

SOURCE = (ROOT / 'autospam.luau').read_text()
def section(start, end):
    return SOURCE[SOURCE.index(start):SOURCE.index(end)]

PRELUDE = '''
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.abs(t.x) end end
V.__sub=function(a,b) return setmetatable({x=a.x-b.x},V) end
local function v(x) return setmetatable({x=x},V) end
function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local gameInfo={getBallSpeedLimits=function() return 16,600 end,isSnapshotValid=function(s) return s~=nil end}
local CONFIG={SHARED={MIN_RETURN=1/25,SNAPSHOT_MAX_AGE=.5},DEACTIVATION={STATIONARY_EPSILON=.05,STATIONARY_TIMEOUT=.3,DEFLECT_COOLDOWN_TIMEOUT=.09,COOLDOWN_PROTECTION_RADIUS=16,COOLDOWN_PROTECTION_MAX_SPEED_RADIUS=40}}
'''

class SpamGates(unittest.TestCase):
    def test_speed_windows(self):
        code = section('local function snapshotSpeed(', 'local function returnTimeout(') + section('local function returnWindow(', 'local function sampleOwnDash(')
        run_lua(PRELUDE + code + '''
assert(math.abs(speedInterval({syncSpeed=16},.5,.1)-.5)<1e-8)
assert(math.abs(speedInterval({syncSpeed=600},.5,.1)-.1)<1e-8)
assert(math.abs(returnWindow(1,16,.3,0)-.3)<1e-8)
assert(math.abs(returnWindow(1,600,.3,0)-.04)<1e-8)
''')

    def test_stationary_and_teleport_resume(self):
        code = section('local function freshSnapshot(', 'local function speedInterval(') + section('local function resetMotion(', 'local function cooldownExpired(')
        run_lua(PRELUDE + '''local function resetExchange(s) s.exchange=nil end\n''' + code + '''
local ball={}; local s={active=true,partner=99,target=42}; local x={ball=ball,position=v(2)}
observeMotion(s,x,1); observeMotion(s,x,1.299); assert(not s.stationary)
observeMotion(s,x,1.301); assert(s.stationary)
x.teleported=true; observeMotion(s,x,1.31); assert(s.teleporting and s.active and not s.stationary)
x.teleported=false; x.position=v(50); observeMotion(s,x,2); assert(s.active and not s.teleporting and not s.stationary)
observeMotion(s,x,2.299); assert(not s.stationary)
x.position=v(51); observeMotion(s,x,2.3); assert(not s.stationary)
''')

    def test_manual_cooldown_is_130_percent_and_resets(self):
        code = section('local function cooldownExpired(', 'local function activate(')
        run_lua(PRELUDE + '''
local cd={blocking=true,blockingSince=10}
local cooldownInfo={getDeflectCooldownState=function() return cd end}
local function opponentOutside() return true end
''' + code + '''
local auto={activatedAt=10}; local manual={activatedAt=10}
assert(not cooldownExpired(auto,nil,10.089)); assert(cooldownExpired(auto,nil,10.091))
assert(not cooldownExpired(manual,nil,10.116,1.3)); assert(cooldownExpired(manual,nil,10.118,1.3))
cd.blocking=false; assert(not cooldownExpired(manual,nil,10.12,1.3)); assert(manual.deflectCooldownSince==nil)
cd.blocking=true; cd.blockingSince=nil; assert(not cooldownExpired(manual,nil,11,1.3)); assert(cooldownExpired(manual,nil,11.118,1.3))
''')

    def test_haunter_rejects_unconfirmed_window_and_fleeing_opponent(self):
        code = section('local function deactivationReason(', 'local function checkDeactivation(')
        run_lua(PRELUDE + """
CONFIG.DEACTIVATION.HAUNTER_CONFIRM_TIMEOUT=.1; CONFIG.DEACTIVATION.CLASH_GRACE_PERIOD=.15
CONFIG.ACTIVATION={RADIUS_FACTOR=1}
local function freshSnapshot(s) return s~=nil end
local function cooldownExpired() return false end
local function dashEscapeRisk() return nil end
local function speedInterval() return .1 end
local function networkLatency() return 0 end
local function userId(x) return x end
local function geometry() return {fullRadius=20,noWindowParryRadius=8,effectiveWindow=.02} end
local function distanceLimit() return 30 end
local function targetReturnTimeout() return .2 end
local function opponentOutside() return false end
local function snapshotSpeed(s) return s.speed end
local utils={isActive=function() return true end,getConfigValue=function() return true end}
localPlayer={UserId=42}; local distance=10
local gameInfo={isSnapshotValid=function() return true end,getBallFrozen=function() return false end,getPlayerMotion=function() return v(distance) end,getPlayerRawRadius=function() return 8 end}
local s={reason='haunter',activatedAt=10,root={Position=v(0)},partner=99,target=42}
local x={targetId=42,position=v(25),speed=600}
""" + code + """
assert(deactivationReason(s,x,10.05)==nil)
assert(deactivationReason(s,x,10.11)=='haunter_window_unconfirmed')
x.position=v(10); assert(deactivationReason(s,x,10.11)==nil)
distance=31; assert(deactivationReason(s,x,10.12)=='opponent_distance')
distance=10; x.targetId=99; s.departedAt=10.2
assert(deactivationReason(s,x,10.29)==nil)
assert(deactivationReason(s,x,10.31)=='haunter_return_timeout')
""")

if __name__ == '__main__': unittest.main()
