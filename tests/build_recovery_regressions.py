"""Generate regression tests for character cleanup and configuration recovery."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:3])
character = (root / 'exodus hub/modules/logic/character.luau').read_text()
utils = (root / 'exodus hub/modules/logic/utils.luau').read_text()
pre = r'''
local _G = {}
local warnings = {}
local function warn(message) table.insert(warnings, message) end
local task = {spawn=function(fn) fn() end, delay=function() end, wait=function() end}
local function signal()
    return {Connect=function(_, fn) return {Connected=true, Disconnect=function(self) self.Connected=false end, fire=fn} end}
end
local player = {CharacterAdded=signal(), CharacterRemoving=signal()}
local workspace = {}
local http = {JSONDecode=function() return {Key={keyCode="RemovedKey"}, Enabled=true} end}
local services = {Players={LocalPlayer=player}, ReplicatedStorage={}, RunService={}, Workspace=workspace, HttpService=http}
local game = {GetService=function(_, name) return services[name] end}
local Enum = {KeyCode=setmetatable({}, {__index=function() error("invalid enum member") end})}
local function typeof(v) return type(v) end
local function isfile() return true end
local function isfolder() return true end
local function makefolder() end
local function readfile() return "{}" end
local function writefile() end
local function loadCharacter()
'''
mid = r'''
end
local characterModule=loadCharacter()
local errors, detached = {}, {}
local testUtils={
    getLocalPlayer=function() return player end, isActive=function() return true end,
    apiVersion=function() return 1 end, trackGlobal=function() end, untrackGlobal=function() end,
    trackCharacter=function() end, disconnectCharacterConnections=function() end,
    setManualSpamActive=function() end, setAutoSpamActive=function() end,
    recordTransition=function() end, recordError=function(_, message) table.insert(errors, message) end,
}
local rootPart={Parent=true, IsA=function(_, kind) return kind=="BasePart" end}
local function makeCharacter()
    return {Parent=true, AncestryChanged=signal(), ChildAdded=signal(),
        FindFirstChild=function(_, name) if name=="HumanoidRootPart" then return rootPart end end,
        FindFirstChildOfClass=function() return nil end}
end
player.Character=makeCharacter()
local binds={
    {name="first", bind=function() return true end, detach=function() table.insert(detached,"first") end},
    {name="second", bind=function() error("bind exploded") end, detach=function() table.insert(detached,"second"); error("detach exploded") end},
}
assert(characterModule.setup({Utils=testUtils, Spam={resetState=function() end}, characterBinds=binds}))
assert(characterModule.getStatus().phase=="invalid", "bind errors must invalidate the current life")
assert(#detached==2 and detached[1]=="second" and detached[2]=="first", "all bindings must be cleaned even if detach fails")
assert(#errors==2 and string.find(errors[1],"bind exploded",1,true) and string.find(errors[2],"detach exploded",1,true))
binds[2].bind=function() return true end
player.Character=makeCharacter()
characterModule.teardown()
assert(characterModule.setup({Utils=testUtils, Spam={resetState=function() end}, characterBinds=binds}))
assert(characterModule.getStatus().phase=="bound", "new character should bind after a failure")
characterModule.teardown()
local function loadUtils()
'''
post = r'''
end
local util=loadUtils()
local config={normalizePatch=function(p) return p end, validate=function() return true end,
    validatePatch=function() return true end}
util.setConfigModule(config)
assert(util.loadConfig(), "invalid saved key must not stop loading")
assert(util.getConfigValue("Key")==nil and util.getConfigValue("Enabled")==true, "valid saved settings should survive")
assert(#warnings==1 and string.find(warnings[1],"RemovedKey",1,true), "invalid key should be reported")
print("Character and config recovery: PASS")
'''
output.write_text(pre + character + mid + utils + post, encoding='utf-8')
