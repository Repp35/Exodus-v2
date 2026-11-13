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
root = pathlib.Path(__file__).resolve().parents[2]
def run(name, script):
    state = lib.luaL_newstate(); lib.luaL_openlibs(state)
    status = lib.luaL_loadstring(state, script.encode())
    if not status: status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status:
        msg = lib.lua_tolstring(state, -1, None)
        raise RuntimeError(name + ': ' + (msg.decode() if msg else 'unknown'))
    lib.lua_close(state)
    print('PASS', name)


source=(root/'modules/front/ui.luau').read_text()
transition=source[source.index('local function fadeOutForReplacement('):source.index('-- setup',source.index('local function fadeOutForReplacement('))]
run('close and reload wait for all fades', """
local function build(action)
 local faded, destroyed, calls={}, {}, 0
 local UIState={closing=false,pageTweens={}}
 local screenGui={Parent=true,Name='screen'}; local informationGui={Parent=true,Name='information'}
 local function card(key) return {Parent=true,Name=key,GetAttribute=function() return key end,Destroy=function(self) destroyed[self.Name]=true; self.Parent=nil end} end
 local update,other=card('update'),card('other'); local children={update,other}
 local persistentLayer={Parent=true,GetChildren=function() return children end,FindFirstChild=function(_,name) if name=='Notification_other' and other.Parent then return other end end}
 local persistentOrder={'update','other'}; local persistentTweens={}; local flowingTweens={}
 local fadeEvent,fadeDone; local Instance={new=function() return {Event={Wait=function() coroutine.yield() end},Fire=function() end,Destroy=function() end} end}
 local function safeCancel() end
 local function fadeGuiTree(root,tweens) faded[root.Name]=true; tweens[#tweens+1]=root end
 local function awaitTweens() coroutine.yield('waiting') end
 local function _spawn() end; local function _wait() end
 table.find=function(t,x) for i,v in ipairs(t) do if v==x then return i end end end
 local Controls={onClose=function() calls=calls+1 end,onReload=function() calls=calls+1 end}
 local function showPersistentNotification() end; local function restoreAfterReloadFailure() end
"""+transition+"""
 local co=coroutine.create(function() animateClose(action) end); local ok,why=coroutine.resume(co); assert(ok and why=='waiting' and calls==0)
 assert(faded.screen and faded.information and faded.other); assert((faded.update==true)==(action=='close'))
 ok,why=coroutine.resume(co); assert(ok,why); assert(calls==1 and destroyed.other)
 assert((destroyed.update==true)==(action=='close'))
end
build('close'); build('reload')
""")
