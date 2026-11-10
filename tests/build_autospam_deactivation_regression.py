"""Exercise deactivation against invalid, stale, locked, and fresh packet data."""
from pathlib import Path
import subprocess
import sys

root, output = map(Path, sys.argv[1:3])
subprocess.run([sys.executable, str(root / 'tests/build_autospam_return_timeout.py'), str(root), str(output)], check=True)
script = output.read_text().split('start(s,"return_target",7,clock,nil,snap)', 1)[0]
script += r'''
local function reset(t)
 clock=t; auto=true; manual=true
 s.active=true; s.partner=7; s.target=42; s.activatedAt=t-1; s.returnWatchAt=t-.2
 snap.valid=true; snap.targetUncertain=false; snap.locked=false; snap.syncAt=t
 snap.targetId=42; snap.syncSpeed=600; snap.position=vec(5); snap.velocity=vec(600)
end
reset(50); snap.valid=false
assert(reason(s,snap,clock,nil,false)==nil and s.returnWatchAt==nil, 'invalid snapshot timed out')
reset(51); snap.targetUncertain=true
assert(reason(s,snap,clock,nil,false)==nil and s.returnWatchAt==nil, 'uncertain target timed out')
reset(52); snap.locked=true
assert(reason(s,snap,clock,nil,false)==nil and s.returnWatchAt==nil, 'locked snapshot timed out')
reset(53); snap.syncAt=52.8
assert(reason(s,snap,clock,nil,false)==nil and s.returnWatchAt~=nil, 'brief packet gap timed out')
snap.syncAt=52.4
assert(reason(s,snap,clock,nil,false)==nil and s.returnWatchAt==nil, 'long packet gap kept old timer')
reset(54)
assert(reason(s,snap,clock,nil,false)=='return_timeout', 'fresh overdue return was missed')
reset(55); snap.targetId=99
assert(reason(s,snap,clock,nil,true)=='distant_target', 'redirect was mistaken for a return timeout')
reset(56); snap.valid=false; snap.targetId=99
mod.onBallSync({Source='packet',Sequence=1,TargetPlayerID=99,Speed=600})
assert(auto and manual and s.active, 'invalid redirect packet stopped spam')
reset(57); snap.locked=true
mod.onBallSync({Source='packet',Sequence=2,TargetPlayerID=7,Speed=600,Locked=true})
assert(auto and s.returnWatchAt==nil, 'locked packet armed the return timer')
snap.locked=false; clock=57.01
mod.onBallSync({Source='packet',Sequence=3,TargetPlayerID=7,Speed=600,Locked=false})
assert(auto and s.returnWatchAt==clock, 'fresh unlocked packet failed to rearm the timer')
print('Auto Spam deactivation regression: PASS')
'''
output.write_text(script)
