-- RETURN BY DEATH | server-authoritative checkpoint / normal respawn restoration
-- Install ONE Script in ServerScriptService in a place you own.
-- Observes the game's existing death/respawn lifecycle. Never requests a reset,
-- changes CharacterAutoLoads, restores inventory, or rewinds the world.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "ReturnByDeath.server.lua must run on the server")

local CONFIG = {
	SaveCooldown = 3,
	StableTime = 0.7,
	SpawnTimeout = 15,
	PollInterval = 0.1,
	MaxStableSpeed = 2.5,
	MaxStableDrift = 0.65,
	MaxGroundSlope = 0.85, -- minimum upward normal
	MaxGroundHeightDifference = 0.65,
	MaxRestoreHeightChange = 4,
	FallbackDistances = { 3, 6 }, -- bounded: center + 8 points on each ring
	RequestBurst = 5,
	RequestsPerSecond = 2,
	SyncInterval = 0.75,
}

local markerName = "ISAGI_ReturnByDeathController"
local previous = ServerScriptService:FindFirstChild(markerName)
if previous then
	if not previous:IsA("ObjectValue") or (previous.Value and previous.Value.Parent) then
		warn("Return By Death already has a controller. Install only one server Script.")
		return
	end
	previous:Destroy()
end
local marker = Instance.new("ObjectValue")
marker.Name = markerName
marker.Value = script
marker.Parent = ServerScriptService

local alive = true
local connections = {}
local states = {}
local humanoidModels = {}
local remote
local ownsRemote = false

local function disconnect(list)
	for _, connection in ipairs(list) do connection:Disconnect() end
	table.clear(list)
end

local function shutdown()
	if not alive then return end
	alive = false
	disconnect(connections)
	for _, state in pairs(states) do
		state.generation = state.generation + 1
		disconnect(state.connections)
		disconnect(state.characterConnections)
	end
	table.clear(states)
	table.clear(humanoidModels)
	if ownsRemote and remote then remote:Destroy() end
	if marker.Parent then marker:Destroy() end
end

local function connect(signal, callback, list)
	local connection = signal:Connect(callback)
	table.insert(list or connections, connection)
	return connection
end

local function now()
	return workspace:GetServerTimeNow()
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function emit(player, action, data)
	if alive and player.Parent == Players and remote and remote.Parent then
		remote:FireClient(player, action, data)
	end
end

local function stateMessage(player, state)
	local checkpoint = state.checkpoint
	emit(player, "State", {
		hasCheckpoint = checkpoint ~= nil,
		position = checkpoint and checkpoint.rootCFrame.Position or nil,
		version = state.version,
		cycle = state.cycle,
		readyAt = state.readyAt,
		waitingForRespawn = state.pending ~= nil,
	})
end

local function denied(player, state, reason)
	emit(player, "Denied", { reason = reason, readyAt = state.readyAt })
	stateMessage(player, state)
end

local function characterParts(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not character:IsDescendantOf(workspace) or not humanoid
		or not root or not root:IsA("BasePart") or humanoid.Health <= 0
		or not finite(humanoid.Health) or not finite(humanoid.MaxHealth) or humanoid.MaxHealth <= 0 then
		return nil
	end
	return character, humanoid, root
end

local function interrupted(character, humanoid, root)
	return root.Anchored or humanoid.Sit or humanoid.SeatPart ~= nil
		or character:GetAttribute("InfiniteVoidOverloaded") == true
		or character:GetAttribute("InfiniteVoidCasting") == true
end

-- Track humanoid models once; characters/NPCs never become checkpoint floors
-- and do not obstruct the static geometry clearance test.
local function rememberHumanoid(instance)
	if instance:IsA("Humanoid") and instance.Parent and instance.Parent:IsA("Model") then
		humanoidModels[instance] = instance.Parent
	end
end

local function queryParams(character, root)
	local excluded = { character }
	for humanoid, model in pairs(humanoidModels) do
		if humanoid:IsDescendantOf(workspace) and model:IsDescendantOf(workspace) then
			excluded[#excluded + 1] = model
		end
	end
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = excluded
	ray.IgnoreWater = false
	ray.RespectCanCollide = true
	ray.CollisionGroup = root.CollisionGroup
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = excluded
	overlap.RespectCanCollide = true
	overlap.CollisionGroup = root.CollisionGroup
	overlap.MaxParts = 1
	return ray, overlap
end

-- Bounding envelope of body parts only: accessories/tools cannot inflate it.
-- The model's pivot is not assumed to coincide with HumanoidRootPart.
local function bodyBounds(character, humanoid, root)
	local halfX, halfZ = math.max(1, root.Size.X / 2), math.max(0.65, root.Size.Z / 2)
	local low, high = -root.Size.Y / 2, root.Size.Y / 2
	for _, part in ipairs(character:GetChildren()) do
		if part:IsA("BasePart") then
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local point = root.CFrame:PointToObjectSpace(part.CFrame:PointToWorldSpace(
							Vector3.new(x * part.Size.X / 2, y * part.Size.Y / 2, z * part.Size.Z / 2)))
						halfX, halfZ = math.max(halfX, math.abs(point.X)), math.max(halfZ, math.abs(point.Z))
						low, high = math.min(low, point.Y), math.max(high, point.Y)
					end
				end
			end
		end
	end
	return {
		x = halfX + 0.12, z = halfZ + 0.12,
		floor = math.max(-low, humanoid.HipHeight + root.Size.Y / 2),
		top = high + 0.15,
	}
end

local function staticGround(hit)
	if not hit or hit.Material == Enum.Material.Water or hit.Normal.Y < CONFIG.MaxGroundSlope then
		return false
	end
	local instance = hit.Instance
	return instance == workspace.Terrain or (instance:IsA("BasePart") and instance.Anchored and instance.CanCollide)
end

local function yawFrame(position, look)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
	return CFrame.lookAt(position, position + flat.Unit)
end

-- Probe center + four feet positions. Prevents saving on an edge or moving
-- platform. Bounds overlap handles parts; column/cross rays also handle Terrain.
local function safeLocation(groundPoint, look, bounds, ray, overlap, maxHeightChange)
	if not finite(groundPoint.X) or not finite(groundPoint.Y) or not finite(groundPoint.Z)
		or groundPoint.Y <= workspace.FallenPartsDestroyHeight + 3 then return nil end
	local orientation = yawFrame(groundPoint, look)
	local samples = {
		Vector3.zero,
		Vector3.new(bounds.x * 0.55, 0, bounds.z * 0.55),
		Vector3.new(-bounds.x * 0.55, 0, bounds.z * 0.55),
		Vector3.new(bounds.x * 0.55, 0, -bounds.z * 0.55),
		Vector3.new(-bounds.x * 0.55, 0, -bounds.z * 0.55),
	}
	local low, high = math.huge, -math.huge
	for _, offset in ipairs(samples) do
		local point = orientation:PointToWorldSpace(offset)
		local hit = workspace:Raycast(point + Vector3.new(0, maxHeightChange + 0.3, 0),
			Vector3.new(0, -(maxHeightChange * 2 + 0.6), 0), ray)
		if not staticGround(hit) or math.abs(hit.Position.Y - groundPoint.Y) > maxHeightChange + 0.05 then return nil end
		low, high = math.min(low, hit.Position.Y), math.max(high, hit.Position.Y)
	end
	if high - low > CONFIG.MaxGroundHeightDifference then return nil end
	local floorPoint = Vector3.new(groundPoint.X, high, groundPoint.Z)
	local rootFrame = yawFrame(floorPoint + Vector3.new(0, bounds.floor + 0.12, 0), look)
	local bottom = high + 0.17
	local top = rootFrame.Position.Y + bounds.top
	local boxFrame = yawFrame(Vector3.new(floorPoint.X, (bottom + top) / 2, floorPoint.Z), look)
	if #workspace:GetPartBoundsInBox(boxFrame, Vector3.new(bounds.x * 2, top - bottom, bounds.z * 2), overlap) > 0 then
		return nil
	end
	local footFrame = yawFrame(Vector3.new(floorPoint.X, bottom, floorPoint.Z), look)
	for x = -1, 1 do
		for z = -1, 1 do
			local start = footFrame:PointToWorldSpace(Vector3.new(bounds.x * x, 0, bounds.z * z))
			if workspace:Raycast(start, Vector3.new(0, top - bottom, 0), ray) then return nil end
		end
	end
	for _, y in ipairs({ 0.2, (top - bottom) * 0.5, top - bottom }) do
		for _, z in ipairs({ -bounds.z, 0, bounds.z }) do
			local start = footFrame:PointToWorldSpace(Vector3.new(-bounds.x, y, z))
			if workspace:Raycast(start, footFrame.RightVector * bounds.x * 2, ray) then return nil end
		end
	end
	return rootFrame, floorPoint
end

local function checkpointAtCharacter(character, humanoid, root)
	if not finite(humanoid.Health) or humanoid.Health <= 0
		or not finite(humanoid.MaxHealth) or humanoid.MaxHealth <= 0 then
		return nil, "CharacterUnavailable"
	end
	if interrupted(character, humanoid, root) then return nil, "Interrupted" end
	if humanoid.FloorMaterial == Enum.Material.Air or humanoid.FloorMaterial == Enum.Material.Water
		or math.abs(root.AssemblyLinearVelocity.Y) > CONFIG.MaxStableSpeed then
		return nil, "GroundRequired"
	end
	local bounds = bodyBounds(character, humanoid, root)
	local ray, overlap = queryParams(character, root)
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -(bounds.floor + 0.65), 0), ray)
	if not staticGround(hit) then return nil, "GroundRequired" end
	local frame, floorPoint = safeLocation(hit.Position, root.CFrame.LookVector, bounds, ray, overlap, 0.7)
	if not frame then return nil, "CheckpointBlocked" end
	return { rootCFrame = frame, floorPoint = floorPoint, health = humanoid.Health, savedAt = now() }
end

local function setCheckpoint(player, state, checkpoint)
	state.version = state.version + 1
	checkpoint.version = state.version
	state.checkpoint = checkpoint
	state.readyAt = now() + CONFIG.SaveCooldown
	emit(player, "Checkpoint", {
		position = checkpoint.rootCFrame.Position, version = checkpoint.version,
		savedAt = checkpoint.savedAt, health = checkpoint.health,
		cycle = state.cycle, readyAt = state.readyAt,
	})
end

local function restoreLocation(character, humanoid, root, checkpoint)
	local bounds = bodyBounds(character, humanoid, root)
	local ray, overlap = queryParams(character, root)
	local look = checkpoint.rootCFrame.LookVector
	local frame = safeLocation(checkpoint.floorPoint, look, bounds, ray, overlap, CONFIG.MaxRestoreHeightChange)
	if frame then return frame end
	for _, radius in ipairs(CONFIG.FallbackDistances) do
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local point = checkpoint.floorPoint + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			frame = safeLocation(point, look, bounds, ray, overlap, CONFIG.MaxRestoreHeightChange)
			if frame then return frame end
		end
	end
	return nil
end

local function invalidate(player, state, reason)
	state.epoch = state.epoch + 1
	state.version = state.version + 1
	state.checkpoint, state.pending = nil, nil
	state.readyAt = 0
	emit(player, "Invalidated", { reason = reason })
	stateMessage(player, state)
	-- A round/team change alone does not schedule a fresh checkpoint. The next
	-- real CharacterAdded or a deliberate B save establishes the new checkpoint.
end

local function bindCharacter(player, state, character)
	state.generation = state.generation + 1
	local generation, epoch = state.generation, state.epoch
	disconnect(state.characterConnections)
	local pending = state.pending
	local deadline = now() + CONFIG.SpawnTimeout
	local function characterValid()
		return alive and states[player] == state and state.generation == generation
			and player.Character == character
	end
	local function valid()
		return characterValid() and state.epoch == epoch
	end
	task.spawn(function()
		local ok, message = xpcall(function()
			local humanoid, root
			while characterValid() and now() < deadline do
				humanoid = character:FindFirstChildOfClass("Humanoid")
				root = character:FindFirstChild("HumanoidRootPart")
				if humanoid and root and root:IsA("BasePart") and character:IsDescendantOf(workspace) then break end
				task.wait(CONFIG.PollInterval)
			end
			if not characterValid() then return end
			if not humanoid or not root or not root:IsA("BasePart") or not character:IsDescendantOf(workspace) then
				if valid() then
					if state.pending == pending then state.pending = nil end
					denied(player, state, "Timeout")
				end
				return
			end
			local deathHandled = false
			connect(humanoid.Died, function()
				-- A new round may invalidate a checkpoint and then save another on the
				-- same character: epoch is intentionally read NOW for this callback.
				if not alive or states[player] ~= state or state.generation ~= generation
					or player.Character ~= character or deathHandled then return end
				deathHandled = true
				local checkpoint = state.checkpoint
				if checkpoint then
					state.cycle = state.cycle + 1
					state.pending = { checkpoint = checkpoint, cycle = state.cycle, epoch = state.epoch }
					emit(player, "Rewind", {
						cycle = state.cycle, position = checkpoint.rootCFrame.Position,
						version = checkpoint.version, startedAt = now(),
					})
					stateMessage(player, state)
				end
			end, state.characterConnections)

			if not valid() then return end
			if not finite(humanoid.Health) or humanoid.Health <= 0
				or not finite(humanoid.MaxHealth) or humanoid.MaxHealth <= 0 then
				if state.pending == pending then state.pending = nil end
				denied(player, state, "Interrupted")
				return
			end
			if pending and state.pending == pending and pending.epoch == epoch then
				-- Give the game's spawn placement one frame; the game still owns all
				-- respawn scheduling. No late teleport loops fight custom controllers.
				RunService.Heartbeat:Wait()
				if not valid() or state.pending ~= pending then return end
				if not finite(humanoid.Health) or humanoid.Health <= 0
					or not finite(humanoid.MaxHealth) or humanoid.MaxHealth <= 0
					or interrupted(character, humanoid, root) then
					state.pending = nil
					denied(player, state, "Interrupted")
					return
				end
				local frame = restoreLocation(character, humanoid, root, pending.checkpoint)
				state.pending = nil
				if frame then
					local rootToPivot = root.CFrame:ToObjectSpace(character:GetPivot())
					character:PivotTo(frame * rootToPivot)
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") and not part.Anchored then
							part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
						end
					end
					humanoid.Health = math.min(pending.checkpoint.health, humanoid.MaxHealth)
					emit(player, "Returned", {
						cycle = pending.cycle, position = frame.Position,
						version = pending.checkpoint.version, character = character,
					})
					stateMessage(player, state)
					return -- Never overwrite the original checkpoint at restored spawn.
				end
				-- Destroyed/blocked support: remain at normal spawn, drop the unsafe
				-- checkpoint and allow one stable initial checkpoint in this spawn.
				state.checkpoint = nil
				state.version = state.version + 1
				denied(player, state, "CheckpointBlocked")
			end
			if state.checkpoint then return end
			local stableSince, stablePosition
			while valid() and humanoid.Health > 0 and not state.checkpoint and now() < deadline do
				local checkpoint = checkpointAtCharacter(character, humanoid, root)
				if checkpoint and root.AssemblyLinearVelocity.Magnitude <= CONFIG.MaxStableSpeed then
					if not stablePosition or (root.Position - stablePosition).Magnitude > CONFIG.MaxStableDrift then
						stablePosition, stableSince = root.Position, now()
					end
					if now() - stableSince >= CONFIG.StableTime then
						setCheckpoint(player, state, checkpoint)
						return
					end
				else
					stableSince, stablePosition = nil, nil
				end
				task.wait(CONFIG.PollInterval)
			end
			if valid() and humanoid.Health > 0 and not state.checkpoint and now() >= deadline then
				denied(player, state, "Timeout")
			end
		end, debug.traceback)
		if not ok and valid() then
			if state.pending == pending then state.pending = nil end
			denied(player, state, "Interrupted")
			warn("Return By Death character task: " .. tostring(message))
		end
	end)
end

local function addPlayer(player)
	if states[player] then return end
	local state = {
		checkpoint = nil, pending = nil, version = 0, cycle = 0,
		generation = 0, epoch = 0, readyAt = 0, tokens = CONFIG.RequestBurst,
		tokenTime = now(), syncAt = -math.huge,
		connections = {}, characterConnections = {},
	}
	states[player] = state
	connect(player.CharacterAdded, function(character) bindCharacter(player, state, character) end, state.connections)
	connect(player:GetPropertyChangedSignal("Team"), function() invalidate(player, state, "TeamChanged") end, state.connections)
	if player.Character then bindCharacter(player, state, player.Character) end
end

local function onRequest(player, action)
	local state = states[player]
	if not state or type(action) ~= "string" then return end
	local time = now()
	state.tokens = math.min(CONFIG.RequestBurst, state.tokens + (time - state.tokenTime) * CONFIG.RequestsPerSecond)
	state.tokenTime = time
	if state.tokens < 1 then return end
	state.tokens = state.tokens - 1
	if action == "Sync" then
		if time - state.syncAt < CONFIG.SyncInterval then return end
		state.syncAt = time
		stateMessage(player, state)
	elseif action == "Checkpoint" then
		if state.pending then denied(player, state, "Interrupted"); return end
		if time < state.readyAt then denied(player, state, "Cooldown"); return end
		local character, humanoid, root = characterParts(player)
		if not character then denied(player, state, "CharacterUnavailable"); return end
		local checkpoint, reason = checkpointAtCharacter(character, humanoid, root)
		if not checkpoint then denied(player, state, reason); return end
		setCheckpoint(player, state, checkpoint)
	end
end

local ok, message = xpcall(function()
	local name = "ISAGI_ReturnByDeathRemote"
	remote = ReplicatedStorage:FindFirstChild(name)
	if remote and not remote:IsA("RemoteEvent") then error(name .. " must be a RemoteEvent") end
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name, remote.Parent = name, ReplicatedStorage
		ownsRemote = true
	end
	connect(script.Destroying, shutdown)
	connect(workspace.DescendantAdded, rememberHumanoid)
	connect(workspace.DescendantRemoving, function(instance) humanoidModels[instance] = nil end)
	for _, instance in ipairs(workspace:GetDescendants()) do rememberHumanoid(instance) end
	connect(remote.OnServerEvent, function(player, action)
		local success, problem = xpcall(function() onRequest(player, action) end, debug.traceback)
		if not success then
			local state = states[player]
			if state then denied(player, state, "Interrupted") end
			warn("Return By Death request: " .. tostring(problem))
		end
	end)
	connect(Players.PlayerAdded, addPlayer)
	connect(Players.PlayerRemoving, function(player)
		local state = states[player]
		if not state then return end
		state.generation = state.generation + 1
		disconnect(state.connections)
		disconnect(state.characterConnections)
		states[player] = nil
	end)
	connect(workspace:GetAttributeChangedSignal("ReturnByDeathRoundId"), function()
		for player, state in pairs(states) do invalidate(player, state, "RoundChanged") end
	end)
	for _, player in ipairs(Players:GetPlayers()) do addPlayer(player) end
end, debug.traceback)
if not ok then
	shutdown()
	error(message)
end
