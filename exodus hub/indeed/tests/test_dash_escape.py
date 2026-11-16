"""Simulate escape decisions; the model does not emulate Roblox networking."""
import unittest
from test_raw_target_parry import ROOT, run_lua

class DashEscapeTests(unittest.TestCase):
    def test_escapes_wait_for_cooldown_and_reject_unsafe_cases(self):
        src=(ROOT/'autospam.luau').read_text()
        code=src[src.index('local function dashEscapeRisk('):src.index('local function activate(')]
        run_lua('''
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end return V[k] end
V.__add=function(a,b) return setmetatable({X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z},V) end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
V.__mul=function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function v(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},V) end
Vector3={new=v,zero=v(0)}; function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local CONFIG={ACTIVATION={DASH_MAX_SNAPSHOT_AGE=.15,RADIUS_FACTOR=1,DASH_WINDOW_FACTOR=.4},DEACTIVATION={DASH_ESCAPE_MIN_HORIZONTAL_RATIO=.35,DASH_ESCAPE_MIN_OUTWARD_SPEED=15,DASH_ESCAPE_MIN_SEPARATION_GAIN=2,DASH_ESCAPE_COOLDOWN=.05}}
local state={root={Parent=true,Position=v(0),AssemblyLinearVelocity=v(0)}}; local tracker={partner=99,activatedAt=10}
local snapshot={syncAt=10,targetId=99,position=v(30),velocity=v(100),speed=100}
local function freshSnapshot(x) return x~=nil end
local function playerIsAlive() return true end
local function snapshotSpeed(s) return s.speed end
local function compensatedRadius() return 8 end
local function networkLatency() return 0 end
local function geometry() return {deflectWindow=.5} end
local localPlayer={UserId=42}; local position,ordinary=v(50),v(5)
local gameInfo={getPlayerMotion=function() return position,ordinary end,getPlayerRawRadius=function() return 8 end}
local cd={source='local',blocking=true,blockingSince=10}; local cooldownInfo={getDeflectCooldownState=function() return cd end}
local opponent={signalActive=true,velocity=v(120),normalModel={estimatedRemaining=.15}}
local selfDash={signalActive=true,velocity=v(-120),normalModel={estimatedRemaining=.15}}
local a,b=opponent,nil; local dashInfo={getEstimate=function(id) if id==99 then return a else return b end end}
''' + code + '''
assert(not dashEscapeRisk(state,tracker,snapshot,10.049),'stopped before 50ms')
local r=dashEscapeRisk(state,tracker,snapshot,10.051); assert(r and r.reason=='opponent_dash_escape')
a=nil; b=selfDash; r=dashEscapeRisk(state,tracker,snapshot,10.051); assert(r and r.reason=='self_dash_escape')
selfDash.velocity=v(0,120); assert(not dashEscapeRisk(state,tracker,snapshot,10.051),'up dash stopped spam')
selfDash.velocity=v(120); assert(not dashEscapeRisk(state,tracker,snapshot,10.051),'dash approaching stopped spam')
selfDash.velocity=v(-120); snapshot.targetId=42; assert(not dashEscapeRisk(state,tracker,snapshot,10.051),'stopped while targeted')
snapshot.targetId=99; snapshot.position=v(10); assert(not dashEscapeRisk(state,tracker,snapshot,10.051),'stopped with ball in own window')
snapshot.position=v(30); snapshot.teleported=true; assert(not dashEscapeRisk(state,tracker,snapshot,10.051)); snapshot.teleported=false
snapshot.syncAt=9; assert(not dashEscapeRisk(state,tracker,snapshot,10.051)); snapshot.syncAt=10
cd.blocking=false; assert(not dashEscapeRisk(state,tracker,snapshot,10.051))
cd.blocking=true; cd.blockingSince=nil; assert(not dashEscapeRisk(state,tracker,snapshot,10.06)); assert(dashEscapeRisk(state,tracker,snapshot,10.111))
''')

    def test_manual_escape_turns_off_manual_spam(self):
        src=(ROOT/'autospam.luau').read_text()
        code=src[src.index('function AutoSpam.canSendManual()'):src.index('function AutoSpam.canSend()')]
        run_lua("""
local manualOn=true; local observedReason
local root={Parent=true,Position={}}; local character={Parent=true}
local current={root=root,character=character,manual={partner=99,activatedAt=10}}
local utils={isManualSpamActive=function() return manualOn end,isActive=function() return true end,setManualSpamActive=function(v) manualOn=v end,recordTransition=function(_,_,_,reason) observedReason=reason end}
local gameInfo={getSnapshotAt=function() return {targetId=99} end}
local localPlayer={UserId=42}
local function now() return 11 end
local function freshSnapshot() return true end
local function userId(x) return x end
local function dashEscapeRisk() return {reason='opponent_dash_escape'} end
local function cooldownExpired() return false end
local AutoSpam={}
""" + code + """
assert(not AutoSpam.canSendManual()); assert(not manualOn and observedReason=='dash_escape')
""")

    def test_auto_escape_has_priority_over_slow_cooldown(self):
        src=(ROOT/'autospam.luau').read_text()
        code=src[src.index('local function deactivationReason('):src.index('local function checkDeactivation(')]
        run_lua("""
local utils={isActive=function() return true end,getConfigValue=function() return true end}
local gameInfo={getBallFrozen=function() return false end}
local function dashEscapeRisk() return {reason='opponent_dash_escape'} end
local function cooldownExpired() error('slow cooldown gate called first') end
local state={active=true}; local snapshot={}
""" + code + """
assert(deactivationReason(state,snapshot,11)=='opponent_dash_escape')
""")

if __name__ == '__main__': unittest.main()
