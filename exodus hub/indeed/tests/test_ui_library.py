"""Behavioral UI checks with a small Roblox test double and real Lua execution.

Covers state and lifecycle behavior, not engine rendering, text metrics or scheduling.
The system Lua 5.4 shared library is required, as in the existing runtime harnesses.
"""
import ctypes
import hashlib
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ctypes.CDLL('liblua5.4.so.0')
LIB.luaL_newstate.restype = ctypes.c_void_p
LIB.luaL_openlibs.argtypes = [ctypes.c_void_p]
LIB.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p]
LIB.luaL_loadbufferx.restype = ctypes.c_int
LIB.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
LIB.lua_pcallk.restype = ctypes.c_int
LIB.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
LIB.lua_tolstring.restype = ctypes.c_char_p
LIB.lua_close.argtypes = [ctypes.c_void_p]


def lua(source):
    return re.sub(r'([A-Za-z_][\w.]*) ([+\-*/])= ([^;\n]+?)(?=;|\n| end)',
                  lambda m: f'{m[1]} = {m[1]} {m[2]} ({m[3]})', source)


MODULE_PATHS = dict(re.findall(r'\{\s*name\s*=\s*"(\w+)",\s*path\s*=\s*"([^"]+)"\s*\}', (ROOT / 'loader.luau').read_text()))


def module_path(name):
    return ROOT / MODULE_PATHS[name]


def module(name):
    source = lua(module_path(name).read_text())
    return f'{name} = assert(load([==[{source}]==], "@{name}.luau"))()\n'


PRELUDE = '''
function table.clone(t) local copy={} for k,v in pairs(t) do copy[k]=v end return copy end
function table.clear(t) for k in pairs(t) do t[k]=nil end end
function table.find(t,x) for k,v in ipairs(t) do if v==x then return k end end end
function table.freeze(t) return t end
function math.clamp(x,a,b) return math.max(a,math.min(b,x)) end
'''
MOCK = (Path(__file__).parent / 'fixtures/roblox_ui.txt').read_text()
MODULES = ''.join(module(name) for name in ('uitheme', 'uiruntime', 'uiicons', 'uidisplay', 'uicontrols', 'uiinputs', 'uiselection', 'uidropdown', 'uikit', 'uipages', 'uiconfig', 'uinotifications', 'uiactions', 'uicontext', 'uiwindow', 'uifloating', 'uinotificationview', 'uitelemetry', 'uiinput', 'uilifecycle', 'ui'))
SETUP = '''
assert(uitheme.setup())
assert(uiruntime.setup({Theme=uitheme}))
assert(uiicons.setup({Theme=uitheme}))
assert(uikit.setup({Theme=uitheme,Runtime=uiruntime,Icons=uiicons,Display=uidisplay,ControlComponents=uicontrols,Inputs=uiinputs,Selection=uiselection,Dropdown=uidropdown}))
local config=table.clone(uiconfig.__config.defaults)
config.UniversalFly=false;config.UniversalFlySpeed=1;config.UniversalSpeedEnabled=false;config.UniversalSpeed=16
config.UniversalGravityEnabled=false;config.UniversalGravity=196.2
local changed,spamChanged=signal(),signal()
local writes,manual=0,false
local utils={
 getConfigValue=function(key) return config[key] end,
 getConfig=function() return table.clone(config) end,
 setConfig=function(patch)
  writes=writes+1
  local changes={}
  for key,value in pairs(patch) do if config[key]~=value then config[key]=value;changes[key]=value end end
  if next(changes) then changed:Fire(changes) end
  return true
 end,
 observeConfig=function(fn) return changed:Connect(fn) end,
 observeSpam=function(fn) return spamChanged:Connect(fn) end,
 getLocalPlayer=function() return game:GetService('Players').LocalPlayer end,
 isActive=function() return true end,
 isManualSpamActive=function() return manual end,
 setManualSpamActive=function(value) if manual~=value then manual=value;spamChanged:Fire() end end,
 resetConfig=function() return true end,
 normalizeSpamRate=function(value,fallback) return tonumber(value) or fallback end,
 recordError=function() end, stop=function() end,
 name=function() return 'Exodus' end,version=function() return '2' end,author=function() return 'Repp' end,
}
local abilities=true
local abilityChanged=signal()
local gameInfo={
 areAbilitiesEnabled=function() return abilities end,
 observeAbilityMode=function(fn) return abilityChanged:Connect(fn) end,
 getSnapshotAt=function() return {} end,isSnapshotValid=function() return false end,
 createCrateNetwork=function() return {} end,spinCrate=function() return true end,
}
assert(uiactions.setup({Utils=utils,GameInfo=gameInfo,Dumper={isRunning=function() return false end,start=function() return true end}}))
local playerGui=game:GetService('Players').LocalPlayer:FindFirstChildOfClass('PlayerGui')
local screen=Instance.new('ScreenGui');screen.DisplayOrder=100;screen.Parent=playerGui
local panel=Instance.new('Frame');panel.Parent=screen
local function newKit(extra)
 local options={parent=screen,read=utils.getConfigValue,write=function(k,v) return utils.setConfig({[k]=v}) end,observe=utils.observeConfig}
 for key,value in pairs(extra or {}) do options[key]=value end
 return uikit.create(options)
end
local function fullDeps()
 return {Utils=utils,UIConfig=uiconfig,GameInfo=gameInfo,AutoSpam={getStatus=function() return {} end},
  UIKit=uikit,UIPages=uipages,UIActions=uiactions,Runtime=uiruntime,Theme=uitheme,NotificationPolicy=uinotifications,Context=uicontext,Window=uiwindow,Floating=uifloating,Notifications=uinotificationview,Telemetry=uitelemetry,Input=uiinput,Lifecycle=uilifecycle,Controls={}}
end
'''


class UILibraryTests(unittest.TestCase):
    def run_lua(self, script):
        source = (PRELUDE + MOCK + MODULES + SETUP + script).encode()
        state = LIB.luaL_newstate()
        LIB.luaL_openlibs(state)
        try:
            result = LIB.luaL_loadbufferx(state, source, len(source), b'ui_library_tests', None)
            if not result:
                result = LIB.lua_pcallk(state, 0, 1, 0, 0, None)
            if result:
                error = LIB.lua_tolstring(state, -1, None)
                self.fail(error.decode() if error else 'Unknown Lua error')
            value = LIB.lua_tolstring(state, -1, None)
            return value.decode() if value else None
        finally:
            LIB.lua_close(state)

    def scene_digest(self, desktop):
        script = '''
local service=game:GetService('UserInputService')
service.KeyboardEnabled=DESKTOP;service.MouseEnabled=DESKTOP;service.TouchEnabled=not DESKTOP
assert(ui.setup(fullDeps(),{open=true}));flushDeferred();finishTweens()
local keys={'ClassName','Name','Size','Position','AnchorPoint','LayoutOrder','BackgroundColor3','BackgroundTransparency','Text','TextSize','Font','TextColor3','TextTransparency','Image','ImageTransparency','Rotation','CornerRadius','Color','Thickness','Padding','PaddingLeft','PaddingRight','PaddingTop','PaddingBottom','AutomaticSize','AutomaticCanvasSize','ScrollBarThickness','GroupTransparency','Visible','ZIndex'}
local function atom(value)
 if type(value)~='table' then return tostring(value) end
 if value.__type=='EnumItem' then return value.Name end
 local parts={}
 for key,item in pairs(value) do if key~='__type' then parts[#parts+1]=tostring(key)..'='..atom(item) end end
 table.sort(parts);return '{'..table.concat(parts,',')..'}'
end
local function tree(root)
 local parts={}
 for _,key in ipairs(keys) do parts[#parts+1]=key..'='..atom(root._props[key]) end
 local children={}
 for _,child in ipairs(root:GetChildren()) do children[#children+1]=tree(child) end
 table.sort(children)
 return '('..table.concat(parts,';')..'['..table.concat(children)..'])'
end
return tree(playerGui)
'''.replace('DESKTOP', 'true' if desktop else 'false')
        return hashlib.sha256(self.run_lua(script).encode()).hexdigest()

    def test_modularization_preserves_desktop_and_mobile_scene_properties(self):
        expected = json.loads((Path(__file__).parent / 'fixtures/ui-scene.json').read_text())
        for desktop in (True, False):
            with self.subTest(desktop=desktop):
                self.assertEqual(self.scene_digest(desktop), expected['desktop' if desktop else 'mobile'])

    def test_dropdown_stays_below_trigger_and_follows_motion_and_scaling(self):
        self.run_lua('''
local kit=newKit()
local select=kit.Components.dropdown(panel,{key='ClickMethod',choices={'Deflect','Direct'}})
local trigger=findDescendant(select.Root,'Select')
select.Root.AbsolutePosition=Vector2.new(100,550);select.Root.AbsoluteSize=Vector2.new(220,64)
trigger.AbsolutePosition=Vector2.new(110,579);trigger.AbsoluteSize=Vector2.new(200,28)
click(trigger);local portal=playerGui:FindFirstChild('ExodusDropdown');assert(portal)
local menu=portal:FindFirstChildOfClass('CanvasGroup')
assert(menu.Position.Y.Offset==619 and menu.Position.X.Offset==110,'popup overlaps the activating card')
local border=select.Root:FindFirstChildOfClass('UIStroke');local popupBorder=menu:FindFirstChildOfClass('UIStroke')
assert(border.Color==popupBorder.Color and border.Thickness==popupBorder.Thickness)
assert(border:FindFirstChildOfClass('UIGradient') and popupBorder:FindFirstChildOfClass('UIGradient'))
assert(trigger.Text=='' and findDescendant(trigger,'Selected').Text=='Deflect')
assert(findDescendant(trigger,'Icon_chevron'):IsA('ImageLabel'))
select.Root.AbsolutePosition=Vector2.new(140,600);select.Root.AbsoluteSize=Vector2.new(110,32)
trigger.AbsolutePosition=Vector2.new(145,614.5);trigger.AbsoluteSize=Vector2.new(100,14)
game:GetService('RunService').Heartbeat:Fire(0.016)
assert(menu.Position.Y.Offset==634.5 and menu.Position.X.Offset==145 and menu.Size.X.Offset==100)
assert(menu.Size.Y.Offset<=720-menu.Position.Y.Offset-6,'popup leaves viewport')
click(trigger);assert(not playerGui:FindFirstChild('ExodusDropdown'),'trigger must close its own popup')
kit.destroy();assert(listenerCount()==0)
''')

    def test_dropdown_scrolls_owner_for_room_without_flipping_above(self):
        self.run_lua('''
local kit=newKit();local scroll=Instance.new('ScrollingFrame');scroll.Parent=panel
scroll.AbsolutePosition=Vector2.new(100,400);scroll.AbsoluteSize=Vector2.new(240,290)
local select=kit.Components.dropdown(scroll,{choices={'A','B','C','D','E'}})
select.Root.AbsolutePosition=Vector2.new(100,625);select.Root.AbsoluteSize=Vector2.new(220,64)
local trigger=findDescendant(select.Root,'Select')
trigger.AbsolutePosition=Vector2.new(110,654);trigger.AbsoluteSize=Vector2.new(200,28)
click(trigger);local portal=playerGui:FindFirstChild('ExodusDropdown');assert(portal)
local menu=portal:FindFirstChildOfClass('CanvasGroup');local shift=scroll.CanvasPosition.Y
assert(shift>0 and menu.Position.Y.Offset>=689,'opening must not cover its trigger')
select.Root.AbsolutePosition=Vector2.new(100,625-shift);trigger.AbsolutePosition=Vector2.new(110,654-shift)
game:GetService('RunService').Heartbeat:Fire(0.016)
assert(menu.Position.Y.Offset==694-shift and menu.Size.Y.Offset>100)
assert(menu.Position.Y.Offset>=trigger.AbsolutePosition.Y+trigger.AbsoluteSize.Y)
kit.destroy();scroll:Destroy();assert(listenerCount()==0)
''')

    def test_selector_colors_follow_modes_and_custom_choice_colors(self):
        self.run_lua('''
local kit=newKit({reducedMotion=true})
local rate=kit.Components.rate_selector(panel,{title='Rate'})
local thumb=findDescendant(rate.Root,'Thumb')
for _, mode in ipairs({'CPS','CPF','MS','Auto'}) do
 utils.setConfig({SpamRateMode=mode})
 assert(thumb.BackgroundColor3==uitheme.tokens.SELECTOR_COLORS[mode],'rate mode lost its semantic color')
end
local spam=kit.Components.segmented(panel,{key='ManualSpamMode',options={{value='Toggle',label='Toggle'},{value='Hold',label='Hold'}}})
local toggleColor=findDescendant(spam.Root,'Thumb').BackgroundColor3
utils.setConfig({ManualSpamMode='Hold'})
assert(findDescendant(spam.Root,'Thumb').BackgroundColor3==uitheme.tokens.COLORS.hold)
assert(findDescendant(spam.Root,'Thumb').BackgroundColor3~=toggleColor)
local custom=Color3.fromRGB(1,2,3)
local tabs=kit.Components.tabs(panel,{value='custom',choices={{value='custom',label='Custom',color=custom}}})
assert(findDescendant(tabs.Root,'Thumb').BackgroundColor3==custom)
kit.destroy()
''')

    def test_panel_border_fades_with_surface_during_minimize_and_reopen(self):
        self.run_lua('''
assert(ui.setup(fullDeps(),{open=true}));flushDeferred()
local root=playerGui:FindFirstChild('ExodusUISystem');local panel=findDescendant(root,'ExodusPanel')
local border=panel:FindFirstChildOfClass('UIStroke')
assert(panel.GroupTransparency==1 and border.Transparency==1,'opening border flashed before surface')
stepTweens(0.5);assert(panel.GroupTransparency==0.5 and border.Transparency==0.5)
finishTweens();assert(border.Transparency==0)
local minimize=findDescendant(root,'MinimizePanel')
click(minimize);stepTweens(0.5)
assert(panel.Visible and panel.GroupTransparency==0.5 and border.Transparency==0.5,'border did not fade with panel')
finishTweens();assert(not panel.Visible and border.Transparency==1)
click(findDescendant(root,'ExodusFloatingButton'));stepTweens(0.5)
assert(panel.Visible and panel.GroupTransparency==0.5 and border.Transparency==0.5)
click(minimize);click(findDescendant(root,'ExodusFloatingButton'));finishTweens()
assert(panel.Visible and panel.GroupTransparency==0 and border.Transparency==0)
local co=coroutine.create(function() _G.ExodusUIFadeOut(false) end)
local ok,err=coroutine.resume(co);assert(ok,err);stepTweens(0.5)
assert(border.Transparency==0.5,'replacement did not fade the panel border')
finishTweens();ok,err=coroutine.resume(co);assert(ok,err)
assert(border.Transparency==1)
_G.ExodusUICleanup();finishTweens();assert(listenerCount()==0 and activeTweenCount()==0)
''')

    def test_embedded_png_icons_load_once_without_network(self):
        expected = (ROOT / 'assets/ui/settings.png').read_bytes()
        literal = '"' + ''.join(f'\\{byte:03d}' for byte in expected) + '"'
        revision = re.search(r'VERSION = "([^"]+)"', module_path('uiicons').read_text())[1]
        self.run_lua('''
local files, writes={},0
makefolder=function() end;isfolder=function() return true end
writefile=function(path,content) files[path]=content;writes=writes+1 end
getcustomasset=function(path) return 'rbxasset://test/'..path end
local icon=uiicons.create(panel,'settings')
assert(icon:IsA('ImageLabel') and icon.Image:find('rbxasset://test/',1,true)==1)
assert(files['ExodusUIAssets/''' + revision + '''-settings.png']==''' + literal + ''')
uiicons.create(panel,'settings');assert(writes==1,'icon bytes were written more than once')
panel:Destroy()
''')

    def test_hub_has_no_font_icons_or_emojis(self):
        sources = '\n'.join(p.read_text() for p in (ROOT / 'modules/front').rglob('*.luau'))
        self.assertNotRegex(sources, '[\\U0001F300-\\U0001FAFF\\u2600-\\u27FF\\uFE0F]')
        self.assertNotIn('▾', sources)

    def test_dropdown_press_is_preview_and_selection_remains_visible_before_fade(self):
        self.run_lua('''
local kit=newKit();local select=kit.Components.dropdown(panel,{key='ClickMethod',choices={'Deflect','Direct'}})
local trigger=findDescendant(select.Root,'Select');local touch=input('Touch',110,110)
trigger.InputBegan:Fire(touch);finishTweens()
assert(select.Border.Color==uitheme.tokens.COLORS.accent and not playerGui:FindFirstChild('ExodusDropdown'))
game:GetService('UserInputService').InputEnded:Fire(touch);finishTweens()
assert(config.ClickMethod=='Deflect','holding the opener selected a value')
click(trigger);finishTweens();local portal=playerGui:FindFirstChild('ExodusDropdown')
local item
for _, object in ipairs(portal:GetDescendants()) do if object:IsA('TextButton') and object.Text=='Direct' then item=object end end
assert(item)
item.MouseEnter:Fire();item.InputBegan:Fire(touch);finishTweens()
assert(item:FindFirstChildOfClass('UIStroke').Transparency==0 and config.ClickMethod=='Deflect')
assert(item.BackgroundColor3==uitheme.tokens.COLORS.cardHover and item.BackgroundTransparency==0.1)
game:GetService('UserInputService').InputEnded:Fire(touch);click(item);finishTweens()
assert(config.ClickMethod=='Direct' and portal.Parent and item.BackgroundTransparency==0.1,'selection vanished before feedback')
flushDelays();assert(portal.Parent,'fade must run after the selection delay')
finishTweens();assert(not portal.Parent)
click(trigger);kit.dismiss();flushDelays();finishTweens();assert(not playerGui:FindFirstChild('ExodusDropdown'))
kit.destroy();assert(listenerCount()==0)
''')

    def test_dropdown_highlight_is_exclusive_and_fades_after_touch_release(self):
        self.run_lua('''
local kit=newKit();local dropdown=kit.Components.dropdown(panel,{key='ClickMethod',choices={'Deflect','Direct','Input'}})
click(findDescendant(dropdown.Root,'Select'));finishTweens()
local portal=playerGui:FindFirstChild('ExodusDropdown');local direct,other,selected
for _, item in ipairs(portal:GetDescendants()) do
 if item:IsA('TextButton') and item.Text=='Deflect' then selected=item end
 if item:IsA('TextButton') and item.Text=='Direct' then direct=item end
 if item:IsA('TextButton') and item.Text=='Input' then other=item end
end
assert(selected:FindFirstChildOfClass('UIStroke').Transparency==1)
local one=input('Touch',110,120);local two=input('Touch',110,150)
direct.InputBegan:Fire(one);finishTweens();assert(direct.BackgroundTransparency==0.1)
other.InputBegan:Fire(two);finishTweens()
assert(direct.BackgroundTransparency==1 and direct:FindFirstChildOfClass('UIStroke').Transparency==1)
assert(other.BackgroundTransparency==0.1 and other:FindFirstChildOfClass('UIStroke').Transparency==0)
game:GetService('UserInputService').InputEnded:Fire(two);stepTweens(0.5)
assert(other.BackgroundTransparency>0.1 and other.BackgroundTransparency<1,'highlight did not fade smoothly')
finishTweens();assert(other.BackgroundTransparency==1 and other:FindFirstChildOfClass('UIStroke').Transparency==1)
assert(config.ClickMethod=='Deflect','pressing changed the selection')
kit.destroy()
''')

    def test_shortcut_registry_uses_the_same_actions_and_can_clear_bindings(self):
        self.run_lua('''
local calls=0;local deps=fullDeps();deps.Controls.onUniversalToggle=function(feature,enabled) assert(feature=='Fly' and enabled);calls=calls+1 end
assert(ui.setup(deps,{open=true}));flushDeferred();finishTweens()
local root=playerGui:FindFirstChild('ExodusUISystem');local fly=findDescendant(root,'UniversalFly')
local cap=findDescendant(fly,'Shortcut_FlyKeybind')
assert(config.FlyKeybind==Enum.KeyCode.Unknown)
click(cap);game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'K'))
assert(config.FlyKeybind==Enum.KeyCode.K)
game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'K'),false)
assert(config.UniversalFly and calls==1,'shortcut did not use the rendered control action')
local toast=findDescendant(playerGui,'ExodusToast');assert(toast and findDescendant(toast,'TextLabel').Text=='Fly On')
click(cap);game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'P'))
assert(config.FlyKeybind==Enum.KeyCode.K,'duplicate shortcut replaced an existing binding')
click(cap);game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'Backspace'))
assert(config.FlyKeybind==Enum.KeyCode.Unknown)
utils.setConfig({FierceKeybind=Enum.KeyCode.L});abilities=false
game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'L'),false);assert(not config.AutoFierce)
_G.ExodusUICleanup();finishTweens();assert(listenerCount()==0)
''')

    def test_notification_policy_and_desktop_child_are_platform_specific(self):
        self.run_lua('''
local policy=uinotifications.shouldShow
assert(policy(config,true,{category='shortcut',topic='AutoSpam'}))
assert(not policy(config,false,{category='shortcut',topic='AutoSpam'}))
for _, desktop in ipairs({true,false}) do
 assert(not policy(config,desktop,{category='interaction'}))
 assert(not policy(config,desktop,{category='shortcut',topic='manualSpam'}))
 assert(not policy(config,desktop,{category='shortcut',topic='upDash'}))
 assert(policy(config,desktop,{category='system'}))
end
config.DesktopShortcutNotifications=false;assert(not policy(config,true,{category='shortcut'}))
config.DesktopNotifications=false;config.MobileNotifications=false
assert(not policy(config,true,{category='system'}) and not policy(config,false,{category='system'}))
assert(policy(config,false,{category='critical'}) and policy(config,true,{category='lifecycle'}))
config.DesktopNotifications=true
assert(ui.setup(fullDeps(),{open=true}));flushDeferred();finishTweens()
local root=playerGui:FindFirstChild('ExodusUISystem');assert(findDescendant(root,'DesktopShortcutNotifications'))
utils.setConfig({DesktopNotifications=false});finishTweens()
assert(not uiruntime.isVisible(findDescendant(root,'DesktopShortcutNotifications')))
_G.ExodusUICleanup();finishTweens()
local service=game:GetService('UserInputService');service.KeyboardEnabled=false;service.MouseEnabled=false;service.TouchEnabled=true
assert(ui.setup(fullDeps(),{open=true}));flushDeferred();finishTweens()
root=playerGui:FindFirstChild('ExodusUISystem')
for _, object in ipairs(root:GetDescendants()) do assert(object.Name~='DesktopShortcutNotifications','PC-only option appeared on mobile') end
_G.ExodusUICleanup();finishTweens()
''')

    def test_manual_spam_and_up_dash_do_not_emit_gameplay_toasts(self):
        self.run_lua('''
local dash=0;local deps=fullDeps();deps.Controls.onUpDash=function() dash=dash+1 end
assert(ui.setup(deps,{open=true}));flushDeferred();finishTweens()
local service=game:GetService('UserInputService')
service.InputBegan:Fire(input('Keyboard',0,0,'F'),false)
service.InputBegan:Fire(input('Keyboard',0,0,'U'),false)
assert(manual and dash==1)
for _, object in ipairs(playerGui:GetDescendants()) do assert(object.Name~='ExodusToast') end
_G.ExodusUICleanup();finishTweens()
''')

    def test_navigation_races_share_one_controller_and_preserve_scroll(self):
        self.run_lua('''
local kit=newKit()
local actions=uiactions.create({scope=kit.scope,controls={},desktop=true,notify=function() end,persistent=function() end,setSpam=utils.setManualSpamActive,showMini=function() end,rebuild=function() end})
local pages=uipages.create(kit,panel,uiconfig.pages,{desktop=true,read=utils.getConfigValue,resolve=actions.resolve})
assert(pages.state().id=='main')
pages.select('utilities');pages.get('utilities').columns[1].CanvasPosition=Vector2.new(0,79)
pages.toggle('config');pages.toggle('config');pages.select('indeed')
finishTweens()
assert(pages.state().id=='indeed' and not pages.state().transitioning)
local visible=0
for _, definition in ipairs(uiconfig.pages) do
 local root=pages.get(definition.id).Root
 if root.Visible then visible=visible+1;assert(definition.id=='indeed' and root.GroupTransparency==0) end
end
assert(visible==1 and not findDescendant(panel,'PageInputShield').Visible)
pages.select('utilities');finishTweens()
assert(pages.get('utilities').columns[1].CanvasPosition.Y==79)
local snapshot=pages.snapshot();pages.select('main',false);pages.restore(snapshot)
assert(pages.state().id=='utilities' and pages.get('utilities').columns[1].CanvasPosition.Y==79)
kit.destroy();assert(activeTweenCount()==0)
''')

    def test_controls_sync_external_values_without_writing_on_mount(self):
        self.run_lua('''
local kit=newKit()
local toggle=kit.Components.toggle(panel,{title='Parry',key='AutoParry'})
local slider=kit.Components.slider(panel,{title='Size',key='MiniSpamScale',min=0.5,max=2,increment=0.05})
local select=kit.Components.dropdown(panel,{title='Method',key='ClickMethod',choices={{value='Deflect',label='Standard'},{value='Direct',label='Direct remote'}}})
local rate=kit.Components.rate_selector(panel,{title='Rate'})
assert(writes==0,'mount must not rewrite settings')
utils.setConfig({AutoParry=false,MiniSpamScale=1.5,ClickMethod='Direct',SpamRateMode='MS',MS=42})
assert(not toggle.getValue() and slider.getValue()==1.5 and select.getValue()=='Direct')
assert(rate.getValue()=='MS' and findDescendant(rate.Root,'RateInput').Text=='42')
assert(findDescendant(select.Root,'Selected').Text=='Direct remote')
click(findDescendant(toggle.Root,'CardHitbox'));assert(config.AutoParry)
local before=writes;toggle.setValue(false);assert(writes==before,'setValue must be silent')
kit.destroy();local value=toggle.getValue();utils.setConfig({AutoParry=true});assert(toggle.getValue()==value)
assert(activeTweenCount()==0 and listenerCount()==0,'destroy must release subscriptions')
assert(#panel:GetChildren()==0,'destroy must remove owned controls')
''')

    def test_invalid_numbers_rollback_and_failed_writes_keep_visual_value(self):
        self.run_lua('''
local kit=newKit({write=function() return false end})
local toggle=kit.Components.toggle(panel,{key='AutoParry'});click(findDescendant(toggle.Root,'CardHitbox'));assert(toggle.getValue())
local input=kit.Components.number(panel,{title='Lead',key='AutoParryWindowFactor',min=0,max=35,displayScale=100})
local box=findDescendant(input.Root,'Input')
box.Text='nan';box.FocusLost:Fire(false);assert(input.getValue()==0.3 and tonumber(box.Text)==30)
box.Text='35';box.FocusLost:Fire(false);assert(input.getValue()==0.3 and tonumber(box.Text)==30)
kit.destroy()
local writable=newKit();local lead=writable.Components.number(panel,{key='AutoParryWindowFactor',min=0,max=35,displayScale=100})
local field=findDescendant(lead.Root,'Input');field.Text='999';field.FocusLost:Fire(false);assert(config.AutoParryWindowFactor==0.35)
writable.destroy()
''')

    def test_drag_owns_one_pointer_and_stops_on_navigation_or_focus_loss(self):
        self.run_lua('''
local kit=newKit();local slider=kit.Components.slider(panel,{key='MiniSpamScale',min=0.5,max=2,increment=0.05})
local hit=findDescendant(slider.Root,'SliderHitbox');local track=findDescendant(slider.Root,'Track')
track.AbsolutePosition=Vector2.new(100,100);track.AbsoluteSize=Vector2.new(200,6)
local touch=input('Touch',150,100);hit.InputBegan:Fire(touch);local initial=slider.getValue()
game:GetService('UserInputService').InputChanged:Fire(input('Touch',300,100));assert(slider.getValue()==initial,'second finger changed slider')
touch.Position=Vector2.new(250,100);game:GetService('UserInputService').InputChanged:Fire(touch);assert(slider.getValue()>initial)
kit.dismiss();local stopped=slider.getValue();touch.Position=Vector2.new(300,100);game:GetService('UserInputService').InputChanged:Fire(touch);assert(slider.getValue()==stopped)
hit.InputBegan:Fire(input('MouseButton1',100,100));game:GetService('UserInputService').WindowFocusReleased:Fire()
local lost=slider.getValue();game:GetService('UserInputService').InputChanged:Fire(input('MouseMovement',300,100));assert(slider.getValue()==lost)
kit.destroy()
''')

    def test_popups_capture_and_component_disposal_release_global_events(self):
        self.run_lua('''
local baseline=listenerCount();local kit=newKit();local selected=kit.Components.dropdown(panel,{key='ClickMethod',choices={'Deflect','Direct'}})
local cap=kit.Components.button(panel,{title='Panic',shortcutKey='Keybind'})
local trigger=findDescendant(selected.Root,'Select')
trigger.AbsolutePosition=Vector2.new(100,650)
click(trigger);local portal=playerGui:FindFirstChild('ExodusDropdown');assert(portal)
local menu=portal:FindFirstChildOfClass('CanvasGroup');assert(menu.Position.Y.Offset>=678,'popup must stay below the trigger near bottom')
kit.dismiss();assert(not playerGui:FindFirstChild('ExodusDropdown'))
click(findDescendant(cap.Root,'Shortcut_Keybind'));game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'Escape'))
assert(config.Keybind==Enum.KeyCode.F9)
click(findDescendant(cap.Root,'Shortcut_Keybind'));game:GetService('UserInputService').InputBegan:Fire(input('Keyboard',0,0,'K'))
assert(config.Keybind==Enum.KeyCode.K)
selected.destroy();cap.destroy();kit.destroy();finishTweens()
assert(listenerCount()==baseline and activeTweenCount()==0)
''')

    def test_all_pages_render_on_desktop_and_mobile_and_rebuild_cleanly(self):
        self.run_lua('''
local baseline=listenerCount();local deps=fullDeps()
assert(ui.setup(deps,{open=true}));flushDeferred();finishTweens()
local root=playerGui:FindFirstChild('ExodusUISystem');assert(root)
click(findDescendant(root,'NextPage'));click(findDescendant(root,'HubSettingsButton'));click(findDescendant(root,'HubSettingsButton'));finishTweens()
local first=listenerCount()
assert(ui.setup(deps,{open=true}));flushDeferred();finishTweens();assert(listenerCount()==first,'desktop rebuild leaked listeners')
_G.ExodusUICleanup();assert(listenerCount()==baseline and activeTweenCount()==0,'desktop cleanup leaked')
local inputService=game:GetService('UserInputService');inputService.KeyboardEnabled=false;inputService.MouseEnabled=false;inputService.TouchEnabled=true
assert(ui.setup(deps,{open=true}));flushDeferred();finishTweens()
root=playerGui:FindFirstChild('ExodusUISystem')
assert(findDescendant(root,'MiniSpamScale'))
abilities=false;abilityChanged:Fire(false)
local automatic=findDescendant(root,'Page_automatic')
assert(not findDescendant(automatic,'AutoJump').Parent.Visible)
_G.ExodusUICleanup();assert(listenerCount()==baseline and activeTweenCount()==0,'mobile cleanup leaked')
''')

    def test_schema_rejects_invalid_page_and_child_relationships(self):
        self.run_lua('''
local kit=newKit()
local function valid(pages) return pcall(uipages.validate,pages,kit.Components) end
assert(not valid({{id='x',title='X',columns=3,sections={}}}))
assert(not valid({{id='x',title='X',columns=1,sections={{components={{kind='missing'}}}}}}))
assert(not valid({{id='x',title='X',columns=1,sections={{components={{kind='toggle',key='a',parentKey='b'}}}}}}))
assert(not valid({{id='x',title='X',columns=1,sections={{components={{kind='toggle',key='a',parentKey='b'},{kind='toggle',key='b',parentKey='a'}}}}}}))
assert(valid(uiconfig.pages))
kit.destroy()
''')

    def test_device_preview_restores_page_scroll_and_releases_hold(self):
        self.run_lua('''
local service=game:GetService('UserInputService')
service.KeyboardEnabled=false;service.MouseEnabled=false;service.TouchEnabled=true
assert(ui.setup(fullDeps(),{open=true}));flushDeferred();finishTweens()
local root=playerGui:FindFirstChild('ExodusUISystem')
click(findDescendant(root,'NextPage'));click(findDescendant(root,'NextPage'));finishTweens()
local column=findDescendant(findDescendant(root,'Page_utilities'),'Column1')
column.CanvasPosition=Vector2.new(0,91)
click(findDescendant(root,'HubSettingsButton'));finishTweens()
local preview=findDescendant(root,'ForcePCUI');click(findDescendant(preview,'CardHitbox'))
flushDeferred();flushDeferred();finishTweens()
root=playerGui:FindFirstChild('ExodusUISystem')
assert(findDescendant(root,'Page_config').Visible,'preview lost active page')
assert(findDescendant(findDescendant(root,'Page_utilities'),'Column1').CanvasPosition.Y==91,'preview lost scroll')
click(findDescendant(root,'HubSettingsButton'));finishTweens()
assert(findDescendant(root,'Page_utilities').Visible,'preview lost return page')
utils.setConfig({ManualSpamMode='Hold'})
service.InputBegan:Fire(input('Keyboard',0,0,'F'),false);assert(manual)
_G.ExodusUICleanup();assert(not manual,'hold survived cleanup')
''')

    def test_suspend_stops_owned_motion_and_resume_restores_interaction(self):
        self.run_lua('''
local kit=newKit();local toggle=kit.Components.toggle(panel,{key='AutoParry'})
assert(activeTweenCount()>0)
kit.suspend();assert(activeTweenCount()==0)
click(findDescendant(toggle.Root,'CardHitbox'));assert(config.AutoParry)
kit.resume();click(findDescendant(toggle.Root,'CardHitbox'));assert(not config.AutoParry)
finishTweens();kit.destroy();assert(activeTweenCount()==0 and listenerCount()==0)
''')

    def test_replacement_preserves_update_notification_and_waits_for_fade(self):
        self.run_lua('''
assert(ui.setup(fullDeps(),{open=true}));flushDeferred();finishTweens()
_G.ExodusShowPersistentNotification('Updating...','update','info')
local co=coroutine.create(function() _G.ExodusUIFadeOut(true) end)
local ok,err=coroutine.resume(co);assert(ok,err);assert(coroutine.status(co)=='suspended')
finishTweens()
local card=findDescendant(playerGui,'Notification_update')
assert(card.GroupTransparency==0,'update notification enter was cancelled by replacement')
ok,err=coroutine.resume(co);assert(ok,err);assert(coroutine.status(co)=='dead')
_G.ExodusUIRestore('simulated failure');finishTweens()
local root=playerGui:FindFirstChild('ExodusUISystem')
local toggle=findDescendant(root,'AutoParry')
click(findDescendant(toggle,'CardHitbox'));assert(not config.AutoParry,'failed reload did not resume controls')
_G.ExodusUICleanup();finishTweens()
''')

    def test_zero_duration_navigation_and_nested_visibility(self):
        self.run_lua('''
local kit=newKit({reducedMotion=true})
local actions=uiactions.create({scope=kit.scope,controls={},desktop=true,notify=function() end,persistent=function() end,setSpam=utils.setManualSpamActive,showMini=function() end,rebuild=function() end})
local pages=uipages.create(kit,panel,uiconfig.pages,{desktop=true,read=utils.getConfigValue,resolve=actions.resolve})
pages.select('indeed');assert(not pages.state().transitioning and activeTweenCount()==0)
local fly=pages.getControl('UniversalFly');local speed=pages.getControl('UniversalFlySpeed')
assert(not uiruntime.isVisible(speed.Root))
utils.setConfig({UniversalFly=true});pages.refresh();assert(uiruntime.isVisible(speed.Root))
utils.setConfig({UniversalFly=false});pages.refresh();utils.setConfig({UniversalFly=true});pages.refresh()
assert(uiruntime.isVisible(speed.Root))
pages.destroy();assert(activeTweenCount()==0)
kit.destroy()
''')


if __name__ == '__main__':
    unittest.main()
