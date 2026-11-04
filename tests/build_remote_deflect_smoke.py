"""Generate a Luau test for the game's deflect-only parry path."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
output = Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/remote.luau').read_text()
pre = r'''
local deflectCount, touchCount, noteCount = 0, 0, 0
local abilities = {Abilities = {[1] = {Deflect = function() deflectCount += 1 end}}}
local module = {IsA = function(_, kind) return kind == "ModuleScript" end}
local touch = {IsA = function(_, kind) return kind == "BindableEvent" end, Fire = function() touchCount += 1 end}
local ts = {FindFirstChild = function(_, name) if name == "ClientAbilities" then return module end end}
local storage = {FindFirstChild = function(_, name) if name == "TS" then return ts elseif name == "TouchTap" then return touch end end}
local function require(item) assert(item == module); return abilities end
local function typeof(value) if type(value) == "table" and value.instance then return "Instance" end return type(value) end
local CFrame = {identity = {Position = {X=1,Y=2,Z=3}, LookVector = {X=4,Y=5,Z=6}}}
local game = {GetService = function(_, name) if name == "Workspace" then return {CurrentCamera = nil} end return {} end}
local function moduleSource()
'''
post = r'''
end
local remote = moduleSource()
assert(remote.setup({Utils={getReplicatedStorage=function() return storage end,apiVersion=function() return 1 end},GameInfo={getDeflectAbility=function() return abilities.Abilities[1] end,noteDeflectPress=function() noteCount+=1 end}}))
assert(remote.fireParry(1) and deflectCount == 1 and touchCount == 0 and noteCount==1, "must call and register active Deflect")
for _=1,3 do assert(remote.fireParry(1), "repeated Deflect calls must work without a click clock") end
assert(deflectCount==4 and noteCount==4, "repeated calls were not delivered")
abilities.Abilities[1] = {Deflect = function() deflectCount += 10 end}
assert(remote.fireParry(1) and deflectCount == 14 and noteCount==5, "must use replacement ability")
abilities.Abilities[1].Deflect=function() return false end
local ok, reason=remote.fireParry(1); assert(not ok and reason:find("recusou",1,true) and remote.getStatus().state=="deflect_ignored" and noteCount==5, "explicit rejection must not start tracking")
abilities.Abilities[1].Deflect=function() error("deflect failure") end
ok, reason=remote.fireParry(1); assert(not ok and reason:find("deflect failure",1,true) and noteCount==5, "real failures must still be reported")
abilities.Abilities[1] = nil
assert(not remote.fireParry(1) and touchCount == 0, "missing ability must not use TouchTap")
assert(not remote.initParry() and not remote.usesGameDeflect() and remote.getRemote() == nil, "missing ability must not expose another method")
local sent
local fallback = {instance=true, Parent={}, IsA=function(_,kind) return kind == "RemoteEvent" end, FireServer=function(_,payload) sent=payload end}
assert(remote.setParryRemote(fallback))
assert(not remote.fireParry(1) and not sent and touchCount == 0, "captured remote must not be sent directly")
assert(remote.getStatus().method == "unavailable", "status must not report a disabled fallback")
print("Deflect only and disabled fallbacks: PASS")
'''
output.write_text(pre + source + post)
