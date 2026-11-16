"""Regression checks for config-driven universal toggle synchronization."""
import unittest
from test_raw_target_parry import ROOT, run_lua

class UniversalToggleSync(unittest.TestCase):
    def test_invisicam_config_changes_and_existing_mode(self):
        source = (ROOT / 'extras/universal/invisicam.luau').read_text()
        run_lua('''
Enum={DevCameraOcclusionMode={Invisicam='invisicam',Zoom='zoom'}}
local player={DevCameraOcclusionMode='invisicam'}
local config={UniversalInvisicam=true}; local listeners={}
local utils={getLocalPlayer=function() return player end,getConfigValue=function(k) return config[k] end}
function utils.observeConfig(fn) local c={connected=true}; function c:Disconnect() self.connected=false end; listeners[#listeners+1]={c,fn}; return c end
function utils.setConfig(patch)
  local changed={}; for k,v in pairs(patch) do if config[k]~=v then config[k]=v; changed[k]=v end end
  if next(changed) then for _,entry in ipairs(listeners) do if entry[1].connected then entry[2](changed) end end end
  return true
end
warn=function() end
local module=(function()\n''' + source + '''\nend)()
assert(module.setup({Utils=utils})); assert(player.DevCameraOcclusionMode=='invisicam')
utils.setConfig({UniversalInvisicam=false}); assert(player.DevCameraOcclusionMode=='zoom','config off left invisicam active')
utils.setConfig({UniversalInvisicam=true}); assert(player.DevCameraOcclusionMode=='invisicam')
assert(module.setEnabled(false)); assert(player.DevCameraOcclusionMode=='zoom')
module.teardown(); utils.setConfig({UniversalInvisicam=true}); assert(player.DevCameraOcclusionMode=='zoom','observer leaked after teardown')
''')

    def test_all_universal_toggles_observe_config(self):
        for file,key in [('fly','UniversalFly'),('speed','UniversalSpeedEnabled'),('gravity','UniversalGravityEnabled'),('infinitejump','UniversalInfiniteJump'),('noclip','UniversalNoclip'),('invisicam','UniversalInvisicam')]:
            with self.subTest(file=file):
                source=(ROOT / 'extras/universal' / (file+'.luau')).read_text()
                self.assertIn('if changes.'+key+' ~= nil then',source)
                self.assertIn('configObserver:Disconnect()',source)

if __name__ == '__main__': unittest.main()
