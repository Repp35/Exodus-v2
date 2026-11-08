"""Exercise the real AP tick with locked spawns, curved motion and mean ping."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/autoparry.luau").read_text()
source = source.replace("return os.clock()", "return testTime", 1)
source = source.replace(
    "return AutoParry\n",
    "return AutoParry, state, tick, samplePing, function(u,g,r) utils=u; gameInfo=g; remote=r end\n",
)
script = r'''
testTime=1
local V={}
V.__index=function(v,k)
    if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    return V[k]
end
V.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z},V) end
function V:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
local function vec(x,y,z) return setmetatable({X=x,Y=y or 0,Z=z or 0},V) end
function typeof(v) if getmetatable(v)==V then return "Vector3" elseif type(v)=="table" and v.instance then return "Instance" end return type(v) end
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local ping=.04
local ball={instance=true,Parent={},IsA=function() return true end}
local rootPart={Parent={},Position=vec(0)}
local character={Parent={}}
local snapshot={ball=ball,position=vec(-55),velocity=vec(600),speed=600,syncSpeed=600,targetId=42,locked=true}
local fires=0
local utils={
  isActive=function() return true end, isSpamActive=function() return false end,
  getConfigValue=function(k) if k=="AutoParryWindowFactor" then return .4 end return true end,
  recordTransition=function() end,recordError=function(_,msg) error(msg) end,
}
local info={
  getSnapshotAt=function() return snapshot end, isSnapshotValid=function() return true end,
  getLocalPing=function() return ping end, getRootPosition=function(root) return root.Position end,
  getBallSpeedLimits=function() return 16,600 end, getDeflectWindow=function() return .2 end,
  getDeflectRange=function() return 8.5 end,
  getDeflectGeometry=function(speed,window,factor,_,latency)
    assert(latency~=nil, "mean ping not passed to geometry")
    return {noWindowParryRadius=8.5,fullRadius=8.5+speed*(window+latency)*factor,
      effectiveWindow=(window+latency)*factor,leadTime=window+latency}
  end,
}
local remote={fireParry=function(_,allowed) assert(allowed()); fires=fires+1; return true end}
local ap,state,tick,sample,inject=assert(loadstring(SOURCE))()
inject(utils,info,remote)
state.player={UserId=42}; state.alive=true; state.bound=true; state.generation=1
state.character=character; state.root=rootPart
tick(character,rootPart,1); assert(fires==0 and state.reason=="ball_locked", "locked spawn fired")
snapshot.locked=false
snapshot.velocity=vec(0,600); tick(character,rootPart,1)
assert(fires==0 and not state.approaching, "sideways curve fired")
snapshot.velocity=vec(60,597); tick(character,rootPart,1)
assert(fires==0 and state.approaching, "curve fired using total speed")
snapshot.position=vec(-12); tick(character,rootPart,1)
assert(fires==1, "approaching curve did not fire at projected threshold")
state.fired=false; snapshot.position=vec(-55); snapshot.velocity=vec(-600)
tick(character,rootPart,1); assert(fires==1, "outgoing ball fired")
snapshot.velocity=vec(600)
tick(character,rootPart,1); assert(fires==2, "straight incoming ball failed")
ping=.08; testTime=1.26; sample(testTime)
assert(math.abs(state.ping-.06)<.0001 and state.pingRaw==.08, "ping is not rolling mean")
ping=.12; testTime=1.52; sample(testTime)
assert(math.abs(state.ping-.08)<.0001)
for i=1,8 do ping=.10; testTime=testTime+.26; sample(testTime) end
assert(#state.pingSamples==8 and math.abs(state.ping-.10)<.0001, "ping samples not bounded")
local before=fires
snapshot.targetId=99; snapshot.position=vec(-12); snapshot.velocity=vec(60,597)
local redirectAt=testTime-.1
assert(ap.tryRedirectReturn(snapshot,redirectAt), "redirected ball did not parry without local target")
assert(fires==before+1, "redirect must send one parry")
assert(ap.tryRedirectReturn(snapshot,redirectAt) and fires==before+1, "redirect sent a double parry")
testTime=testTime+.3; snapshot.targetId=-1
assert(ap.tryRedirectReturn(snapshot,testTime-.1) and fires==before+2, "return must work with no target")
print("Auto Parry trajectory and ping: PASS")
'''
output.write_text(script.replace("SOURCE", "[========[" + source + "]========]", 1))

