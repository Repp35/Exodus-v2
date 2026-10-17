# Generates a Luau loader smoke test with fake Roblox services.
# UI and Enum-backed configuration are stubbed; gameplay is not exercised.
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); out=Path(sys.argv[2]); local_mode = len(sys.argv) > 3 and sys.argv[3] == "local"
files={str(p.relative_to(root/'exodus hub')):p.read_text() for p in (root/'exodus hub/modules').rglob('*.luau')}
files['loader.luau']=(root/'exodus hub/loader.luau').read_text()
files["modules/front/ui.luau"]="return {setup=function() return true end}"
files["modules/front/config.luau"]="return {register=function() return true end, defaults=function() return {} end, validate=function() return true end, normalizePatch=function(p) return p end}"
def quote(s): return '[========['+s+']========]'
pre='''_G = {}
local queue = {}
task = {spawn = function(fn, ...) local args={...}; queue[#queue+1]=function() fn(table.unpack(args)) end end,
 defer = function(fn, ...) local args={...}; queue[#queue+1]=function() fn(table.unpack(args)) end end,
 wait = function() if #queue > 0 then local fn=table.remove(queue,1); fn() end; return 0.016 end}
warn = function(...) print("WARN",...) end
Vector3 = {zero={X=0,Y=0,Z=0,Magnitude=0}}
Enum = {KeyCode=setmetatable({F9={EnumType="KeyCode"}, F={EnumType="KeyCode"}}, {__index=function(t,k) return {EnumType="KeyCode"} end})}
for _, item in pairs(Enum.KeyCode) do item.EnumType=Enum.KeyCode end
typeof=function(v) if type(v)=="table" and v.EnumType==Enum.KeyCode then return "EnumItem" end return type(v) end
local function signal() return {Connect=function(self,fn) return {Connected=true,Disconnect=function(self) self.Connected=false end} end} end
local function obj(fields)
 local o=fields or {}
 return setmetatable(o,{__index=function(self,k)
   if k=="FindFirstChild" or k=="WaitForChild" or k=="FindFirstChildOfClass" then return function() return nil end end
   if k=="GetPlayers" then return function() return {o.LocalPlayer} end end
   if k=="GetAttribute" then return function() return nil end end
   if k=="GetDescendants" then return function() return {} end end
   if k=="IsA" then return function() return false end end
   if k=="SetAttribute" then return function() end end
   if k=="GetService" then return function(self,name) return self.services[name] end end
   if k=="GetNetworkPing" then return function() return 0.05 end end
   if k=="Kick" then return function(_,reason) error("KICK: "..tostring(reason)) end end
   if string.match(k,"Added$") or string.match(k,"Removing$") or k=="Heartbeat" or k=="ChildAdded" or k=="ChildRemoved" or k=="DescendantAdded" or k=="DescendantRemoving" or k=="CharacterAdded" or k=="CharacterRemoving" then return signal() end
   return nil
 end})
end
local player=obj({UserId=123, Name="Tester"})
local services={Players=obj({LocalPlayer=player}),ReplicatedStorage=obj(),Workspace=obj(),RunService=obj(),VirtualInputManager=obj(),HttpService=obj({JSONDecode=function(self,body) return {sha="363ccbbcd9f8943d1594d3842071881c0b526109"} end})}
game=obj({services=services})
local sources={}
'''
for key,value in files.items():
    pre+=f'sources[{json.dumps(key)}] = {quote(value)}\n'
pre+='''local function request(args)
 local path=string.match(args.Url,"/(modules/.+)$")
 if string.find(args.Url,"api.github.com",1,true) then return {StatusCode=200,Body="sha"} end
 local body=path and sources[path]
 if not body then return {StatusCode=404,Body="missing "..tostring(path)} end
 return {StatusCode=200,Body=body}
end
getgenv=function() return {http_request=request} end
local ok, result = pcall(function() return assert(loadstring(sources["loader.luau"]))() end)
assert(ok and type(result)=="table" and _G.Exodus and _G.Exodus.Started == true, tostring(_G.Exodus and _G.Exodus.StartError))
print("Loader smoke test: PASS")
'''
if local_mode:
    pre=pre.replace("local ok, result = pcall", 'isfile=function(path) return sources[string.gsub(path, "^exodus hub/", "")] ~= nil end\nreadfile=function(path) return assert(sources[string.gsub(path, "^exodus hub/", "")]) end\ngetgenv=function() return {} end\n'+"local ok, result = pcall")
out.write_text(pre)
