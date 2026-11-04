-- [[ autoclash ]]

local AutoClash = {}

-- [[ dependencies ]]

local AP, GI, Dash, Utils
local State = {
	generation = 0, bound = false, active = false, phase = "detached",
	uid = nil, root = nil, players = nil, run = nil, connections = {},
	darkConnections = {}, lastGate = "none",
	target = -1, previousWasMe = nil, partner = -1,
	sequence = nil, lastSyncAt = 0, lastSource = nil, resetToken = 0,
	speed = 0, parryRadius = 0, activationRadius = 0,
	lostAt = nil, lostServerAt = nil, lostTo = -1,
	returnWindow = 0, returnWindowBonus = 0, returnExpiresAt = 0,
	returnPending = false, returnToken = 0,
	dashUntil = 0, dashEvent = nil, dashData = nil,
	dashEscapeAt = nil, dashEscapeDistance = nil, dashEscapeLastAt = 0, dashEscapeFrames = 0,
	directionAt = 0, switchAt = 0, switchServerAt = nil,
	switchInterval = 0, switchEma = nil, switchSamples = 0,
	outsideAt = nil, confirmAt = nil, confirmLast = 0, confirmFrames = 0,
	activationLock = 0, dashLock = 0,
	missingAt = nil, recoveryUntil = 0, pull = nil, pullEvent = nil,
	activationAt = 0, activationSource = "none", activationReason = "none",
	activationTrigger = "none", activationTarget = -1, activationPartner = -1,
	activationDistance = 0, activationRadiusUsed = 0, activationSpeed = 0,
}
local snapshotReader, snapshotValidator, clock
local errors = {}

-- [[ utilities ]]

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local function number(x, fallback) x = tonumber(x); return finite(x) and x or fallback end
local function safe(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end
local function now() return number(safe(clock), os.clock()) end
local function target(x)
	x = number(x)
	return x and x > 0 and x % 1 == 0 and x or nil
end
local function config(key)
	if not Utils then return nil end
	if type(Utils.getConfigValue) == "function" then return safe(Utils.getConfigValue, key) end
	local c = safe(Utils.getConfig)
	return type(c) == "table" and c[key] or nil
end
local function ping() return math.max(0, number(GI and safe(GI.getLocalPing), 0)) end
local function pos(snapshot) return snapshot and typeof(snapshot.position) == "Vector3" and snapshot.position or nil end
local function rootPos() return State.root and State.root.Parent and State.root.Position or nil end
local function dist2(a,b) local d=a-b; return d:Dot(d) end
local function horizontal(a,b)
	local x,z=a.X-b.X,a.Z-b.Z
	return math.sqrt(x*x+z*z)
end
local function radius(factor, speed)
	local r = AP and safe(AP.getRadius, "geometry", factor, speed or State.speed, "game")
	return type(r) == "table" and r or nil
end
local function targetsMe(snapshot)
	if not snapshot then return false end
	if snapshot.targetId ~= nil then return target(snapshot.targetId) == State.uid end
	return snapshot.targeted == true
end
local function speedWindow(base, factor, speed)
	local lo,hi
	if GI and type(GI.getBallSpeedLimits) == "function" then lo,hi = GI.getBallSpeedLimits() end
	lo,hi=number(lo),number(hi)
	if not lo or not hi or hi<=lo then return base end
	return base*(1+(factor-1)*math.clamp((speed-lo)/(hi-lo),0,1))
end
local function report(source, err)
	local message,t=tostring(err),now()
	local previous=errors[source]
	if previous and previous.message==message and t-previous.at<1 then return end
	errors[source]={message=message,at=t}
	if Utils and type(Utils.recordError)=="function" then Utils.recordError(source,message) end
end

-- [[ lifecycle ]]

local function phase(value,reason)
	if State.phase==value then return end
	local previous=State.phase
	State.phase=value
	if Utils and type(Utils.recordTransition)=="function" then
		Utils.recordTransition("AutoClash",previous,value,reason)
	end
end
local function clearReturn()
	State.lostAt,State.lostServerAt,State.lostTo=nil,nil,-1
	State.returnWindow,State.returnWindowBonus,State.returnExpiresAt=0,0,0
	State.returnPending=false
	State.returnToken+=1
end
local function clearConfirm()
	State.outsideAt,State.confirmAt,State.confirmFrames=nil,nil,0
	State.confirmLast=0
	State.dashEscapeAt,State.dashEscapeDistance,State.dashEscapeLastAt,State.dashEscapeFrames=nil,nil,0,0
end
local function setActive(value,reason,snapshot,why)
	if State.active==value then return end
	State.active=value
	clearConfirm()
	local t=now()
	if value then
		State.activationAt=t
		State.activationSource=t<State.dashUntil and "anti_dash" or "normal"
		State.activationReason=why or "predicted_impact"
		State.activationTrigger=reason
		State.activationTarget,State.activationPartner=State.target,State.partner
		State.activationRadiusUsed,State.activationSpeed=State.activationRadius,State.speed
		local a,b=rootPos(),pos(snapshot)
		State.activationDistance=a and b and (a-b).Magnitude or 0
		State.activationLock=a and b and State.parryRadius>0 and dist2(a,b)<=(State.parryRadius*0.7)^2 and t+0.05 or 0
		State.dashLock=t<State.dashUntil and t+0.07+ping()*0.3 or 0
	else
		State.activationLock,State.dashLock=0,0
	end
	if Utils and type(Utils.setAutoSpamActive)=="function" then Utils.setAutoSpamActive(value) end
	phase(value and "active" or "idle",reason)
end
local function clearTargets()
	State.resetToken+=1
	State.target,State.previousWasMe,State.partner=-1,nil,-1
	State.directionAt,State.switchAt,State.switchInterval=0,0,0
	State.switchServerAt,State.switchEma,State.switchSamples=nil,nil,0
	State.dashUntil,State.dashEvent,State.dashData=0,nil,nil
	State.pull=nil
	clearReturn()
	clearConfirm()
end
local function disconnectAll()
	for i=#State.connections,1,-1 do
		local connection=State.connections[i]
		if Utils and Utils.untrackCharacter then Utils.untrackCharacter(connection) end
		pcall(function() connection:Disconnect() end)
		State.connections[i]=nil
	end
	for player,connection in pairs(State.darkConnections) do
		if Utils and Utils.untrackCharacter then Utils.untrackCharacter(connection) end
		pcall(function() connection:Disconnect() end)
		State.darkConnections[player]=nil
	end
end
local function reset(reason)
	State.generation+=1
	setActive(false,reason)
	disconnectAll()
	State.bound,State.root=false,nil
	State.sequence,State.lastSyncAt,State.lastSource=nil,0,nil
	State.missingAt,State.recoveryUntil=nil,0
	State.speed,State.parryRadius,State.activationRadius=0,0,0
	State.pullEvent=nil
	clearTargets()
	State.lastGate=reason
	phase("detached",reason)
end

-- [[ timing and returns ]]

local function updateRadius(snapshot)
	State.speed=math.max(0,number(snapshot.speed,State.speed))
	local full,activation=radius(1),radius(0.8)
	State.parryRadius=math.max(0,full and number(full.fullRadius,0) or 0)
	State.activationRadius=math.max(0,activation and number(activation.fullRadius,State.parryRadius) or State.parryRadius)
end
local function canActivate(snapshot)
	if not snapshot or not snapshot.ball or not snapshot.ball.Parent then State.lastGate="no_ball"; return false end
	if State.target~=State.uid or not targetsMe(snapshot) then State.lastGate="target_not_me"; return false end
	local a,b=rootPos(),pos(snapshot)
	if not a or not b then State.lastGate="no_position"; return false end
	local v=snapshot.velocity
	if typeof(v)~="Vector3" then v=snapshot.ball.AssemblyLinearVelocity end
	if typeof(v)~="Vector3" or v.Magnitude<6 then State.lastGate="ball_speed_invalid"; return false end
	local d=a-b
	if d.Magnitude==0 then State.lastGate="ball_not_closing"; return false end
	local closing=v:Dot(d.Unit)
	if closing<=0 or closing/v.Magnitude<0.3 then State.lastGate="ball_not_approaching"; return false end
	local r=radius(0)
	local base=r and number(r.noWindowParryRadius)
	local window=r and number(r.deflectWindow)
	if not base or base<0 or not window or window<=0 then State.lastGate="timing_unavailable"; return false end
	if math.max(0,d.Magnitude-base)/closing>window+ping() then State.lastGate="impact_not_imminent"; return false end
	State.lastGate="activation_ready"
	return true
end
local function getReturnWindow()
	local base=math.clamp(number(config("AutoClashActivationMs"),180),0,400)/1000
	local duration=speedWindow(base,0.1,State.speed)
	local pressure=AP and safe(AP.getPressure)
	local level=type(pressure)=="table" and number(pressure.currentLevel) or nil
	local interval=type(pressure)=="table" and number(pressure.latestReturnTime) or nil
	local bonus=0
	if level and interval and interval>0 and interval<=0.5 then
		if level>=0.6 then bonus=0.5 elseif level>=0.4 then bonus=0.3 elseif level>=0.2 then bonus=0.15 end
	end
	State.returnWindowBonus=bonus
	return math.max(duration+ping()*0.3,2/60)*(1+bonus)
end
local function startReturn(t,id,serverTime)
	local window=getReturnWindow()
	if t<State.dashUntil then window*=10 end
	State.lostAt,State.lostTo,State.lostServerAt=t,id,serverTime
	State.returnWindow=window
	State.returnExpiresAt=t+window+2*ping()+1/30
	State.returnPending=false
	State.returnToken+=1
end
local function extendReturn(t)
	if not State.lostAt or State.returnPending or t>State.returnExpiresAt then return end
	State.returnWindow=math.max(State.returnWindow,getReturnWindow()*10)
	State.returnExpiresAt=State.lostAt+State.returnWindow+2*ping()+1/30
end
local function acceptTarget(id,t,serverTime)
	local previous,wasMe=State.target,State.previousWasMe
	local me=id==State.uid
	if previous==id and wasMe~=nil then return end
	State.target=id
	if wasMe==nil then
		State.previousWasMe=me
		clearReturn()
		State.lastGate=me and "initial_me" or "initial_not_me"
		return
	end
	if State.pull then
		if id~=State.pull.lastTarget and (id==State.uid or id==State.pull.partner) then State.pull.switched=true end
		State.pull.lastTarget=id
		State.previousWasMe=me
		return
	end
	if wasMe~=me then
		State.directionAt=t
		if State.active and State.partner>0 and (previous==State.partner or id==State.partner) then
			local interval=State.switchAt>0 and t-State.switchAt or nil
			if serverTime and State.switchServerAt and serverTime>=State.switchServerAt then interval=serverTime-State.switchServerAt end
			if interval and interval>=0 then
				State.switchInterval=interval*1000
				State.switchEma=State.switchEma and 0.4*interval+0.6*State.switchEma or interval
				State.switchSamples+=1
			end
			State.switchAt,State.switchServerAt=t,serverTime
		end
	end
	if wasMe and not me then
		if State.active and State.partner>0 and id~=State.partner then setActive(false,"target_redirected") end
		startReturn(t,id,serverTime)
		State.partner=id
		State.lastGate="target_lost"
	elseif not wasMe and me then
		local elapsed=State.lostAt and t-State.lostAt
		if serverTime and State.lostServerAt then elapsed=serverTime-State.lostServerAt end
		if elapsed and elapsed>=0 and elapsed<=State.returnWindow and t<=State.returnExpiresAt and State.lostTo==previous then
			State.partner,State.returnPending,State.lastGate=previous,true,"target_return"
		else
			clearReturn()
			State.lastGate="return_too_late"
		end
	elseif not me and id~=previous then
		clearReturn()
		setActive(false,"target_redirected")
		State.partner=-1
		State.lastGate="target_redirected"
	end
	State.previousWasMe=me
end

-- [[ dash and pull ]]

local function opponent()
	if not State.players or State.partner<=0 then return nil,nil end
	local player=State.players:GetPlayerByUserId(State.partner)
	local root=player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return player,root
end
local function onDash(event)
	if type(event)~="table" or event.userId~=State.partner then return end
	State.dashEvent=event
	State.dashData=nil
	local a=rootPos()
	if not a or State.parryRadius<=0 or typeof(event.position)~="Vector3" or typeof(event.velocity)~="Vector3" then return end
	local distance=horizontal(a,event.position)
	local velocity=event.velocity
	local speed=math.sqrt(velocity.X^2+velocity.Z^2)
	if distance<=0 or speed<=0 then return end
	local closing=(velocity.X*(a.X-event.position.X)+velocity.Z*(a.Z-event.position.Z))/distance
	if closing/speed<0.3 then return end
	local accept=radius(1.15)
	local detect=radius(1.5)
	local near=accept and number(accept.fullRadius,0) or 0
	local far=detect and number(detect.fullRadius,0) or 0
	if near<=0 or far<=0 then return end
	if distance>far and distance-closing*(0.25+ping())>near then return end
	local t=number(event.detectedAt,now())
	State.dashData={
		player=event.player,userId=event.userId,position=event.position,velocity=velocity,
		previousPosition=event.previousPosition,detectedAt=t,expiresAt=t+0.25+ping()*0.3,
		confirmRadius=near,targetAtDetection=State.target,distanceAtDetection=distance,
		dangerous=distance<=near,
	}
	if distance<=near then
		State.dashUntil=t+0.7
		extendReturn(t)
	end
end
local function updateDash(t)
	local data=State.dashData
	if not data or data.dangerous then return end
	if t>data.expiresAt or data.userId~=State.partner then State.dashData=nil; return end
	local player,root=opponent()
	local a=rootPos()
	if player~=data.player or not root or not a then return end
	if horizontal(a,root.Position)<=data.confirmRadius then
		data.dangerous=true
		data.confirmedAt=t
		State.dashUntil=data.detectedAt+0.7+ping()*0.3
		extendReturn(t)
	end
end
local function escapeDash(t)
	local event=State.dashEvent
	local a=rootPos()
	local _,root=opponent()
	if not event or not a or not root or State.target==State.uid then return false end
	local detected=number(event.detectedAt)
	if not detected or t-detected<0 or t-detected>0.25+ping()*0.3 then return false end
	local distance=horizontal(a,root.Position)
	if State.dashEscapeAt~=detected then
		State.dashEscapeAt,State.dashEscapeLastAt,State.dashEscapeDistance,State.dashEscapeFrames=detected,t,distance,0
		return false
	end
	local dt=t-State.dashEscapeLastAt
	if dt<=0 or dt>0.1 then State.dashEscapeFrames=0
	elseif distance>State.dashEscapeDistance then
		local observed=(distance-State.dashEscapeDistance)/dt
		local velocity=root.AssemblyLinearVelocity
		local speed=typeof(velocity)=="Vector3" and math.sqrt(velocity.X^2+velocity.Z^2) or 0
		State.dashEscapeFrames=observed>=math.max(18,speed*0.08) and State.dashEscapeFrames+1 or 0
	else State.dashEscapeFrames=0 end
	State.dashEscapeDistance,State.dashEscapeLastAt=distance,t
	return t-detected>=0.06 and State.dashEscapeFrames>=2
end
local function outsidePull(position,reason)
	local a=rootPos()
	if not a or typeof(position)~="Vector3" or State.parryRadius<=0 then return false end
	if dist2(a,position)<=State.parryRadius^2 then return false end
	if State.active then
		State.pull={partner=State.partner,lastTarget=State.target,switched=false,stoppedAt=now()}
		setActive(false,reason)
		clearReturn()
	end
	State.pullEvent={reason=reason,at=now(),position=position}
	State.lastGate=reason
	return true
end

-- [[ deactivation ]]

local function confirmDirection(t)
	if not State.confirmAt or t-State.confirmLast>0.1 then
		State.confirmAt,State.confirmFrames=t,1
	else State.confirmFrames+=1 end
	State.confirmLast=t
	if t-State.confirmAt<0.05 or State.confirmFrames<2 then
		State.lastGate="deact_direction_confirming"
		return false
	end
	State.lastGate="deact_direction"
	return true
end
local function shouldDeactivate(t,snapshot)
	if targetsMe(snapshot) and State.target==State.uid then
		clearConfirm()
		State.lastGate="targeted"
		return false
	end
	local a,b=rootPos(),pos(snapshot)
	if not a or not b then State.lastGate="deact_no_position"; return false end
	if State.parryRadius>0 and dist2(a,b)>State.parryRadius^2 then
		if not State.outsideAt then State.outsideAt=t end
		if t-State.outsideAt>=0.05 then State.lastGate="deact_outside_radius"; return true end
	else State.outsideAt=nil end
	if escapeDash(t) then State.lastGate="own_dash_escape"; return true end
	if t<State.activationLock or t<State.dashLock then return false end
	if State.speed<=0 then State.lastGate="deact_ball_stopped"; return true end
	if State.directionAt<=0 or State.lastSyncAt<State.directionAt then return false end
	local r=radius(0)
	local base=r and number(r.noWindowParryRadius)
	if not base or dist2(a,b)<=(base*1.1)^2 then return false end
	local duration=math.clamp(number(config("AutoClashDeactivationMs"),130),0,400)/1000
	local threshold=speedWindow(duration,0.1,State.speed)+ping()*0.3
	if State.switchEma and State.switchSamples>=5 then threshold=math.max(threshold,State.switchEma*3) end
	if t-State.directionAt<=threshold then return false end
	local velocity=snapshot.velocity
	if typeof(velocity)~="Vector3" then velocity=snapshot.ball.AssemblyLinearVelocity end
	if typeof(velocity)=="Vector3" and velocity:Dot(a-b)>0 then return false end
	return confirmDirection(t)
end

-- [[ evaluation ]]

local function evaluate(t,snapshot)
	if not State.bound or not State.root or not State.root.Parent then return end
	if not snapshot or not snapshot.ball or not snapshot.ball.Parent then State.lastGate="no_ball"; return end
	updateRadius(snapshot)
	if State.pull then
		local pull=State.pull
		if t-pull.stoppedAt>2 then State.pull=nil
		else
			local a,b=rootPos(),pos(snapshot)
			local player=State.players and State.players:GetPlayerByUserId(pull.partner)
			local other=player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if pull.switched and State.target==State.uid and a and b and other and State.parryRadius>0
				and dist2(a,b)<=State.parryRadius^2 and dist2(a,other.Position)<=State.parryRadius^2 and canActivate(snapshot) then
				State.partner=pull.partner
				State.pull=nil
				clearReturn()
				setActive(true,"pull_return",snapshot,"pull_return")
			end
			return
		end
	end
	if State.active then
		if shouldDeactivate(t,snapshot) then setActive(false,"target_deactivated") end
		return
	end
	if State.recoveryUntil>t and State.previousWasMe==true and canActivate(snapshot) then
		State.recoveryUntil=0
		clearReturn()
		setActive(true,"recovered",snapshot,"snapshot_recovered")
		return
	end
	if not State.returnPending then State.lastGate="act_no_return_pending"; return end
	if t>State.returnExpiresAt then clearReturn(); State.lastGate="return_expired"; return end
	if canActivate(snapshot) then
		local reason=t<State.dashUntil and "anti_dash" or "predicted_impact"
		clearReturn()
		setActive(true,"activated",snapshot,reason)
	end
end
local function readSnapshot(t)
	local ok,snapshot=pcall(snapshotReader,t)
	if not ok then report("GameInfo.getSnapshot",snapshot); return nil,"snapshot_error" end
	if type(snapshot)~="table" then return nil,"snapshot_error" end
	local valid,result=pcall(snapshotValidator,snapshot,t)
	if not valid then report("GameInfo.isSnapshotValid",result); return nil,"snapshot_invalid" end
	if result~=true then return nil,"snapshot_invalid" end
	return snapshot
end
local function missing(t,reason)
	if not State.missingAt then State.missingAt=t end
	State.lastGate=reason
	if State.active and t-State.missingAt>=0.2 then
		State.recoveryUntil=t+1
		setActive(false,reason)
	end
end
local function ready()
	if not Utils then return false end
	local reason
	if Utils.isManualSpamActive() then reason="manual_spam"
	elseif not Utils.isActive() then reason="hub_inactive"
	elseif config("AutoClash")~=true then reason="hub_disabled"
	else
		local cd=GI and safe(GI.getDeflectCooldownState)
		if type(cd)=="table" and cd.fierceUsedForTarget==true then reason="fierce_active" end
	end
	if reason then
		setActive(false,reason)
		if State.target~=-1 or State.returnPending then clearTargets() end
		State.lastGate=reason
		return false
	end
	return true
end
local function step(generation,character,root)
	if generation~=State.generation or not State.bound or not character.Parent or not root.Parent then return end
	local t=now()
	if not ready() then return end
	if State.returnExpiresAt>0 and not State.returnPending and t>=State.returnExpiresAt then clearReturn() end
	local snapshot,err=readSnapshot(t)
	if not snapshot then missing(t,err); return end
	if Dash and type(Dash.tick)=="function" then Dash.tick(t) end
	updateDash(t)
	if snapshot.teleported==true then
		if not State.teleported then AutoClash.onBallSync({Sequence=snapshot.syncSequence,Teleported=true,Source="snapshot"}) end
		State.lastGate="teleported"
		return
	end
	State.teleported=false
	local id=target(snapshot.targetId)
	local sequence=number(snapshot.syncSequence)
	if sequence and State.sequence then
		local delta=(sequence-State.sequence)%65536
		if delta>=32768 or (delta==0 and id and State.target>0 and id~=State.target) then missing(t,"snapshot_stale"); return end
	elseif not sequence and State.lastSource=="event" and id and State.target>0 and id~=State.target and t-State.lastSyncAt<0.2 then
		missing(t,"snapshot_stale")
		return
	end
	State.missingAt=nil
	if (id and (State.previousWasMe==nil or id~=State.target)) or (snapshot.targetId~=nil and not id and State.target~=-1) then
		if sequence or (not State.sequence and (State.lastSource~="event" or t-State.lastSyncAt>=0.1)) then
			AutoClash.onBallSync({Sequence=sequence,TargetPlayerID=snapshot.targetId,Speed=snapshot.syncSpeed,Source="snapshot"})
		end
	end
	evaluate(t,snapshot)
end

-- [[ synchronization ]]

function AutoClash.onBallSync(data)
	if type(data)~="table" or not State.bound or not ready() then return end
	local seq=number(data.Sequence or data.TeleportSequence)
	if seq and seq>=0 and seq<65536 and seq%1==0 then
		if State.sequence then
			local delta=(seq-State.sequence)%65536
			if delta==0 or delta>=32768 then return true end
		end
		State.sequence=seq
	end
	local t=now()
	State.lastSyncAt=t
	State.lastSource=data.Source=="snapshot" and "snapshot" or "event"
	if data.Teleported==true then
		State.teleported=true
		setActive(false,"teleported")
		clearTargets()
		State.lastGate="teleported"
		return true
	end
	State.teleported=false
	local possessor=target(data.PossessorId)
	if possessor and possessor~=State.uid and State.players then
		local player=State.players:GetPlayerByUserId(possessor)
		local root=player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and outsidePull(root.Position,"possession_pull") then return true end
	end
	local id=target(data.TargetPlayerID) or target(data.HighlightTargetPlayerID)
	local explicit=data.TargetPlayerID~=nil or data.HighlightTargetPlayerID~=nil
	if not id and not explicit then id=GI and target(safe(GI.getTargetId)) end
	if not id then
		if explicit then
			setActive(false,"invalid_target")
			clearTargets()
			State.lastGate="invalid_target"
		end
		return true
	end
	State.speed=math.max(0,number(data.Speed,State.speed))
	acceptTarget(id,t,number(data.ServerTime))
	if data.Source~="snapshot" and (State.returnPending or (id==State.uid and data.Source=="packet")) then
		local snapshot=readSnapshot(t)
		if snapshot and snapshot.teleported~=true then evaluate(t,snapshot) end
	end
	return true
end

-- [[ character binding ]]

local function bind(character)
	reset("rebind")
	if not character or not character.Parent then return false end
	local root=character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart",1)
	if not root or not root.Parent or not State.run or not State.run.Heartbeat then return false end
	State.root,State.bound=true and root,true
	local generation=State.generation
	local function track(connection)
		table.insert(State.connections,connection)
		if Utils.trackCharacter then Utils.trackCharacter(connection) end
	end
	track(State.run.Heartbeat:Connect(function() step(generation,character,root) end))
	track(character.AncestryChanged:Connect(function(_,parent)
		if not parent and generation==State.generation then reset("character_removed") end
	end))
	local function watchDark(player)
		if player.UserId==State.uid or State.darkConnections[player] then return end
		local connection=player:GetAttributeChangedSignal("DarkSealed"):Connect(function()
			if generation~=State.generation or not State.bound or player:GetAttribute("DarkSealed")~=true then return end
			local other=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if other then outsidePull(other.Position,"dark_seal_pull") end
		end)
		State.darkConnections[player]=connection
		if Utils.trackCharacter then Utils.trackCharacter(connection) end
	end
	if State.players then
		for _,player in ipairs(State.players:GetPlayers()) do watchDark(player) end
		track(State.players.PlayerAdded:Connect(watchDark))
		track(State.players.PlayerRemoving:Connect(function(player)
			local connection=State.darkConnections[player]
			if connection then
				if Utils.untrackCharacter then Utils.untrackCharacter(connection) end
				connection:Disconnect()
				State.darkConnections[player]=nil
			end
		end))
	end
	local manifest=GI and safe(GI.getManifestRemote)
	if manifest and manifest.OnClientEvent then
		track(manifest.OnClientEvent:Connect(function(caster)
			if generation==State.generation and State.bound and typeof(caster)=="CFrame" then
				outsidePull(caster.Position,"manifest_pull")
			end
		end))
	end
	phase("waiting","character_bound")
	return true
end

-- [[ public interface ]]

function AutoClash.setup(deps)
	if type(deps)~="table" then return false,"dependencias invalidas" end
	local required={
		AutoParry={"getRadius","getStatus"}, Dash={"setHandler","tick"},
		GameInfo={"getSnapshot","isSnapshotValid"},
		Utils={"now","getConfig","getRunService","getPlayers","recordTransition","setAutoSpamActive","trackCharacter","untrackCharacter","isActive","isManualSpamActive","getLocalPlayer","apiVersion"},
	}
	for module,methods in pairs(required) do
		local dependency=deps[module]
		for _,method in ipairs(methods) do
			if type(dependency)~="table" or type(dependency[method])~="function" then return false,module.."."..method.." ausente" end
		end
	end
	if Utils then reset("setup") end
	AP,GI,Dash,Utils=deps.AutoParry,deps.GameInfo,deps.Dash,deps.Utils
	clock=Utils.now
	snapshotReader=type(GI.getSnapshotAt)=="function" and GI.getSnapshotAt or function(t) return GI.getSnapshot(nil,t) end
	snapshotValidator=GI.isSnapshotValid
	local player=Utils.getLocalPlayer()
	if not player then return false,"LocalPlayer indisponivel" end
	State.uid,State.run,State.players=player.UserId,Utils.getRunService(),Utils.getPlayers()
	State.lastGate="none"
	Dash.setHandler(onDash)
	return true
end
function AutoClash.bindCharacter(character) return bind(character) end
function AutoClash.detachCharacter() reset("detach") end
function AutoClash.teardown()
	reset("teardown")
	if Dash and Dash.setHandler then Dash.setHandler(nil) end
	AP,GI,Dash,Utils,clock,snapshotReader,snapshotValidator=nil,nil,nil,nil,nil,nil,nil
	State.uid,State.run,State.players=nil,nil,nil
end
function AutoClash.isActive() return State.active end
function AutoClash.stopSpam()
	setActive(false,"fierce_deflect")
	clearReturn()
	State.lastGate="fierce_deflect"
end
function AutoClash.getPullEvent() return State.pullEvent end
function AutoClash.getDashData()
	local data=State.dashData
	if not data or not data.player or not data.player.Parent or data.userId~=State.partner then return nil end
	local t=now()
	if t<data.detectedAt or t>data.expiresAt then return nil end
	if State.target~=State.uid and State.target~=data.userId then return nil end
	return data
end
function AutoClash.getTargetSwitch()
	return {timestampMs=State.switchAt*1000,intervalMs=State.switchInterval,partnerId=State.partner,resetToken=State.resetToken}
end
function AutoClash.getActivationContext()
	return {
		active=State.active,source=State.activationSource,reason=State.activationReason,
		trigger=State.activationTrigger,timestamp=State.activationAt,
		target=State.activationTarget,partner=State.activationPartner,
		distance=State.activationDistance,parryRadius=State.activationRadiusUsed,speed=State.activationSpeed,
	}
end
function AutoClash.getStatus()
	local context=GI and safe(GI.getClashContext)
	return {
		schema=Utils and safe(Utils.apiVersion),phase=State.phase,bound=State.bound,active=State.active,
		gameClash=context,activationSource=State.activationSource,activationReason=State.activationReason,
		activationTrigger=State.activationTrigger,activationAt=State.activationAt,
		activationTarget=State.activationTarget,activationPartner=State.activationPartner,
		activationDistance=State.activationDistance,activationRadius=State.activationRadiusUsed,
		activationSpeed=State.activationSpeed,parryRadius=State.parryRadius,
		lastTarget=State.target,clashPartnerId=State.partner,
		clashIntervalEma=State.switchEma,clashIntervalEmaSamples=State.switchSamples,
		lastGate=State.lastGate,ownDashEscapePending=State.dashEscapeAt~=nil,
		ownDashEscapeConfirmFrames=State.dashEscapeFrames,
		ownDashEscapeLastDistance=State.dashEscapeDistance,ownDashEscapeLastAt=State.dashEscapeLastAt,
		returnPending=State.returnPending,returnWindow=State.returnWindow,
		returnWindowBonus=State.returnWindowBonus,returnExpiresAt=State.returnExpiresAt,
		returnFromTarget=State.lostTo,returnToken=State.returnToken,
		dashBonusUntil=State.dashUntil,dashDeactLockedUntil=State.dashLock,
		deactivationCandidate=State.confirmAt and "deact_direction" or nil,
		deactivationConfirmFrames=State.confirmFrames,deactivationCandidateAt=State.confirmAt or 0,
	}
end

AutoClash.__contract={
	requires={AutoParry="autoparry",Dash="dash",GameInfo="gameinfo",Utils="utils"},
	requiresMethods={
		AutoParry={"getRadius","getStatus"},Dash={"setHandler","tick"},
		GameInfo={"getSnapshot","isSnapshotValid"},
		Utils={"now","getConfig","getRunService","getPlayers","recordTransition","setAutoSpamActive","trackCharacter","untrackCharacter","isActive","isManualSpamActive","getLocalPlayer","apiVersion"},
	},
	provides={"setup","bindCharacter","detachCharacter","onBallSync","getStatus","getTargetSwitch","getDashData","getPullEvent","stopSpam"},
	onBallSync=true,bindCharacter=true,minAutoParryVersion=11,requiresVersions={AutoParry=11},
}

return AutoClash
