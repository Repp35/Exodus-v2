local function expect(value, text) if not value then error(text, 2) end end
math.clamp = function(v,a,b) return math.max(a,math.min(v,b)) end
table.clear = function(t) for k in pairs(t) do t[k]=nil end end
table.clone = function(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
local function signal()
  local s={listeners={}}
  function s:Connect(f)
    local c={Connected=true,callback=f}; function c:Disconnect()self.Connected=false end
    self.listeners[#self.listeners+1]=c; return c
  end
  function s:Fire(...) local count=#self.listeners; for i=1,count do local c=self.listeners[i];if c.Connected then c.callback(...)end end end
  function s:active()local n=0;for _,c in ipairs(self.listeners)do if c.Connected then n=n+1 end end;return n end
  return s
end
Enum=setmetatable({}, {__index=function(self,family)
  local e=setmetatable({},{__index=function(t,k)local v={Name=k,EnumType=t,__kind='EnumItem'};rawset(t,k,v);return v end});rawset(self,family,e);return e
end})
local vectorMeta={__index=function(v,k)if k=='Magnitude'then return math.sqrt(v.X*v.X+v.Y*v.Y+(v.Z or 0)^2)end end}
vectorMeta.__sub=function(a,b)return setmetatable({X=a.X-b.X,Y=a.Y-b.Y,Z=(a.Z or 0)-(b.Z or 0)},vectorMeta)end
Vector2={new=function(x,y)return setmetatable({X=x or 0,Y=y or 0},vectorMeta)end}
UDim={new=function(s,o)return{Scale=s,Offset=o}end}
UDim2={new=function(xs,xo,ys,yo)return{X=UDim.new(xs or 0,xo or 0),Y=UDim.new(ys or 0,yo or 0)}end}
UDim2.fromOffset=function(x,y)return UDim2.new(0,x,0,y)end
UDim2.fromScale=function(x,y)return UDim2.new(x,0,y,0)end
Color3={new=function(r,g,b)return{R=r,G=g,B=b,__kind='Color3'}end}
Color3.fromRGB=function(r,g,b)return Color3.new(r/255,g/255,b/255)end
function typeof(x)return type(x)=='table' and (rawget(x,'__kind')or type(x))or type(x)end
local objects={}
Instance={new=function(class)
  local obj={__kind='Instance',_props={ClassName=class,Name=class,AbsoluteSize=Vector2.new(400,300),AbsolutePosition=Vector2.new(0,0),Position=UDim2.new(),Visible=true},_signals={},_children={}}
  function obj:IsA(c)return c==class or c=='GuiButton' and(class=='TextButton'or class=='ImageButton')end
  function obj:Destroy()self._props.Parent=nil;self.destroyed=true;for _,child in ipairs(self._children)do if not child.destroyed then child:Destroy()end end end
  function obj:GetChildren()return self._children end
  function obj:FindFirstChildOfClass(c)for _,child in ipairs(self._children)do if child:IsA(c)and not child.destroyed then return child end end end
  function obj:FindFirstChild(n)for _,child in ipairs(self._children)do if child.Name==n and not child.destroyed then return child end end end
  setmetatable(obj,{__index=function(t,k)
    local v=t._props[k];if v~=nil then return v end
    if k:match('^Input')or k=='Activated'or k=='FocusLost'or k=='Focused'or k=='AncestryChanged'then if not t._signals[k]then t._signals[k]=signal()end;return t._signals[k]end
  end,__newindex=function(t,k,v)
    t._props[k]=v;if k=='Parent'and v and v._children then v._children[#v._children+1]=t end
  end})
  objects[#objects+1]=obj;return obj
end}
local input={TouchEnabled=false,KeyboardEnabled=true,MouseEnabled=true,InputBegan=signal(),InputEnded=signal(),InputChanged=signal(),WindowFocusReleased=signal(),GetFocusedTextBox=function()return nil end}
local run={Heartbeat=signal()}
local parent=Instance.new('PlayerGui')
local player={UserId=1,Idled=signal(),FindFirstChildOfClass=function(_,c)if c=='PlayerGui'then return parent end end}
workspace={CurrentCamera={ViewportSize=Vector2.new(1000,800)}}
game={GetService=function(_,s)if s=='UserInputService'then return input elseif s=='RunService'then return run elseif s=='Players'then return{LocalPlayer=player}end end}
task={delay=function()end,spawn=function()end,defer=function(f)f()end,wait=function()end}
warn=function(message)error(message)end
local ui=assert(loadfile('exodus hub/modules/front/ui.luau'))()
local events=0
local w=ui.new({parent=parent,pages={{id='test',components={
 {kind='toggle',id='toggle',title='Flag',value=false,onChange=function()events=events+1 end},
 {kind='number',id='number',value=5,min=0,max=10},
 {kind='slider',id='slider',value=0,min=0,max=10,step=.5},
 {kind='dropdown',id='dropdown',value='a',options={'a','b'}},
 {kind='multiselect',id='multi',value={'a'},options={'a','b'}},
 {kind='keybind',id='key',value=Enum.KeyCode.F},
 {kind='color',id='color',value=Color3.new(1,0,0)},
 {kind='progress',id='progress',value=50,min=0,max=100},
 {kind='paragraph',id='paragraph',value='Description'},
 {kind='section',title='Section'},{kind='separator'},
 {kind='toggle',id='reject',value=false,onChange=function()return false end},
}}}})
expect(w.set('toggle',true,false)and events==0,'programmatic updates must not call callbacks')
expect(w.set('toggle',false,true)and events==1,'user changes call callback once')
expect(not w.set('reject',true,true)and not w.get('reject').get(),'rejected change rollback')
expect(not w.set('number',0/0),'NaN rejected')
expect(w.set('number',100)and w.get('number').get()==10,'numeric clamping')
expect(w.set('slider',3.24)and w.get('slider').get()==3,'slider quantization')
expect(not w.set('dropdown','invalid'),'invalid choice rejected')
local keyCalls=0;w.bindKey('action',Enum.KeyCode.P,function()keyCalls=keyCalls+1 end)
input.InputBegan:Fire({KeyCode=Enum.KeyCode.P,UserInputType=Enum.UserInputType.Keyboard},false)
expect(keyCalls==1,'key action')
local n=w.notify('First','info',0,'test');w.notify('Second','info',0,'test');expect(n=='test','persistent notice id');w.clearNotification('test')
local before=input.InputBegan:active();expect(before==1,'one input handler per window')
w.destroy();expect(input.InputBegan:active()==0 and run.Heartbeat:active()==0,'destroy disconnects input and update handlers')
input.InputBegan:Fire({KeyCode=Enum.KeyCode.P,UserInputType=Enum.UserInputType.Keyboard},false);expect(keyCalls==1,'destroyed callbacks stopped')
local config=assert(loadfile('exodus hub/modules/front/config.luau'))()
expect(config.register('core',config.__config),'core schema registers')
expect(config.validate(config.defaults()),'defaults validate')
expect(not config.normalizePatch({AutoSpam='yes'}),'wrong flag rejected')
expect(not config.normalizePatch({Unknown=true}),'unknown key rejected')
local values=config.defaults();local observers,spamObservers={},{};local active=true;local manual=false
local utils={
 getLocalPlayer=function()return player end,getConfigValue=function(key)return values[key]end,
 setConfig=function(patch)for k,v in pairs(patch)do values[k]=v end;for _,c in ipairs(observers)do if c.Connected then c.callback(patch)end end;return true end,
 isManualSpamActive=function()return manual end,setManualSpamActive=function(v)manual=v;for _,c in ipairs(spamObservers)do if c.Connected then c.callback()end end;return true end,
 isActive=function()return active end,stop=function()active=false;config.teardown()end,
 name=function()return'Test Hub'end,version=function()return'1'end,author=function()return'Test'end,
 recordError=function(context,err)error(context..': '..err)end,
 resetConfig=function()values=config.defaults();return true end,
 observeConfig=function(f)local c={callback=f,Connected=true,Disconnect=function(self)self.Connected=false end};observers[#observers+1]=c;return c end,
 observeSpam=function(f)local c={callback=f,Connected=true,Disconnect=function(self)self.Connected=false end};spamObservers[#spamObservers+1]=c;return c end,
}
local changes=signal()
local info={areAbilitiesEnabled=function()return true end,observeAbilityMode=function(f)return changes:Connect(f)end,getSnapshotAt=function()return nil end,isSnapshotValid=function()return false end}
local deps={Utils=utils,UI=ui,GameInfo=info,AutoSpam={getStatus=function()return{}end},Dumper={isRunning=function()return false end},Controls={}}
expect(config.setup(deps),'hub setup')
expect(input.InputBegan:active()==1,'hub has a single generic window')
run.Heartbeat:Fire(.2)
config.teardown();expect(input.InputBegan:active()==0 and changes:active()==0,'hub teardown cleans generic UI and subscriptions')
expect(config.setup(deps),'hub can reinitialize');config.teardown()
print('UI runtime: components, bindings, lifecycle, schema and hub injection passed')
