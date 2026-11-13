"""Offline regression harness; requires the system Lua 5.4 shared library.

The shim translates compound assignments in the tested Luau modules and mocks
Roblox APIs. It does not validate engine scheduling or server-side outcomes.
Run from any directory: python path/to/parry_runtime_regression.py
"""
import ctypes, pathlib, re
lib = ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.luaL_loadstring.restype = ctypes.c_int
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
lib.lua_pcallk.restype = ctypes.c_int
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ctypes.c_void_p]
root = pathlib.Path(__file__).resolve().parents[2] / 'modules' / 'logic'
def run(name, script):
    state = lib.luaL_newstate(); lib.luaL_openlibs(state)
    status = lib.luaL_loadstring(state, script.encode())
    if not status: status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status:
        msg = lib.lua_tolstring(state, -1, None)
        raise RuntimeError(name + ': ' + (msg.decode() if msg else 'unknown'))
    lib.lua_close(state)
    print('PASS', name)

source=(root/'aux/danger.luau').read_text()
fixture = '''
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local V={}; V.__index=function(t,k)
 if k=='Magnitude' then return math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z) end
 if k=='Unit' then return t/t.Magnitude end
 return V[k]
end
local function v(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},V) end
V.__add=function(a,b) return v(a.x+b.x,a.y+b.y,a.z+b.z) end
V.__sub=function(a,b) return v(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__div=function(a,b) return v(a.x/b,a.y/b,a.z/b) end
V.__mul=function(a,b) return v(a.x*b,a.y*b,a.z*b) end
function V:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
Vector3={zero=v(0)}
function typeof(x) return getmetatable(x)==V and 'Vector3' or type(x) end
local module=(function()
'''+source+'''
end)()
local tm=10; local grace=.125; local frozen=false
local ap={enabled=true,armed=true,blocking=false,lastRequestAt=0,lastParriedAt=0,retryAt=0,triggerDistance=20}
local owner={root={Parent=true,Position=v(0),AssemblyLinearVelocity=v(0)}}
local value={ball={},position=v(40),velocity=v(-16),syncSpeed=16,speed=16,targetId=42,serverTime=tm}
local g={isSnapshotValid=function() return true end,getBallFrozen=function() return frozen end,
getDefensePhysics=function() return {killRadius=4,grace=grace,ping=.05,uplink=.025,serverNow=tm} end,
getDeflectGeometry=function() return {fullRadius=100} end}
assert(module.setup({GameInfo=g,AutoParry={getDefenseState=function() return ap end}}))
local function sample(t) tm=t or tm; return module.sample(owner,value,tm,42) end
local function fresh(t) tm=t; value.serverTime=t end
'''
run('normal approach is protected until the AP trigger, not a fixed entry timer',fixture+'''
local r=sample(); assert(r.phase=='watching' and r.protect and not r.urgent)
fresh(10.3); value.position=v(35); r=sample(); assert(r.protect and not r.urgent,'ordinary AP wait activated spam')
value.position=v(19); fresh(10.31); r=sample(); assert(r.phase=='expected' and not r.urgent)
fresh(10.34); r=sample(); assert(not r.urgent and r.protect,'AP lateness alone activated spam with ample margin')
''')
run('critical approach bypasses the extra callback and old AP cycle lock',fixture+'''
grace=.02; value.position=v(6); value.velocity=v(-600); value.syncSpeed=600
ap.armed=false; ap.lastRequestAt=9
local r=sample(); assert(r.urgent and r.phase=='critical' and r.allowSend)
''')
run('pending request is watched, rejected outcome resumes rescue, confirmation ends arrival',fixture+'''
grace=.02; value.position=v(5); value.velocity=v(-600); value.syncSpeed=600
ap.armed=false; ap.lastRequestAt=10
local r=sample(); assert(r.pending and not r.urgent and not r.allowSend,'duplicated the AP request')
fresh(10.05); r=sample(); assert(r.urgent,'unconfirmed request disabled watchdog')
ap.lastParriedAt=10.06; fresh(10.06); r=sample(); assert(r.phase=='resolved' and not r.allowSend)
fresh(10.08); r=sample(); assert(r.phase=='resolved','same rendered arrival fired again')
value.realPosition=v(5); value.syncDirection=v(-1); fresh(10.10); r=sample(); assert(r.urgent,'fresh return remained resolved')
''')
run('a confirmed return inside 40ms does not inherit the prior arrival request',fixture+'''
grace=.02; value.position=v(5);value.velocity=v(-600);value.syncSpeed=600;ap.armed=false;ap.lastRequestAt=10
sample();ap.lastParriedAt=10.005;fresh(10.005);assert(sample().phase=='resolved')
value.realPosition=v(5);value.syncDirection=v(-1);fresh(10.01)
local r=sample();assert(r.urgent and not r.pending,'previous arrival imposed a new 40ms delay')
''')
run('third target and away trajectories never become emergency activation',fixture+'''
value.position=v(5); value.velocity=v(600); value.syncSpeed=600
local r=sample(); assert(not r.urgent and r.phase=='moving_away')
value.targetId=99; r=sample(); assert(not r.urgent and r.phase=='not_target')
value.targetId=42; value.targetUncertain=true; r=sample(); assert(not r.urgent)
''')
run('grace countdown survives retreat and repeated true packets do not renew it',fixture+'''
grace=.125; value.position=v(3); value.velocity=v(-100); value.grace=true
local r=sample(); local deadline=r.deadline
value.position=v(30); value.velocity=v(100); fresh(10.04); r=sample()
assert(r.deadline<=deadline+1e-9,'retreat cancelled server grace')
fresh(10.08); r=sample(); assert(r.deadline<=deadline+1e-9 and r.urgent,'grace was renewed or urgency lost')
''')
run('slowing before grace extends physical margin instead of inventing an impact',fixture+'''
value.position=v(30); value.velocity=v(-300); value.syncSpeed=300; sample()
fresh(10.1); value.velocity=v(-16); value.syncSpeed=16
local r=sample(); assert(r.remaining>1 and not r.urgent)
''')
run('stale snapshots, freeze, teleport and new ball reset the correct state',fixture+'''
grace=.02; value.position=v(5); value.velocity=v(-600); value.syncSpeed=600; ap.armed=false
tm=10.4; local r=sample(); assert(not r.urgent,'stale state triggered instant gate')
fresh(10.41); frozen=true; r=sample(); assert(r.phase=='suspended' and not r.urgent)
frozen=false; value.teleported=true; r=sample(); assert(r.phase=='suspended' and not r.urgent)
value.teleported=false; value.ball={}; fresh(10.42); r=sample(); assert(r.urgent)
''')
run('player velocity and packet age contribute to the danger estimate',fixture+'''
value.position=v(25); value.velocity=v(-100); value.syncSpeed=100
owner.root.AssemblyLinearVelocity=v(60)
local r=sample(); assert(math.abs(r.closing-160)<1e-9)
value.realPosition=v(8);value.syncDirection=v(-1);value.serverTime=9.98;ap.armed=false;grace=.02
r=sample();assert(r.urgent and r.distance<=6.001,'ignored unrendered fresh packet')
''')

gameinfo=(root/'aux/gameinfo.luau').read_text()
physics=gameinfo[gameinfo.index('function GameInfo.getDeflectWindow('):gameinfo.index('function GameInfo.getBallFrozen(')]
physics=re.sub(r'([A-Za-z_][\w.]*) ([+\-*/])= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} {m[2]} ({m[3]})',physics)
geometry=gameinfo[gameinfo.index('function GameInfo.getDeflectGeometry('):gameinfo.index('function GameInfo.getAutoParryGeometry(')]
run('server pressure reduces the actual window to 30ms and grace to 20ms without an artificial floor','''
math.clamp=function(x,a,b) return math.max(a,math.min(b,x)) end
local function finite(x) return type(x)=='number' and x==x and x>-math.huge and x<math.huge end
local pressure=0; local press=nil
local CONFIG={WINDOW_BASE=.85,WINDOW_SPREAD=.65,RANGE_BASE=8.5,AP_WINDOW_HIGH_SPEED=.25}
local GameInfo={getBallSpeedLimits=function() return 16,600 end,getAveragePing=function() return .05 end,getDeflectRange=function() return 8.5 end}
local function sharedLayout() return true end
local function syncData() return {} end
local EMPTY_OPTIONS={}
local players={LocalPlayer={GetAttribute=function() return press end}}
local world={GetServerTimeNow=function() return 10 end}
local gameBall={IsInClash=function() return true end,GetClashMinWindow=function() return .32 end,
 ApplyClashPressure=function(_,w) return w+(.03-w)*pressure end,
 ApplyClashPressureGrace=function(_,g) return g+(.02-g)*pressure end,GetKillDistance=function() return 4 end}
'''+physics+geometry+'''
assert(math.abs(GameInfo.getDeflectWindow(600)-.32)<1e-9)
assert(math.abs(GameInfo.getDefensePhysics().grace-.125)<1e-9)
pressure=1
assert(math.abs(GameInfo.getDeflectWindow(600)-.03)<1e-9)
local p=GameInfo.getDefensePhysics(); assert(math.abs(p.grace-.02)<1e-9 and p.uplink==.025)
local g=GameInfo.getDeflectGeometry(600,'game',1,false)
assert(math.abs(g.effectiveWindow-.08)<1e-9,'legacy minimum window survived pressure')
pressure=0; press=.2; assert(math.abs(GameInfo.getDefensePhysics().grace-.25)<1e-9)
''')

spam=(root/'spam.luau').read_text()
spam=re.sub(r'([A-Za-z_][\w.]*) ([+\-*/])= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} {m[2]} ({m[3]})',spam)
run('emergency send guard pauses and resumes, manual spam bypasses automatic protection','''
local now=0; os.clock=function() return now end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local thread;task={spawn=function(fn) thread=coroutine.create(fn) end,wait=function(x) return coroutine.yield(x) end}
local manual=false; local permit=false;local count=0
local utils={apiVersion=function() return 1 end,getConfigValue=function(k) return ({SpamRateMode='CPS',CPS=25})[k] end,isActive=function() return true end,
 isManualSpamActive=function() return manual end,isAutoSpamActive=function() return true end,
 observeSpam=function() return {Disconnect=function() end} end,observeConfig=function() return {Disconnect=function() end} end,
 trackGlobal=function() end,untrackGlobal=function() end,recordTransition=function() end,recordError=function(_,err) error(err) end}
local m=(function()
'''+spam+'''
end)()
local g={getMinimumSpamInterval=function() return .03 end,getAutoSpamDelay=function() return 0 end}
local r={fireParry=function(_,guard) assert(guard());count=count+1;return true end}
assert(m.setup({Utils=utils,GameInfo=g,Remote=r,AutoSpam={canSend=function() return permit end}}))
local function step(t) now=t;local ok,err=coroutine.resume(thread);assert(ok,err) end
step(0);step(.02);assert(count==0)
permit=true;step(.04);assert(count==1)
permit=false;step(.08);assert(count==1)
manual=true;step(.121);assert(count==2,'automatic guard blocked manual spam')
m.teardown()
''')

# Compile the complete modified modules after translating compound assignments.
for path in [root/'autoparry.luau',root/'autospam.luau',root/'aux/gameinfo.luau',root/'spam.luau',root/'aux/danger.luau']:
    content=path.read_text()
    content=re.sub(r'([A-Za-z_][\w.]*) ([+\-*/])= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} {m[2]} ({m[3]})',content)
    run('compile '+path.name, 'local fn,err=load([====['+content+']====]); assert(fn,err)')

modules={
    'autoparry':root/'autoparry.luau','autospam':root/'autospam.luau',
    'gameinfo':root/'aux/gameinfo.luau','remote':root/'aux/remote.luau',
    'spam':root/'spam.luau','danger':root/'aux/danger.luau','permissions':root/'aux/permissions.luau',
}
script='table.freeze=function(x) return x end; local loaded={}\n'
for name,path in modules.items():
    content=path.read_text()
    content=re.sub(r'([A-Za-z_][\w.]*) ([+\-*/])= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} {m[2]} ({m[3]})',content)
    script+='loaded["'+name+'"]=(assert(load([====['+content+']====])))()\n'
script+='''
local stubs={}
for _,module in pairs(loaded) do
 for alias,provider in pairs(module.__contract.requires or {}) do
  if not loaded[provider] then
   local stub=stubs[provider] or {__contract={requires={},provides={}}};stubs[provider]=stub
   for _,method in ipairs(module.__contract.requiresMethods[alias] or {}) do
    if not stub[method] then stub[method]=function() end; table.insert(stub.__contract.provides,method) end
   end
  end
 end
end
for name,module in pairs(stubs) do loaded[name]=module end
for name,module in pairs(loaded) do assert(loaded.permissions.validate(name,module)) end
for name in pairs(loaded) do assert(loaded.permissions.resolve(name,loaded)) end
local marks={}
local function visit(name)
 assert(marks[name]~=1,'circular dependency '..name)
 if marks[name]==2 then return end
 marks[name]=1
 for _,provider in pairs(loaded[name].__contract.requires or {}) do visit(provider) end
 marks[name]=2
end
for name in pairs(loaded) do visit(name) end
'''
run('real permissions accept all new APIs and the module graph has no cycles',script)
