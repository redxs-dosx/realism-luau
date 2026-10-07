-- RealismWeapons (LocalScript add-on)
-- Client-side only: "kills" are visual for you. The real player is unaffected.

if _G.RealismWeaponsLoaded then return end
_G.RealismWeaponsLoaded = true

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

-- Settings
local FIRE_RATE = 0.25        -- seconds between shots
local RAGDOLL_TIME = 5        -- seconds before the real player is shown again
local IMPULSE = 60            -- hit force on the ragdoll
local MAX_RANGE = 1000
local STRESS_LOCK_AT = 99.5   -- at this much Realism stress you can only aim at yourself
local SELF_DAMAGE_FRACTION = 1 -- share of max health a self-aimed shot takes (1 = all of it)

-- Folder holding the fake ragdolls
local ragdollFolder = Instance.new("Folder")
ragdollFolder.Name = "RealismRagdolls"
ragdollFolder.Parent = workspace

local active = {} -- characters currently "dead" locally

-- Realism (RealismAPI) reports stress. At max stress the gun will only point at you.
local function stressLocked()
	local api = _G.RealismAPI
	if not (api and api.getStress) then return false end
	local ok, value = pcall(api.getStress)
	if not ok or (tonumber(value) or 0) < STRESS_LOCK_AT then return false end
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	return head ~= nil, head
end

local lastNotice = -100
local function lockNotice()
	if os.clock() - lastNotice < 20 then return end
	lastNotice = os.clock()
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = "Pistol",
			Text = "Your hands won't aim it anywhere but at yourself.",
			Duration = 6,
		})
	end)
end

------------------------------------------------------------
-- Hide / show the real character (local only)
------------------------------------------------------------
local function hideCharacter(char)
	local saved = {}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") then
			table.insert(saved, { d, "Transparency", d.Transparency })
			d.Transparency = 1
		elseif d:IsA("Humanoid") then
			table.insert(saved, { d, "DisplayDistanceType", d.DisplayDistanceType })
			d.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		elseif d:IsA("BillboardGui") then
			table.insert(saved, { d, "Enabled", d.Enabled })
			d.Enabled = false
		end
	end
	return saved
end

local function restore(saved)
	for _, s in ipairs(saved) do
		pcall(function()
			s[1][s[2]] = s[3]
		end)
	end
end

------------------------------------------------------------
-- Build a physics ragdoll clone (joints -> ball sockets)
------------------------------------------------------------
local function buildRagdoll(char)
	local wasArchivable = char.Archivable
	char.Archivable = true
	local clone = char:Clone()
	char.Archivable = wasArchivable
	if not clone then return nil end

	-- Strip scripts and the humanoid so nothing fights the physics
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("LuaSourceContainer") or d:IsA("Humanoid") then
			d:Destroy()
		end
	end

	for _, m in ipairs(clone:GetDescendants()) do
		if m:IsA("Motor6D") and m.Part0 and m.Part1 then
			local a0 = Instance.new("Attachment")
			a0.CFrame = m.C0
			a0.Parent = m.Part0

			local a1 = Instance.new("Attachment")
			a1.CFrame = m.C1
			a1.Parent = m.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = 60
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -35
			socket.TwistUpperAngle = 35
			socket.Parent = m.Part0

			-- stop connected limbs from fighting each other
			local nc = Instance.new("NoCollisionConstraint")
			nc.Part0 = m.Part0
			nc.Part1 = m.Part1
			nc.Parent = m.Part0

			m:Destroy()
		end
	end

	for _, p in ipairs(clone:GetChildren()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			if p.Name == "HumanoidRootPart" then
				p.CanCollide = false
				p.Massless = true
			else
				p.CanCollide = true
			end
		end
	end

	return clone
end

------------------------------------------------------------
-- "Kill" a character locally
------------------------------------------------------------
local function killLocally(char, hitPart, hitPos, direction)
	if active[char] then return end
	active[char] = true

	local root = char:FindFirstChild("HumanoidRootPart")
	local ragdoll = buildRagdoll(char)
	if not ragdoll then
		active[char] = nil
		return
	end

	local saved = hideCharacter(char)
	ragdoll.Parent = ragdollFolder

	-- carry over the victim's momentum, then apply the bullet hit
	if root then
		for _, p in ipairs(ragdoll:GetChildren()) do
			if p:IsA("BasePart") then
				p.AssemblyLinearVelocity = root.AssemblyLinearVelocity
			end
		end
	end

	local target = ragdoll:FindFirstChild(hitPart.Name, true)
	if target and target:IsA("BasePart") then
		target:ApplyImpulseAtPosition(direction.Unit * IMPULSE * target.AssemblyMass, hitPos)
	end

	-- after a few seconds: remove the ragdoll, show them wherever they really are
	task.delay(RAGDOLL_TIME, function()
		ragdoll:Destroy()
		restore(saved)
		active[char] = nil
	end)
end

------------------------------------------------------------
-- The gun
------------------------------------------------------------
local gun

local function buildGun()
	local tool = Instance.new("Tool")
	tool.Name = "Pistol"
	tool.ToolTip = "Client-side pistol"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.3, 0.35, 1.4)
	handle.Color = Color3.fromRGB(35, 35, 40)
	handle.Material = Enum.Material.Metal
	handle.Massless = true
	handle.CanCollide = false
	handle.Parent = tool

	local grip = Instance.new("Part")
	grip.Name = "GripPart"
	grip.Size = Vector3.new(0.3, 0.7, 0.3)
	grip.Color = Color3.fromRGB(60, 40, 25)
	grip.Massless = true
	grip.CanCollide = false
	grip.CFrame = handle.CFrame * CFrame.new(0, -0.5, 0.45)
	grip.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = grip
	weld.Parent = handle

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -0.75)
	muzzle.Parent = handle

	local flash = Instance.new("PointLight")
	flash.Color = Color3.fromRGB(255, 200, 100)
	flash.Range = 10
	flash.Brightness = 0
	flash.Parent = handle

	local lastShot = 0

	tool.Equipped:Connect(function()
		if stressLocked() then lockNotice() end
	end)

	tool.Activated:Connect(function()
		if tick() - lastShot < FIRE_RATE then return end
		lastShot = tick()

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character, ragdollFolder }

		local locked, selfHead = stressLocked()
		local ray = mouse.UnitRay
		local result = nil
		local hitPos
		if locked then
			lockNotice()
			hitPos = selfHead.Position -- stress is maxed: the aim is forced onto you
		else
			result = workspace:Raycast(ray.Origin, ray.Direction * MAX_RANGE, params)
			hitPos = result and result.Position or (ray.Origin + ray.Direction * MAX_RANGE)
		end

		-- tracer
		local from = muzzle.WorldPosition
		local dist = (hitPos - from).Magnitude
		local tracer = Instance.new("Part")
		tracer.Anchored = true
		tracer.CanCollide = false
		tracer.CanQuery = false
		tracer.CanTouch = false
		tracer.Material = Enum.Material.Neon
		tracer.Color = Color3.fromRGB(255, 220, 120)
		tracer.Size = Vector3.new(0.05, 0.05, dist)
		tracer.CFrame = CFrame.lookAt(from, hitPos) * CFrame.new(0, 0, -dist / 2)
		tracer.Parent = workspace
		Debris:AddItem(tracer, 0.06)

		-- muzzle flash
		flash.Brightness = 3
		task.delay(0.05, function() flash.Brightness = 0 end)

		if locked then
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.Health = math.max(0, hum.Health - hum.MaxHealth * SELF_DAMAGE_FRACTION)
			end
			return
		end

		-- hit check
		if result then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			if model
				and model ~= player.Character
				and model:FindFirstChildOfClass("Humanoid") then
				killLocally(model, result.Instance, result.Position, ray.Direction)
			end
		end
	end)

	return tool
end

local function giveGun()
	local backpack = player:WaitForChild("Backpack")
	if gun then gun:Destroy() end
	gun = buildGun()
	gun.Parent = backpack
end

player.CharacterAdded:Connect(function()
	task.wait(0.5)
	giveGun()
end)

giveGun()
