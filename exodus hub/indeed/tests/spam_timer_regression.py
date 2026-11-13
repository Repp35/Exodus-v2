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


remote=(root/'aux/remote.luau').read_text()
run('real ability path and rejected click acknowledgement', """
local module=(function()\n"""+remote+"""\nend)()
local ability={ClickInstances={},did={}}; local sent=0
function ability:Deflect() sent=sent+1; table.insert(self.ClickInstances,{Time=1}) end
local info={isTrainingArea=function() return false end,getDeflectAbility=function() return ability end,getLastDeflectPressAt=function() return 0 end}
assert(module.setup({GameInfo=info})); assert(module.fireParry(1)); assert(module.fireParry(1)); assert(sent==2)
ability.did=nil; assert(module.fireParry(1)==false, 'missing remote was treated as sent'); ability.did={}
ability.Deflect=function() end; assert(module.fireParry(1)==false)
assert(module.fireParry(1,function() return false end)==false)
""")
spam=(root/'spam.luau').read_text()
spam=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',spam)
run('explicit CPS follows timer without Auto throttle', """
local now=0; os.clock=function() return now end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
local thread,wake; local task={}
function task.spawn(fn) thread=coroutine.create(fn); local ok,delay=coroutine.resume(thread); assert(ok,delay); wake=now+(delay or 0) end
function task.wait(delay) return coroutine.yield(delay or 0) end
function task.defer(fn) fn() end; function task.delay() end
local module=(function()\n"""+spam+"""\nend)()
local count=0; local active=true
local u={apiVersion=function() return 1 end,getConfigValue=function(k) return ({SpamRateMode='CPS',CPS=40})[k] end,isActive=function() return active end,isManualSpamActive=function() return true end,isAutoSpamActive=function() return false end,observeSpam=function() return {Disconnect=function() end} end,observeConfig=function() return {Disconnect=function() end} end,trackGlobal=function() end,untrackGlobal=function() end,recordTransition=function() end,recordError=function(_,err) error(err) end}
local g={getMinimumSpamInterval=function() return 0.4 end,getAutoSpamDelay=function() return 1 end}
local r={fireParry=function(_,guard) assert(guard()); count=count+1; return true end}
assert(module.setup({Utils=u,GameInfo=g,Remote=r}))
for frame=1,2400 do now=frame/240; if wake and now+1e-8>=wake then local ok,delay=coroutine.resume(thread); assert(ok,delay); wake=now+(delay or 0) end end
print(string.format('SIMULATED 240 FPS: %.1f attempts/s',count/10)); assert(count>=399 and count<=402)
assert(module.getStatus().attemptsLastSecond>=39); active=false; module.teardown()
""")
