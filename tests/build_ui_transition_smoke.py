"""Generate UI page-transition checks with deterministic mocked tweens."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
ui = (root / "exodus hub/modules/front/ui.luau").read_text(encoding="utf-8")
uiconfig = (root / "exodus hub/modules/front/uiconfig.luau").read_text(encoding="utf-8")
script = r'''
local all, pending, delayed = {}, {}, {}
local function signal()
    local handlers={}
    return {
        Connect=function(_, fn)
            local c={Connected=true}; function c:Disconnect() self.Connected=false end
            handlers[#handlers+1]={c, fn}; return c
        end,
        Fire=function(_, ...) for _,h in ipairs(handlers) do if h[1].Connected then h[2](...) end end end,
    }
end
local methods={}
function methods:FindFirstChild(name) for _,v in ipairs(all) do if v.Parent==self and v.Name==name then return v end end end
function methods:Destroy() self.Parent=nil end
local events={Activated=true,MouseEnter=true,MouseLeave=true,InputBegan=true,InputEnded=true,InputChanged=true,FocusLost=true,Focused=true}
local mt={__index=function(t,k)
    if methods[k] then return methods[k] end
    if events[k] then local s=signal();rawset(t,k,s);return s end
    if k=="AbsolutePosition" then return {X=0,Y=0} end
    if k=="AbsoluteSize" then return {X=64,Y=64} end
end}
Instance={new=function(cls) local x=setmetatable({ClassName=cls},mt);all[#all+1]=x;return x end}
local function dynamic() return setmetatable({}, {__index=function(t,k) local v={Name=k};rawset(t,k,v);return v end}) end
Enum=setmetatable({}, {__index=function(t,k) local v=dynamic();rawset(t,k,v);return v end})
Color3={new=function(...)return {...} end,fromRGB=function(...)return {...} end}
ColorSequence={new=function(v)return v end};ColorSequenceKeypoint={new=function(a,b)return {a,b} end}
UDim={new=function(a,b)return {Scale=a,Offset=b} end}
UDim2={new=function(a,b,c,d)return {X={Scale=a,Offset=b},Y={Scale=c,Offset=d}} end}
Vector2={new=function(x,y)return {X=x,Y=y} end};TweenInfo={new=function(...)return {...} end}
local tweenService={Create=function(_, object, _, properties)
    local t={Completed=signal(),cancelled=false}
    function t:Play()
        if properties.GroupTransparency~=nil then pending[#pending+1]={self,object,properties}
        else for k,v in pairs(properties) do object[k]=v end end
    end
    function t:Cancel() self.cancelled=true;self.Completed:Fire("Cancelled") end
    return t
end}
local function finishTweens()
    local queue=pending;pending={}
    for _,entry in ipairs(queue) do
        if not entry[1].cancelled then
            for k,v in pairs(entry[3]) do entry[2][k]=v end
            entry[1].Completed:Fire("Completed")
        end
    end
end
local gui=Instance.new("CoreGui")
local uis={InputBegan=signal(),InputChanged=signal(),InputEnded=signal()}
workspace={CurrentCamera={ViewportSize={X=1000,Y=700}}}
game={GetService=function(_,name)return ({UserInputService=uis,TweenService=tweenService,CoreGui=gui})[name] end}
task={wait=function()end,spawn=function()end,defer=function()end,delay=function(_,fn) delayed[#delayed+1]=fn end}
math.clamp=function(x,a,b)return math.max(a,math.min(x,b)) end
local config={AutoParry=true,AutoClash=true,AutoDark=false,ClashBallVisible=false,DarkBallVisible=false,CPF=.36,CPS=24,SpamRateMode="CPF",Keybind=Enum.KeyCode.F9,SpamKeybind=Enum.KeyCode.F}
local changes=0; local manualSpam=false; local spamObservers={}; local configObservers={}
local function observe(list, fn)
    local item={Connected=true}; function item:Disconnect() self.Connected=false end
    list[#list+1]={item,fn}; return item
end
local function notify(list, value) for _,item in ipairs(list) do if item[1].Connected then item[2](value) end end end
local utils={
    getConfig=function()return config end,getConfigValue=function(k)return config[k] end,
    setConfig=function(p)for k,v in pairs(p) do config[k]=v end;notify(configObservers,p);return true end,
    normalizeSpamRate=function(v)return v end,isManualSpamActive=function()return manualSpam end,
    setManualSpamActive=function(v) if manualSpam~=v then manualSpam=v;notify(spamObservers) end end,
    observeSpam=function(fn)return observe(spamObservers,fn) end,observeConfig=function(fn)return observe(configObservers,fn) end,
    isActive=function()return true end,stop=function()end,
    name=function()return "Exodus" end,version=function()return "1" end,author=function()return "X" end,
}
local ui=assert(loadstring(UI_SOURCE))()
local uiConfig=assert(loadstring(CONFIG_SOURCE))()
assert(ui.setup({Utils=utils,UIConfig=uiConfig,Controls={onAutoDarkChanged=function()changes=changes+1 end}}))
local function find(predicate) for _,x in ipairs(all) do if predicate(x) then return x end end end
local function named(name) return assert(find(function(x)return x.Name==name end), name) end
local page1,page2,page3,page4=named("Page1"),named("Page2"),named("Page3"),named("Page4")
local shield=named("PageInputShield")
local prev,nextPage=named("PreviousPage"),named("NextPage")
local pageLabel=named("PageLabel")
local panel=named("ExodusPanel")
local floating=assert(find(function(x)return x.ClassName=="TextButton" and x.Text=="E" end))
floating.Activated:Fire();assert(panel.Visible and panel.GroupTransparency==1)
finishTweens();assert(panel.Visible and panel.GroupTransparency==0, "panel did not fade in")
floating.Activated:Fire();finishTweens();assert(not panel.Visible, "panel did not fade out")
floating.Activated:Fire();finishTweens();assert(panel.Visible, "panel did not reopen")
floating.Activated:Fire();floating.Activated:Fire();finishTweens()
assert(panel.Visible and panel.GroupTransparency==0, "rapid panel toggle left it hidden")
assert(page1.Visible and not page2.Visible and not page3.Visible and not page4.Visible and not shield.Visible)
assert(pageLabel.Text=="1/4 Principal")
prev.Activated:Fire(); assert(page1.Visible and not shield.Visible, "previous at first page must do nothing")
nextPage.Activated:Fire()
assert(page1.Visible and page2.Visible and shield.Visible, "transition did not start")
finishTweens()
assert(not page1.Visible and page2.Visible and not page3.Visible and not shield.Visible, "page 2 did not settle")
nextPage.Activated:Fire(); prev.Activated:Fire()
assert(shield.Visible, "rapid navigation did not block page input")
finishTweens()
assert(not page1.Visible and page2.Visible and not page3.Visible and not page4.Visible and not shield.Visible, "rapid navigation left pages visible")
for _,fn in ipairs(delayed) do fn() end
assert(page2.Visible and not shield.Visible, "stale completion changed page")
prev.Activated:Fire(); finishTweens(); assert(page1.Visible and pageLabel.Text=="1/4 Principal", "back navigation failed")
nextPage.Activated:Fire(); finishTweens(); nextPage.Activated:Fire(); finishTweens()
assert(page3.Visible and pageLabel.Text=="3/4 Utilidades")
nextPage.Activated:Fire(); finishTweens()
assert(page4.Visible and pageLabel.Text=="4/4 Automáticos")
nextPage.Activated:Fire(); assert(page4.Visible and not shield.Visible, "next at last page must do nothing")
for _,name in ipairs({"Auto Dark", "Mini Dark UI", "Auto Deflexo Feroz", "Auto Jump", "Mini Auto Jump", "Mini Up Dash"}) do
 local entry=assert(find(function(x)return x.ClassName=="TextLabel" and x.Text==name end), name)
 assert(entry.Parent.Parent.Parent==page4, name .. " must be on autos page")
end
local afk=assert(find(function(x)return x.ClassName=="TextLabel" and x.Text=="Anti AFK" end))
assert(afk.Parent.Parent.Parent==page3, "anti afk must remain on utilities page")
prev.Activated:Fire(); finishTweens(); assert(page3.Visible, "back from autos failed")
nextPage.Activated:Fire(); finishTweens(); assert(page4.Visible, "return to autos failed")
local label=assert(find(function(x)return x.ClassName=="TextLabel" and x.Text=="Auto Dark" end))
assert(label.Parent.Parent.Parent==page4, "Auto Dark must be on the autos page")
local button=assert(find(function(x)return x.Parent==label.Parent and x.ClassName=="TextButton" and x.Text=="" end))
button.Activated:Fire()
assert(config.AutoDark and changes==1 and named("ExodusDarkBall").Text=="ON", "page controls failed after transition")
local jumpLabel=assert(find(function(x)return x.ClassName=="TextLabel" and x.Text=="Auto Jump" end))
assert(jumpLabel.Parent.Parent.Parent==page4, "Auto Jump must be on autos page")
local jumpButton=assert(find(function(x)return x.Parent==jumpLabel.Parent and x.ClassName=="TextButton" and x.Text=="" end))
jumpButton.Activated:Fire(); assert(config.AutoJump and named("ExodusJumpBall").Text=="JUMP\nON", "jump toggle failed")
named("ExodusJumpBall").Activated:Fire(); assert(not config.AutoJump, "jump mini must stay synchronized")
assert(named("ExodusClashBall").Text=="ON", "floating clash button changed")
named("SpamButton").Activated:Fire(); assert(manualSpam and named("SpamButton").Text=="ON")
utils.setManualSpamActive(false); utils.setConfig({AutoClash=false})
assert(named("SpamButton").Text=="OFF" and named("ExodusClashBall").Text=="OFF", "external shutdown must update controls")
assert(config.ClashBallVisible==false, "external shutdown must not alter mini visibility")
print("UI transitions, rapid navigation and controls: PASS")
'''
quote = lambda s: "[========[" + s + "]========]"
output.write_text(script.replace("UI_SOURCE", quote(ui), 1).replace("CONFIG_SOURCE", quote(uiconfig), 1), encoding="utf-8")
