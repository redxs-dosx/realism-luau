-- Realism LocalScript (single-file, client-only)
-- Executor-friendly: progress and errors also appear as on-screen notifications,
-- so you don't need to find the console.

local __toasts = 0
local function __toast(text)
	text = "[Realism] " .. tostring(text)
	print(text)
	if __toasts >= 8 then return end
	__toasts = __toasts + 1
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", {
					Title = "Realism",
					Text = string.sub(text, 1, 230),
					Duration = 12,
				})
			end)
			if ok then return end
			task.wait(0.5)
		end
	end)
end

__toast("script started")

local __ok, __err = xpcall(function()


-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local BIND_NAME = "RealismBodyAndCameraUpdate"

--------------------------------------------------------------------------------
-- RE-RUN SAFETY: clean up any previous run, and register cleanup for this one
--------------------------------------------------------------------------------
if _G.RealismCleanup then
	pcall(_G.RealismCleanup)
end

local connections = {}      -- every connection made by this script
local charConnections = {}  -- per-character connections
local createdInstances = {} -- everything we create, destroyed on cleanup

local function track(conn)
	table.insert(connections, conn)
	return conn
end

local function trackInstance(inst)
	table.insert(createdInstances, inst)
	return inst
end

-- Error reporting: a failure in one system is printed once to the Output window
-- (View > Output in Studio, or F9 in game) instead of silently breaking everything else.
local reportedErrors = {}
local function reportError(where, err)
	local key = where .. "|" .. tostring(err)
	if not reportedErrors[key] then
		reportedErrors[key] = true
		warn("[Realism] error in " .. where .. ": " .. tostring(err))
		__toast("error in " .. where .. ": " .. string.match(tostring(err), "^[^\n]*"))
	end
end

local function safeCall(where, fn, ...)
	local ok, result = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
	if not ok then reportError(where, result) end
	return ok, result
end

local lightingBackup = {
	Brightness = Lighting.Brightness,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	ExposureCompensation = Lighting.ExposureCompensation,
	GlobalShadows = Lighting.GlobalShadows,
	ShadowSoftness = Lighting.ShadowSoftness,
	EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
	EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
	ClockTime = Lighting.ClockTime,
	ColorShift_Top = Lighting.ColorShift_Top,
}
local atmosphereBackup = nil -- filled only if the game already had an Atmosphere

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
	-- Speeds
	WALK_SPEED = 10,
	ADRENALINE_SPEED = 15,

	-- FOV Settings
	NORMAL_FOV = 70,
	ADRENALINE_FOV = 80,

	-- Head Bobbing & Camera Sway Settings
	BOB_FREQUENCY = 10,
	BOB_AMPLITUDE_Y = 0.18,
	BOB_AMPLITUDE_X = 0.12,
	SWAY_TILT_ANGLE = 3.0,
	CAMERA_FORWARD_OFFSET = 0.6,

	-- Stamina & Sprint System
	MAX_STAMINA = 100,
	STAMINA_DRAIN_RATE = 20,
	STAMINA_REGEN_RATE = 15,        -- stamina/sec recovered while standing still
	STAMINA_REGEN_WALK = 1,         -- stamina/sec recovered while walking (very slow)
	SPRINT_RESUME_THRESHOLD = 20,
	ADRENALINE_STAMINA_DRAIN_MULT = 0,

	-- Leg Strength
	MAX_RUN_SPEED = 36,
	STRENGTH_GAIN_RUN = 0.03,
	STRENGTH_GAIN_WALK = 0.006,

	-- Fall Damage (NOTE: a LocalScript can't replicate damage to the server,
	-- so this affects the local health display/effects only in most games)
	FALL_DAMAGE_MIN_SPEED = 70,
	FALL_DAMAGE_LETHAL_SPEED = 150,

	-- Injury Effects
	INJURY_TINT_MAX = 0.65,
	INJURY_VIGNETTE_MAX = 0.8,
	INJURY_VIGNETTE_COLOR = Color3.fromRGB(160, 0, 0),

	-- Adrenaline System
	THREAT_RADIUS = 40,
	THREAT_REQUIRE_ON_SCREEN = true,
	THREAT_CHECK_INTERVAL = 0.15, -- seconds between threat scans (saves raycasts)
	-- Tools that do NOT count as weapons (add flashlights, build tools, etc.)
	THREAT_IGNORE_TOOLS = {
		["Water Bottle"] = true,
		["Food Bar"] = true,
	},
	INVISIBLE_TRANSPARENCY = 0.95, -- parts at/above this don't block line of sight
	ADRENALINE_DECAY = 8.33,

	-- Hunger & Thirst
	HUNGER_DECAY = 0.5,
	THIRST_DECAY = 0.8,
	-- Damage taken (health per second) while a bar is empty
	STARVE_DAMAGE_SINGLE = 0.5,    -- hunger OR thirst is empty (slow)
	STARVE_DAMAGE_BOTH = 1.5,      -- hunger AND thirst are empty

	-- Gear
	WATER_REFILL_AMOUNT = 35,
	FOOD_REFILL_AMOUNT = 35,
	GEAR_COOLDOWN = 1.2,

	-- Motion Blur (normalized to a 60 FPS frame so it's FPS-independent)
	MOTION_BLUR_INTENSITY = 35,
	MAX_BLUR = 20,

	-- Day / Night Cycle
	ENABLE_DAY_NIGHT = true,
	DAY_NIGHT_SPEED = 0.03,

	-- Sun Glare
	SUN_GLARE_COS_START = 0.88,
	SUN_GLARE_RISE = 6,
	SUN_GLARE_FALL = 1.2,
	SUN_RAYS_MAX = 0.55,
	SUN_BLOOM_MAX = 1.6,
	SUN_EXPOSURE_MAX = 1.5,

	-- Body & Eye Realism
	BREATH_AMPLITUDE = 0.025,
	LANDING_MIN_SPEED = 25,
	LANDING_STIFFNESS = 120,
	LANDING_DAMPING = 12,
	DOF_FOCUS_SPEED = 4,
	NEEDS_PENALTY_THRESHOLD = 25,

	-- Audio (all local to your client)
	FOOTSTEP_DEFAULT_ID = "rbxasset://sounds/action_footsteps_plastic.mp3",
	-- The default file above contains SEVERAL steps in one clip. Each step plays only
	-- the first slice of it (file length / FOOTSTEP_STEPS_IN_FILE) so you hear one step.
	-- Still doubled? Raise FOOTSTEP_STEPS_IN_FILE (try 4). Cut short or silent? Lower it.
	-- Use FOOTSTEP_STEPS_IN_FILE = 1 if you swap in a single-step sound ID.
	-- FOOTSTEP_CLIP_LENGTH (seconds) overrides the automatic slice when above 0.
	FOOTSTEP_STEPS_IN_FILE = 3,
	FOOTSTEP_CLIP_START = 0,
	FOOTSTEP_CLIP_LENGTH = 0,
	-- Optional per-material overrides, e.g. [Enum.Material.Grass] = "rbxassetid://123",
	MATERIAL_SOUNDS = {},
	MUTE_DEFAULT_FOOTSTEPS = true, -- silences Roblox's own footstep sound so they don't double up
	STEP_RATE_WALK = 2.0,          -- footsteps per second when walking
	STEP_RATE_RUN_MIN = 3.4,       -- footsteps per second when you start running
	STEP_RATE_RUN_MAX = 5.0,       -- footsteps per second at top speed
	-- Looped sounds: the first ID in each list that actually loads is used.
	-- Roblox only plays audio your game/account is allowed to use, so paste working
	-- rbxassetid:// IDs at the FRONT of these lists.
	BREATH_SOUND_IDS = {
		"rbxassetid://180315285",
		"rbxassetid://199696655",
		"rbxassetid://5765036319",
		"rbxassetid://5764962071",
		"rbxassetid://1212068412",
	},
	HEARTBEAT_SOUND_IDS = {
		-- "rbxassetid://YOUR_HEARTBEAT_LOOP_ID",
	},
	-- Used when no heartbeat loop above loads: a built-in thump played on every beat
	HEARTBEAT_FALLBACK_ID = "rbxasset://sounds/bass.wav",
	RING_SOUND_IDS = {
		-- "rbxassetid://YOUR_EAR_RINGING_LOOP_ID",
		"rbxasset://sounds/electronicpingshort.wav", -- built-in placeholder; put a real tinnitus loop above it
	},
	DEBUG_KEYS = true,             -- G = pass out right now, H = empty hunger + thirst (for testing)
	BREATH_MAX_VOLUME = 0.8,
	HEARTBEAT_MAX_VOLUME = 0.9,
	RING_MAX_VOLUME = 0.7,
	BREATH_STAMINA_START = 60,     -- breathing gets louder as stamina drops below this
	DEPLETED_STAMINA_START = 25,   -- heartbeat + ear ringing build up below this stamina
	HEARTBEAT_PULSE = 0.8,         -- camera thump per heartbeat (works even without a sound ID)

	-- Stamina Effects (dark tunnel vision, blur, heavier bob when winded)
	TIRED_STAMINA_START = 40,      -- effects start below this stamina
	STAMINA_VIGNETTE_MAX = 0.6,
	STAMINA_BLUR_MAX = 4,

	-- Mantling (jump at a ledge to pull yourself up)
	ENABLE_MANTLE = true,
	MANTLE_MAX_HEIGHT = 6,         -- studs above your feet you can grab
	MANTLE_REACH = 3,              -- how far ahead to look for a wall
	MANTLE_DURATION = 0.45,
	MANTLE_STAMINA_COST = 15,
	MANTLE_COOLDOWN = 0.6,

	-- Hand Sway (held tools lag behind camera turns and bob while moving)
	HAND_SWAY_AMOUNT = 0.012,      -- studs of lag per radian/sec of camera turn
	HAND_SWAY_MAX = 0.35,
	HAND_SWAY_SPEED = 8,           -- how quickly the tool catches up
	HAND_BOB_AMOUNT = 0.05,

	-- Ragdoll
	RAGDOLL_JOINT_FRICTION = 1.5,  -- higher = stiffer, less floppy limbs
	RAGDOLL_TOPPLE_SPEED = 2.5,    -- how hard you tip forward when you pass out

	-- Passing Out (walking while exhausted, with no rest)
	FAINT_MIN_TIME = 5,            -- random 5-10s of walking while exhausted triggers it
	FAINT_MAX_TIME = 10,
	FAINT_FADE_OUT = 2.5,          -- slow fade to black as you collapse
	FAINT_HOLD_MIN = 3,            -- time spent out cold (random between min/max)
	FAINT_HOLD_MAX = 5,
	FAINT_FADE_IN = 0.6,           -- quick fade back in after standing up
	FAINT_RECOVER_STAMINA = 40,    -- stamina you wake up with
	RESPAWN_FADE_IN = 0.8,         -- fade in after dying and respawning

	-- Night / Moonlight (sun is 2.5 at noon, moon stays well below that)
	SUN_BRIGHTNESS = 2.5,
	MOON_BRIGHTNESS = 1.0,
	MOON_AMBIENT = Color3.fromRGB(60, 70, 105),
	MOON_TINT = Color3.fromRGB(110, 130, 190),
	MOON_EXPOSURE = 0.3,

	-- Injury Limp
	LIMP_HEALTH_THRESHOLD = 0.3,   -- limp starts below this health fraction
	LIMP_MAX_SLOWDOWN = 0.35,      -- up to 35% slower at near-zero health
	LIMP_SWAY = 0.12,              -- extra side-to-side sway while limping

	-- Colors
	HEALTH_COLOR = Color3.fromRGB(235, 75, 75),
	HUNGER_COLOR = Color3.fromRGB(235, 160, 60),
	THIRST_COLOR = Color3.fromRGB(60, 160, 235),
	SPRINT_COLOR = Color3.fromRGB(80, 220, 120),
	STRENGTH_COLOR = Color3.fromRGB(170, 110, 235),
	ADRENALINE_COLOR = Color3.fromRGB(240, 220, 70),
}

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------
local adrenaline = 0
local stamina = CONFIG.MAX_STAMINA
local exhausted = false
local legStrength = 0
local injuryVisual = 0
local shiftPressed = false
local mobileSprinting = false
local hunger = 100
local thirst = 100
local lastHealth = nil        -- set from the real humanoid on first frame
local lastHumanoid = nil
local lastLookVector = Camera and Camera.CFrame.LookVector or Vector3.new(0, 0, -1)

local bobIndex = 0
local currentRoll = 0

local sunGlare = 0
local landingOffset = 0
local landingVelocity = 0
local focusDistance = 50
local peakFallSpeed = 0
local wasAirborne = false

local threatTimer = 0
local threatCached = false

local bodyParts = {} -- [BasePart] = shouldBeHidden

local limpFactor = 0 -- 0..1, how hard you're limping
local staminaVisual = 0 -- smoothed 0..1 tiredness used for screen effects

local blackAlpha, blackTarget, blackRate = 0, 0, 1 -- full-screen black overlay
local faint = nil            -- passing-out state table, nil when awake
local faintTimer = 0         -- seconds walked while exhausted
local faintThreshold = nil   -- random seconds before you pass out
local deadHandled = false
local footstepPool, footstepIndex = {}, 0
local breathSound, heartSound, ringSound, thumpSound = nil, nil, nil, nil
local stepTimer, stepRate = 0, 2
local defaultRunning, defaultRunningVolume = nil, nil
local heartPhase, heartDubDone = 0, true
local soundGen = 0

local ragdollData = nil      -- declared up here so the render-step closure can see it
local ragdollCamCF = nil

--------------------------------------------------------------------------------
-- RAYCAST HELPER (skips invisible parts so they don't block sight/sun)
--------------------------------------------------------------------------------
local sharedRayParams = RaycastParams.new()
sharedRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function firstSolidHit(origin, direction, ignoreCharacter)
	local filter = { ignoreCharacter }
	for _ = 1, 8 do
		sharedRayParams.FilterDescendantsInstances = filter
		local result = Workspace:Raycast(origin, direction, sharedRayParams)
		if not result then return nil end
		if result.Instance.Transparency < CONFIG.INVISIBLE_TRANSPARENCY then
			return result
		end
		table.insert(filter, result.Instance)
	end
	return nil
end

--------------------------------------------------------------------------------
-- SPRINT INPUT (KEYBOARD)
--------------------------------------------------------------------------------
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		shiftPressed = true
	end
end))

track(UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		shiftPressed = false
	end
end))

--------------------------------------------------------------------------------
-- 1. FIRST-PERSON LOCK, BODY VISIBILITY & HEAD BOBBING
--------------------------------------------------------------------------------
local gripBase = setmetatable({}, { __mode = "k" }) -- original RightGrip.C0 per grip
local swayX, swayY = 0, 0
local lastCamCF = nil

local function updateHandSway(deltaTime, character, moveSpeed, walkSpeed)
	local dt = math.max(deltaTime, 1 / 240)
	local camCF = Camera.CFrame

	-- How fast the camera is turning (radians/sec)
	local yawRate, pitchRate = 0, 0
	if lastCamCF then
		local rx, ry = lastCamCF:ToObjectSpace(camCF):ToEulerAnglesYXZ()
		yawRate = ry / dt
		pitchRate = rx / dt
	end
	lastCamCF = camCF

	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local tool = character:FindFirstChildOfClass("Tool")
	local grip = hand and tool and hand:FindFirstChild("RightGrip")
	if not grip or not grip:IsA("JointInstance") then
		swayX, swayY = 0, 0
		return
	end

	-- Lag opposite to the turn, plus a walking bob
	local maxSway = CONFIG.HAND_SWAY_MAX
	local targetX = math.clamp(yawRate * CONFIG.HAND_SWAY_AMOUNT, -maxSway, maxSway)
	local targetY = math.clamp(-pitchRate * CONFIG.HAND_SWAY_AMOUNT, -maxSway, maxSway)

	local speedFactor = math.clamp(moveSpeed / math.max(walkSpeed, 1), 0, 1.2)
	targetX = targetX + math.cos(bobIndex) * CONFIG.HAND_BOB_AMOUNT * speedFactor
	targetY = targetY - math.sin(bobIndex * 2) * CONFIG.HAND_BOB_AMOUNT * speedFactor

	local follow = math.clamp(dt * CONFIG.HAND_SWAY_SPEED, 0, 1)
	swayX = swayX + (targetX - swayX) * follow
	swayY = swayY + (targetY - swayY) * follow

	-- Camera-space offset -> hand-space offset applied to the grip weld
	local base = gripBase[grip]
	if not base then
		base = grip.C0
		gripBase[grip] = base
	end
	local worldOffset = camCF:VectorToWorldSpace(Vector3.new(swayX, swayY, 0))
	local handOffset = hand.CFrame:VectorToObjectSpace(worldOffset)
	grip.C0 = CFrame.new(handOffset) * base
end

local function classifyPart(part)
	if part:IsA("BasePart") then
		bodyParts[part] = (part.Name == "Head" or part:FindFirstAncestorOfClass("Accessory") ~= nil)
	end
end

local function setupFirstPersonAndBobbing(character)
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)

	-- Cache body parts once instead of scanning descendants every frame
	for _, c in ipairs(charConnections) do c:Disconnect() end
	table.clear(charConnections)
	table.clear(bodyParts)
	for _, d in ipairs(character:GetDescendants()) do classifyPart(d) end
	table.insert(charConnections, character.DescendantAdded:Connect(classifyPart))
	table.insert(charConnections, character.DescendantRemoving:Connect(function(d)
		bodyParts[d] = nil
	end))

	local function renderUpdate(deltaTime)
		Camera = Workspace.CurrentCamera
		if not Camera then return end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart")

		if humanoid and hrp then
			if ragdollData then
				-- Ragdolled: the camera rides on the limp head, so you see the fall
				humanoid.CameraOffset = Vector3.zero
				local head = character:FindFirstChild("Head")
				if head then
					local target = head.CFrame * CFrame.new(0, 0.1, -0.5)
					ragdollCamCF = ragdollCamCF or Camera.CFrame
					ragdollCamCF = ragdollCamCF:Lerp(target, math.clamp(deltaTime * 15, 0, 1))
					Camera.CFrame = ragdollCamCF
				end
			else
				ragdollCamCF = nil

				-- B. Head bobbing & strafe sway
				local velocity = hrp.AssemblyLinearVelocity
				local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
				local moveSpeed = flatVelocity.Magnitude

				local bobX, bobY = 0, 0
				if moveSpeed > 1 and humanoid.FloorMaterial ~= Enum.Material.Air then
					local speedRatio = math.clamp(humanoid.WalkSpeed / CONFIG.WALK_SPEED, 0.5, 2)
					bobIndex = bobIndex + (deltaTime * CONFIG.BOB_FREQUENCY * speedRatio)

					local speedFactor = math.clamp(moveSpeed / math.max(humanoid.WalkSpeed, 1), 0, 1.2)
					bobX = math.cos(bobIndex) * CONFIG.BOB_AMPLITUDE_X * speedFactor
					bobY = math.sin(bobIndex * 2) * CONFIG.BOB_AMPLITUDE_Y * speedFactor
				else
					local excitement = adrenaline / 100
					bobIndex = bobIndex + (deltaTime * (2 + excitement * 3))
					bobY = math.sin(bobIndex) * CONFIG.BREATH_AMPLITUDE * (1 + excitement * 2)
				end

				-- Winded: heavier vertical bob
				bobY = bobY * (1 + staminaVisual * 0.5)

				-- Landing impact spring
				local dt = math.min(deltaTime, 0.05)
				local accel = -CONFIG.LANDING_STIFFNESS * landingOffset - CONFIG.LANDING_DAMPING * landingVelocity
				landingVelocity = landingVelocity + accel * dt
				landingOffset = landingOffset + landingVelocity * dt

				bobX = bobX + math.sin(bobIndex) * CONFIG.LIMP_SWAY * limpFactor
				humanoid.CameraOffset = Vector3.new(bobX, bobY + landingOffset, -CONFIG.CAMERA_FORWARD_OFFSET)

				-- Strafe tilt
				local relativeVel = hrp.CFrame:VectorToObjectSpace(flatVelocity)
				local strafeSpeed = relativeVel.X
				local targetRoll = math.rad(-strafeSpeed / math.max(humanoid.WalkSpeed, 1) * CONFIG.SWAY_TILT_ANGLE)

				currentRoll = currentRoll + (targetRoll - currentRoll) * math.clamp(deltaTime * 10, 0, 1)
				updateHandSway(deltaTime, character, moveSpeed, humanoid.WalkSpeed)

				Camera.CFrame = Camera.CFrame * CFrame.Angles(0, 0, currentRoll)
			end
		end
	end

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value, function(deltaTime)
		if not character or not character.Parent then return end

		-- A. Body visibility (hide head + accessories only). Runs first and on its own,
		-- so a bug in the camera code below can never make your body disappear.
		for part, hidden in pairs(bodyParts) do
			part.LocalTransparencyModifier = hidden and 1 or 0
		end

		safeCall("camera", renderUpdate, deltaTime)
	end)
end

--------------------------------------------------------------------------------
-- 2. CLIENT-SIDED GEAR CREATION (WATER BOTTLE & FOOD BAR)
--------------------------------------------------------------------------------
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- stands a cylinder (axis X) up along Y

-- Adds a decorative part welded to the tool's handle (offset is relative to the handle)
local function buildVisual(tool, handle, name, shape, size, offset, color, material, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CFrame = handle.CFrame * offset

	local weld = Instance.new("Weld")
	weld.Part0 = handle
	weld.Part1 = p
	weld.C0 = offset
	weld.C1 = CFrame.new()
	weld.Parent = p

	p.Parent = tool
	return p
end

-- One bad decoration part never breaks the whole tool
local function addVisual(...)
	local ok, result = pcall(buildVisual, ...)
	if not ok then
		reportError("gear part", result)
		return nil
	end
	return result
end

local function cyl(tool, handle, name, y, length, diameter, color, material, transparency)
	return addVisual(tool, handle, name, Enum.PartType.Cylinder,
		Vector3.new(length, diameter, diameter), CFrame.new(0, y, 0) * UPRIGHT,
		color, material, transparency)
end

local function buildWaterBottle()
	local tool = Instance.new("Tool")
	tool.Name = "Water Bottle"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Drink to restore thirst"

	-- Invisible grip block; all the visible bottle parts are welded to it
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 1.4, 0.5)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local plastic = Color3.fromRGB(205, 232, 250)
	local blue = Color3.fromRGB(30, 110, 205)

	-- Clear plastic body with a rounded shoulder
	cyl(tool, handle, "Body", -0.1, 1.3, 0.7, plastic, Enum.Material.SmoothPlastic, 0.55)
	addVisual(tool, handle, "Shoulder", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7),
		CFrame.new(0, 0.55, 0), plastic, Enum.Material.SmoothPlastic, 0.55)

	-- Water inside
	cyl(tool, handle, "Water", -0.18, 1.15, 0.6, Color3.fromRGB(70, 150, 235), Enum.Material.SmoothPlastic, 0.25)

	-- Paper label with a blue stripe
	cyl(tool, handle, "Label", -0.1, 0.5, 0.73, Color3.fromRGB(240, 244, 248), Enum.Material.SmoothPlastic, 0)
	cyl(tool, handle, "LabelStripe", -0.1, 0.12, 0.745, blue, Enum.Material.SmoothPlastic, 0)

	-- Neck, ring and screw cap
	cyl(tool, handle, "Neck", 0.95, 0.25, 0.34, plastic, Enum.Material.SmoothPlastic, 0.4)
	cyl(tool, handle, "NeckRing", 0.88, 0.06, 0.44, plastic, Enum.Material.SmoothPlastic, 0.2)
	cyl(tool, handle, "Cap", 1.15, 0.22, 0.42, blue, Enum.Material.SmoothPlastic, 0)

	return tool
end

local function buildFoodBar()
	local tool = Instance.new("Tool")
	tool.Name = "Food Bar"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Eat to restore hunger"

	-- Handle = the foil wrapper
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.7, 0.22, 1.7)
	handle.Color = Color3.fromRGB(200, 55, 45)
	handle.Material = Enum.Material.Foil
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	-- Yellow label band with the name printed on it
	local band = addVisual(tool, handle, "LabelBand", Enum.PartType.Block, Vector3.new(0.72, 0.24, 0.9),
		CFrame.new(0, 0, 0.15), Color3.fromRGB(245, 205, 60), Enum.Material.SmoothPlastic, 0)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 200
	gui.Parent = band or handle

	local text = Instance.new("TextLabel")
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromOffset(180, 144) -- rotated so the text runs along the bar
	text.Rotation = 90
	text.BackgroundTransparency = 1
	text.Text = "FOOD BAR"
	text.TextScaled = true
	text.Font = Enum.Font.GothamBlack
	text.TextColor3 = Color3.fromRGB(120, 25, 20)
	text.Parent = gui

	-- Crimped end of the wrapper
	addVisual(tool, handle, "Crimp", Enum.PartType.Block, Vector3.new(0.7, 0.05, 0.16),
		CFrame.new(0, 0, 0.93), Color3.fromRGB(160, 40, 32), Enum.Material.Foil, 0)
	for i = 1, 3 do
		addVisual(tool, handle, "CrimpRidge" .. i, Enum.PartType.Block, Vector3.new(0.7, 0.07, 0.015),
			CFrame.new(0, 0, 0.88 + i * 0.04), Color3.fromRGB(135, 32, 26), Enum.Material.Foil, 0)
	end

	-- Torn-open end showing the bar: oat base with a chocolate coat and nut bits
	addVisual(tool, handle, "BarBase", Enum.PartType.Block, Vector3.new(0.55, 0.09, 0.55),
		CFrame.new(0, -0.04, -1.1), Color3.fromRGB(205, 160, 90), Enum.Material.Sand, 0)
	addVisual(tool, handle, "BarChocolate", Enum.PartType.Block, Vector3.new(0.55, 0.08, 0.55),
		CFrame.new(0, 0.045, -1.1), Color3.fromRGB(88, 52, 30), Enum.Material.SmoothPlastic, 0)
	local nuts = {
		Vector3.new(-0.15, 0.09, -0.95),
		Vector3.new(0.12, 0.09, -1.15),
		Vector3.new(-0.05, 0.09, -1.28),
	}
	for i, pos in ipairs(nuts) do
		addVisual(tool, handle, "Nut" .. i, Enum.PartType.Ball, Vector3.new(0.12, 0.12, 0.12),
			CFrame.new(pos), Color3.fromRGB(160, 110, 60), Enum.Material.Sand, 0)
	end

	return tool
end

-- Plain fallback tool so you always get your gear even if the detailed model fails
local function simpleTool(name, tip, color)
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = tip

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 1.2, 0.6)
	handle.Color = color
	handle.Material = Enum.Material.SmoothPlastic
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	return tool
end

local function safeBuild(builder, name, tip, color)
	local ok, tool = xpcall(builder, function(e) return debug.traceback(tostring(e), 2) end)
	if ok and tool then return tool end
	reportError("building " .. name, tool)
	return simpleTool(name, tip, color)
end

local function createClientGears()
	task.wait(0.25) -- let the new Backpack exist after a respawn
	local backpack = LocalPlayer:WaitForChild("Backpack")

	-- Some games hide the hotbar; without it you can't equip anything
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
	end)

	for _, folder in ipairs({ backpack, LocalPlayer.Character }) do
		if folder then
			for _, item in ipairs(folder:GetChildren()) do
				if item.Name == "Water Bottle" or item.Name == "Food Bar" then
					item:Destroy()
				end
			end
		end
	end

	local waterTool = safeBuild(buildWaterBottle, "Water Bottle", "Drink to restore thirst", Color3.fromRGB(60, 160, 235))
	local lastWaterUse = 0
	waterTool.Activated:Connect(function()
		if os.clock() - lastWaterUse < CONFIG.GEAR_COOLDOWN then return end
		lastWaterUse = os.clock()
		thirst = math.clamp(thirst + CONFIG.WATER_REFILL_AMOUNT, 0, 100)
	end)
	waterTool.Parent = backpack

	local foodTool = safeBuild(buildFoodBar, "Food Bar", "Eat to restore hunger", Color3.fromRGB(235, 160, 60))
	local lastFoodUse = 0
	foodTool.Activated:Connect(function()
		if os.clock() - lastFoodUse < CONFIG.GEAR_COOLDOWN then return end
		lastFoodUse = os.clock()
		hunger = math.clamp(hunger + CONFIG.FOOD_REFILL_AMOUNT, 0, 100)
	end)
	foodTool.Parent = backpack
end

--------------------------------------------------------------------------------
-- 3. SHADERS, ATMOSPHERE & ATMOSPHERIC LIGHTING
--------------------------------------------------------------------------------
local function getOrCreate(className, name)
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return trackInstance(existing)
	end
	local inst = Instance.new(className)
	inst.Name = name
	return trackInstance(inst)
end

local function setupShaders()
	-- Atmosphere (reuse the game's if present, and remember it so we can restore it)
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere and atmosphere.Name ~= "RealismAtmosphere" then
		atmosphereBackup = {
			inst = atmosphere,
			Name = atmosphere.Name,
			Density = atmosphere.Density,
			Offset = atmosphere.Offset,
			Color = atmosphere.Color,
			Decay = atmosphere.Decay,
			Glare = atmosphere.Glare,
			Haze = atmosphere.Haze,
		}
	elseif not atmosphere then
		atmosphere = trackInstance(Instance.new("Atmosphere"))
	else
		trackInstance(atmosphere)
	end
	atmosphere.Name = "RealismAtmosphere"
	atmosphere.Density = 0.36
	atmosphere.Offset = 0.25
	atmosphere.Color = Color3.fromRGB(195, 210, 230)
	atmosphere.Decay = Color3.fromRGB(110, 125, 140)
	atmosphere.Glare = 0.45
	atmosphere.Haze = 2.1
	atmosphere.Parent = Lighting

	local motionBlur = getOrCreate("BlurEffect", "RealismMotionBlur")
	motionBlur.Size = 0
	motionBlur.Parent = Lighting

	local colorCorrection = getOrCreate("ColorCorrectionEffect", "RealismColorCorrection")
	colorCorrection.Brightness = 0.02
	colorCorrection.Contrast = 0.15
	colorCorrection.Saturation = 0.1
	colorCorrection.Parent = Lighting

	local sunRays = getOrCreate("SunRaysEffect", "RealismSunRays")
	sunRays.Intensity = 0.18
	sunRays.Spread = 0.85
	sunRays.Parent = Lighting

	local bloom = getOrCreate("BloomEffect", "RealismBloom")
	bloom.Intensity = 0.45
	bloom.Size = 24
	bloom.Threshold = 0.92
	bloom.Parent = Lighting

	local dof = getOrCreate("DepthOfFieldEffect", "RealismDOF")
	dof.FarIntensity = 0.1
	dof.FocusDistance = 15
	dof.InFocusRadius = 25
	dof.NearIntensity = 0.05
	dof.Parent = Lighting

	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.2
	Lighting.OutdoorAmbient = Color3.fromRGB(110, 115, 125)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1

	return {
		colorCorrection = colorCorrection,
		motionBlur = motionBlur,
		sunRays = sunRays,
		bloom = bloom,
		dof = dof,
		atmosphere = atmosphere,
	}
end

local shaders = setupShaders()
local colorCorrection = shaders.colorCorrection
local motionBlur = shaders.motionBlur
local sunRays = shaders.sunRays
local bloom = shaders.bloom
local dof = shaders.dof
local atmosphere = shaders.atmosphere

--------------------------------------------------------------------------------
-- 4. GUI CREATION (BOTTOM RIGHT HUD)
--------------------------------------------------------------------------------
local function createHUD()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("RealismHUD")
	if existing then existing:Destroy() end

	local screenGui = trackInstance(Instance.new("ScreenGui"))
	screenGui.Name = "RealismHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local hudContainer = Instance.new("Frame")
	hudContainer.Name = "HUDContainer"
	hudContainer.Size = UDim2.new(0, 220, 0, 140)
	hudContainer.Position = UDim2.new(1, -240, 1, -160)
	hudContainer.BackgroundTransparency = 1
	hudContainer.Parent = screenGui

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = hudContainer

	local function makeBar(name, color, layoutOrder)
		local bg = Instance.new("Frame")
		bg.Name = name .. "BG"
		bg.Size = UDim2.new(1, 0, 0, 18)
		bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		bg.BackgroundTransparency = 0.3
		bg.BorderSizePixel = 0
		bg.LayoutOrder = layoutOrder
		bg.Parent = hudContainer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = bg

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.new(1, 0, 1, 0)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = bg

		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(0, 4)
		fillCorner.Parent = fill

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(1, -10, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = name:upper()
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.GothamBold
		label.TextSize = 11
		label.Parent = bg

		return fill, bg
	end

	local healthFill = makeBar("Health", CONFIG.HEALTH_COLOR, 1)
	local hungerFill = makeBar("Hunger", CONFIG.HUNGER_COLOR, 2)
	local thirstFill = makeBar("Thirst", CONFIG.THIRST_COLOR, 3)
	local sprintFill = makeBar("Sprint", CONFIG.SPRINT_COLOR, 4)
	local adrenalineFill, adrenalineBG = makeBar("Adrenaline", CONFIG.ADRENALINE_COLOR, 5)
	local strengthFill = makeBar("Leg Strength", CONFIG.STRENGTH_COLOR, 6)

	adrenalineBG.Visible = false

	-- Mobile touch sprint button (hold to run)
	if UserInputService.TouchEnabled then
		local mobileBtn = Instance.new("TextButton")
		mobileBtn.Name = "MobileSprintButton"
		mobileBtn.Size = UDim2.new(0, 65, 0, 65)
		mobileBtn.Position = UDim2.new(1, -95, 1, -245)
		mobileBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		mobileBtn.BackgroundTransparency = 0.3
		mobileBtn.Text = "RUN"
		mobileBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		mobileBtn.Font = Enum.Font.GothamBold
		mobileBtn.TextSize = 14
		mobileBtn.AutoButtonColor = false
		mobileBtn.Parent = screenGui

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(1, 0)
		btnCorner.Parent = mobileBtn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Color = CONFIG.SPRINT_COLOR
		btnStroke.Thickness = 2.5
		btnStroke.Parent = mobileBtn

		local function setPressedLook(pressed)
			mobileBtn.BackgroundColor3 = pressed and CONFIG.SPRINT_COLOR or Color3.fromRGB(30, 30, 30)
			mobileBtn.TextColor3 = pressed and Color3.fromRGB(20, 20, 20) or Color3.fromRGB(255, 255, 255)
		end

		local sprintInput = nil

		track(mobileBtn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				sprintInput = input
				mobileSprinting = true
				setPressedLook(true)
			end
		end))

		-- Global listener so lifting your finger anywhere stops the run
		track(UserInputService.InputEnded:Connect(function(input)
			if input == sprintInput then
				sprintInput = nil
				mobileSprinting = false
				setPressedLook(false)
			end
		end))
	end

	return {
		Health = healthFill,
		Hunger = hungerFill,
		Thirst = thirstFill,
		Sprint = sprintFill,
		Strength = strengthFill,
		Adrenaline = adrenalineFill,
		AdrenalineBG = adrenalineBG,
	}
end

local bars = createHUD()

--------------------------------------------------------------------------------
-- 4b. INJURY VIGNETTE (red glow around the screen edges)
--------------------------------------------------------------------------------
local function createDamageOverlay()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("RealismDamageOverlay")
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = "RealismDamageOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -1
	gui.Parent = playerGui

	local sides = {
		{ pos = UDim2.new(0, 0, 0, 0),    size = UDim2.new(1, 0, 0.4, 0),  rot = 90 },
		{ pos = UDim2.new(0, 0, 0.6, 0),  size = UDim2.new(1, 0, 0.4, 0),  rot = 270 },
		{ pos = UDim2.new(0, 0, 0, 0),    size = UDim2.new(0.35, 0, 1, 0), rot = 0 },
		{ pos = UDim2.new(0.65, 0, 0, 0), size = UDim2.new(0.35, 0, 1, 0), rot = 180 },
	}

	local frames = {}
	for _, side in ipairs(sides) do
		local frame = Instance.new("Frame")
		frame.BackgroundColor3 = CONFIG.INJURY_VIGNETTE_COLOR
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Position = side.pos
		frame.Size = side.size
		frame.Parent = gui

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = side.rot
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = frame

		table.insert(frames, frame)
	end

	return frames
end

local damageFrames = createDamageOverlay()

local function createEdgeOverlay(name, color)
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild(name)
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -2
	gui.Parent = playerGui

	local sides = {
		{ pos = UDim2.new(0, 0, 0, 0),    size = UDim2.new(1, 0, 0.4, 0),  rot = 90 },
		{ pos = UDim2.new(0, 0, 0.6, 0),  size = UDim2.new(1, 0, 0.4, 0),  rot = 270 },
		{ pos = UDim2.new(0, 0, 0, 0),    size = UDim2.new(0.35, 0, 1, 0), rot = 0 },
		{ pos = UDim2.new(0.65, 0, 0, 0), size = UDim2.new(0.35, 0, 1, 0), rot = 180 },
	}

	local frames = {}
	for _, side in ipairs(sides) do
		local frame = Instance.new("Frame")
		frame.BackgroundColor3 = color
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Position = side.pos
		frame.Size = side.size
		frame.Parent = gui

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = side.rot
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = frame

		table.insert(frames, frame)
	end

	return frames
end

local staminaFrames = createEdgeOverlay("RealismStaminaOverlay", Color3.new(0, 0, 0))

-- Full-screen black overlay used for passing out and dying
local blackFrame
do
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("RealismBlackout")
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = "RealismBlackout"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Parent = playerGui

	blackFrame = Instance.new("Frame")
	blackFrame.Size = UDim2.new(1, 0, 1, 0)
	blackFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	blackFrame.BackgroundTransparency = 1
	blackFrame.BorderSizePixel = 0
	blackFrame.Parent = gui
end

--------------------------------------------------------------------------------
-- 5. THREAT DETECTION & ADRENALINE LOGIC
--------------------------------------------------------------------------------
local function canSeePart(targetPart, targetCharacter)
	local origin = Camera.CFrame.Position
	local result = firstSolidHit(origin, targetPart.Position - origin, LocalPlayer.Character)
	return result == nil or result.Instance:IsDescendantOf(targetCharacter)
end

local function isThreatVisible(otherCharacter, otherHrp)
	if CONFIG.THREAT_REQUIRE_ON_SCREEN then
		local _, onScreen = Camera:WorldToViewportPoint(otherHrp.Position)
		if not onScreen then return false end
	end

	if canSeePart(otherHrp, otherCharacter) then
		return true
	end
	local head = otherCharacter:FindFirstChild("Head")
	return head ~= nil and canSeePart(head, otherCharacter)
end

local function isThreatNearby(myPos)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Character then
			local otherCharacter = player.Character
			local otherHrp = otherCharacter:FindFirstChild("HumanoidRootPart")
			local tool = otherCharacter:FindFirstChildOfClass("Tool")

			if otherHrp and tool and not CONFIG.THREAT_IGNORE_TOOLS[tool.Name] then
				local dist = (otherHrp.Position - myPos).Magnitude
				if dist <= CONFIG.THREAT_RADIUS and isThreatVisible(otherCharacter, otherHrp) then
					return true
				end
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- 6. SUN GLARE, TIME-OF-DAY LIGHTING & DYNAMIC FOCUS
--------------------------------------------------------------------------------
local WHITE = Color3.new(1, 1, 1)
local WARM_TINT = Color3.fromRGB(255, 225, 195)
local PAIN_TINT = Color3.fromRGB(255, 70, 70)

local function getSunExposure(character)
	local sunDir = Lighting:GetSunDirection()
	if sunDir.Y < -0.05 then return 0 end

	local facing = Camera.CFrame.LookVector:Dot(sunDir)
	local angle = math.clamp((facing - CONFIG.SUN_GLARE_COS_START) / (1 - CONFIG.SUN_GLARE_COS_START), 0, 1)
	if angle <= 0 then return 0 end

	if firstSolidHit(Camera.CFrame.Position, sunDir * 2000, character) then
		return 0
	end

	local horizonFade = math.clamp((sunDir.Y + 0.05) / 0.15, 0, 1)
	return angle * angle * horizonFade
end

local function updateTimeOfDayLighting()
	local sunHeight = Lighting:GetSunDirection().Y
	local day = math.clamp((sunHeight + 0.1) / 0.4, 0, 1)
	local golden = 1 - math.clamp(math.abs(sunHeight) / 0.3, 0, 1)

	local skyColor = Color3.fromRGB(45, 55, 85):Lerp(Color3.fromRGB(195, 210, 230), day):Lerp(Color3.fromRGB(255, 185, 130), golden * 0.7)
	local skyDecay = Color3.fromRGB(25, 28, 50):Lerp(Color3.fromRGB(110, 125, 140), day):Lerp(Color3.fromRGB(200, 110, 70), golden * 0.7)

	atmosphere.Color = skyColor
	atmosphere.Decay = skyDecay
	atmosphere.Density = 0.3 + golden * 0.1 + (1 - day) * 0.05

	Lighting.Brightness = CONFIG.MOON_BRIGHTNESS + day * (CONFIG.SUN_BRIGHTNESS - CONFIG.MOON_BRIGHTNESS)
	Lighting.OutdoorAmbient = CONFIG.MOON_AMBIENT:Lerp(Color3.fromRGB(110, 115, 125), day):Lerp(Color3.fromRGB(150, 110, 90), golden * 0.4)

	Lighting.ColorShift_Top = Color3.new(0, 0, 0):Lerp(CONFIG.MOON_TINT, 1 - day)

	return day, golden
end

--------------------------------------------------------------------------------
-- 6b. AUDIO (FOOTSTEPS, BREATHING, HEARTBEAT, EAR RINGING)
--------------------------------------------------------------------------------
local function makeSound(parent, name, id, looped)
	if not id or id == "" then return nil end
	local sound = trackInstance(Instance.new("Sound"))
	sound.Name = name
	sound.SoundId = id
	sound.Looped = looped
	sound.Volume = 0
	sound.Parent = parent
	if looped then sound:Play() end
	return sound
end

-- Tries each ID in order and keeps the first one that actually loads
local function loadFirstWorking(parent, name, ids)
	for _, id in ipairs(ids) do
		local candidate = makeSound(parent, name, id, true)
		if candidate then
			pcall(function() ContentProvider:PreloadAsync({ candidate }) end)
			if candidate.TimeLength > 0 then
				return candidate
			end
			candidate:Destroy()
		end
	end
	return nil
end

local function destroyLoopSounds()
	if breathSound then breathSound:Destroy() end
	if heartSound then heartSound:Destroy() end
	if ringSound then ringSound:Destroy() end
	if thumpSound then thumpSound:Destroy() end
	breathSound, heartSound, ringSound, thumpSound = nil, nil, nil, nil
end

local function setupSounds(character)
	soundGen = soundGen + 1
	local gen = soundGen
	destroyLoopSounds()

	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or gen ~= soundGen then return end

	footstepPool, footstepIndex = {}, 0
	for i = 1, 3 do -- a small pool so fast footsteps don't cut each other off
		local s = makeSound(hrp, "RealismFootstep" .. i, CONFIG.FOOTSTEP_DEFAULT_ID, false)
		if s then table.insert(footstepPool, s) end
	end
	pcall(function() ContentProvider:PreloadAsync(footstepPool) end) -- so TimeLength is known
	if gen ~= soundGen then return end

	-- Breathing is positional (comes from your body); heartbeat and ringing are
	-- parented to PlayerGui so they play "inside your head" at full volume.
	local breath = loadFirstWorking(hrp, "RealismBreath", CONFIG.BREATH_SOUND_IDS)
	if gen ~= soundGen then
		if breath then breath:Destroy() end
		return
	end
	breathSound = breath
	if not breathSound then
		warn("[Realism] No breathing sound could load. Put a working rbxassetid:// ID in CONFIG.BREATH_SOUND_IDS.")
	end

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local heart = loadFirstWorking(playerGui, "RealismHeartbeat", CONFIG.HEARTBEAT_SOUND_IDS)
	if gen ~= soundGen then
		if heart then heart:Destroy() end
		return
	end
	heartSound = heart
	if not heartSound then
		-- No heartbeat loop: fall back to a built-in thump played on every beat
		local thump = makeSound(playerGui, "RealismHeartThump", CONFIG.HEARTBEAT_FALLBACK_ID, false)
		if thump then
			pcall(function() ContentProvider:PreloadAsync({ thump }) end)
			if gen ~= soundGen or thump.TimeLength <= 0 then
				thump:Destroy()
				if gen ~= soundGen then return end
			else
				thumpSound = thump
			end
		end
		if not thumpSound then
			warn("[Realism] No heartbeat sound loaded. Put a working rbxassetid:// ID in CONFIG.HEARTBEAT_SOUND_IDS (the camera thump still works).")
		end
	end

	local ring = loadFirstWorking(playerGui, "RealismEarRinging", CONFIG.RING_SOUND_IDS)
	if gen ~= soundGen then
		if ring then ring:Destroy() end
		return
	end
	ringSound = ring
	if not ringSound then
		warn("[Realism] No ear ringing sound loaded. Put a working rbxassetid:// ID in CONFIG.RING_SOUND_IDS.")
	end

	defaultRunning, defaultRunningVolume = nil, nil
	if CONFIG.MUTE_DEFAULT_FOOTSTEPS then
		local running = hrp:WaitForChild("Running", 3)
		if running and running:IsA("Sound") then
			defaultRunning = running
			defaultRunningVolume = running.Volume
		end
	end
end

local function playFootstep(sound, humanoid, isRunning, speedT)
	local id = CONFIG.MATERIAL_SOUNDS[humanoid.FloorMaterial] or CONFIG.FOOTSTEP_DEFAULT_ID
	if sound.SoundId ~= id then sound.SoundId = id end
	sound.PlaybackSpeed = (isRunning and 1.2 or 0.95) + math.random() * 0.15 + speedT * 0.2
	sound.Volume = isRunning and 0.85 or 0.45
	sound.TimePosition = CONFIG.FOOTSTEP_CLIP_START
	sound:Play()

	-- The default file holds several steps; cut it off after the first one
	local clip = CONFIG.FOOTSTEP_CLIP_LENGTH
	if clip <= 0 and CONFIG.FOOTSTEP_STEPS_IN_FILE > 1 and sound.TimeLength > 0 then
		clip = sound.TimeLength / CONFIG.FOOTSTEP_STEPS_IN_FILE
	end
	if clip > 0 then
		task.delay(clip / math.max(sound.PlaybackSpeed, 0.1), function()
			if sound.Parent and sound.IsPlaying then
				sound:Stop()
			end
		end)
	end
end

local function approachVolume(sound, target, deltaTime, rate)
	sound.Volume = sound.Volume + (target - sound.Volume) * math.clamp(deltaTime * rate, 0, 1)
end

local function playThump(strength, pitch)
	if thumpSound then
		thumpSound.Volume = math.clamp(strength, 0, 1) * CONFIG.HEARTBEAT_MAX_VOLUME
		thumpSound.PlaybackSpeed = pitch
		thumpSound.TimePosition = 0
		thumpSound:Play()
	end
end

local function updateAudio(deltaTime, humanoid, flatSpeed, healthPercent)
	if defaultRunning and defaultRunning.Parent then
		defaultRunning.Volume = 0
	end

	-- Footsteps: cadence climbs with speed, so running is clearly faster than walking
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local isRunning = flatSpeed > CONFIG.WALK_SPEED * 1.25
	local speedT = math.clamp((flatSpeed - CONFIG.WALK_SPEED) / math.max(CONFIG.MAX_RUN_SPEED - CONFIG.WALK_SPEED, 1), 0, 1)
	local targetRate
	if isRunning then
		targetRate = CONFIG.STEP_RATE_RUN_MIN + (CONFIG.STEP_RATE_RUN_MAX - CONFIG.STEP_RATE_RUN_MIN) * speedT
	else
		targetRate = CONFIG.STEP_RATE_WALK * math.clamp(flatSpeed / CONFIG.WALK_SPEED, 0.4, 1)
	end
	stepRate = stepRate + (targetRate - stepRate) * math.clamp(deltaTime * 10, 0, 1)

	if grounded and flatSpeed > 1.5 and #footstepPool > 0 then
		stepTimer = stepTimer + deltaTime
		if stepTimer >= 1 / stepRate then
			stepTimer = 0
			footstepIndex = footstepIndex % #footstepPool + 1
			playFootstep(footstepPool[footstepIndex], humanoid, isRunning, speedT)
			-- Each step while limping dips the camera a little
			if limpFactor > 0 then
				landingVelocity = landingVelocity - 1.2 * limpFactor
			end
		end
	else
		stepTimer = (1 / stepRate) * 0.7 -- first step lands quickly once you start moving
	end

	-- How close you are to running out of sprint (also while passed out)
	local depleted = math.clamp((CONFIG.DEPLETED_STAMINA_START - stamina) / CONFIG.DEPLETED_STAMINA_START, 0, 1)
	if exhausted then depleted = math.max(depleted, 0.7) end
	if faint then depleted = 1 end

	-- Heavy breathing: low stamina or adrenaline
	if breathSound then
		local tired = math.clamp((CONFIG.BREATH_STAMINA_START - stamina) / CONFIG.BREATH_STAMINA_START, 0, 1)
		local factor = math.max(tired, (adrenaline / 100) * 0.5)
		approachVolume(breathSound, factor * CONFIG.BREATH_MAX_VOLUME, deltaTime, 3)
		breathSound.PlaybackSpeed = 0.9 + factor * 0.4
	end

	-- Heartbeat: low health, out of sprint, and a little with adrenaline
	local lowHealth = math.clamp((0.4 - healthPercent) / 0.4, 0, 1)
	local heartFactor = math.max(lowHealth, depleted, (adrenaline / 100) * 0.35)
	if heartSound then
		approachVolume(heartSound, heartFactor * CONFIG.HEARTBEAT_MAX_VOLUME, deltaTime, 3)
		heartSound.PlaybackSpeed = 0.9 + heartFactor * 0.5
	end

	-- Ear ringing: builds as sprint runs out
	if ringSound then
		approachVolume(ringSound, depleted * CONFIG.RING_MAX_VOLUME, deltaTime, 3)
	end

	-- Camera thump on every heartbeat (lub-dub), works even with no sound loaded
	if heartFactor > 0.1 then
		heartPhase = heartPhase + deltaTime * (1.1 + heartFactor * 1.6)
		if heartPhase >= 1 then
			heartPhase = heartPhase - 1
			heartDubDone = false
			landingVelocity = landingVelocity - CONFIG.HEARTBEAT_PULSE * heartFactor
			playThump(heartFactor, 0.6)
		elseif not heartDubDone and heartPhase >= 0.3 then
			heartDubDone = true
			landingVelocity = landingVelocity - CONFIG.HEARTBEAT_PULSE * 0.6 * heartFactor
			playThump(heartFactor * 0.7, 0.75)
		end
	end
end

-- Dying: ear ringing only. No heartbeat, no breathing.
local function updateDeathAudio(deltaTime)
	if breathSound then breathSound.Volume = 0 end
	if heartSound then heartSound.Volume = 0 end
	if thumpSound then thumpSound.Volume = 0 end
	if ringSound then
		approachVolume(ringSound, CONFIG.RING_MAX_VOLUME, deltaTime, 3)
	end
end

--------------------------------------------------------------------------------
-- 6c. RAGDOLL, FAINTING & BLACKOUT
--------------------------------------------------------------------------------

-- Distance from the HumanoidRootPart centre to the ground when standing (R15 and R6)
local function getRootHeightAboveGround(humanoid, hrp, character)
	local legHeight = 0
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local leg = character:FindFirstChild("Left Leg")
		legHeight = leg and leg.Size.Y or 2
	end
	return hrp.Size.Y / 2 + humanoid.HipHeight + legHeight
end

local function updateBlackout(deltaTime)
	if blackAlpha < blackTarget then
		blackAlpha = math.min(blackTarget, blackAlpha + blackRate * deltaTime)
	elseif blackAlpha > blackTarget then
		blackAlpha = math.max(blackTarget, blackAlpha - blackRate * deltaTime)
	end
	blackFrame.BackgroundTransparency = 1 - blackAlpha
end

-- Swaps the character's joints for loose ball-socket joints so the body goes limp
local function startRagdoll(character, topple)
	if ragdollData then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid then return end

	local data = {
		instances = {},
		motors = {},
		canCollide = {},
		requiresNeck = humanoid.RequiresNeck,
		autoRotate = humanoid.AutoRotate,
	}
	ragdollData = data

	humanoid.RequiresNeck = false
	humanoid.AutoRotate = false
	-- Stop the humanoid from standing itself back up while the body is limp
	pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false) end)

	local startVelocity = hrp and hrp.AssemblyLinearVelocity or Vector3.zero

	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") and d.Parent == character then
			data.canCollide[d] = d.CanCollide
		end
		if d:IsA("Motor6D") and d.Name ~= "RootJoint" and d.Part0 and d.Part1 then
			local a0 = Instance.new("Attachment")
			a0.Name = "RealismRagdollA0"
			a0.CFrame = d.C0
			a0.Parent = d.Part0

			local a1 = Instance.new("Attachment")
			a1.Name = "RealismRagdollA1"
			a1.CFrame = d.C1
			a1.Parent = d.Part1

			local limit = (d.Name == "Neck") and 45 or 80
			local ball = Instance.new("BallSocketConstraint")
			ball.Attachment0 = a0
			ball.Attachment1 = a1
			ball.LimitsEnabled = true
			ball.UpperAngle = limit
			ball.TwistLimitsEnabled = true
			ball.TwistLowerAngle = -limit / 2
			ball.TwistUpperAngle = limit / 2
			ball.Restitution = 0
			ball.MaxFrictionTorque = CONFIG.RAGDOLL_JOINT_FRICTION
			ball.Parent = d.Part0

			local noCollide = Instance.new("NoCollisionConstraint")
			noCollide.Part0 = d.Part0
			noCollide.Part1 = d.Part1
			noCollide.Parent = d.Part0

			d.Enabled = false
			table.insert(data.motors, d)
			table.insert(data.instances, a0)
			table.insert(data.instances, a1)
			table.insert(data.instances, ball)
			table.insert(data.instances, noCollide)
		end
	end

	-- Every body part now collides with the world (the humanoid normally turns most off)
	for part in pairs(data.canCollide) do
		if part.Name ~= "HumanoidRootPart" then part.CanCollide = true end
	end

	humanoid.PlatformStand = true
	pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Physics) end)

	-- The joints just came apart, so give every limb the body's momentum
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			d.AssemblyLinearVelocity = startVelocity
		end
	end

	if topple and hrp then
		hrp.AssemblyLinearVelocity = startVelocity + topple * 6
		hrp.AssemblyAngularVelocity = Vector3.yAxis:Cross(topple) * CONFIG.RAGDOLL_TOPPLE_SPEED
	end
end

-- Puts the body back together, upright, where it was lying
local function stopRagdoll(character, humanoid, hrp, lookDir)
	local data = ragdollData
	if not data then return end
	ragdollData = nil
	ragdollCamCF = nil

	local torso = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	local base = torso and torso.Position or hrp.Position
	local ground = firstSolidHit(base + Vector3.new(0, 3, 0), Vector3.new(0, -12, 0), character)
	local groundY = ground and ground.Position.Y or (base.Y - 1)
	local pos = Vector3.new(base.X, groundY + getRootHeightAboveGround(humanoid, hrp, character) + 0.1, base.Z)

	for _, inst in ipairs(data.instances) do
		if inst then inst:Destroy() end
	end
	for part, canCollide in pairs(data.canCollide) do
		if part.Parent then part.CanCollide = canCollide end
	end

	hrp.CFrame = CFrame.lookAt(pos, pos + lookDir)
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			d.AssemblyLinearVelocity = Vector3.zero
			d.AssemblyAngularVelocity = Vector3.zero
		end
	end

	for _, m in ipairs(data.motors) do
		if m then m.Enabled = true end
	end
	humanoid.RequiresNeck = data.requiresNeck
	humanoid.AutoRotate = data.autoRotate
	humanoid.PlatformStand = false
	pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true) end)
	humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

local function startFaint(character, humanoid, hrp)
	local camLook = Camera.CFrame.LookVector
	local look = Vector3.new(camLook.X, 0, camLook.Z)
	if look.Magnitude < 0.01 then
		look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	end
	look = look.Unit

	faint = {
		phase = "falling",
		t = 0,
		hold = CONFIG.FAINT_HOLD_MIN + math.random() * (CONFIG.FAINT_HOLD_MAX - CONFIG.FAINT_HOLD_MIN),
		look = look,
	}
	blackTarget = 1
	blackRate = 1 / CONFIG.FAINT_FADE_OUT

	startRagdoll(character, look) -- topple forward
end

local function updateFaint(deltaTime, character, humanoid, hrp)
	-- Keep the body limp for as long as the ragdoll lasts
	if ragdollData and humanoid.Health > 0 then
		humanoid.PlatformStand = true
	end
	if not faint then return end
	faint.t = faint.t + deltaTime
	peakFallSpeed = 0 -- collapsing shouldn't count as a damaging fall

	if faint.phase == "falling" then
		if blackAlpha >= 1 then
			faint.phase = "out"
			faint.t = 0
		end
	elseif faint.phase == "out" then
		if faint.t >= faint.hold then
			stopRagdoll(character, humanoid, hrp, faint.look)
			stamina = CONFIG.FAINT_RECOVER_STAMINA
			exhausted = false
			blackTarget = 0
			blackRate = 1 / CONFIG.FAINT_FADE_IN
			faint.phase = "waking"
			faint.t = 0
		end
	elseif faint.phase == "waking" then
		if blackAlpha <= 0 then
			faint = nil
			faintTimer = 0
			faintThreshold = nil
		end
	end
end

--------------------------------------------------------------------------------
-- 6d. MANTLING
--------------------------------------------------------------------------------
local mantle = nil
local mantleCooldown = 0

local function smoothstep(x)
	return x * x * (3 - 2 * x)
end

local function tryStartMantle(humanoid, hrp, character)
	local moveDir = humanoid.MoveDirection
	local flatDir = Vector3.new(moveDir.X, 0, moveDir.Z)
	if flatDir.Magnitude < 0.1 then return end
	flatDir = flatDir.Unit

	-- A solid, roughly vertical wall right in front of you
	local wall = firstSolidHit(hrp.Position, flatDir * CONFIG.MANTLE_REACH, character)
	if not wall or not wall.Instance.CanCollide then return end
	if wall.Normal.Y > 0.3 or wall.Normal:Dot(-flatDir) < 0.4 then return end

	-- Find the flat top surface just past the wall face
	local feetY = hrp.Position.Y - getRootHeightAboveGround(humanoid, hrp, character)
	local probe = wall.Position + flatDir * 0.6
	local topOrigin = Vector3.new(probe.X, feetY + CONFIG.MANTLE_MAX_HEIGHT + 1, probe.Z)
	local top = firstSolidHit(topOrigin, Vector3.new(0, -(CONFIG.MANTLE_MAX_HEIGHT + 0.5), 0), character)
	if not top or not top.Instance.CanCollide or top.Normal.Y < 0.7 then return end

	local topY = top.Position.Y
	if topY - feetY < 1 then return end            -- low enough to just step up
	if hrp.Position.Y < topY - 3 then return end   -- hands can't reach yet

	-- Room to stand up on the ledge
	if firstSolidHit(Vector3.new(probe.X, topY + 0.1, probe.Z), Vector3.new(0, 5, 0), character) then return end

	if stamina < CONFIG.MANTLE_STAMINA_COST then return end
	stamina = stamina - CONFIG.MANTLE_STAMINA_COST

	local standY = topY + getRootHeightAboveGround(humanoid, hrp, character) + 0.05
	mantle = {
		t = 0,
		startPos = hrp.Position,
		endPos = Vector3.new(probe.X, standY, probe.Z) + flatDir * 0.6,
		flatDir = flatDir,
	}
	landingVelocity = landingVelocity - 2
end

-- Returns true while a mantle is in progress
local function updateMantle(deltaTime, humanoid, hrp, character)
	if mantle then
		if humanoid.Health <= 0 then
			mantle = nil
			return false
		end

		mantle.t = mantle.t + deltaTime
		local a = math.clamp(mantle.t / CONFIG.MANTLE_DURATION, 0, 1)
		local ay = smoothstep(math.clamp(a / 0.65, 0, 1))          -- rise first
		local axz = smoothstep(math.clamp((a - 0.35) / 0.65, 0, 1)) -- then pull forward
		local s, e = mantle.startPos, mantle.endPos
		local pos = Vector3.new(s.X + (e.X - s.X) * axz, s.Y + (e.Y - s.Y) * ay, s.Z + (e.Z - s.Z) * axz)

		hrp.CFrame = CFrame.lookAt(pos, pos + mantle.flatDir)
		hrp.AssemblyLinearVelocity = Vector3.zero
		peakFallSpeed = 0

		if a >= 1 then
			mantle = nil
			mantleCooldown = CONFIG.MANTLE_COOLDOWN
			landingVelocity = landingVelocity - 3
		end
		return true
	end

	mantleCooldown = math.max(0, mantleCooldown - deltaTime)
	if not CONFIG.ENABLE_MANTLE or mantleCooldown > 0 then return false end

	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
		tryStartMantle(humanoid, hrp, character)
	end
	return mantle ~= nil
end

--------------------------------------------------------------------------------
-- 7. MAIN UPDATE LOOP
--------------------------------------------------------------------------------
local function mainUpdate(deltaTime)
	local character = LocalPlayer.Character
	if not character then return end

	Camera = Workspace.CurrentCamera
	if not Camera then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp then return end

	-- New humanoid (respawn): sync health tracking so no false adrenaline spike
	if humanoid ~= lastHumanoid then
		lastHumanoid = humanoid
		lastHealth = humanoid.Health
		deadHandled = false
	end

	updateBlackout(deltaTime)

	-- Death: ragdoll, cut to black instantly, ear ringing only (no heartbeat)
	if humanoid.Health <= 0 then
		if not deadHandled then
			deadHandled = true
			faint = nil
			blackAlpha, blackTarget = 1, 1
			startRagdoll(character)
		end
		updateDeathAudio(deltaTime)
		updateBlackout(0)
		return
	end

	updateFaint(deltaTime, character, humanoid, hrp)

	if LocalPlayer.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
	end

	-- Landing impact & fall damage
	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	local humanoidState = humanoid:GetState()

	if humanoidState == Enum.HumanoidStateType.Swimming
		or humanoidState == Enum.HumanoidStateType.Climbing
		or humanoidState == Enum.HumanoidStateType.Seated
		or humanoidState == Enum.HumanoidStateType.Dead then
		peakFallSpeed = 0
	elseif airborne then
		peakFallSpeed = math.max(peakFallSpeed, -hrp.AssemblyLinearVelocity.Y)
	end

	if wasAirborne and not airborne then
		if peakFallSpeed > CONFIG.LANDING_MIN_SPEED then
			landingVelocity = landingVelocity - math.clamp(peakFallSpeed * 0.08, 0, 7)
		end

		if peakFallSpeed > CONFIG.FALL_DAMAGE_MIN_SPEED then
			local severity = math.clamp(
				(peakFallSpeed - CONFIG.FALL_DAMAGE_MIN_SPEED) / (CONFIG.FALL_DAMAGE_LETHAL_SPEED - CONFIG.FALL_DAMAGE_MIN_SPEED),
				0, 1
			)
			humanoid:TakeDamage(humanoid.MaxHealth * severity)
		end

		peakFallSpeed = 0
	end
	wasAirborne = airborne

	-- A. Health check (damage triggers adrenaline)
	if humanoid.Health < lastHealth then
		adrenaline = 100
	end
	lastHealth = humanoid.Health

	-- B. Threat detection (throttled)
	threatTimer = threatTimer + deltaTime
	if threatTimer >= CONFIG.THREAT_CHECK_INTERVAL then
		threatTimer = 0
		threatCached = isThreatNearby(hrp.Position)
	end
	if threatCached then
		adrenaline = 100
	end

	-- C. Adrenaline decay
	if adrenaline > 0 then
		adrenaline = math.clamp(adrenaline - (CONFIG.ADRENALINE_DECAY * deltaTime), 0, 100)
	end

	-- C2. Sprint & stamina
	local flatVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
	local isMoving = flatVelocity.Magnitude > 1.5
	local isAdrenalineActive = adrenaline > 1
	local wantsToSprint = (shiftPressed or mobileSprinting) and isMoving

	if stamina <= 0 then
		exhausted = true
	elseif exhausted and stamina >= CONFIG.SPRINT_RESUME_THRESHOLD then
		exhausted = false
	end

	local isSprinting = wantsToSprint and not exhausted

	if isSprinting then
		local drainMultiplier = isAdrenalineActive and CONFIG.ADRENALINE_STAMINA_DRAIN_MULT or 1
		stamina = math.clamp(stamina - (CONFIG.STAMINA_DRAIN_RATE * drainMultiplier * deltaTime), 0, CONFIG.MAX_STAMINA)
	else
		-- Walking barely recovers stamina; standing still recovers it quickly
		local regen = isMoving and CONFIG.STAMINA_REGEN_WALK or CONFIG.STAMINA_REGEN_RATE
		stamina = math.clamp(stamina + (regen * deltaTime), 0, CONFIG.MAX_STAMINA)
	end

	-- C2b. Pass out after walking too long while exhausted
	if not faint then
		if exhausted and isMoving then
			faintThreshold = faintThreshold or (CONFIG.FAINT_MIN_TIME + math.random() * (CONFIG.FAINT_MAX_TIME - CONFIG.FAINT_MIN_TIME))
			faintTimer = faintTimer + deltaTime
			if faintTimer >= faintThreshold then
				startFaint(character, humanoid, hrp)
			end
		elseif exhausted then
			faintTimer = math.max(0, faintTimer - deltaTime * 2) -- resting lets you recover
		else
			faintTimer = 0
			faintThreshold = nil
		end
	end

	-- C3. Leg strength
	if isMoving and humanoid.FloorMaterial ~= Enum.Material.Air then
		local isRunningFast = flatVelocity.Magnitude > CONFIG.WALK_SPEED * 1.25
		local gain = isRunningFast and CONFIG.STRENGTH_GAIN_RUN or CONFIG.STRENGTH_GAIN_WALK
		legStrength = math.clamp(legStrength + gain * deltaTime, 0, 100)
	end

	-- C4. Mantling
	if not faint then
		safeCall("mantle", updateMantle, deltaTime, humanoid, hrp, character)
	end

	-- C5. Tiredness (drives vignette, blur, saturation and bob)
	local tired = math.clamp((CONFIG.TIRED_STAMINA_START - stamina) / CONFIG.TIRED_STAMINA_START, 0, 1)
	if exhausted then tired = math.max(tired, 0.8) end
	staminaVisual = staminaVisual + (tired - staminaVisual) * math.clamp(deltaTime * 3, 0, 1)

	-- D. Motion blur (normalized to a 60 FPS frame so it's FPS-independent)
	local currentLookVector = Camera.CFrame.LookVector
	local cameraRotDelta = (currentLookVector - lastLookVector).Magnitude
	lastLookVector = currentLookVector

	local normalizedDelta = cameraRotDelta * ((1 / 60) / math.max(deltaTime, 1 / 240))
	local targetBlur = math.clamp(normalizedDelta * CONFIG.MOTION_BLUR_INTENSITY, 0, CONFIG.MAX_BLUR) + staminaVisual * CONFIG.STAMINA_BLUR_MAX
	motionBlur.Size = motionBlur.Size + (targetBlur - motionBlur.Size) * math.clamp(deltaTime * 12, 0, 1)

	-- E. Hunger & thirst decay
	hunger = math.clamp(hunger - (CONFIG.HUNGER_DECAY * deltaTime), 0, 100)
	thirst = math.clamp(thirst - (CONFIG.THIRST_DECAY * deltaTime), 0, 100)

	-- E2. Starvation / dehydration damage (both empty = much more damage)
	local emptyBars = (hunger <= 0 and 1 or 0) + (thirst <= 0 and 1 or 0)
	if emptyBars > 0 and humanoid.Health > 0 then
		local rate = (emptyBars >= 2) and CONFIG.STARVE_DAMAGE_BOTH or CONFIG.STARVE_DAMAGE_SINGLE
		humanoid.Health = math.max(0, humanoid.Health - rate * deltaTime)
		lastHealth = humanoid.Health -- slow damage shouldn't trigger the adrenaline spike
	end

	-- F. WalkSpeed & FOV
	local adrenalinePercent = adrenaline / 100
	local runSpeed = CONFIG.ADRENALINE_SPEED + (CONFIG.MAX_RUN_SPEED - CONFIG.ADRENALINE_SPEED) * (legStrength / 100)
	local targetSpeed = CONFIG.WALK_SPEED + ((runSpeed - CONFIG.WALK_SPEED) * adrenalinePercent)
	if isSprinting then
		targetSpeed = math.max(targetSpeed, runSpeed)
	end
	local targetFOV = CONFIG.NORMAL_FOV + ((CONFIG.ADRENALINE_FOV - CONFIG.NORMAL_FOV) * adrenalinePercent)

	local lowestNeed = math.min(hunger, thirst)
	if lowestNeed < CONFIG.NEEDS_PENALTY_THRESHOLD then
		targetSpeed = targetSpeed * (0.7 + 0.3 * (lowestNeed / CONFIG.NEEDS_PENALTY_THRESHOLD))
	end

	-- Injury limp: slower and uneven below the health threshold
	local hpFraction = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
	limpFactor = math.clamp((CONFIG.LIMP_HEALTH_THRESHOLD - hpFraction) / CONFIG.LIMP_HEALTH_THRESHOLD, 0, 1)
	targetSpeed = targetSpeed * (1 - CONFIG.LIMP_MAX_SLOWDOWN * limpFactor)

	humanoid.WalkSpeed = targetSpeed
	Camera.FieldOfView = Camera.FieldOfView + (targetFOV - Camera.FieldOfView) * math.clamp(deltaTime * 5, 0, 1)

	-- F2. Sun glare
	local sunTarget = getSunExposure(character)
	local glareRate = sunTarget > sunGlare and CONFIG.SUN_GLARE_RISE or CONFIG.SUN_GLARE_FALL
	sunGlare = sunGlare + (sunTarget - sunGlare) * math.clamp(deltaTime * glareRate, 0, 1)

	local day, golden = updateTimeOfDayLighting()

	sunRays.Intensity = 0.18 + sunGlare * CONFIG.SUN_RAYS_MAX
	sunRays.Spread = 0.85 + sunGlare * 0.15
	bloom.Intensity = 0.45 + sunGlare * CONFIG.SUN_BLOOM_MAX
	bloom.Threshold = 0.92 - sunGlare * 0.4
	bloom.Size = 24 + sunGlare * 40
	atmosphere.Glare = 0.45 + sunGlare * 1.5
	Lighting.ExposureCompensation = sunGlare * CONFIG.SUN_EXPOSURE_MAX + (1 - day) * CONFIG.MOON_EXPOSURE

	-- F3. Color grading
	local healthPercent = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
	local injury = 1 - healthPercent
	injuryVisual = injuryVisual + (injury - injuryVisual) * math.clamp(deltaTime * 4, 0, 1)
	local blend = math.clamp(deltaTime * 6, 0, 1)

	local targetBrightness = 0.02 + (0.13 * adrenalinePercent) + sunGlare * 0.2
	local targetContrast = 0.15 + (0.05 * adrenalinePercent) - sunGlare * 0.1
	local targetSaturation = 0.1 + (0.1 * adrenalinePercent) - sunGlare * 0.25 - injuryVisual * 0.3 - staminaVisual * 0.15
	local targetTint = WHITE:Lerp(WARM_TINT, golden * day * 0.5):Lerp(PAIN_TINT, injuryVisual * CONFIG.INJURY_TINT_MAX)

	colorCorrection.Brightness = colorCorrection.Brightness + (targetBrightness - colorCorrection.Brightness) * blend
	colorCorrection.Contrast = colorCorrection.Contrast + (targetContrast - colorCorrection.Contrast) * blend
	colorCorrection.Saturation = colorCorrection.Saturation + (targetSaturation - colorCorrection.Saturation) * blend
	colorCorrection.TintColor = colorCorrection.TintColor:Lerp(targetTint, blend)

	local vignetteAlpha = injuryVisual * CONFIG.INJURY_VIGNETTE_MAX
	for _, frame in ipairs(damageFrames) do
		frame.BackgroundTransparency = 1 - vignetteAlpha
	end

	local staminaAlpha = staminaVisual * CONFIG.STAMINA_VIGNETTE_MAX
	for _, frame in ipairs(staminaFrames) do
		frame.BackgroundTransparency = 1 - staminaAlpha
	end

	-- F3b. Audio
	safeCall("audio", updateAudio, deltaTime, humanoid, flatVelocity.Magnitude, healthPercent)

	-- F4. Dynamic depth of field
	local focusHit = firstSolidHit(Camera.CFrame.Position, Camera.CFrame.LookVector * 500, character)
	local targetFocus = focusHit and (focusHit.Position - Camera.CFrame.Position).Magnitude or 500
	focusDistance = focusDistance + (targetFocus - focusDistance) * math.clamp(deltaTime * CONFIG.DOF_FOCUS_SPEED, 0, 1)
	dof.FocusDistance = focusDistance
	dof.InFocusRadius = math.clamp(focusDistance * 0.6, 8, 60)

	-- G. HUD bars (set directly; no per-frame tweens)
	bars.Health.Size = UDim2.new(healthPercent, 0, 1, 0)
	bars.Hunger.Size = UDim2.new(hunger / 100, 0, 1, 0)
	bars.Thirst.Size = UDim2.new(thirst / 100, 0, 1, 0)
	bars.Sprint.Size = UDim2.new(stamina / CONFIG.MAX_STAMINA, 0, 1, 0)
	bars.Strength.Size = UDim2.new(legStrength / 100, 0, 1, 0)

	if adrenaline > 0.1 then
		bars.AdrenalineBG.Visible = true
		bars.Adrenaline.Size = UDim2.new(adrenaline / 100, 0, 1, 0)
	else
		bars.AdrenalineBG.Visible = false
	end

	-- H. Day / night cycle
	if CONFIG.ENABLE_DAY_NIGHT then
		Lighting.ClockTime = (Lighting.ClockTime + (CONFIG.DAY_NIGHT_SPEED * deltaTime)) % 24
	end
end

track(RunService.Heartbeat:Connect(function(deltaTime)
	safeCall("main loop", mainUpdate, deltaTime)
end))

--------------------------------------------------------------------------------
-- RESPAWN & INITIALIZATION
--------------------------------------------------------------------------------
local function resetStateForNewCharacter()
	lastHealth = nil
	lastHumanoid = nil
	hunger = 100
	thirst = 100
	adrenaline = 0
	bobIndex = 0
	currentRoll = 0
	stamina = CONFIG.MAX_STAMINA
	exhausted = false
	mobileSprinting = false
	sunGlare = 0
	landingOffset = 0
	landingVelocity = 0
	peakFallSpeed = 0
	injuryVisual = 0
	wasAirborne = false
	threatTimer = 0
	threatCached = false
	limpFactor = 0
	staminaVisual = 0
	mantle = nil
	mantleCooldown = 0
	swayX, swayY = 0, 0
	lastCamCF = nil
	footstepPool, footstepIndex = {}, 0
	destroyLoopSounds()
	stepTimer = 0
	heartPhase, heartDubDone = 0, true
	faint = nil
	ragdollData = nil
	ragdollCamCF = nil
	deadHandled = false
	faintTimer = 0
	faintThreshold = nil
	blackTarget = 0
	blackRate = 1 / CONFIG.RESPAWN_FADE_IN
	defaultRunning, defaultRunningVolume = nil, nil
end

-- Each system starts on its own, so one failing never stops the others
local function initCharacter(char)
	safeCall("first-person setup", setupFirstPersonAndBobbing, char)
	task.spawn(safeCall, "gear creation", createClientGears)
	task.spawn(safeCall, "sound setup", setupSounds, char)
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
	resetStateForNewCharacter()
	initCharacter(char)
end))

if LocalPlayer.Character then
	initCharacter(LocalPlayer.Character)
end

-- Test keys: G = pass out right now, H = empty hunger and thirst
if CONFIG.DEBUG_KEYS then
	track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not hum or not root or hum.Health <= 0 then return end

		if input.KeyCode == Enum.KeyCode.G and not faint then
			safeCall("debug faint", startFaint, char, hum, root)
		elseif input.KeyCode == Enum.KeyCode.H then
			hunger, thirst = 0, 0
		end
	end))
end

__toast("loaded OK. Press G to test passing out.")

--------------------------------------------------------------------------------
-- CLEANUP (runs automatically if the script is executed again)
--------------------------------------------------------------------------------
_G.RealismCleanup = function()
	for _, c in ipairs(connections) do c:Disconnect() end
	for _, c in ipairs(charConnections) do c:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)

	for _, inst in ipairs(createdInstances) do
		if inst and inst.Parent then
			-- A pre-existing game Atmosphere is restored below, not destroyed
			if not (atmosphereBackup and inst == atmosphereBackup.inst) then
				inst:Destroy()
			end
		end
	end

	if atmosphereBackup and atmosphereBackup.inst then
		local a = atmosphereBackup.inst
		a.Name = atmosphereBackup.Name
		a.Density = atmosphereBackup.Density
		a.Offset = atmosphereBackup.Offset
		a.Color = atmosphereBackup.Color
		a.Decay = atmosphereBackup.Decay
		a.Glare = atmosphereBackup.Glare
		a.Haze = atmosphereBackup.Haze
	end

	for prop, value in pairs(lightingBackup) do
		Lighting[prop] = value
	end

	for part in pairs(bodyParts) do
		if part and part.Parent then part.LocalTransparencyModifier = 0 end
	end
	if defaultRunning and defaultRunning.Parent and defaultRunningVolume then
		defaultRunning.Volume = defaultRunningVolume
	end
	for grip, base in pairs(gripBase) do
		if grip and grip.Parent then grip.C0 = base end
	end

	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then hum.CameraOffset = Vector3.new(0, 0, 0) end
	if ragdollData then
		for _, inst in ipairs(ragdollData.instances) do
			if inst then inst:Destroy() end
		end
		for _, m in ipairs(ragdollData.motors) do
			if m then m.Enabled = true end
		end
		for part, canCollide in pairs(ragdollData.canCollide) do
			if part and part.Parent then part.CanCollide = canCollide end
		end
		if hum then
			hum.PlatformStand = false
			hum.AutoRotate = ragdollData.autoRotate
			pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true) end)
			hum.RequiresNeck = ragdollData.requiresNeck
		end
		ragdollData = nil
	end
	LocalPlayer.CameraMode = Enum.CameraMode.Classic

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	for _, folder in ipairs({ backpack, char }) do
		if folder then
			for _, item in ipairs(folder:GetChildren()) do
				if item.Name == "Water Bottle" or item.Name == "Food Bar" then
					item:Destroy()
				end
			end
		end
	end

	_G.RealismCleanup = nil
end

end, function(e) return debug.traceback(tostring(e), 2) end)

if not __ok then
	__toast("SCRIPT CRASHED: " .. string.match(tostring(__err), "^[^\n]*"))
	warn(__err)
end
