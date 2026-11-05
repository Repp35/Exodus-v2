"""Exercise distant third-party redirects for automatic and manual clash spam."""
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / 'exodus hub/modules/logic/autoclash.luau').read_text()
source = s[s.index('function AutoClash.onBallSync(data)'):s.index('function AutoClash.isActive()')]
pre = r'''
local AutoClash={}
local localPlayer={UserId=42}
local current, stopped, manual, distant = nil, 0, false, true
local function id(n) return type(n)=='number' and n>0 and n or nil end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local utils={isManualSpamActive=function() return manual end, stopAllSpam=function() stopped+=1; manual=false end}
local gameInfo={getTargetId=function() return -1 end,getSyncData=function() return nil end}
local function outsideClashRadius(_,target) return distant end
local function setActive(s,active) s.active=active; if not active then s.partner=-1 end end
local function clearReturn(s) s.returnPending=false end
local function rememberDistantRecovery() end
local function clock() return 1 end
local function dispatch() return true end
'''
post = r'''
local function scenario(isManual,previous,partner,far,newTarget,paused)
 manual=isManual; stopped=0; distant=far
 current={active=not paused, target=previous, partner=paused and -1 or partner, recentPartner=partner,
  windowPartner=paused and partner or nil, windowPaused=paused, manualTarget=previous, manualPartner=partner,returnPending=true}
 AutoClash.onBallSync({TargetPlayerID=newTarget})
 return current,stopped
end
for _,manualMode in ipairs({false,true}) do
 for _,previous in ipairs({42,7}) do
  local s,n=scenario(manualMode,previous,7,true,9,false)
  assert(n==1 and not s.active and not s.windowPaused and not s.returnPending, 'distant third party must stop from player or partner')
 end
 local _,n=scenario(manualMode,42,7,true,7,false); assert(n==0,'partner should not be treated as third party')
 local _,near=scenario(manualMode,42,7,false,9,false); assert(near==0,'near third party should not trigger distant stop')
end
local s,n=scenario(false,42,7,true,9,true); assert(n==1 and not s.windowPaused,'paused clash must retain partner')
s,n=scenario(false,-1,7,true,9,false); assert(n==1 and not s.active,'missing previous target must not delay stopping')
s,n=scenario(false,9,7,true,9,false); assert(n==1 and not s.active,'already known distant target must stop immediately')
manual=true; stopped=0; distant=true
current={active=false,target=-1,partner=-1,recentPartner=-1,manualTarget=42,manualPartner=-1}
AutoClash.onBallSync({TargetPlayerID=9}); assert(stopped==1,'unknown partner and distant target must stop manual spam')
manual=false; stopped=0; distant=true
current={active=true,target=42,partner=7,recentPartner=7,manualTarget=-1,manualPartner=-1,sequence=100}
AutoClash.onBallSync({TargetPlayerID=9,Sequence=99}); assert(stopped==0 and current.active, 'old sequence must not stop clash')
AutoClash.onBallSync({TargetPlayerID=9,Sequence=100}); assert(stopped==0 and current.active, 'same sequence with changed target must be ignored')
AutoClash.onBallSync({TargetPlayerID=9,Sequence=101}); assert(stopped==1 and not current.active, 'new sequence must stop clash')
print('Auto Clash distant redirect: PASS')
'''
output.write_text(pre + source + post)
