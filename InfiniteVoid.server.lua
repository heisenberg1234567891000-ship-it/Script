-- INFINITE VOID | authoritative territory / information overload
-- Install ONE copy as a Script in ServerScriptService in your own experience.
-- The matching client renders the cinematic. Only this server can freeze players.
-- No damage, permanent map edits, client-supplied origins, or client hit reports.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

assert(RunService:IsServer(), "InfiniteVoid.server.lua must run on the server")

local CONFIG = {
	Radius = 85,
	Windup = 3.2,
	Duration = 8,
	Cooldown = 28,
	StartDelay = 0.15,
	ScanInterval = 0.1,
	MaxDomains = 3,
	-- NPCs are opt-in: tag their character Model, not their limbs.
	AffectTaggedNPCs = true,
	NPCTag = "InfiniteVoidTarget",
	MaxTaggedNPCs = 80,
	RequestBurst = 6,
	RequestsPerSecond = 2,
	SyncInterval = 1,
}

-- Refuse a second running controller instead of creating competing freezes.
local markerName = "ISAGI_InfiniteVoidController"
local previous = ServerScriptService:FindFirstChild(markerName)
if previous then
	if not previous:IsA("ObjectValue") or (previous.Value and previous.Value.Parent) then
		warn("Infinite Void already has a controller. Install only one server Script.")
		return
	end
	previous:Destroy()
end
local marker = Instance.new("ObjectValue")
marker.Name = markerName
marker.Value = script
marker.Parent = ServerScriptService

local remoteName = "ISAGI_InfiniteVoidRemote"
local remote = ReplicatedStorage:FindFirstChild(remoteName)
if remote and not remote:IsA("RemoteEvent") then
	marker:Destroy()
	error(remoteName .. " must be a RemoteEvent")
end
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = ReplicatedStorage
end

local alive = true
local domains = {}
local states = {}
local frozen = {}
local connections = {}
local finishDomain
local shutdown

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	connections[#connections + 1] = connection
	return connection
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validFrame(frame)
	for _, component in ipairs({ frame:GetComponents() }) do
		if not finite(component) or math.abs(component) > 10000000 then return false end
	end
	return true
end

local function characterParts(character)
	if not character or not character:IsA("Model") or not character:IsDescendantOf(workspace) then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then return end
	if not validFrame(root.CFrame) then return end
	return humanoid, root
end

-- Each character gets ONE freeze record. Reasons are keyed by domain and kind,
-- so leaving/ending one of two overlapping territories never unfreezes early.
local function pauseTrack(record, track)
	if record.tracks[track] == nil then
		record.tracks[track] = track.Speed
	elseif track.Speed ~= 0 then
		-- Another animation controller changed its speed while overloaded.
		record.tracks[track] = track.Speed
	end
	pcall(function() track:AdjustSpeed(0) end)
end

local function stopAnimationPause(record)
	if record.animationConnection then
		record.animationConnection:Disconnect()
		record.animationConnection = nil
	end
	for track, speed in pairs(record.tracks) do
		pcall(function()
			-- Never restart a track that its own animation controller stopped.
			if track.IsPlaying and track.Speed == 0 then track:AdjustSpeed(speed) end
		end)
	end
	record.tracks = {}
	record.animator = nil
end

local function maintainAnimations(record)
	if record.overloadCount <= 0 then
		if record.animator then stopAnimationPause(record) end
		return
	end
	local animator = record.humanoid:FindFirstChildOfClass("Animator")
	if animator ~= record.animator then
		stopAnimationPause(record)
		record.animator = animator
		if animator then
			record.animationConnection = animator.AnimationPlayed:Connect(function(track)
				if not record.released and record.overloadCount > 0 then pauseTrack(record, track) end
			end)
		end
	end
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do pauseTrack(record, track) end
	end
end

local function updateAttributes(record)
	local character = record.character
	character:SetAttribute("InfiniteVoidOverloaded", record.overloadCount > 0 or record.originalOverloaded)
	character:SetAttribute("InfiniteVoidCasting", record.castCount > 0 or record.originalCasting)
end

local function releaseRecord(record)
	if record.released then return end
	record.released = true
	frozen[record.character] = nil
	for _, connection in ipairs(record.connections) do connection:Disconnect() end
	stopAnimationPause(record)
	-- Restore only values still held by this controller. Property listeners retain
	-- new walk/jump settings requested by other server scripts during a freeze.
	for _, entry in ipairs(record.properties) do
		pcall(function()
			if entry.object[entry.name] == entry.forced then
				entry.object[entry.name] = entry.restore
			end
		end)
	end
	pcall(function()
		if record.character:GetAttribute("InfiniteVoidOverloaded") == true then
			record.character:SetAttribute("InfiniteVoidOverloaded", record.originalOverloaded)
		end
		if record.character:GetAttribute("InfiniteVoidCasting") == true then
			record.character:SetAttribute("InfiniteVoidCasting", record.originalCasting)
		end
	end)
	if record.manualOwnership and record.root.Parent and not record.root.Anchored then
		pcall(function()
			if not record.networkOwner or record.networkOwner.Parent == Players then
				record.root:SetNetworkOwner(record.networkOwner)
			end
		end)
	end
end

local function holdProperty(record, object, name, forced)
	local entry = { object = object, name = name, forced = forced, restore = object[name] }
	record.properties[#record.properties + 1] = entry
	object[name] = forced
	record.connections[#record.connections + 1] = object:GetPropertyChangedSignal(name):Connect(function()
		if record.released then return end
		local value = object[name]
		if value ~= forced then
			entry.restore = value
			object[name] = forced
		end
	end)
end

local function newRecord(character, humanoid, root)
	local record = {
		character = character, humanoid = humanoid, root = root,
		reasons = {}, count = 0, overloadCount = 0, castCount = 0,
		properties = {}, connections = {}, tracks = {}, released = false,
		originalOverloaded = character:GetAttribute("InfiniteVoidOverloaded"),
		originalCasting = character:GetAttribute("InfiniteVoidCasting"),
	}
	frozen[character] = record
	-- An anchored seated character would also anchor its vehicle assembly.
	-- Detach the engine-created seat weld before anchoring the character root.
	local seat = humanoid.SeatPart
	if seat then
		humanoid.Sit = false
		local weld = seat:FindFirstChild("SeatWeld")
		if weld and weld:IsA("Weld") then
			local a, b = weld.Part0, weld.Part1
			if (a and a:IsDescendantOf(character)) or (b and b:IsDescendantOf(character)) then
				weld:Destroy()
			end
		end
	end
	pcall(function()
		if not root.Anchored then
			record.manualOwnership = not root:GetNetworkOwnershipAuto()
			record.networkOwner = root:GetNetworkOwner()
		end
	end)
	-- Momentum is deliberately discarded rather than replayed after eight seconds.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	holdProperty(record, humanoid, "WalkSpeed", 0)
	holdProperty(record, humanoid, "JumpPower", 0)
	holdProperty(record, humanoid, "JumpHeight", 0)
	holdProperty(record, humanoid, "AutoRotate", false)
	holdProperty(record, root, "Anchored", true)
	record.connections[#record.connections + 1] = humanoid.Died:Connect(function()
		releaseRecord(record)
	end)
	return record
end

local function acquire(character, key, kind)
	local humanoid, root = characterParts(character)
	if not humanoid then return false end
	local record = frozen[character]
	if record and (record.humanoid ~= humanoid or record.root ~= root) then
		releaseRecord(record)
		record = nil
	end
	if not record then record = newRecord(character, humanoid, root) end
	if not record.reasons[key] then
		record.reasons[key] = kind
		record.count = record.count + 1
		if kind == "overload" then
			record.overloadCount = record.overloadCount + 1
		else
			record.castCount = record.castCount + 1
		end
		updateAttributes(record)
		maintainAnimations(record)
	end
	return true
end

local function release(character, key)
	local record = frozen[character]
	if not record or not record.reasons[key] then return end
	local kind = record.reasons[key]
	record.reasons[key] = nil
	record.count = record.count - 1
	if kind == "overload" then
		record.overloadCount = record.overloadCount - 1
	else
		record.castCount = record.castCount - 1
	end
	if record.count == 0 then
		releaseRecord(record)
	else
		updateAttributes(record)
		maintainAnimations(record)
	end
end

finishDomain = function(domain)
	if domain.finished then return end
	domain.finished = true
	domains[domain.payload.id] = nil
	if domain.deathConnection then domain.deathConnection:Disconnect() end
	release(domain.character, domain.castKey)
	for character in pairs(domain.targets) do release(character, domain.overloadKey) end
	domain.targets = {}
	local state = states[domain.player]
	if state and state.domain == domain then state.domain = nil end
	if remote.Parent then remote:FireAllClients("End", { id = domain.payload.id }) end
end

local function deny(player, reason, retryAt)
	local state = states[player]
	local now = workspace:GetServerTimeNow()
	if not state or now - state.lastDenied < 0.4 then return end
	state.lastDenied = now
	remote:FireClient(player, "Denied", { reason = reason, retryAt = retryAt or now })
end

local function startDomain(player)
	local state = states[player]
	if not state then return end
	local now = workspace:GetServerTimeNow()
	if now < state.cooldownUntil then return deny(player, "Cooldown", state.cooldownUntil) end
	if state.domain then return deny(player, "AlreadyCasting", state.cooldownUntil) end
	local character = player.Character
	local humanoid, root = characterParts(character)
	if not humanoid then return deny(player, "CharacterUnavailable") end
	if humanoid.SeatPart or humanoid.Sit then return deny(player, "Seated") end
	if root.Anchored or character:GetAttribute("InfiniteVoidOverloaded")
		or character:GetAttribute("InfiniteVoidCasting") then
		return deny(player, "Interrupted")
	end
	local count = 0
	for _ in pairs(domains) do count = count + 1 end
	if count >= CONFIG.MaxDomains then return deny(player, "TooManyDomains", now + 1) end
	local startAt = now + CONFIG.StartDelay
	local id = HttpService:GenerateGUID(false)
	local payload = {
		id = id, casterUserId = player.UserId, center = root.Position, frame = root.CFrame,
		startAt = startAt, openAt = startAt + CONFIG.Windup,
		endAt = startAt + CONFIG.Windup + CONFIG.Duration,
		radius = CONFIG.Radius, seed = math.random(1, 2147483646),
		cooldownUntil = startAt + CONFIG.Cooldown,
	}
	local domain = {
		player = player, character = character, root = root, humanoid = humanoid,
		payload = payload, targets = {}, opened = false, finished = false,
		castKey = id .. ":cast", overloadKey = id .. ":overload",
	}
	domains[id] = domain
	state.domain = domain
	state.cooldownUntil = payload.cooldownUntil
	player:SetAttribute("InfiniteVoidCooldownUntil", payload.cooldownUntil)
	acquire(character, domain.castKey, "cast")
	domain.deathConnection = humanoid.Died:Connect(function() finishDomain(domain) end)
	remote:FireAllClients("Start", payload)
end

local function candidates()
	local result, seen = {}, {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid, root = characterParts(character)
		if humanoid then
			seen[character] = true
			result[#result + 1] = { character = character, root = root }
		end
	end
	if CONFIG.AffectTaggedNPCs then
		local count = 0
		for _, character in ipairs(CollectionService:GetTagged(CONFIG.NPCTag)) do
			if count >= CONFIG.MaxTaggedNPCs then break end
			-- Count scanned entries too, so malformed tags cannot make scans unbounded.
			count = count + 1
			if not seen[character] then
				local humanoid, root = characterParts(character)
				if humanoid then result[#result + 1] = { character = character, root = root } end
			end
		end
	end
	return result
end

local function step()
	local now = workspace:GetServerTimeNow()
	local targets = candidates()
	local ordered = {}
	for _, domain in pairs(domains) do ordered[#ordered + 1] = domain end
	-- Resolve openings in server-time order so a late frame cannot let a later
	-- interrupted cast open first merely because pairs() visited it first.
	table.sort(ordered, function(a, b)
		if a.payload.openAt == b.payload.openAt then return a.payload.id < b.payload.id end
		return a.payload.openAt < b.payload.openAt
	end)
	for _, domain in ipairs(ordered) do
		local p = domain.payload
		local humanoid, root = characterParts(domain.character)
		if now >= p.endAt or domain.player.Parent ~= Players
			or domain.player.Character ~= domain.character
			or humanoid ~= domain.humanoid or root ~= domain.root then
			finishDomain(domain)
		elseif not domain.opened and domain.character:GetAttribute("InfiniteVoidOverloaded") then
			-- Check before the opening deadline: overload may arrive on the final
			-- preparation frame, and still has to cancel the interrupted cast.
			finishDomain(domain)
		elseif now >= p.openAt then
			if not domain.opened then
				domain.opened = true
				release(domain.character, domain.castKey)
			end
			local inside = {}
			for _, target in ipairs(targets) do
				local character = target.character
				-- The caster is immune to their own territory only.
				if character ~= domain.character and (target.root.Position - p.center).Magnitude <= p.radius then
					if acquire(character, domain.overloadKey, "overload") then inside[character] = true end
				end
			end
			for character in pairs(domain.targets) do
				if not inside[character] then release(character, domain.overloadKey) end
			end
			domain.targets = inside
		end
	end
	for _, record in pairs(frozen) do
		local humanoid, root = characterParts(record.character)
		if humanoid ~= record.humanoid or root ~= record.root then
			releaseRecord(record)
		else
			maintainAnimations(record)
		end
	end
end

local function addPlayer(player)
	if states[player] then return end
	local state = {
		cooldownUntil = 0, tokens = CONFIG.RequestBurst, refillAt = os.clock(),
		lastSync = -math.huge, lastDenied = -math.huge,
	}
	states[player] = state
	state.removing = player.CharacterRemoving:Connect(function(character)
		if state.domain and state.domain.character == character then finishDomain(state.domain) end
		local record = frozen[character]
		if record then releaseRecord(record) end
	end)
end

shutdown = function()
	if not alive then return end
	alive = false
	for _, connection in ipairs(connections) do connection:Disconnect() end
	for _, domain in pairs(domains) do finishDomain(domain) end
	for _, record in pairs(frozen) do releaseRecord(record) end
	for player, state in pairs(states) do
		state.removing:Disconnect()
		if player.Parent == Players then player:SetAttribute("InfiniteVoidCooldownUntil", nil) end
	end
	states = {}
	if marker.Parent then marker:Destroy() end
	-- Keep the RemoteEvent stable for already-connected LocalScripts / hot reload.
end

local function guarded(callback)
	return function(...)
		if not alive then return end
		local ok, message = xpcall(callback, debug.traceback, ...)
		if not ok then
			warn("Infinite Void stopped safely after an error: " .. tostring(message))
			shutdown()
		end
	end
end

for _, player in ipairs(Players:GetPlayers()) do addPlayer(player) end
connect(Players.PlayerAdded, addPlayer)
connect(Players.PlayerRemoving, function(player)
	local state = states[player]
	if not state then return end
	if state.domain then finishDomain(state.domain) end
	if player.Character and frozen[player.Character] then releaseRecord(frozen[player.Character]) end
	state.removing:Disconnect()
	states[player] = nil
end)

connect(remote.OnServerEvent, guarded(function(player, action)
	local state = states[player]
	if not state or (action ~= "Cast" and action ~= "Sync") then return end
	local now = os.clock()
	state.tokens = math.min(CONFIG.RequestBurst, state.tokens + (now - state.refillAt) * CONFIG.RequestsPerSecond)
	state.refillAt = now
	if state.tokens < 1 then return end
	state.tokens = state.tokens - 1
	if action == "Sync" then
		if now - state.lastSync < CONFIG.SyncInterval then return end
		state.lastSync = now
		local serverNow = workspace:GetServerTimeNow()
		for _, domain in pairs(domains) do
			if serverNow < domain.payload.endAt then remote:FireClient(player, "Start", domain.payload) end
		end
		remote:FireClient(player, "SyncDone", {})
	else
		startDomain(player)
	end
end))

local accumulated = 0
connect(RunService.Heartbeat, guarded(function(dt)
	accumulated = accumulated + dt
	if accumulated >= CONFIG.ScanInterval then
		accumulated = accumulated % CONFIG.ScanInterval
		step()
	end
end))
connect(script.Destroying, shutdown)
connect(script.AncestryChanged, function()
	if not script:IsDescendantOf(game) then shutdown() end
end)
game:BindToClose(shutdown)
