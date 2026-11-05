"""Test the Auto Clash window from the dumped deflect rules."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / "exodus hub/modules/logic/autoclash.luau").read_text()
helper = s[s.index("local function withinDeflectWindow("):s.index("local function geometry(")]
pre = r'''
local mt={}
mt.__index=function(a,k) if k=="Magnitude" then return math.abs(a.X) elseif k=="Dot" then return function(x,y) return x.X*y.X end end end
mt.__sub=function(a,b) return setmetatable({X=a.X-b.X,Y=0,Z=0},mt) end
local function v(x) return setmetatable({X=x,Y=0,Z=0},mt) end
local function typeof(x) return getmetatable(x)==mt and "Vector3" or type(x) end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function vector(x) return typeof(x)=="Vector3" and finite(x.X) and finite(x.Y) and finite(x.Z) end
local function id(x) return type(x)=="number" and x>0 and x or nil end
local root=v(0)
local function rootPosition() return root end
local localPlayer={UserId=42}
local ball={targetId=42,position=v(-50),velocity=v(100)}
local ability={DeflectDistance=10}
local gameInfo={getDeflectAbility=function() return ability end, getSyncData=function() return {Speed=100} end,
 getDeflectWindow=function(speed) assert(speed==100); return .3 end}
'''
post = r'''
assert(not withinDeflectWindow({},ball), "ball reaches range after window")
ball.position=v(-39); assert(withinDeflectWindow({},ball), "ball reaches range during window")
ball.velocity=v(-100); assert(not withinDeflectWindow({},ball), "ball moving away")
ball.position=v(-5); assert(withinDeflectWindow({},ball), "ball in range")
ball.targetId=7; assert(not withinDeflectWindow({},ball), "different target")
ball.targetId=42; ball.teleported=true; assert(not withinDeflectWindow({},ball), "teleport")
ball.teleported=false; ability.DeflectDistance=nil; assert(not withinDeflectWindow({},ball), "unknown range")
ability.DeflectDistance=10; gameInfo.getDeflectWindow=function() return nil end
assert(not withinDeflectWindow({},ball), "unknown window")
print("Auto Clash game window: PASS")
'''
output.write_text(pre + helper + post)
