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

source=(root/'loader.luau').read_text()
channel=source[source.index('local function startUpdateChannel()'):source.index('local started = startSafely()')]
run('polling fallback and safe stop', """
local revisionA,revisionB=string.rep('a',40),string.rep('b',40)
local manifest=revisionA; local polls,reloads=0,0; local thread
_G.ExodusLoaderSessionToken='session'; _G.ExodusLastLoadedRevision=revisionA
local Exodus={Started=true,Revision=revisionA}; local reloadInFlight=false; local UPDATE_WS_URL='unused'; WebSocket=nil
local function validRevision(x) return type(x)=='string' and #x==40 end
local function closeUpdateChannel() if _G.ExodusUpdateStop then _G.ExodusUpdateStop() end end
local function resolveLatestRevision() polls=polls+1; return manifest end
local function reloadLatest(_,rev,automatic) assert(automatic and rev==revisionB); reloads=reloads+1 end
local HttpService={}
local task={}
function task.spawn(fn) local co=coroutine.create(fn); local ok,err=coroutine.resume(co); assert(ok,err); if coroutine.status(co)~='dead' then thread=co end end
function task.wait(_) coroutine.yield() end
"""+channel+"""
assert(startUpdateChannel()); assert(polls==1 and reloads==0)
manifest=revisionB; local ok,err=coroutine.resume(thread); assert(ok,err); assert(polls==2 and reloads==1)
_G.ExodusUpdateStop(); ok,err=coroutine.resume(thread); assert(ok,err); assert(polls==2)
""")
run('websocket reconnect and manifest authority', """
local a,b,c=string.rep('a',40),string.rep('b',40),string.rep('c',40); local manifest=a; local thread; local sockets={}; local reloads=0
_G.ExodusLoaderSessionToken='session'; _G.ExodusLastLoadedRevision=a
local Exodus={Started=true,Revision=a}; local reloadInFlight=false; local UPDATE_WS_URL='unused'
local function validRevision(x) return type(x)=='string' and #x==40 end
local function closeUpdateChannel() if _G.ExodusUpdateStop then _G.ExodusUpdateStop() end end
local function resolveLatestRevision() return manifest end
local function reloadLatest(_,rev) assert(rev==b,'trusted unverified message'); reloads=reloads+1 end
local HttpService={JSONDecode=function(_,raw) return {event='message',message=raw} end}
local function signal() return {Connect=function(self,fn) self.callback=fn; return {Disconnect=function() self.callback=nil end} end} end
WebSocket={connect=function() local x={OnMessage=signal(),OnClose=signal(),Close=function() end}; sockets[#sockets+1]=x; return x end}
local task={}
function task.spawn(fn) local co=coroutine.create(fn); local ok,err=coroutine.resume(co); assert(ok,err); if coroutine.status(co)~='dead' then thread=co end end
function task.wait(_) coroutine.yield() end
"""+channel+"""
assert(startUpdateChannel()); assert(#sockets==1); sockets[1].OnMessage.callback(c); assert(reloads==0)
sockets[1].OnClose.callback(); local ok,err=coroutine.resume(thread); assert(ok,err); assert(#sockets==2,'no reconnect')
manifest=b; sockets[2].OnMessage.callback(c); assert(reloads==1)
_G.ExodusUpdateStop()
""")
