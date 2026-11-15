"""Offline tests for raw targeting and AP cooldown integration; no Roblox server emulation."""
import ctypes
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2] / "modules" / "logic"
LIB = ctypes.CDLL("liblua5.4.so.0")
LIB.luaL_newstate.restype = ctypes.c_void_p
LIB.luaL_openlibs.argtypes = [ctypes.c_void_p]
LIB.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
LIB.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
LIB.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
LIB.lua_tolstring.restype = ctypes.c_char_p
LIB.lua_close.argtypes = [ctypes.c_void_p]

def run_lua(script):
    state = LIB.luaL_newstate()
    try:
        LIB.luaL_openlibs(state)
        status = LIB.luaL_loadstring(state, script.encode())
        if not status:
            status = LIB.lua_pcallk(state, 0, 0, 0, 0, None)
        if status:
            raise AssertionError(LIB.lua_tolstring(state, -1, None).decode())
    finally:
        LIB.lua_close(state)

PRELUDE = """
local tm=10; os.clock=function() return tm end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local V={}; V.__index=function(t,k) if k=='Magnitude' then return math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) elseif k=='Unit' then local m=t.Magnitude; return setmetatable({X=t.X/m,Y=t.Y/m,Z=t.Z/m},V) end return V[k] end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
V.__mul=function(a,b) return setmetatable({X=a.X*b,Y=a.Y*b,Z=a.Z*b},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function v(x,y) return setmetatable({X=x,Y=y or 0,Z=0},V) end
Vector3={zero=v(0)}
function typeof(x) if getmetatable(x)==V then return 'Vector3' elseif type(x)=='table' and x.instance then return 'Instance' else return type(x) end end
local frameCb
local function signal() return {Connect=function(self,fn) if not frameCb then frameCb=fn end; return {Disconnect=function() end} end} end
local player={UserId=42}; local root={Parent=true,Position=v(0),AssemblyLinearVelocity=v(0),IsA=function() return true end}
local character={Parent=true,AncestryChanged=signal(),FindFirstChild=function() return root end}
local ball={Parent=true,instance=true,IsA=function() return true end}
local snap={ball=ball,position=v(10),realPosition=v(10),velocity=v(-600),speed=600,syncSpeed=600,targetId=42,syncSequence=1}
local fires=0; local cd={source='local',blocking=false}
local u={getLocalPlayer=function() return player end,getRunService=function() return {PostSimulation=signal()} end,isActive=function() return true end,getConfigValue=function(k) if k=='AutoParryWindowFactor' then return 0.3 else return true end end,isSpamActive=function() return false end,trackCharacter=function() end,untrackCharacter=function() end,recordTransition=function() end,recordError=function() end}
local g={getDeflectAbility=function() return {} end,getSnapshotAt=function() return snap end,isSnapshotValid=function() return true end,getRootPosition=function() return root.Position end,isTrainingArea=function() return false end,observeTraining=function() return {Disconnect=function() end} end,getSyncSequence=function() return snap.syncSequence end,getAveragePing=function() return 0,0,1 end,getAutoParryGeometry=function(speed,factor) return {noWindowParryRadius=8.5,triggerPadding=1,leadTime=0.08,effectiveWindow=0.08,deflectWindow=0.2,windowFactor=factor,fullRadius=57} end}
local c={getDeflectCooldownState=function() return cd end,recordDeflectAttempt=function(at) cd.pressAt=at end}
local r={fireParry=function(_,guard) assert(guard()); fires=fires+1; return true end}

g.getBallVelocity=function() return snap.velocity end
local trainingUntil=0
c.recordTrainingDeflectAttempt=function(at) trainingUntil=at+1.45 end
c.getTrainingCooldownState=function() return {blocking=tm<trainingUntil} end
"""

class RawTargetParry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "autoparry.luau").read_text()
        cls.source = re.sub(r"([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)", lambda m: f"{m[1]} = {m[1]} + ({m[2]})", source)

    def check_ap(self, case):
        run_lua(PRELUDE + "local ap=(function()\n" + self.source + "\nend)()\n" + """
assert(ap.setup({Utils=u,GameInfo=g,Remote=r,Cooldown=c}))
assert(ap.bindCharacter(character))
local function packet(target)
  snap.syncSequence=snap.syncSequence+1; snap.targetId=target
  ap.onBallSync({Sequence=snap.syncSequence,TargetPlayerID=target})
end
""" + case)

    def test_raw_target_has_no_confirmation_or_visual_fallback(self):
        source = (ROOT / "aux/gameinfo.luau").read_text()
        target = source[source.index("local function targetId("):source.index("local function findBall()")]
        run_lua(target + """
assert(targetId({TargetPlayerID=42,HighlightTargetPlayerID=99})==42)
assert(targetId({TargetPlayerID=99,HighlightTargetPlayerID=42})==99)
assert(targetId({TargetPlayerID=42})==42)
assert(targetId({TargetPlayerID=0})==0)
assert(targetId({HighlightTargetPlayerID=42,Targeted=true})==-1)
assert(targetId(nil)==-1)
assert(targetId({TargetPlayerID=99})==99)
""")

    def test_ready_cooldown_does_not_delay_first_click_or_fast_returns(self):
        self.check_ap("""
packet(42); assert(fires==1,'first target packet did not click immediately')
for i=1,16 do
  tm=tm+1/32; packet(99); tm=tm+1/32; packet(42)
end
assert(fires==17,'ready cooldown throttled fresh target cycles')
""")

    def test_same_target_stays_blocked_after_success(self):
        self.check_ap("""
packet(42); cd.lastParriedAt=tm+0.001
for i=1,16 do tm=tm+1/16; packet(42); frameCb(1/60) end
assert(fires==1,'repeated packet or successful cooldown reset duplicated click')
packet(99); packet(42); assert(fires==2)
""")

    def test_actual_cooldown_still_blocks_first_click(self):
        self.check_ap("""
cd.blocking=true; packet(42); assert(fires==0,'ignored real cooldown')
cd.blocking=false; frameCb(1/60); assert(fires==1,'wait added after ready cooldown')
""")

    def test_cooldown_still_blocks_fresh_target_return(self):
        self.check_ap("""
packet(42); packet(99); cd.blocking=true; packet(42)
assert(fires==1,'fresh target bypassed actual cooldown')
cd.blocking=false; frameCb(1/60); assert(fires==2)
""")

    def test_miss_retry_requires_cooldown_to_finish(self):
        self.check_ap("""
packet(42); cd.miss=true; cd.blocking=true
frameCb(1/60); assert(fires==1,'retried during miss cooldown')
cd.blocking=false; frameCb(1/60); assert(fires==2,'lost cooldown-based miss recovery')
""")

    def test_training_cooldown_and_miss_recovery_remain(self):
        self.check_ap("""
snap.mode='training'; snap.trainingRound=1
frameCb(1/60); assert(fires==1)
tm=tm+1; frameCb(1/60); assert(fires==1,'ignored training cooldown')
tm=tm+0.46; frameCb(1/60); assert(fires==2,'lost training cooldown recovery')
""")

    def test_no_target_and_redirect_cannot_click_for_an_opponent(self):
        self.check_ap("""
packet(99); assert(fires==0)
assert(ap.tryRedirectReturn(snap,tm)==false); assert(fires==0)
packet(42); assert(fires==1)
packet(-1); packet(42); assert(fires==2,'raw no-target departure did not rearm')
""")

    def test_outside_window_still_waits_for_arrival(self):
        self.check_ap("""
snap.position=v(300); packet(42); assert(fires==0)
snap.position=v(10); frameCb(1/60); assert(fires==1)
""")

    def test_base_radius_fires_without_incoming_velocity(self):
        for velocity in ('v(0)', 'v(600)', 'v(0,600)'):
            with self.subTest(velocity=velocity):
                self.check_ap("snap.position=v(8.5); snap.velocity=" + velocity + """
packet(42); assert(fires==1,'base radius incorrectly depends on incoming velocity')
frameCb(1/60); packet(42); assert(fires==1,'radius check duplicated same cycle')
""")

    def test_resilience_and_ping_radius_exact_boundary(self):
        self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
local geometry=g.getAutoParryGeometry
g.getAutoParryGeometry=function(...)
  local result=geometry(...); result.noWindowParryRadius=11.5; return result
end
snap.velocity=v(0,600); snap.position=v(41.5001)
packet(42); assert(fires==0,'fired outside base + resilience + speed * ping')
snap.position=v(41.5); frameCb(1/60)
assert(fires==1,'did not fire on exact ping/resilience radius boundary')
""")

    def test_inside_radius_keeps_target_and_cooldown_requirements(self):
        self.check_ap("""
snap.position=v(8); snap.velocity=v(0)
packet(99); assert(fires==0,'radius bypassed target')
cd.blocking=true; packet(42); assert(fires==0,'radius bypassed cooldown')
cd.blocking=false; frameCb(1/60); assert(fires==1,'ready radius click delayed')
""")

    def test_training_base_radius_does_not_require_closing_velocity(self):
        self.check_ap("""
snap.mode='training'; snap.trainingRound=1; snap.position=v(8.5); snap.velocity=v(600)
frameCb(1/60); assert(fires==1,'training base radius still requires incoming velocity')
""")

    def test_redirect_radius_keeps_cooldown(self):
        self.check_ap("""
cd.blocking=true; snap.position=v(8.5); snap.velocity=v(600)
packet(42); assert(fires==0)
assert(ap.tryRedirectReturn(snap,tm)==false); assert(fires==0,'redirect radius bypassed cooldown')
cd.blocking=false; assert(ap.tryRedirectReturn(snap,tm)); assert(fires==1)
""")

    def test_radius_tti_gate_uses_minimum_and_maximum_speed_windows(self):
        for speed, boundary, near_boundary in ((16, 20.5, 9.3), (600, 128.5, 38.5)):
            with self.subTest(speed=speed):
                self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
local geometry=g.getAutoParryGeometry
g.getAutoParryGeometry=function(speed,factor)
  local result=geometry(speed,factor)
  result.deflectWindow=0.85-0.65*math.clamp((speed-16)/(600-16),0,1)
  return result
end
""" + f"""
snap.syncSpeed={speed}; snap.speed={speed}; snap.velocity=v(-{speed})
snap.position=v({boundary}+0.001); packet(42)
assert(fires==0,'full window gate fired before arrival horizon')
local timing=ap.getTiming(snap)
assert(math.abs(timing.defenseRadius-(8.5+{speed}*0.05))<1e-9)
assert(timing.radiusGateFactor>=0.4 and timing.radiusGateFactor<0.9)
assert(timing.tti>timing.radiusGateLead)
snap.position=v({near_boundary}-0.000001); frameCb(1/60)
assert(fires==1,'full window TTI gate did not fire')
""")

    def test_radius_tti_rejects_a_nearby_trajectory_that_misses(self):
        self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
snap.position=v(100); snap.velocity=v(-600*math.cos(math.rad(30)),600*math.sin(math.rad(30)))
packet(42); assert(fires==0,'radial approximation accepted a missed trajectory')
assert(ap.getTiming(snap).tti==math.huge)
snap.velocity=v(-600*math.cos(math.rad(10)),600*math.sin(math.rad(10)))
frameCb(1/60); assert(fires==1,'intersecting direction did not activate TTI gate')
""")

    def test_radius_tti_uses_player_relative_velocity(self):
        self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
snap.position=v(100); root.AssemblyLinearVelocity=v(-100)
packet(42); assert(fires==0,'gate ignored player retreat')
assert(math.abs(ap.getTiming(snap).tti-0.123)<1e-9)
root.AssemblyLinearVelocity=v(100); frameCb(1/60)
assert(fires==1,'gate ignored player approach')
""")

    def test_radius_tti_does_not_double_count_ping_and_keeps_cooldown(self):
        self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
snap.position=v(170); packet(42)
assert(fires==0,'ping added to both radius and TTI horizon')
snap.position=v(70); cd.blocking=true; frameCb(1/60)
assert(fires==0,'TTI gate bypassed cooldown')
cd.blocking=false; frameCb(1/60); assert(fires==1)
cd.lastParriedAt=tm+0.001; frameCb(1/60); assert(fires==1,'TTI gate duplicated cycle')
""")

    def test_defense_radius_is_independent_of_window(self):
        self.check_ap("""
g.getAveragePing=function() return 0.05,0.05,1 end
packet(99); snap.position=v(100)
local first=ap.getTiming(snap)
local geometry=g.getAutoParryGeometry
g.getAutoParryGeometry=function(...)
  local result=geometry(...); result.deflectWindow=0.85; return result
end
local second=ap.getTiming(snap)
assert(first.defenseRadius==second.defenseRadius)
assert(first.tti==second.tti,'window changed actual TTI to radius')
assert(first.radiusGateLead~=second.radiusGateLead)
""")

    def test_tti_factor_starts_at_0_4_and_rises_with_urgency(self):
        self.check_ap("""
g.getAveragePing=function() return 0,0,1 end
local geometry=g.getAutoParryGeometry
g.getAutoParryGeometry=function(speed,factor)
  local result=geometry(speed,factor); result.deflectWindow=0.2; result.noWindowParryRadius=8.5; return result
end
snap.syncSpeed=600; snap.speed=600; snap.velocity=v(-600); snap.position=v(500)
local far=ap.getTiming(snap); assert(math.abs(far.radiusGateFactor-0.4)<1e-9)
snap.position=v(100); frameCb(1/60); local near=ap.getTiming(snap)
assert(near.radiusGateFactor>far.radiusGateFactor and near.radiusGateFactor<0.9)
snap.position=v(8.5); frameCb(1/60); local inside=ap.getTiming(snap)
assert(math.abs(inside.radiusGateFactor-0.9)<1e-9)
""")

    def test_fast_target_return_temporarily_raises_tti_factor(self):
        self.check_ap("""
g.getAveragePing=function() return 0,0,1 end
local geometry=g.getAutoParryGeometry
g.getAutoParryGeometry=function(speed,factor)
  local result=geometry(speed,factor); result.deflectWindow=0.2; result.noWindowParryRadius=8.5; return result
end
snap.syncSpeed=600; snap.speed=600; snap.velocity=v(-600); snap.position=v(500)
packet(42); local initial=ap.getTiming(snap).radiusGateFactor
tm=tm+0.05; packet(99); tm=tm+0.05; packet(42)
local returned=ap.getTiming(snap); assert(returned.returnInterval<0.2)
assert(returned.radiusGateFactor>initial)
tm=tm+1; frameCb(1/60); local decayed=ap.getTiming(snap)
assert(decayed.radiusGateFactor<returned.radiusGateFactor)
""")

if __name__ == "__main__":
    unittest.main()
