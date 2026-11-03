"""Generate a Luau test for AP movement and reset synchronization."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
output = Path(sys.argv[2])
s=(root / 'exodus hub/modules/logic/autoparry.luau').read_text().replace('return AutoParry\n','return AutoParry, {state=R, update=updateVelocity, enter=enterTeleportLock, leave=leaveTeleportLock, readTarget=readTargeted, bonus=getResilienceBonus, radius=computeParryRadius, setUtils=function(v) Utils=v end, setInfo=function(v) GameInfo=v end}\n')
pre='''local mt={}\nmt.__index=function(t,k) if k=="Magnitude" then return math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z) end end\nmt.__add=function(a,b) return setmetatable({x=a.x+b.x,y=a.y+b.y,z=a.z+b.z},mt) end\nmt.__sub=function(a,b) return setmetatable({x=a.x-b.x,y=a.y-b.y,z=a.z-b.z},mt) end\nmt.__mul=function(a,b) return setmetatable({x=a.x*b,y=a.y*b,z=a.z*b},mt) end\nmt.__div=function(a,b) return a*(1/b) end\nlocal function vec(x) return setmetatable({x=x,y=0,z=0},mt) end\nlocal Vector3={zero=vec(0)}\nlocal function typeof(x) if getmetatable(x)==mt then return "Vector3" end return type(x) end\nlocal _G={}\nlocal function module()\n'''
post='''\nend\nlocal ap,t=module()\nlocal state=t.state\nlocal seq=99\nt.setInfo({getSyncSequence=function() return seq end, getBallVelocity=function(ball) return ball.AssemblyLinearVelocity end})\nlocal ball={AssemblyLinearVelocity=vec(0)}\nlocal sync={Speed=100}\nassert(t.update(ball,vec(0),1,1/120,sync))\nassert(t.update(ball,vec(1.6667),1+1/120,1/120,sync))\nassert(state.velocity.Magnitude>0)\nlocal v=state.velocity.Magnitude\nassert(t.update(ball,vec(1.6667),1+2/120,1/120,sync))\nassert(state.velocity.Magnitude==v,"zero frame removed movement")\nassert(not t.update(ball,vec(1000),1+3/120,1/120,sync),"teleport treated as speed")\nassert(state.velocity.Magnitude==0)\nassert(t.update(ball,vec(1000),1+4/120,1/120,sync))\nassert(t.update(ball,vec(1001.6667),1+5/120,1/120,sync))\nassert(state.velocity.Magnitude>0,"movement after reset blocked")\nstate.firedForTarget=true; state.lastTarget=42\nt.enter(2,100)\nassert(state.teleported and state.lastBall==nil and not state.firedForTarget and state.lastTarget==-1)\nassert(not t.leave(2),"stale sequence released reset")\nseq=100; assert(t.leave(2) and not state.teleported)\nseq=65535; t.enter(3,0); assert(not t.leave(3)); seq=0; assert(t.leave(3))\nt.enter(4,65535); seq=0; assert(t.leave(4),"wraparound rejected")\nstate.player={UserId=42, GetAttribute=function(_,name) if name=="DeflectRange" then return 16 end end}
state.alive=true; state.bound=true
t.setInfo({getDeflectRange=function() return state.player:GetAttribute("DeflectRange") end})
assert(t.bonus(5)==7.5, "resilience must use published range")
state.player.GetAttribute=function() return 8.95 end
assert(math.abs(t.bonus(6)-0.45)<0.0001)
state.player.GetAttribute=function() return 100 end
assert(t.bonus(7)==7.5, "resilience must cap total range at 16")
t.setInfo({getSyncData=function() return {TargetPlayerID=9,HighlightTargetPlayerID=42} end})
assert(not t.readTarget({targetId=9,targeted=true}), "old local target bypassed current target")
assert(not t.readTarget(nil), "highlight bypassed real target")
assert(t.readTarget({targetId=42}))
t.setUtils({getConfig=function() return {AutoParryWindowFactor=0.5} end})
local radius,lead=t.radius(100,0.1,0,nil)
assert(math.abs(radius-(8.5+100*0.5*0.5))<0.00001 and lead==0.5, "reference timing changed")
print("AP movement, reset, target, timing and resilience: PASS")\n'''
output.write_text(pre+s+post)
