-- HOLLOW PURPLE | 200% EDITION | optional authoritative gameplay companion
-- Install as a Script in ServerScriptService. The client also works without it.
-- No client-supplied positions, damage values, targets, or hit results are trusted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CONFIG = {
	ChargeTime = 3.4, MergeTime = 1.1, MinCharge = 0.3, Cooldown = 6,
	Speed = 200, MaxRange = 360, ProjectileRadius = 6,
	MuzzleHeight = 7, MuzzleForward = 12, MuzzleCorridorRadius = 1.25,
	BlastRadius = 70, PullRadius = 75, PullAcceleration = 120,
	PushSpeed = 220, Damage = 45, PullInterval = 1 / 20,
	ChargeTimeout = 30, RequestBurst = 10, RequestsPerSecond = 4,
}

local remote = ReplicatedStorage:FindFirstChild("ISAGI_PurpleRemote")
if remote and not remote:IsA("RemoteEvent") then
	error("ISAGI_PurpleRemote must be a RemoteEvent")
end
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "ISAGI_PurpleRemote"
	remote.Parent = ReplicatedStorage
end

-- Spherecast does not report parts already overlapping the starting sphere.
-- An exact shape query closes that gap at the muzzle (no approximate AABB test).
local probe = Instance.new("Part")
probe.Name = "ISAGI_Purple_QueryOnly"
probe.Shape = Enum.PartType.Ball
probe.Size = Vector3.one * CONFIG.ProjectileRadius * 2
probe.Anchored = true
probe.CanCollide = false
probe.CanTouch = false
probe.CanQuery = false
probe.CastShadow = false
probe.Transparency = 1
probe.CFrame = CFrame.new(0, -10000, 0)
probe.Parent = workspace

local states = {}
local projectiles = {}
local connections = {}

local function finite(n)
	return typeof(n) == "number" and n == n and math.abs(n) < math.huge
end

local function finiteVector(v)
	return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z)
end

local function validId(id)
	return typeof(id) == "string" and #id >= 1 and #id <= 80
end

local function livingCharacter(player)
	local character = player.Character
	if not character or not character:IsDescendantOf(workspace) then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return character, humanoid, root
	end
end

local function castParams(character)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, probe }
	params.IgnoreWater = true
	return params
end

local function overlapParams(character)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, probe }
	-- Avoid limb/accessory counts arbitrarily cutting off valid nearby targets.
	params.MaxParts = 0
	return params
end

local function humanoidOf(part)
	local ancestor = part.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor:IsA("Model") then
			local humanoid = ancestor:FindFirstChildOfClass("Humanoid")
			if humanoid then return humanoid, ancestor end
		end
		ancestor = ancestor.Parent
	end
end

local function lineOfSight(projectile, origin, target, model, assembly)
	local delta = target - origin
	if delta.Magnitude < 0.05 then return true end
	local hit = workspace:Raycast(origin, delta, projectile.rayParams)
	if not hit then return true end
	if model and hit.Instance:IsDescendantOf(model) then return true end
	return hit.Instance:IsA("BasePart") and hit.Instance.AssemblyRootPart == assembly
end

local function impulse(assembly, velocityChange)
	if not assembly.Parent or assembly.Anchored then return end
	local mass = assembly.AssemblyMass
	if finite(mass) and mass > 0 and mass < 1000000 then
		assembly:ApplyImpulse(velocityChange * mass)
	end
end

local function eligibleAssembly(part, humanoid)
	local assembly = part.AssemblyRootPart
	if not assembly or assembly.Anchored then return end
	if humanoid and humanoid.Health > 0 then return assembly end
	if part:GetAttribute("PurplePhysics") == true
		or assembly:GetAttribute("PurplePhysics") == true then
		return assembly
	end
end

local function pull(projectile, dt)
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(
		projectile.position, CONFIG.PullRadius, projectile.overlapParams
	)) do
		local humanoid, model = humanoidOf(part)
		local assembly = eligibleAssembly(part, humanoid)
		if assembly and not seen[assembly] then
			seen[assembly] = true
			local delta = projectile.position - assembly.Position
			local distance = delta.Magnitude
			if distance > 0.5 and distance <= CONFIG.PullRadius
				and lineOfSight(projectile, projectile.position, assembly.Position, model, assembly) then
				local falloff = 1 - distance / CONFIG.PullRadius
				impulse(assembly, delta.Unit * CONFIG.PullAcceleration * falloff * dt)
			end
		end
	end
end

local function finish(projectile, position, normal, applyGameplay)
	if projectile.finished then return end
	projectile.finished = true
	projectiles[projectile] = nil
	local state = states[projectile.player]
	if state and state.active == projectile then state.active = nil end
	remote:FireAllClients("Impact", projectile.player.UserId, projectile.id,
		position, normal, projectile.power)
	if not applyGameplay then return end

	-- Keep the LOS origin outside the struck surface, never inside the wall.
	local sightOrigin = position + normal * 0.15
	local hitHumanoids, pushed = {}, {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(
		position, CONFIG.BlastRadius, projectile.overlapParams
	)) do
		local humanoid, model = humanoidOf(part)
		local assembly = eligibleAssembly(part, humanoid)
		if humanoid and humanoid.Health > 0 and not hitHumanoids[humanoid] then
			local targetRoot = model:FindFirstChild("HumanoidRootPart") or part
			local distance = (targetRoot.Position - position).Magnitude
			if distance <= CONFIG.BlastRadius and lineOfSight(
				projectile, sightOrigin, targetRoot.Position, model, targetRoot.AssemblyRootPart
			) then
				hitHumanoids[humanoid] = true
				humanoid:TakeDamage(CONFIG.Damage)
			end
		end
		if assembly and not pushed[assembly] then
			pushed[assembly] = true
			local delta = assembly.Position - position
			local distance = delta.Magnitude
			if distance <= CONFIG.BlastRadius and lineOfSight(
				projectile, sightOrigin, assembly.Position, model, assembly
			) then
				local direction = distance > 0.1 and delta.Unit or Vector3.yAxis
				local falloff = 0.3 + 0.7 * (1 - distance / CONFIG.BlastRadius)
				impulse(assembly, (direction + Vector3.yAxis * 0.35) * CONFIG.PushSpeed * falloff)
			end
		end
	end
end

local function cancelState(player)
	local state = states[player]
	if not state then return end
	state.began = nil
	state.character = nil
	if state.active then
		finish(state.active, state.active.position, -state.active.direction, false)
	end
end

local function addPlayer(player)
	if states[player] then return end
	local state = {
		lastCast = -math.huge, tokens = CONFIG.RequestBurst,
		refillAt = os.clock(), lastReject = -math.huge,
	}
	states[player] = state
	state.characterRemoving = player.CharacterRemoving:Connect(function()
		cancelState(player)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do addPlayer(player) end
connections[#connections + 1] = Players.PlayerAdded:Connect(addPlayer)
connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
	cancelState(player)
	local state = states[player]
	if state and state.characterRemoving then state.characterRemoving:Disconnect() end
	states[player] = nil
end)

local function reject(player, state, id, now)
	if validId(id) and now - state.lastReject >= 0.15 then
		state.lastReject = now
		remote:FireClient(player, "Rejected", id)
	end
end

connections[#connections + 1] = remote.OnServerEvent:Connect(function(player, action, direction, id)
	local state = states[player]
	if not state then return end
	local now = os.clock()
	state.tokens = math.min(CONFIG.RequestBurst,
		state.tokens + (now - state.refillAt) * CONFIG.RequestsPerSecond)
	state.refillAt = now
	if state.tokens < 1 then
		if action == "Fire" then reject(player, state, id, now) end
		return
	end
	state.tokens = state.tokens - 1

	if action == "Cancel" then
		state.began, state.character = nil, nil
		return
	elseif action == "Begin" then
		local character = livingCharacter(player)
		if character and not state.active and now - state.lastCast >= CONFIG.Cooldown then
			-- Repeated Begin packets cannot reset a valid charge.
			if not state.began or now - state.began > CONFIG.ChargeTimeout then
				state.began, state.character = now, character
			end
		end
		return
	elseif action ~= "Fire" then
		return
	end

	local began, chargeCharacter = state.began, state.character
	state.began, state.character = nil, nil
	local character, _, root = livingCharacter(player)
	local elapsed = began and now - began or 0
	if not validId(id) or not finiteVector(direction)
		or direction.Magnitude < 0.1 or direction.Magnitude > 100
		or not character or chargeCharacter ~= character or state.active
		or not began or elapsed < CONFIG.MinCharge + CONFIG.MergeTime - 0.03
		or elapsed > CONFIG.ChargeTimeout or now - state.lastCast < CONFIG.Cooldown then
		reject(player, state, id, now)
		return
	end
	direction = direction.Unit
	if not finiteVector(root.Position) then
		reject(player, state, id, now)
		return
	end
	local chest = root.Position + Vector3.new(0, 1.5, 0)
	local forward = CONFIG.MuzzleForward
	if direction.Y < 0 then
		-- Match the client: shorten steep downward shots along their aim ray.
		local clearance = math.max(0, CONFIG.MuzzleHeight - CONFIG.ProjectileRadius - 0.5)
		forward = math.min(forward, clearance / -direction.Y)
	end
	local origin = root.Position + Vector3.new(0, CONFIG.MuzzleHeight, 0)
		+ direction * forward
	local muzzlePath = origin - chest
	local rayParams, overlaps = castParams(character), overlapParams(character)
	-- The small corridor starts at the chest without intersecting the floor.
	-- The full six-stud projectile sphere is checked only at its raised muzzle.
	local blocked = workspace:Raycast(chest, muzzlePath, rayParams)
		or workspace:Spherecast(chest, CONFIG.MuzzleCorridorRadius, muzzlePath, rayParams)
	probe.Position = origin
	local touching = workspace:GetPartsInPart(probe, overlaps)
	probe.Position = Vector3.new(0, -10000, 0)
	if blocked or #touching > 0 then
		reject(player, state, id, now)
		return
	end

	local projectile = {
		player = player, character = character, id = id, position = origin,
		direction = direction, power = math.clamp((elapsed - CONFIG.MergeTime) / CONFIG.ChargeTime, 0.15, 1),
		distance = 0, pullElapsed = 0, rayParams = rayParams, overlapParams = overlaps,
	}
	state.lastCast, state.active = now, projectile
	projectiles[projectile] = true
	remote:FireAllClients("Launch", player.UserId, id, origin, direction, projectile.power)
end)

connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
	for player, state in pairs(states) do
		if state.began then
			local character = livingCharacter(player)
			if character ~= state.character or os.clock() - state.began > CONFIG.ChargeTimeout then
				state.began, state.character = nil, nil
			end
		end
	end
	for projectile in pairs(projectiles) do
		local character = livingCharacter(projectile.player)
		if character ~= projectile.character then
			finish(projectile, projectile.position, -projectile.direction, false)
		else
			local step = math.min(CONFIG.Speed * dt, CONFIG.MaxRange - projectile.distance)
			local hit = workspace:Spherecast(projectile.position, CONFIG.ProjectileRadius,
				projectile.direction * step, projectile.rayParams)
			if hit then
				finish(projectile, hit.Position, hit.Normal, true)
			else
				projectile.position = projectile.position + projectile.direction * step
				projectile.distance = projectile.distance + step
				projectile.pullElapsed = projectile.pullElapsed + dt
				if projectile.distance >= CONFIG.MaxRange then
					finish(projectile, projectile.position, -projectile.direction, true)
				elseif projectile.pullElapsed >= CONFIG.PullInterval then
					pull(projectile, math.min(projectile.pullElapsed, 0.1))
					projectile.pullElapsed = 0
				end
			end
		end
	end
end)

script.Destroying:Connect(function()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	for player, state in pairs(states) do
		cancelState(player)
		state.characterRemoving:Disconnect()
	end
	probe:Destroy()
end)
