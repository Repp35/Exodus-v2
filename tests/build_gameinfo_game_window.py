"""Compare the window formula and its clash-only rules with the game dump."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
source = s[s.index('function GameInfo.getDeflectWindow(speed)'):s.index('function GameInfo.getHaunterRemote()')]
pre = r'''
local GameInfo={getBallSpeedLimits=function() return 16,600 end, getDeflectRange=function() return 8.5 end}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function syncData() return {Speed=600} end
local inClash=false
local players={LocalPlayer={}}
local gameBall={IsInClash=function() return inClash end, GetClashMinWindow=function() return .5 end,
 GetClashWindowScale=function() return .5 end}
'''
post = r'''
assert(math.abs(GameInfo.getDeflectWindow(600)-.2)<1e-6, 'clash minimum outside clash')
inClash=true; assert(math.abs(GameInfo.getDeflectWindow(600)-.25)<1e-6, 'clash minimum and scale')
GameInfo.getDeflectRange=function() return 16 end
assert(math.abs(GameInfo.getDeflectWindow(600)-.31)<1e-6, 'range bonus precedes clash scale')
inClash=false; assert(math.abs(GameInfo.getDeflectWindow(600)-.32)<1e-6, 'range bonus outside clash')
print('GameInfo deflect window: PASS')
'''
output.write_text(pre + source + post)
