-- Realism LocalScript (single-file, client-only)
-- Executor-friendly: progress and errors also appear as on-screen notifications,
-- so you don't need to find the console.
-- v2: added BLEEDING (+ Bandage tool) and WEATHER (rain, wet screen, puddles, lightning)
-- v3: added TEMPERATURE (+ Campfire tool) and FALL INJURIES (stumble, sprained ankle, knockdown)
-- v4: longer sprint, STANCES (crouch / sit / crawl button), randomized weather, new HUD
-- v7: LIGHTNING BOLTS, per-drop rain occlusion (rain outside windows, not inside rooms), rain on water
-- v6: WATER (terrain water look, splashes, ripples, wake, underwater)
-- v5: SKY (twilight palette, stars, sun/moon size, clouds, storm clouds)
-- v4 stance fix: real leg geometry, torso leans about the hips, camera follows the real head
-- v8: EYES (blinking, squinting at the sun), lightning-squircle test menu (all test buttons live in it now)
-- v8.2: stances use real custom animations (Action4) and a shrinking hitbox; joint poses stay as a fallback

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

-- Many executors leave Lua's random generator unseeded, which made the weather start at the
-- same moment every time. Seed it, and give the weather its own Random object as well.
math.randomseed(os.time() + math.floor(os.clock() * 100000))

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
	STAMINA_DRAIN_RATE = 5,         -- stamina/sec while sprinting (5 = a 20 second sprint from full)
	STAMINA_FITNESS_BONUS = 0.4,    -- at max leg strength your sprint drains this much slower (0.4 = 40%)
	STAMINA_REGEN_RATE = 12,        -- stamina/sec recovered while standing still
	STAMINA_REGEN_WALK = 1,         -- stamina/sec recovered while walking (very slow)
	SPRINT_RESUME_THRESHOLD = 20,
	ADRENALINE_STAMINA_DRAIN_MULT = 0,

	-- Stances: the STANCE button (or the C key) cycles Stand > Crouch > Sit > Crawl.
	-- Angles are in degrees, measured against the WORLD:
	--   thigh / thighR: leg angle from hanging straight down. 90 = leg straight out forward, negative = trailing behind.
	--   knee: how far the knee is folded (R15 only, R6 legs are rigid).
	--   pitch: torso lean forward from the hips (90 = lying flat on your stomach).
	--   head: how far the head still tilts forward (0 = looking level).
	--   arm: arm angle from hanging down (90 = arms straight out forward).
	--   hipY: height of the hip joint above the ground in studs (leave out to work it out from the leg bend).
	--   flat: 1 = feet stay flat on the ground, 0 = feet follow the leg (toes down when crawling).
	--   armSwing / legSwing: how far arms and legs move while you walk in that stance.
	--   speed: walk speed multiplier (0 = can't move). quiet: footstep volume multiplier.
	--   hit: hitbox height as a fraction of standing (the HumanoidRootPart shrinks, head and torso follow the pose).
	--   r6 = { ... }: values that replace the ones above for R6 avatars (rigid legs, so crouch becomes a lunge).
	ENABLE_STANCES = true,
	STANCE_KEY = Enum.KeyCode.C,
	STANCE_BLEND_SPEED = 5,         -- how quickly the body height and hitbox move between stances
	STANCE_FADE = 0.25,             -- seconds to blend between stance animations
	STANCE_ANIMATIONS = true,       -- play real animations for each stance (falls back to joint poses if they won't load)
	STANCE_HITBOX = true,           -- shrink the hitbox with the pose
	STANCE_GAIT_RATE = 2.2,         -- arm / leg swing speed in the joint-pose fallback
	STANCE_GAIT_STRIDE = 3,         -- studs you travel per walking-animation cycle (higher = slower stepping)
	STANCE_ANIM_DAMP = 0.9,         -- joint-pose fallback only: how much of the default animation is faded out
	MIN_HIP_HEIGHT = 0,             -- lowest HipHeight a stance may use; anything lower slides the body down instead
	STANCES = {
		stand  = {},
		crouch = { thigh = 105, knee = 145, pitch = 20, head = 0, arm = 30, armSwing = 10, legSwing = 12,
			hit = 0.65, speed = 0.5, quiet = 0.45,
			r6 = { thigh = 62, thighR = -62, knee = 0, pitch = 25, legSwing = 0 } },
		sit    = { thigh = 140, knee = 80, pitch = 10, head = 0, arm = 40, hit = 0.45, speed = 0, quiet = 0,
			r6 = { thigh = 90, knee = 0, pitch = 12, hipY = 0.5 } },
		crawl  = { thigh = -90, knee = 0, pitch = 90, head = 45, arm = 90, hipY = 0.55, flat = 0,
			armSwing = 30, legSwing = -15, hit = 0.25, speed = 0.25, quiet = 0.2 },
	},

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

	-- Temperature: cold at night, heat at noon. Shade, roofs and fires help.
	ENABLE_TEMPERATURE = true,
	TEMP_ADJUST_RATE = 0.04,       -- how fast your body temperature follows your surroundings
	TEMP_HOT_THIRST = 1.2,         -- extra thirst drain at full heat (+120%)
	TEMP_COLD_HUNGER = 0.8,        -- extra hunger drain at full cold (+80%)
	TEMP_REGEN_PENALTY = 0.5,      -- stamina regen lost at full cold or full heat
	TEMP_HOT_SPRINT_DRAIN = 0.4,   -- extra sprint stamina drain at full heat
	TEMP_SHADE_RELIEF = 0.65,      -- share of the heat blocked in shade or under a roof
	TEMP_FIRE_RADIUS = 20,         -- a lit Fire object (yours or the game's) warms you inside this range (studs)
	TEMP_FIRE_HEAT = 1.0,          -- how much a fire at point-blank range raises your temperature
	TEMP_DAMAGE_START = 0.9,       -- freezing / overheating starts to hurt beyond this (0 to 1)
	TEMP_DAMAGE_RATE = 0.25,       -- health per second at the very extreme
	TEMP_VIGNETTE_MAX = 0.5,       -- frost / heat glow strength at the screen edges
	CAMPFIRE_LIFETIME = 240,       -- seconds a campfire you light keeps burning
	CAMPFIRE_COOLDOWN = 2,
	COLD_TINT = Color3.fromRGB(190, 215, 255),
	HOT_TINT = Color3.fromRGB(255, 215, 170),
	COLD_COLOR = Color3.fromRGB(110, 190, 255),
	HEAT_COLOR = Color3.fromRGB(255, 140, 60),

	-- Fall injuries (landing speed in studs/sec; an ordinary jump lands at about 50)
	FALL_STUMBLE_SPEED = 62,       -- hard landing: you stagger
	STUMBLE_MIN_TIME = 0.5,        -- stagger length (grows with the fall)
	STUMBLE_MAX_TIME = 1.6,
	STUMBLE_SLOWDOWN = 0.5,        -- how much slower you move at the start of a stagger
	STUMBLE_STAMINA_COST = 20,
	FALL_SPRAIN_SPEED = 80,        -- harder landing: sprained ankle, you limp for a while
	SPRAIN_MIN_TIME = 15,          -- seconds of limping (grows with the fall)
	SPRAIN_MAX_TIME = 60,
	FALL_KNOCKDOWN_SPEED = 115,    -- brutal landing: you are thrown to the ground for a moment
	KNOCKDOWN_MIN_TIME = 1.5,
	KNOCKDOWN_MAX_TIME = 2.5,

	-- Bleeding: a big hit can start a slow health drain that only a Bandage stops
	BLEED_HIT_FRACTION = 0.12,     -- one hit must take at least this fraction of max health
	BLEED_DRAIN_MIN = 0.5,         -- health/sec from the lightest bleed
	BLEED_DRAIN_MAX = 2.5,         -- health/sec from the worst bleed
	BANDAGE_USE_TIME = 3,          -- seconds to wrap the wound (keep the Bandage equipped)
	BANDAGE_MOVE_MULT = 0.75,      -- walk speed multiplier while wrapping
	BLOOD_DROP_RATE = 0,           -- blood drips on the screen per second at the worst bleed (0 = off)
	ENABLE_BLOOD_POOLS = true,     -- leave blood on the ground behind you while you bleed
	BLOOD_MAX_POOLS = 80,          -- oldest blood is removed past this many (keeps it light)
	BLOOD_POOL_MAX = 3.5,          -- widest a pool can spread while you stand still (studs)

	-- Adrenaline System
	THREAT_RADIUS = 40,
	THREAT_REQUIRE_ON_SCREEN = true,
	THREAT_CHECK_INTERVAL = 0.15, -- seconds between threat scans (saves raycasts)
	-- Tools that do NOT count as weapons (add flashlights, build tools, etc.)
	THREAT_IGNORE_TOOLS = {
		["Water Bottle"] = true,
		["Food Bar"] = true,
		["Bandage"] = true,
		["Campfire"] = true,
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

	-- Weather (random rain showers that come and go; every shower ends on its own)
	ENABLE_WEATHER = true,
	CLEAR_MIN_TIME = 90,           -- seconds of dry weather between showers (random min/max)
	CLEAR_MAX_TIME = 300,
	RAIN_MIN_TIME = 45,            -- how long a shower lasts (random min/max)
	RAIN_MAX_TIME = 150,
	RAIN_MIN_INTENSITY = 0.4,      -- each shower picks a strength between this and 1
	RAIN_FADE_TIME = 12,           -- seconds to fade a shower in or out
	FIRST_RAIN_MIN = 20,           -- the first shower after you run the script starts after this many seconds (random min/max)
	FIRST_RAIN_MAX = 240,
	START_RAINING_CHANCE = 0.15,   -- chance it is ALREADY raining when you run the script
	STORM_BUTTON_MIN = 45,         -- a storm you start with the STORM button / K key lasts this long (random min/max)
	STORM_BUTTON_MAX = 90,
	RAIN_STREAKS = 240,            -- 3D raindrops around you at full intensity (halved automatically on touch devices)
	RAIN_RADIUS = 28,              -- how far around you the rain falls (studs)
	RAIN_SPEED = 65,               -- fall speed (studs/sec)
	RAIN_LENGTH = 4,               -- length of each streak (studs)
	RAIN_SLANT = -0.12,            -- wind slant (negative = blows left, 0 = straight down)
	RAIN_PARTICLES = false,        -- optional 3D particle rain (only looks right with a good RAIN_TEXTURE)
	TEST_BUTTONS = true,           -- the lightning squircle that opens the test menu (BLEED, STORM, NIGHT, NOON, FALL, BLINK)
	RAIN_DARKEN = 0.35,            -- how much rain dims the daylight (0 = none)
	RAIN_AREA = 70,                -- width of the rain curtain around you (studs)
	RAIN_HEIGHT = 30,              -- how far above your head the rain starts
	RAIN_RATE_MAX = 700,           -- raindrops per second at full intensity
	-- Texture of one raindrop particle. Swap in a streak texture ID for nicer rain.
	RAIN_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds",
	SHELTER_CHECK_HEIGHT = 80,     -- a solid, collidable roof within this height above you counts as shelter
	SCREEN_DROP_POOL = 28,         -- max water/blood drops on the screen at once
	RAIN_DROP_RATE = 7,            -- new water drops per second at full rain (outdoors)
	-- Looped rain sound + thunder: the first ID in each list that loads is used.
	-- Nothing plays until you paste working rbxassetid:// IDs here (rain still looks fine).
	RAIN_SOUND_IDS = {
		-- "rbxassetid://YOUR_RAIN_LOOP_ID",
	},
	THUNDER_SOUND_IDS = {
		-- "rbxassetid://YOUR_THUNDER_ID",
	},
	RAIN_MAX_VOLUME = 0.6,
	RAIN_INDOOR_MUFFLE = 22,       -- how much the rain is dulled under a roof (dB cut on highs)
	THUNDER_VOLUME = 1,
	-- Puddle splash for wet-ground footsteps. One ID, ideally a single splashy step.
	PUDDLE_SOUND_ID = "",          -- e.g. "rbxassetid://YOUR_PUDDLE_STEP_ID"
	PUDDLE_STEPS_IN_FILE = 1,      -- raise if the clip contains several steps (see footsteps below)
	-- Lightning (only in heavy rain)
	ENABLE_LIGHTNING = true,
	LIGHTNING_MIN_RAIN = 0.75,     -- rain strength needed before lightning can strike
	LIGHTNING_MIN_GAP = 8,         -- seconds between strikes (random min/max)
	LIGHTNING_MAX_GAP = 25,
	LIGHTNING_BOLTS = true,        -- draw visible bolts in the sky
	BOLT_MIN_DIST = 120,           -- how far away bolts can strike (studs). Fog hides far ones, so lower BOLT_MAX_DIST if they look faint
	BOLT_MAX_DIST = 480,
	LIGHTNING_EXPOSURE = 3,        -- how blown-out the screen gets at the flash peak

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
		"rbxassetid://139826397745716",
	},
	-- Used when no heartbeat loop above loads: a built-in thump played on every beat
	HEARTBEAT_FALLBACK_ID = "rbxasset://sounds/bass.wav",
	RING_SOUND_IDS = {
		"rbxassetid://9069161602",
		"rbxasset://sounds/electronicpingshort.wav", -- built-in placeholder; put a real tinnitus loop above it
	},
	DEBUG_KEYS = true,             -- G = pass out, H = empty hunger + thirst, J = start bleeding, K = toggle storm
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
	BLEED_COLOR = Color3.fromRGB(150, 20, 35),
	BANDAGE_COLOR = Color3.fromRGB(235, 232, 220),
}

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------
local randRange
do
	local rng = Random.new()
	randRange = function(a, b)
		return rng:NextNumber(a, b)
	end
end

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
local puddlePool, puddleIndex = {}, 0
local breathSound, heartSound, ringSound, thumpSound = nil, nil, nil, nil
local stepTimer, stepRate = 0, 2
local defaultRunning, defaultRunningVolume = nil, nil
local heartPhase, heartDubDone = 0, true
local soundGen = 0

local ragdollData = nil      -- declared up here so the render-step closure can see it
local ragdollCamCF = nil

-- Bleeding
local bleedSeverity = 0      -- 0 = not bleeding, 1 = worst bleed
local bandaging = false
local bandageStart = 0
local bandageToken = 0       -- bumped to cancel an in-progress bandage

-- Assigned further down (they need helpers that are defined later in the file)
local placeCampfire = nil
local runFallTest = nil

-- Temperature (everything in one table)
local temp = {
	body = 0,                -- -1 freezing .. 0 comfortable .. 1 overheating
	shade = 0,
	shadeTarget = 0,
	fire = 0,                -- 0..1 warmth from the nearest fire
	timer = 0,
	fires = {},              -- every Fire object in the world
	campfire = nil,          -- the campfire you lit: { folder, fire, light, embers, born }
	campfireUsed = -100,
	warned = -100,
}

-- Fall injuries
local fall = {
	stumbleT = 0, stumbleDur = 1, dir = 1, roll = 0,
	sprainLeft = 0, sprainStrength = 0,
	knock = nil,             -- { t, dur, look } while you're knocked down
}

-- Stances (everything in one table; its functions are defined in section 3c).
-- Kept in a table on purpose: Luau allows at most 200 local variables in one scope and
-- this script was already close to that limit.
local stance = {
	mode = "stand",
	order = { "stand", "crouch", "sit", "crawl" },
	ready = false,
	char = nil,
	r15 = false,
	joints = {},             -- [key] = { motor, base }
	defs = {},               -- resolved poses for this avatar
	pivot = Vector3.zero,    -- hip pivot in HumanoidRootPart space
	upper = 1, lower = 1, foot = 0.3,
	baseHip = 2,
	baseJumpPower = 50,
	baseJumpHeight = 7.2,
	phase = 0,
	moving = 0,
	dirty = false,           -- true while any pose is applied
	lastCam = Vector3.zero,  -- the CameraOffset we set last frame
	baseSize = Vector3.new(2, 2, 1), -- standing HumanoidRootPart size
	rootName = "HumanoidRootPart",
	tree = {},               -- [partName] = { motors that hang off that part }
	motorKey = {},           -- [motor] = joint key
	tracks = {},             -- [mode] = { idle = AnimationTrack, move = AnimationTrack or nil }
	playing = nil,
	playedAt = 0,
	useAnim = false,         -- true when the custom animations load
	cur = { thigh = 0, thighR = 0, knee = 0, pitch = 0, head = 0, arm = 0, flat = 1, drop = 0,
		armSwing = 0, legSwing = 0, speed = 1, quiet = 1, amount = 0, hip = 2, camDrop = 0, hit = 1 },
	button = nil,
	lastLabel = nil,
}

-- Weather (everything in one table)
local weather = {
	rain = 0,                -- current rain strength 0..1 (fades toward target)
	target = 0,
	timer = randRange(CONFIG.FIRST_RAIN_MIN, CONFIG.FIRST_RAIN_MAX), -- seconds until the first shower
	sheltered = 0,           -- 0 = open sky above you, 1 = roof overhead
	shelterTarget = 0,
	shelterTimer = 0,
	wet = 0,                 -- how soaked the ground is 0..1
	flash = 0,               -- current lightning brightness 0..1
	lightning = nil,         -- active strike state, nil when idle
	lightningTimer = randRange(CONFIG.LIGHTNING_MIN_GAP, CONFIG.LIGHTNING_MAX_GAP),
	rainSound = nil,
	rainEQ = nil,
	thunderSound = nil,
	part = nil,              -- invisible part that follows the camera and emits rain
	emitter = nil,
}

-- Sometimes the script starts in the middle of a shower
if randRange(0, 1) < CONFIG.START_RAINING_CHANCE then
	weather.target = randRange(CONFIG.RAIN_MIN_INTENSITY, 1)
	weather.rain = weather.target
	weather.wet = 0.5
	weather.timer = randRange(CONFIG.RAIN_MIN_TIME, CONFIG.RAIN_MAX_TIME)
end

--------------------------------------------------------------------------------
-- EYES (blinking + squinting against the sun)
--------------------------------------------------------------------------------
-- One table = one local variable. The two black eyelids are Frames that close in from the top
-- and bottom of the screen; the HUD (DisplayOrder 10) stays on top of them.
local eyes = {
	frames = nil,
	closure = 0,        -- how shut the eyes are right now (0 open .. 1 closed)
	squint = 0,         -- the sun part of it
	blinkT = nil,       -- seconds into the current blink, nil when not blinking
	blinkDur = 0.2,
	pending = 0,        -- queued extra blinks (double blink)
	timer = randRange(2, 5),
}

eyes.blink = function(double)
	if eyes.blinkT then return end
	eyes.blinkT = 0
	eyes.blinkDur = randRange(0.16, 0.24)
	eyes.pending = double and 1 or 0
end

eyes.reset = function()
	eyes.blinkT, eyes.pending = nil, 0
	eyes.squint, eyes.closure = 0, 0
	eyes.timer = randRange(2, 5)
end

eyes.create = function()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("RealismEyelids")
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = "RealismEyelids"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5 -- over the world, under the HUD
	gui.Parent = playerGui

	local function lid(name, anchorY, rot)
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.new(0, 0, anchorY, 0)
		f.Size = UDim2.new(1, 0, 0, 0)
		f.BackgroundColor3 = Color3.fromRGB(10, 6, 6)
		f.BorderSizePixel = 0
		f.Visible = false
		f.Parent = gui

		local g = Instance.new("UIGradient") -- soft edge where the lid meets the view
		g.Rotation = rot
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.82, 0),
			NumberSequenceKeypoint.new(1, 0.6),
		})
		g.Parent = f
		return f
	end

	local full = Instance.new("Frame") -- seals the last gap when the eyes are fully shut
	full.Name = "Full"
	full.Size = UDim2.new(1, 0, 1, 0)
	full.BackgroundColor3 = Color3.fromRGB(10, 6, 6)
	full.BackgroundTransparency = 1
	full.BorderSizePixel = 0
	full.Visible = false
	full.Parent = gui

	eyes.frames = { top = lid("Top", 0, 90), bottom = lid("Bottom", 1, 270), full = full }
end

eyes.update = function(dt)
	local e = eyes
	local f = e.frames
	if not f then return end

	-- Squint: how directly you face the sun (sunGlare is already 0 behind clouds and walls)
	-- times how strong the sun is (a low sun squints you less than a noon sun).
	-- 0.9 is the most the eyes close from light alone: a thin slit, basically shut.
	local power = 0.45 + 0.55 * math.clamp(Lighting:GetSunDirection().Y / 0.6, 0, 1)
	local target = (math.clamp(sunGlare * power, 0, 1) ^ 0.85) * 0.9
	e.squint = e.squint + (target - e.squint) * math.clamp(dt * (target > e.squint and 9 or 3), 0, 1)

	local droop = staminaVisual * 0.16 -- heavy lids when winded

	-- Blinking: more often when tired, less often with adrenaline
	local blinkAmt = 0
	if e.blinkT then
		e.blinkT = e.blinkT + dt
		local p = e.blinkT / e.blinkDur
		if p >= 1 then
			if e.pending > 0 then
				e.pending = e.pending - 1
				e.blinkT = 0
				e.blinkDur = randRange(0.14, 0.2)
			else
				e.blinkT = nil
				e.timer = randRange(2.5, 6) * (1 - 0.45 * staminaVisual) * (1 + 0.6 * adrenaline / 100)
			end
		else
			local x = p < 0.4 and p / 0.4 or (1 - p) / 0.6 -- shuts fast, opens slower
			blinkAmt = x * x * (3 - 2 * x)
		end
	elseif not (faint or ragdollData or fall.knock) then
		e.timer = e.timer - dt
		if e.timer <= 0 then eyes.blink(math.random() < 0.15) end -- now and then a double blink
	end

	-- A blink closes whatever gap the squint left open
	local base = math.max(e.squint, droop)
	local closure = base + (1 - base) * blinkAmt
	e.closure = closure

	if closure < 0.004 then
		f.top.Visible, f.bottom.Visible, f.full.Visible = false, false, false
	else
		f.top.Visible, f.bottom.Visible = true, true
		f.top.Size = UDim2.new(1, 0, closure * 0.56, 0)
		f.bottom.Size = UDim2.new(1, 0, closure * 0.46, 0)
		local seal = math.clamp((closure - 0.9) / 0.1, 0, 1)
		f.full.Visible = seal > 0
		f.full.BackgroundTransparency = 1 - seal
	end
end

safeCall("eyes setup", eyes.create)

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
				stance.lastCam = Vector3.zero
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
				-- In a stance the camera moves to the real head position (see stance.cameraOffset)
				humanoid.CameraOffset = stance.cameraOffset(character, hrp, Vector3.new(bobX, bobY + landingOffset, -CONFIG.CAMERA_FORWARD_OFFSET))

				-- Strafe tilt
				local relativeVel = hrp.CFrame:VectorToObjectSpace(flatVelocity)
				local strafeSpeed = relativeVel.X
				local targetRoll = math.rad(-strafeSpeed / math.max(humanoid.WalkSpeed, 1) * CONFIG.SWAY_TILT_ANGLE)

				currentRoll = currentRoll + (targetRoll - currentRoll) * math.clamp(deltaTime * 10, 0, 1)
				updateHandSway(deltaTime, character, moveSpeed, humanoid.WalkSpeed)
				stance.apply(deltaTime, character, humanoid)

				Camera.CFrame = Camera.CFrame * CFrame.Angles(0, 0, currentRoll + fall.roll)
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
-- 2. CLIENT-SIDED GEAR CREATION (WATER BOTTLE, FOOD BAR & BANDAGE)
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

local function buildBandage()
	local tool = Instance.new("Tool")
	tool.Name = "Bandage"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Hold to stop bleeding"

	-- Invisible grip block; the roll is welded to it
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 0.9, 0.5)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local gauze = Color3.fromRGB(238, 234, 222)
	cyl(tool, handle, "Roll", 0, 0.6, 0.9, gauze, Enum.Material.Fabric, 0)
	cyl(tool, handle, "RollCore", 0, 0.64, 0.28, Color3.fromRGB(150, 130, 100), Enum.Material.SmoothPlastic, 0)
	cyl(tool, handle, "RollStripe", 0, 0.12, 0.92, Color3.fromRGB(190, 40, 40), Enum.Material.Fabric, 0)

	-- Loose end hanging off the side of the roll
	addVisual(tool, handle, "Tail", Enum.PartType.Block, Vector3.new(0.03, 0.5, 0.4),
		CFrame.new(0.46, -0.3, 0), gauze, Enum.Material.Fabric, 0)

	return tool
end

local function buildCampfireKit()
	local tool = Instance.new("Tool")
	tool.Name = "Campfire"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Click to light a campfire ahead of you"

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 1.2, 0.6)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	-- A small bundle of firewood tied with twine
	local wood = Color3.fromRGB(110, 72, 42)
	for i, x in ipairs({ -0.18, 0, 0.18 }) do
		addVisual(tool, handle, "Log" .. i, Enum.PartType.Cylinder, Vector3.new(1.2, 0.26, 0.26),
			CFrame.new(x, 0, (i - 2) * 0.05) * UPRIGHT, wood, Enum.Material.Wood, 0)
	end
	cyl(tool, handle, "Twine", 0.1, 0.1, 0.66, Color3.fromRGB(200, 180, 130), Enum.Material.Fabric, 0)

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

local GEAR_NAMES = { ["Water Bottle"] = true, ["Food Bar"] = true, ["Bandage"] = true, ["Campfire"] = true }

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
				if GEAR_NAMES[item.Name] then
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

	-- Bandage: click to start wrapping; keep it equipped until the bar empties.
	-- Unequipping mid-wrap cancels it and the bleeding continues.
	local bandageTool = safeBuild(buildBandage, "Bandage", "Hold to stop bleeding", Color3.fromRGB(238, 234, 222))
	bandageTool.Activated:Connect(function()
		if bandaging or bleedSeverity <= 0 then return end
		bandaging = true
		bandageStart = os.clock()
		bandageToken = bandageToken + 1
		local token = bandageToken
		task.delay(CONFIG.BANDAGE_USE_TIME, function()
			if token ~= bandageToken or not bandaging then return end
			bandaging = false
			bleedSeverity = 0
		end)
	end)
	bandageTool.Unequipped:Connect(function()
		bandageToken = bandageToken + 1
		bandaging = false
	end)
	bandageTool.Parent = backpack

	-- Campfire: click to light one ahead of you (warms you, lights up the night)
	local campTool = safeBuild(buildCampfireKit, "Campfire", "Click to light a campfire ahead of you", Color3.fromRGB(110, 72, 42))
	campTool.Activated:Connect(function()
		if os.clock() - temp.campfireUsed < CONFIG.CAMPFIRE_COOLDOWN then return end
		temp.campfireUsed = os.clock()
		if placeCampfire then placeCampfire() end
	end)
	campTool.Parent = backpack
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
-- 3b. ON-SCREEN NOTICES & QUICK ACTIONS
--------------------------------------------------------------------------------
local noticeLabel
do
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("RealismNotice")
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = "RealismNotice"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 500
	gui.Parent = playerGui

	noticeLabel = Instance.new("TextLabel")
	noticeLabel.AnchorPoint = Vector2.new(0.5, 0)
	noticeLabel.Position = UDim2.new(0.5, 0, 0.12, 0)
	noticeLabel.Size = UDim2.new(0.8, 0, 0, 30)
	noticeLabel.BackgroundTransparency = 1
	noticeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	noticeLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	noticeLabel.TextTransparency = 1
	noticeLabel.TextStrokeTransparency = 1
	noticeLabel.Font = Enum.Font.GothamBold
	noticeLabel.TextSize = 18
	noticeLabel.Text = ""
	noticeLabel.Parent = gui
end

local noticeToken = 0
local function showNotice(text)
	noticeToken = noticeToken + 1
	local token = noticeToken
	noticeLabel.Text = text
	noticeLabel.TextTransparency = 0
	noticeLabel.TextStrokeTransparency = 0.4
	task.delay(3.5, function()
		if token ~= noticeToken then return end
		noticeLabel.TextTransparency = 1
		noticeLabel.TextStrokeTransparency = 1
	end)
end

local function toggleStorm()
	if weather.target > 0 then
		weather.target = 0
		showNotice("The rain is clearing")
	else
		weather.target = 1
		weather.lightningTimer = math.min(weather.lightningTimer, 3)
		showNotice("A storm is rolling in")
	end
	-- A storm you start by hand runs for a while and then ends by itself
	weather.timer = randRange(CONFIG.STORM_BUTTON_MIN, CONFIG.STORM_BUTTON_MAX)
end

local function forceBleed()
	bleedSeverity = 0.7
	showNotice("You're bleeding - equip the Bandage and click")
end

--------------------------------------------------------------------------------
-- 3c. STANCES (stand / crouch / sit / crawl)
--------------------------------------------------------------------------------
-- How the poses work (R15 and R6):
--  * The torso leans about the HIPS, the legs bend so the feet stay on the ground, and the
--    arms and head are posed to match. Only your own client sees the pose.
--  * Body height comes from the leg bend (HipHeight). When a pose needs the body lower than
--    HipHeight 0 allows (sitting, R6 avatars), the body is slid down on its root joint instead.
--  * Roblox's default camera follows the HumanoidRootPart, NOT your head, so lowering the body
--    never lowered the view. stance.cameraOffset puts the camera at the real head position.
--  * Each stance is a real custom animation (a KeyframeSequence built in code from the pose maths),
--    played at Action4 priority, with a walking loop for crouch and crawl. If the game won't play
--    code-made animations, the joints are posed directly instead (see stance.apply).
--  * The hitbox shrinks with the pose (HumanoidRootPart height), and the head / torso colliders
--    follow the animation, so crawling really is low and sitting really is small.

stance.keys = { "thigh", "thighR", "knee", "pitch", "head", "arm", "flat", "drop", "armSwing", "legSwing", "speed", "quiet", "hit" }
stance.defaults = { thigh = 0, knee = 0, pitch = 0, head = 0, arm = 0, flat = 1, drop = 0, armSwing = 0, legSwing = 0, speed = 1, quiet = 1, hit = 1 }

-- Rotates a joint's C0 about a pivot point (default: the joint itself), in the parent part's space
stance.rotatedC0 = function(base, rotation, pivot)
	local p = pivot or base.Position
	return CFrame.new(p) * rotation * CFrame.new(-p) * base
end

-- Height of the hip joint above the ground for a given leg bend (feet flat on the floor)
stance.reach = function(thighDeg, kneeDeg)
	local a = math.rad(thighDeg)
	local k = math.rad(kneeDeg)
	return stance.upper * math.cos(a) + stance.lower * math.cos(a - k) + stance.foot
end

stance.resetCur = function()
	local c = stance.cur
	c.thigh, c.thighR, c.knee, c.pitch, c.head, c.arm = 0, 0, 0, 0, 0, 0
	c.flat, c.drop, c.armSwing, c.legSwing, c.hit = 1, 0, 0, 0, 1
	c.speed, c.quiet, c.amount, c.camDrop = 1, 1, 0, 0
	c.hip = stance.baseHip
end

-- The pose for one set of values: returns { jointKey = new C0 }. Used both to build the
-- custom animations and (as a fallback) to pose the joints directly.
-- a1 / a2 (0..1) are the two halves of the walking swing (left leg / right leg).
stance.pose = function(v, a1, a2)
	local lean = math.rad(v.pitch)
	local thL = v.thigh + v.legSwing * a1
	local thR = v.thighR + v.legSwing * a2
	local arL = v.arm + v.armSwing * a2 -- each arm moves with the opposite leg
	local arR = v.arm + v.armSwing * a1
	local j = stance.joints
	local out = {}

	local function put(key, rotation, pivot)
		local joint = j[key]
		if joint and joint.motor.Parent then
			out[key] = stance.rotatedC0(joint.base, rotation, pivot)
		end
	end

	-- Torso: lean about the hips, and slide down if HipHeight can't go low enough
	local rootJoint = j.root
	if rootJoint and rootJoint.motor.Parent then
		out.root = CFrame.new(0, -v.drop, 0)
			* stance.rotatedC0(rootJoint.base, CFrame.Angles(-lean, 0, 0), stance.pivot)
	end

	-- Angles are world angles, so the torso lean is added back on top
	put("lHip", CFrame.Angles(math.rad(thL) + lean, 0, 0))
	put("rHip", CFrame.Angles(math.rad(thR) + lean, 0, 0))
	if stance.r15 then
		local knee = CFrame.Angles(-math.rad(v.knee), 0, 0)
		put("lKnee", knee)
		put("rKnee", knee)
		-- Ankles cancel the leg angle so the soles stay flat on the ground (flat = 1)
		put("lAnkle", CFrame.Angles(math.rad(v.flat * (v.knee - thL)), 0, 0))
		put("rAnkle", CFrame.Angles(math.rad(v.flat * (v.knee - thR)), 0, 0))
	end
	put("lShoulder", CFrame.Angles(math.rad(arL) + lean, 0, 0))
	put("rShoulder", CFrame.Angles(math.rad(arR) + lean, 0, 0))
	put("neck", CFrame.Angles(lean - math.rad(v.head), 0, 0))
	return out
end

-- Adds one Pose per joint under `parent`, following the rig's real joint tree.
-- Joints we don't control get an identity pose, so the walk / idle animation can't leak through.
stance.addPoses = function(parent, partName, c0s)
	for _, motor in ipairs(stance.tree[partName] or {}) do
		local pose = Instance.new("Pose")
		pose.Name = motor.Part1.Name
		local key = stance.motorKey[motor]
		local c0 = key and c0s[key]
		if c0 then
			pose.CFrame = stance.joints[key].base:Inverse() * c0 -- Pose = the joint's Transform
		end
		pose.Weight = 1
		pose.Parent = parent
		stance.addPoses(pose, motor.Part1.Name, c0s)
	end
end

-- Registers a KeyframeSequence made in code, so it can be played like an uploaded animation
stance.register = function(ks)
	local id = nil
	pcall(function()
		id = game:GetService("AnimationClipProvider"):RegisterAnimationClip(ks)
	end)
	if not id then
		pcall(function()
			id = game:GetService("KeyframeSequenceProvider"):RegisterKeyframeSequence(ks)
		end)
	end
	return id
end

-- Builds one looping animation. frames = { { time, a1, a2 }, ... }
stance.makeTrack = function(animator, name, frames, def)
	local ok, track = pcall(function()
		local ks = Instance.new("KeyframeSequence")
		ks.Name = "Realism" .. name
		ks.Loop = true
		ks.Priority = Enum.AnimationPriority.Action4
		for _, f in ipairs(frames) do
			local kf = Instance.new("Keyframe")
			kf.Time = f[1]
			local rootPose = Instance.new("Pose")
			rootPose.Name = stance.rootName
			rootPose.Weight = 0
			rootPose.Parent = kf
			stance.addPoses(rootPose, stance.rootName, stance.pose(def, f[2], f[3]))
			kf.Parent = ks
		end

		local id = stance.register(ks)
		if not id then return nil end
		local anim = Instance.new("Animation")
		anim.Name = "RealismStance" .. name
		anim.AnimationId = id
		local t = animator:LoadAnimation(anim)
		t.Priority = Enum.AnimationPriority.Action4
		t.Looped = true
		return t
	end)
	if ok then return track end
	return nil
end

-- One idle animation per stance, plus a walking loop for stances with armSwing / legSwing
stance.buildTracks = function(humanoid)
	stance.tracks = {}
	stance.playing = nil
	stance.useAnim = false
	if not CONFIG.STANCE_ANIMATIONS then return end

	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 3)
	if not animator then return end

	local need, got = 0, 0
	for mode, def in pairs(stance.defs) do
		if mode ~= "stand" then
			need = need + 1
			local idle = stance.makeTrack(animator, mode .. "Idle", { { 0, 0.5, 0.5 }, { 1, 0.5, 0.5 } }, def)
			local move = nil
			if def.armSwing ~= 0 or def.legSwing ~= 0 then
				move = stance.makeTrack(animator, mode .. "Move", { { 0, 1, 0 }, { 0.5, 0, 1 }, { 1, 1, 0 } }, def)
			end
			if idle then
				got = got + 1
				stance.tracks[mode] = { idle = idle, move = move }
			end
		end
	end
	stance.useAnim = need > 0 and got == need
end

-- Puts every joint, the hip height, the hitbox, the jump and the animations back exactly as they were
stance.restore = function()
	local wasActive = stance.dirty

	for _, j in pairs(stance.joints) do
		if j.motor and j.motor.Parent then j.motor.C0 = j.base end
	end

	if stance.playing then
		pcall(function() stance.playing:Stop(0.2) end)
		stance.playing = nil
	end

	local char = stance.char
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and stance.ready and wasActive then
		if hrp then hrp.Size = stance.baseSize end
		hum.HipHeight = stance.baseHip
		hum.JumpPower = stance.baseJumpPower
		hum.JumpHeight = stance.baseJumpHeight
		local animator = hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				if not string.find(track.Name, "^RealismStance") then
					track:AdjustWeight(1, 0)
				end
			end
		end
	end

	stance.mode = "stand"
	stance.dirty = false
	stance.moving = 0
	stance.lastCam = Vector3.zero
	stance.resetCur()
end

-- Reads the avatar's joints and leg lengths, works out every pose, and builds the animations
stance.setup = function(char)
	stance.ready = false
	stance.char = char
	stance.joints = {}
	stance.defs = {}
	stance.tree, stance.motorKey = {}, {}
	stance.tracks, stance.playing, stance.useAnim = {}, nil, false
	stance.phase = 0
	stance.moving = 0
	stance.dirty = false
	stance.lastCam = Vector3.zero

	local humanoid = char:WaitForChild("Humanoid", 5)
	if not humanoid then return end
	stance.r15 = humanoid.RigType == Enum.HumanoidRigType.R15

	local names
	if stance.r15 then
		for _, n in ipairs({ "LowerTorso", "UpperTorso", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
			"RightUpperLeg", "RightLowerLeg", "RightFoot", "LeftUpperArm", "RightUpperArm", "Head" }) do
			char:WaitForChild(n, 5)
		end
		names = { root = "RootJoint", lHip = "LeftHip", rHip = "RightHip", lKnee = "LeftKnee", rKnee = "RightKnee",
			lAnkle = "LeftAnkle", rAnkle = "RightAnkle", lShoulder = "LeftShoulder", rShoulder = "RightShoulder", neck = "Neck" }
	else
		for _, n in ipairs({ "Torso", "Left Leg", "Right Leg", "Left Arm", "Right Arm", "Head" }) do
			char:WaitForChild(n, 5)
		end
		names = { root = "RootJoint", lHip = "Left Hip", rHip = "Right Hip",
			lShoulder = "Left Shoulder", rShoulder = "Right Shoulder", neck = "Neck" }
	end

	local j = stance.joints
	for key, name in pairs(names) do
		local motor = char:FindFirstChild(name, true)
		if motor and motor:IsA("Motor6D") then
			j[key] = { motor = motor, base = motor.C0 }
			stance.motorKey[motor] = key
		end
	end

	-- The rig's joint tree (needed to build animations)
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 and d.Part1:IsDescendantOf(char)
			and not d.Part1:FindFirstAncestorOfClass("Tool") and not d.Part1:FindFirstAncestorOfClass("Accessory") then
			local list = stance.tree[d.Part0.Name]
			if not list then
				list = {}
				stance.tree[d.Part0.Name] = list
			end
			table.insert(list, d)
		end
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	stance.rootName = hrp and hrp.Name or "HumanoidRootPart"
	stance.baseSize = hrp and hrp.Size or Vector3.new(2, 2, 1)

	-- Leg lengths straight from the rig's joints, so any avatar proportions work
	if stance.r15 then
		stance.upper, stance.lower, stance.foot = 1.0, 1.2, 0.3 -- fallback
		local foot = char:FindFirstChild("LeftFoot")
		if j.lHip and j.lKnee and j.lAnkle and foot then
			local upper = (j.lKnee.motor.C0.Position - j.lHip.motor.C1.Position).Magnitude
			local lower = (j.lAnkle.motor.C0.Position - j.lKnee.motor.C1.Position).Magnitude
			local footH = foot.Size.Y / 2 + j.lAnkle.motor.C1.Position.Y
			if upper > 0.3 and lower > 0.3 and footH > 0 then
				stance.upper, stance.lower, stance.foot = upper, lower, footH
			end
		end
	else
		stance.upper, stance.lower, stance.foot = 2, 0, 0 -- one rigid leg
		local leg = char:FindFirstChild("Left Leg")
		if leg and j.lHip then
			stance.upper = leg.Size.Y / 2 + j.lHip.motor.C1.Position.Y
		end
	end

	-- The torso leans about the hips: find the hip pivot in HumanoidRootPart space
	local root = j.root
	if root then
		local pl = j.lHip and j.lHip.motor.C0.Position
		local pr = j.rHip and j.rHip.motor.C0.Position
		local p = (pl and pr) and (pl + pr) / 2 or Vector3.new(0, stance.r15 and -0.2 or -1, 0)
		stance.pivot = (root.motor.C0 * root.motor.C1:Inverse()) * p
	end

	if LocalPlayer.Character ~= char then return end
	stance.baseHip = humanoid.HipHeight
	stance.baseJumpPower = humanoid.JumpPower
	stance.baseJumpHeight = humanoid.JumpHeight

	-- Resolve every pose for this rig (R6 overrides, defaults, hip height)
	local standReach = stance.reach(0, 0)
	for mode, def in pairs(CONFIG.STANCES) do
		local d = {}
		for key, value in pairs(def) do d[key] = value end
		if not stance.r15 and def.r6 then
			for key, value in pairs(def.r6) do d[key] = value end
		end
		d.r6 = nil
		for key, value in pairs(stance.defaults) do
			if d[key] == nil then d[key] = value end
		end
		if d.thighR == nil then d.thighR = d.thigh end
		if d.hipY == nil then
			d.hipY = math.max(stance.reach(d.thigh, d.knee), stance.reach(d.thighR, d.knee))
		end
		local raw = stance.baseHip + d.hipY - standReach
		d.hipHeight = math.max(CONFIG.MIN_HIP_HEIGHT, raw)
		d.drop = d.hipHeight - raw -- how far the body must slide down because HipHeight can't go lower
		if mode == "stand" then
			d.hipHeight, d.drop = stance.baseHip, 0
		end
		stance.defs[mode] = d
	end
	if not stance.defs.stand then return end

	stance.mode = "stand"
	stance.resetCur()
	stance.buildTracks(humanoid)
	stance.ready = true

	local joints = 0
	for _ in pairs(j) do joints = joints + 1 end
	__toast("Stances: " .. (stance.r15 and "R15" or "R6") .. ", " .. joints .. " joints, "
		.. (stance.useAnim and "custom animations" or "joint poses (animations unavailable)"))
end

-- Plays the animation for the current stance (walking loop while moving, idle pose otherwise)
stance.playTracks = function(flatSpeed)
	local set = stance.mode ~= "stand" and stance.tracks[stance.mode] or nil
	local want = nil
	if set then
		local limit = (stance.playing ~= nil and stance.playing == set.move) and 0.15 or 0.5
		if set.move and stance.moving > limit then
			want = set.move
		else
			want = set.idle
		end
	end

	if want ~= stance.playing then
		if stance.playing then stance.playing:Stop(CONFIG.STANCE_FADE) end
		if want then
			want:Play(CONFIG.STANCE_FADE)
			stance.playedAt = os.clock()
		end
		stance.playing = want
	end

	if want and set and want == set.move then
		want:AdjustSpeed(math.clamp(flatSpeed / CONFIG.STANCE_GAIT_STRIDE, 0.2, 3))
	end

	-- Safety net: if the animation never actually starts, fall back to posing the joints directly
	if want and os.clock() - stance.playedAt > 1 and not want.IsPlaying then
		stance.useAnim = false
		stance.playing = nil
		for _, t in pairs(stance.tracks) do
			pcall(function()
				t.idle:Stop(0)
				if t.move then t.move:Stop(0) end
			end)
		end
		__toast("Stance animations would not play, using joint poses instead")
	end
end

-- Runs every render frame: eases toward the current stance and writes the pose
stance.apply = function(dt, character, humanoid)
	if not stance.ready or stance.char ~= character then return end
	if stance.mode == "stand" and not stance.dirty then return end -- nothing to do while standing

	local def = stance.defs[stance.mode] or stance.defs.stand
	local cur = stance.cur
	local k = math.clamp(dt * CONFIG.STANCE_BLEND_SPEED, 0, 1)

	for _, key in ipairs(stance.keys) do
		cur[key] = cur[key] + (def[key] - cur[key]) * k
	end
	cur.hip = cur.hip + (def.hipHeight - cur.hip) * k
	cur.amount = cur.amount + ((stance.mode == "stand" and 0 or 1) - cur.amount) * k

	-- Back on your feet and settled: hand everything back exactly as the game had it
	if stance.mode == "stand" and cur.amount < 0.01 then
		stance.restore()
		return
	end

	-- Changing body height shouldn't count as a fall
	if math.abs(def.hipHeight - cur.hip) > 0.05 then peakFallSpeed = 0 end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	local v = hrp and hrp.AssemblyLinearVelocity or Vector3.zero
	local flatSpeed = Vector3.new(v.X, 0, v.Z).Magnitude
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded then
		stance.phase = stance.phase + flatSpeed * dt * CONFIG.STANCE_GAIT_RATE
	end
	local moveTarget = (grounded and flatSpeed > 0.5) and 1 or 0
	stance.moving = stance.moving + (moveTarget - stance.moving) * math.clamp(dt * 8, 0, 1)

	if stance.useAnim then
		-- The pose comes from the custom animation (it also covers the walking swing)
		stance.playTracks(flatSpeed)
	else
		-- Fallback: write the joints directly, and fade the default animation out
		local s = math.sin(stance.phase) * stance.moving
		local c0s = stance.pose(cur, 0.5 + 0.5 * s, 0.5 - 0.5 * s)
		for key, c0 in pairs(c0s) do
			local joint = stance.joints[key]
			if joint and joint.motor.Parent then joint.motor.C0 = c0 end
		end

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local w = 1 - CONFIG.STANCE_ANIM_DAMP * cur.amount
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				if math.abs(track.WeightTarget - w) > 0.02 then
					track:AdjustWeight(w, 0)
				end
			end
		end
	end

	-- Hitbox: the root part shrinks around its centre, and HipHeight makes up the difference
	-- so the body stays exactly where it was. The head and torso also collide, and they now
	-- follow the pose (leaning, sitting, lying flat).
	local sizeY = stance.baseSize.Y
	if CONFIG.STANCE_HITBOX and hrp then
		sizeY = math.max(0.2, stance.baseSize.Y * cur.hit)
		if math.abs(hrp.Size.Y - sizeY) > 0.01 then
			hrp.Size = Vector3.new(stance.baseSize.X, sizeY, stance.baseSize.Z)
		end
	end
	humanoid.HipHeight = cur.hip + (stance.baseSize.Y - sizeY) / 2

	-- No jumping out of a stance: pressing jump stands you up instead (see JumpRequest below)
	local locked = stance.mode ~= "stand"
	humanoid.JumpPower = locked and 0 or stance.baseJumpPower
	humanoid.JumpHeight = locked and 0 or stance.baseJumpHeight
end

-- The default camera follows the HumanoidRootPart, so in a stance we move it onto the real head.
-- `legacy` is the normal bob offset; the result blends between it and the head position.
stance.cameraOffset = function(character, hrp, legacy)
	local out = legacy
	local cur = stance.cur
	if stance.ready and stance.char == character and cur.amount > 0.001 then
		local head = character:FindFirstChild("Head")
		if head and Camera then
			-- Where the camera sits with no offset, then where the eyes really are
			local base = Camera.CFrame.Position - hrp.CFrame:VectorToWorldSpace(stance.lastCam)
			local eye = head.CFrame:PointToWorldSpace(Vector3.new(0, 0.1, -0.5))
			local want = hrp.CFrame:VectorToObjectSpace(eye - base) + Vector3.new(legacy.X, legacy.Y, 0)
			if want.Magnitude < 10 then
				out = legacy:Lerp(want, math.clamp(cur.amount, 0, 1))
			end
		end
	end
	stance.lastCam = out
	return out
end

-- Switches stance. Returns false if something stopped it.
stance.set = function(mode)
	if mode == stance.mode then return true end

	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not stance.ready or stance.char ~= char or not hum or not root or hum.Health <= 0 then return false end
	if not stance.defs[mode] then return false end
	if faint or fall.knock or ragdollData then return false end
	if hum.FloorMaterial == Enum.Material.Air then return false end

	if mode == "stand" then
		-- Standing up needs head room
		local need = 2.4 + math.max(0, stance.baseHip - stance.cur.hip)
		if firstSolidHit(root.Position, Vector3.new(0, need, 0), char) then
			showNotice("No room to stand up")
			return false
		end
	end

	stance.mode = mode
	stance.dirty = true
	return true
end

-- Stand > Crouch > Sit > Crawl > Stand ...
stance.cycle = function()
	if not CONFIG.ENABLE_STANCES then return end
	local idx = table.find(stance.order, stance.mode) or 1
	stance.set(stance.order[idx % #stance.order + 1])
end

--------------------------------------------------------------------------------
-- 4. GUI CREATION (HUD PANEL + BUTTONS)
--------------------------------------------------------------------------------
local function createHUD()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("RealismHUD")
	if existing then existing:Destroy() end

	local screenGui = trackInstance(Instance.new("ScreenGui"))
	screenGui.Name = "RealismHUD"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10 -- above the game's own GUIs
	screenGui.Parent = playerGui

	-- Panel that holds the clock/weather line and every status bar
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -110, 1, -12) -- leaves room for the mobile jump button
	panel.Size = UDim2.new(0, 210, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	panel.BackgroundTransparency = 0.45
	panel.BorderSizePixel = 0
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.new(1, 1, 1)
	panelStroke.Transparency = 0.85
	panelStroke.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 5)
	listLayout.Parent = panel

	-- Top line: in-game clock and the weather (with a countdown while it rains)
	local info = Instance.new("TextLabel")
	info.Name = "Info"
	info.Size = UDim2.new(1, 0, 0, 14)
	info.BackgroundTransparency = 1
	info.Text = ""
	info.TextColor3 = Color3.fromRGB(205, 214, 228)
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.Font = Enum.Font.GothamMedium
	info.TextSize = 11
	info.LayoutOrder = 0
	info.Parent = panel

	local versionTag = Instance.new("TextLabel")
	versionTag.Name = "VersionTag"
	versionTag.Size = UDim2.new(1, 0, 0, 14)
	versionTag.BackgroundTransparency = 1
	versionTag.Text = "Realism v8.2"
	versionTag.TextColor3 = Color3.fromRGB(130, 140, 155)
	versionTag.TextXAlignment = Enum.TextXAlignment.Right
	versionTag.Font = Enum.Font.GothamMedium
	versionTag.TextSize = 10
	versionTag.Parent = info

	-- One status bar: rounded track, smooth fill, optional "ghost" that trails behind drops
	local function makeRow(name, color, order, opts)
		opts = opts or {}

		local row = Instance.new("CanvasGroup")
		row.Name = name .. "Row"
		row.Size = UDim2.new(1, 0, 0, 16)
		row.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
		row.BackgroundTransparency = 0.2
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = panel

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 5)
		rowCorner.Parent = row

		local ghost
		if opts.ghost then
			ghost = Instance.new("Frame")
			ghost.Name = "Ghost"
			ghost.Size = UDim2.new(1, 0, 1, 0)
			ghost.BackgroundColor3 = Color3.new(1, 1, 1)
			ghost.BackgroundTransparency = 0.55
			ghost.BorderSizePixel = 0
			ghost.Parent = row
		end

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.new(1, 0, 1, 0)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = row

		local shine = Instance.new("UIGradient")
		shine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(185, 185, 185))
		shine.Rotation = 90
		shine.Parent = fill

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(0.6, 0, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = name:upper()
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.7
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.GothamBold
		label.TextSize = 10
		label.Parent = row

		local value = Instance.new("TextLabel")
		value.Name = "Value"
		value.Size = UDim2.new(0.4, -8, 1, 0)
		value.Position = UDim2.new(0.6, 0, 0, 0)
		value.BackgroundTransparency = 1
		value.Text = ""
		value.TextColor3 = Color3.new(1, 1, 1)
		value.TextStrokeTransparency = 0.7
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Font = Enum.Font.GothamBold
		value.TextSize = 10
		value.Parent = row

		return {
			row = row, fill = fill, ghost = ghost, label = label, value = value,
			color = color,
			warn = opts.warn,        -- pulses when nearly empty
			idle = opts.idle or 1,   -- opacity while "not needed"
			disp = 1, ghostDisp = 1, alpha = 1,
			lastText = nil,
		}
	end

	local rows = {
		health = makeRow("Health", CONFIG.HEALTH_COLOR, 1, { ghost = true, warn = true }),
		hunger = makeRow("Hunger", CONFIG.HUNGER_COLOR, 2, { warn = true }),
		thirst = makeRow("Thirst", CONFIG.THIRST_COLOR, 3, { warn = true }),
		sprint = makeRow("Sprint", CONFIG.SPRINT_COLOR, 4, { warn = true, idle = 0.4 }),
		strength = makeRow("Leg Strength", CONFIG.STRENGTH_COLOR, 5, { idle = 0.5 }),
		adrenaline = makeRow("Adrenaline", CONFIG.ADRENALINE_COLOR, 6),
		bleed = makeRow("Bleeding", CONFIG.BLEED_COLOR, 7),
		temp = makeRow("Temperature", CONFIG.COLD_COLOR, 8),
	}
	rows.adrenaline.row.Visible = false
	rows.bleed.row.Visible = false
	rows.temp.row.Visible = false

	-- Eases a bar toward its value, pulses it when low, and dims it while it isn't needed
	local function setBar(r, frac, dt, text, needed)
		frac = math.clamp(frac, 0, 1)
		r.disp = r.disp + (frac - r.disp) * math.clamp(dt * 10, 0, 1)
		r.fill.Size = UDim2.new(r.disp, 0, 1, 0)

		if r.ghost then
			if r.ghostDisp < frac then
				r.ghostDisp = frac
			else
				r.ghostDisp = r.ghostDisp + (frac - r.ghostDisp) * math.clamp(dt * 1.5, 0, 1)
			end
			r.ghost.Size = UDim2.new(r.ghostDisp, 0, 1, 0)
		end

		local shown = text or tostring(math.floor(frac * 100 + 0.5))
		if shown ~= r.lastText then
			r.lastText = shown
			r.value.Text = shown
		end

		if r.warn and frac < 0.2 then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 7)
			r.fill.BackgroundColor3 = r.color:Lerp(Color3.new(1, 1, 1), pulse * 0.5)
		else
			r.fill.BackgroundColor3 = r.color
		end

		local target = needed and 1 or r.idle
		r.alpha = r.alpha + (target - r.alpha) * math.clamp(dt * 4, 0, 1)
		r.row.GroupTransparency = 1 - r.alpha
	end

	local hud = {
		rows = rows,
		-- main loop fills these in every frame, then calls update()
		values = {
			health = 1, hunger = 1, thirst = 1, sprint = 1, sprinting = false, strength = 0,
			adrenaline = 0, bleed = 0, bandaging = false, temp = 0,
		},
		lastInfo = nil,
	}

	local function formatTime(seconds)
		seconds = math.max(0, math.floor(seconds))
		return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
	end

	hud.update = function(dt)
		local v = hud.values

		setBar(rows.health, v.health, dt, nil, true)
		setBar(rows.hunger, v.hunger, dt, nil, true)
		setBar(rows.thirst, v.thirst, dt, nil, true)
		setBar(rows.sprint, v.sprint, dt, nil, v.sprint < 0.995 or v.sprinting)
		setBar(rows.strength, v.strength, dt, nil, false)

		local showAdrenaline = v.adrenaline > 0.001
		rows.adrenaline.row.Visible = showAdrenaline
		if showAdrenaline then setBar(rows.adrenaline, v.adrenaline, dt, nil, true) end

		local showBleed = v.bleed > 0.001
		rows.bleed.row.Visible = showBleed
		if showBleed then
			rows.bleed.color = v.bandaging and CONFIG.BANDAGE_COLOR or CONFIG.BLEED_COLOR
			rows.bleed.label.Text = v.bandaging and "WRAPPING" or "BLEEDING"
			setBar(rows.bleed, v.bleed, dt, "", true)
		end

		local tempAmount = math.abs(v.temp)
		local showTemp = tempAmount > 0.15
		rows.temp.row.Visible = showTemp
		if showTemp then
			rows.temp.color = v.temp < 0 and CONFIG.COLD_COLOR or CONFIG.HEAT_COLOR
			rows.temp.label.Text = v.temp < 0 and "COLD" or "HEAT"
			setBar(rows.temp, tempAmount, dt, nil, true)
		end

		-- Clock and weather. While it rains you can see exactly how long is left.
		local clock = Lighting.ClockTime
		local hours = math.floor(clock)
		local minutes = math.floor((clock - hours) * 60)
		local weatherText
		if weather.rain > 0.03 then
			if weather.target > 0 then
				weatherText = "RAIN " .. formatTime(weather.timer)
			else
				weatherText = "CLEARING"
			end
		else
			weatherText = "CLEAR"
		end
		local text = string.format("%02d:%02d   %s", hours, minutes, weatherText)
		if text ~= hud.lastInfo then
			hud.lastInfo = text
			info.Text = text
		end

		if stance.button and stance.lastLabel ~= stance.mode then
			stance.lastLabel = stance.mode
			stance.button.Text = stance.mode:upper()
		end
	end

	-- Round button used for RUN and STANCE
	local function makeRoundButton(name, text, position, strokeColor)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Size = UDim2.new(0, 65, 0, 65)
		b.Position = position
		b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		b.BackgroundTransparency = 0.3
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.AutoButtonColor = false
		b.Parent = screenGui

		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = b

		local s = Instance.new("UIStroke")
		s.Color = strokeColor
		s.Thickness = 2.5
		s.Parent = b
		return b
	end

	-- Mobile touch sprint button (hold to run)
	if UserInputService.TouchEnabled then
		local mobileBtn = makeRoundButton("MobileSprintButton", "RUN", UDim2.new(1, -95, 1, -295), CONFIG.SPRINT_COLOR)

		local function setPressedLook(pressed)
			mobileBtn.BackgroundColor3 = pressed and CONFIG.SPRINT_COLOR or Color3.fromRGB(30, 30, 30)
			mobileBtn.TextColor3 = pressed and Color3.fromRGB(20, 20, 20) or Color3.new(1, 1, 1)
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

	-- Stance button: tap to cycle Stand > Crouch > Sit > Crawl (PC: press C)
	if CONFIG.ENABLE_STANCES then
		local stanceBtn = makeRoundButton("StanceButton", "STAND", UDim2.new(1, -170, 1, -295), Color3.fromRGB(120, 180, 255))
		stanceBtn.Activated:Connect(function()
			safeCall("stance", stance.cycle)
		end)
		stance.button = stanceBtn
		stance.lastLabel = "stand"
	end

	-- Test menu: a lightning-bolt squircle opens a small panel with every test button in it
	if CONFIG.TEST_BUTTONS then
		local toggle = Instance.new("TextButton")
		toggle.Name = "TestToggle"
		toggle.Size = UDim2.fromOffset(44, 44)
		toggle.Position = UDim2.new(0, 10, 0, 70)
		toggle.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		toggle.BackgroundTransparency = 0.25
		toggle.Text = "\u{26A1}"
		toggle.TextSize = 24
		toggle.Font = Enum.Font.GothamBold
		toggle.TextColor3 = Color3.fromRGB(255, 220, 80)
		toggle.AutoButtonColor = false
		toggle.Parent = screenGui

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(0.3, 0) -- rounded square (squircle)
		toggleCorner.Parent = toggle

		local toggleStroke = Instance.new("UIStroke")
		toggleStroke.Color = Color3.fromRGB(255, 220, 80)
		toggleStroke.Thickness = 2
		toggleStroke.Transparency = 0.5
		toggleStroke.Parent = toggle

		-- Two columns so the menu stays short on a phone screen
		local menu = Instance.new("Frame")
		menu.Name = "TestMenu"
		menu.Position = UDim2.new(0, 10, 0, 120)
		menu.Size = UDim2.fromOffset(0, 0)
		menu.AutomaticSize = Enum.AutomaticSize.XY
		menu.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
		menu.BackgroundTransparency = 0.35
		menu.BorderSizePixel = 0
		menu.Visible = false
		menu.Parent = screenGui

		local menuCorner = Instance.new("UICorner")
		menuCorner.CornerRadius = UDim.new(0, 12)
		menuCorner.Parent = menu

		local menuPadding = Instance.new("UIPadding")
		menuPadding.PaddingTop = UDim.new(0, 8)
		menuPadding.PaddingBottom = UDim.new(0, 8)
		menuPadding.PaddingLeft = UDim.new(0, 8)
		menuPadding.PaddingRight = UDim.new(0, 8)
		menuPadding.Parent = menu

		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(84, 30)
		grid.CellPadding = UDim2.fromOffset(6, 6)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = menu

		toggle.Activated:Connect(function()
			menu.Visible = not menu.Visible
			toggle.BackgroundColor3 = menu.Visible and Color3.fromRGB(70, 60, 20) or Color3.fromRGB(30, 30, 30)
		end)

		local order = 0
		local function testButton(text, onClick)
			order = order + 1
			local b = Instance.new("TextButton")
			b.Name = "Test" .. text
			b.LayoutOrder = order
			b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
			b.BackgroundTransparency = 0.2
			b.Text = text
			b.TextColor3 = Color3.new(1, 1, 1)
			b.Font = Enum.Font.GothamBold
			b.TextSize = 12
			b.Parent = menu

			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 6)
			c.Parent = b

			b.Activated:Connect(onClick)
		end
		testButton("BLEED", forceBleed)
		testButton("STORM", toggleStorm)
		testButton("NIGHT", function()
			Lighting.ClockTime = 0
			temp.body = -0.6
			showNotice("Midnight")
		end)
		testButton("NOON", function()
			Lighting.ClockTime = 12
			temp.body = 0.6
			showNotice("High noon")
		end)
		testButton("FALL", function()
			if runFallTest then runFallTest(100) end
		end)
		testButton("BLINK", function()
			eyes.blink(false)
		end)
	end

	return hud
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
local coldFrames = createEdgeOverlay("RealismColdOverlay", CONFIG.COLD_TINT)
local heatFrames = createEdgeOverlay("RealismHeatOverlay", Color3.fromRGB(255, 190, 110))

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
	local rain = weather.rain

	local skyColor = Color3.fromRGB(45, 55, 85):Lerp(Color3.fromRGB(195, 210, 230), day):Lerp(Color3.fromRGB(255, 185, 130), golden * 0.7)
	local skyDecay = Color3.fromRGB(25, 28, 50):Lerp(Color3.fromRGB(110, 125, 140), day):Lerp(Color3.fromRGB(200, 110, 70), golden * 0.7)

	-- Rain: grey, heavy sky
	if rain > 0 then
		local grey = Color3.fromRGB(125, 132, 145):Lerp(Color3.fromRGB(30, 34, 46), 1 - day)
		skyColor = skyColor:Lerp(grey, rain * 0.65)
		skyDecay = skyDecay:Lerp(grey:Lerp(Color3.new(0, 0, 0), 0.35), rain * 0.5)
	end

	atmosphere.Color = skyColor
	atmosphere.Decay = skyDecay
	atmosphere.Density = 0.3 + golden * 0.1 + (1 - day) * 0.05 + rain * 0.18
	atmosphere.Haze = 2.1 + rain * 3

	Lighting.Brightness = (CONFIG.MOON_BRIGHTNESS + day * (CONFIG.SUN_BRIGHTNESS - CONFIG.MOON_BRIGHTNESS)) * (1 - rain * CONFIG.RAIN_DARKEN)
	Lighting.OutdoorAmbient = CONFIG.MOON_AMBIENT:Lerp(Color3.fromRGB(110, 115, 125), day):Lerp(Color3.fromRGB(150, 110, 90), golden * 0.4)

	Lighting.ColorShift_Top = Color3.new(0, 0, 0):Lerp(CONFIG.MOON_TINT, 1 - day)

	return day, golden
end

--------------------------------------------------------------------------------
-- 6a. SKY (twilight palette, stars, sun/moon size, clouds, storm clouds)
--------------------------------------------------------------------------------
local sky = {
	obj = nil,
	clouds = nil,
	backup = nil,
	cloudBackup = nil,
	cover = 0.4,
	seed = math.random() * 1000,
	starTimer = 0,
	stars = -1,
}

-- Sky colour by sun height (sun direction Y: -1 midnight .. +1 noon).
-- Each row: { sunHeight, atmosphere Color, atmosphere Decay (horizon glow), OutdoorAmbient }
sky.palette = {
	{ -0.30, Color3.fromRGB(20, 26, 54),    Color3.fromRGB(8, 10, 24),     Color3.fromRGB(48, 58, 95) },    -- night
	{ -0.12, Color3.fromRGB(45, 58, 105),   Color3.fromRGB(60, 45, 90),    Color3.fromRGB(70, 78, 118) },   -- blue hour
	{ -0.03, Color3.fromRGB(150, 130, 150), Color3.fromRGB(255, 120, 80),  Color3.fromRGB(125, 105, 115) }, -- sun on the horizon
	{  0.06, Color3.fromRGB(200, 175, 160), Color3.fromRGB(255, 150, 85),  Color3.fromRGB(140, 112, 100) }, -- golden hour
	{  0.22, Color3.fromRGB(190, 205, 225), Color3.fromRGB(225, 150, 100), Color3.fromRGB(125, 118, 115) },
	{  0.55, Color3.fromRGB(180, 202, 228), Color3.fromRGB(115, 128, 145), Color3.fromRGB(110, 115, 125) }, -- day
	{  1.00, Color3.fromRGB(170, 196, 232), Color3.fromRGB(100, 122, 148), Color3.fromRGB(110, 116, 128) }, -- noon
}

sky.sample = function(h)
	local p = sky.palette
	local first, last = p[1], p[#p]
	if h <= first[1] then return first[2], first[3], first[4] end
	if h >= last[1] then return last[2], last[3], last[4] end
	for i = 1, #p - 1 do
		local lo, hi = p[i], p[i + 1]
		if h <= hi[1] then
			local t = (h - lo[1]) / (hi[1] - lo[1])
			return lo[2]:Lerp(hi[2], t), lo[3]:Lerp(hi[3], t), lo[4]:Lerp(hi[4], t)
		end
	end
	return last[2], last[3], last[4]
end

sky.setup = function()
	-- Sky object: reuse the game's if it has one (and remember it), else make our own
	local s = Lighting:FindFirstChildOfClass("Sky")
	if s and s.Name ~= "RealismSky" then
		sky.backup = {
			inst = s, Name = s.Name, StarCount = s.StarCount,
			SunAngularSize = s.SunAngularSize, MoonAngularSize = s.MoonAngularSize,
			CelestialBodiesShown = s.CelestialBodiesShown,
		}
	elseif not s then
		s = trackInstance(Instance.new("Sky"))
	else
		trackInstance(s)
	end
	s.Name = "RealismSky"
	s.CelestialBodiesShown = true
	s.Parent = Lighting
	sky.obj = s

	-- Clouds live on Terrain
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local c = terrain:FindFirstChildOfClass("Clouds")
		if c then
			sky.cloudBackup = { inst = c, Cover = c.Cover, Density = c.Density, Color = c.Color, Enabled = c.Enabled }
		else
			c = trackInstance(Instance.new("Clouds"))
			c.Parent = terrain
		end
		c.Enabled = true
		sky.clouds = c
	end
end

sky.restore = function()
	local b = sky.backup
	if b and b.inst and b.inst.Parent then
		local s = b.inst
		s.Name, s.StarCount = b.Name, b.StarCount
		s.SunAngularSize, s.MoonAngularSize = b.SunAngularSize, b.MoonAngularSize
		s.CelestialBodiesShown = b.CelestialBodiesShown
	end
	local cb = sky.cloudBackup
	if cb and cb.inst and cb.inst.Parent then
		cb.inst.Cover, cb.inst.Density, cb.inst.Color, cb.inst.Enabled = cb.Cover, cb.Density, cb.Color, cb.Enabled
	end
end

sky.update = function(dt, day, golden)
	local s, c = sky.obj, sky.clouds
	if not s then return end

	local rain = weather.rain
	local flash = weather.flash * (1 - weather.sheltered * 0.5)
	local h = Lighting:GetSunDirection().Y
	local morning = Lighting.ClockTime < 12

	-- 1. Sky colour, horizon glow and ambient light from the twilight palette
	local col, dec, amb = sky.sample(h)
	if morning then
		dec = dec:Lerp(Color3.fromRGB(255, 170, 180), golden * 0.3) -- sunrise glows pinker than sunset
	end
	if rain > 0 then
		local grey = Color3.fromRGB(125, 132, 145):Lerp(Color3.fromRGB(30, 34, 46), 1 - day)
		col = col:Lerp(grey, rain * 0.65)
		dec = dec:Lerp(grey:Lerp(Color3.new(0, 0, 0), 0.35), rain * 0.6)
		amb = amb:Lerp(grey:Lerp(Color3.new(0, 0, 0), 0.4), rain * 0.4)
	end
	atmosphere.Color = col
	atmosphere.Decay = dec
	Lighting.OutdoorAmbient = amb

	-- 2. Sun and moon look bigger near the horizon
	local sunLow = math.clamp(1 - math.abs(h) / 0.35, 0, 1)
	local moonLow = math.clamp(1 - math.abs(-h) / 0.35, 0, 1)
	s.SunAngularSize = 21 + sunLow * 14
	s.MoonAngularSize = 11 + moonLow * 5

	-- 3. Stars fade in after dusk and are hidden by cloud (set in steps, and not every frame)
	sky.starTimer = sky.starTimer + dt
	if sky.starTimer >= 0.5 then
		sky.starTimer = 0
		local night = math.clamp((-h - 0.05) / 0.25, 0, 1)
		local count = math.floor(3500 * night * (1 - sky.cover * 0.9) / 250 + 0.5) * 250
		if count ~= sky.stars then
			sky.stars = count
			s.StarCount = count
		end
	end

	-- 4. Clouds: drift between clear and cloudy, build up before a shower, go dark in rain
	if c then
		local n = math.noise(os.clock() * 0.004, sky.seed, 0) -- slow wandering value
		local base = math.clamp(0.38 + n * 0.5, 0.15, 0.7)
		local pre = 0
		if CONFIG.ENABLE_WEATHER and weather.target == 0 and weather.timer < 50 then
			pre = (1 - weather.timer / 50) * 0.5 -- clouds gather ~50 s before the rain
		end
		local coverTarget = math.clamp(math.max(base + pre, rain * 0.95), 0, 1)
		sky.cover = sky.cover + (coverTarget - sky.cover) * math.clamp(dt * 0.5, 0, 1)

		local cc = Color3.fromRGB(48, 56, 82):Lerp(Color3.new(1, 1, 1), day)
		cc = cc:Lerp(Color3.fromRGB(255, 175, 125), golden * 0.55 * (1 - rain)) -- lit from below at dusk/dawn
		cc = cc:Lerp(Color3.fromRGB(120, 126, 138):Lerp(Color3.fromRGB(26, 30, 40), 1 - day), rain * 0.8)
		cc = cc:Lerp(Color3.new(1, 1, 1), flash * 0.9) -- lightning lights up the clouds

		c.Cover = sky.cover
		c.Density = math.clamp(0.4 + sky.cover * 0.25 + rain * 0.3, 0, 1)
		c.Color = cc
	end
end

safeCall("sky setup", sky.setup)

--------------------------------------------------------------------------------
-- 6b. AUDIO (FOOTSTEPS, BREATHING, HEARTBEAT, EAR RINGING, RAIN)
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
-- (looped defaults to true; pass false for one-shot sounds like thunder)
local function loadFirstWorking(parent, name, ids, looped)
	local loop = looped ~= false
	for _, id in ipairs(ids) do
		local candidate = makeSound(parent, name, id, loop)
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
	if weather.rainSound then weather.rainSound:Destroy() end
	if weather.thunderSound then weather.thunderSound:Destroy() end
	breathSound, heartSound, ringSound, thumpSound = nil, nil, nil, nil
	weather.rainSound, weather.rainEQ, weather.thunderSound = nil, nil, nil
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

	-- Puddle splashes for wet ground (only if you set CONFIG.PUDDLE_SOUND_ID)
	puddlePool, puddleIndex = {}, 0
	for i = 1, 2 do
		local s = makeSound(hrp, "RealismPuddle" .. i, CONFIG.PUDDLE_SOUND_ID, false)
		if s then table.insert(puddlePool, s) end
	end
	if #puddlePool > 0 then
		pcall(function() ContentProvider:PreloadAsync(puddlePool) end)
		if gen ~= soundGen then return end
	end

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

	-- Rain loop (with a low-pass filter so it sounds muffled indoors) and thunder.
	-- Both are optional: with empty ID lists the rain still shows, it just has no sound.
	local rain = loadFirstWorking(playerGui, "RealismRain", CONFIG.RAIN_SOUND_IDS)
	if gen ~= soundGen then
		if rain then rain:Destroy() end
		return
	end
	weather.rainSound = rain
	if rain then
		local eq = Instance.new("EqualizerSoundEffect")
		eq.Parent = rain
		weather.rainEQ = eq
	end

	local thunder = loadFirstWorking(playerGui, "RealismThunder", CONFIG.THUNDER_SOUND_IDS, false)
	if gen ~= soundGen then
		if thunder then thunder:Destroy() end
		return
	end
	weather.thunderSound = thunder

	defaultRunning, defaultRunningVolume = nil, nil
	if CONFIG.MUTE_DEFAULT_FOOTSTEPS then
		local running = hrp:WaitForChild("Running", 3)
		if running and running:IsA("Sound") then
			defaultRunning = running
			defaultRunningVolume = running.Volume
		end
	end
end

local function playFootstep(sound, humanoid, isRunning, speedT, puddle)
	local id
	if puddle then
		id = CONFIG.PUDDLE_SOUND_ID
	else
		id = CONFIG.MATERIAL_SOUNDS[humanoid.FloorMaterial] or CONFIG.FOOTSTEP_DEFAULT_ID
	end
	if sound.SoundId ~= id then sound.SoundId = id end
	sound.PlaybackSpeed = (isRunning and 1.2 or 0.95) + math.random() * 0.15 + speedT * 0.2
	-- Crouching and crawling are quieter (stance.cur.quiet eases between stances)
	sound.Volume = (isRunning and 0.85 or 0.45) * stance.cur.quiet
	sound.TimePosition = CONFIG.FOOTSTEP_CLIP_START
	sound:Play()

	-- The default file holds several steps; cut it off after the first one
	local steps = puddle and CONFIG.PUDDLE_STEPS_IN_FILE or CONFIG.FOOTSTEP_STEPS_IN_FILE
	local clip = CONFIG.FOOTSTEP_CLIP_LENGTH
	if clip <= 0 and steps > 1 and sound.TimeLength > 0 then
		clip = sound.TimeLength / steps
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
			-- Wet ground (outdoors) swaps in puddle splashes
			local puddleChance = weather.wet * (1 - weather.sheltered * 0.8)
			if #puddlePool > 0 and math.random() < puddleChance then
				puddleIndex = puddleIndex % #puddlePool + 1
				playFootstep(puddlePool[puddleIndex], humanoid, isRunning, speedT, true)
			else
				footstepIndex = footstepIndex % #footstepPool + 1
				playFootstep(footstepPool[footstepIndex], humanoid, isRunning, speedT, false)
			end
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
		local factor = math.max(tired, (adrenaline / 100) * 0.5, math.max(0, temp.body) * 0.4)
		approachVolume(breathSound, factor * CONFIG.BREATH_MAX_VOLUME, deltaTime, 3)
		breathSound.PlaybackSpeed = 0.9 + factor * 0.4
	end

	-- Heartbeat: low health, out of sprint, bleeding, and a little with adrenaline
	local lowHealth = math.clamp((0.4 - healthPercent) / 0.4, 0, 1)
	local heartFactor = math.max(lowHealth, depleted, (adrenaline / 100) * 0.35, bleedSeverity * 0.4)
	if heartSound then
		approachVolume(heartSound, heartFactor * CONFIG.HEARTBEAT_MAX_VOLUME, deltaTime, 3)
		heartSound.PlaybackSpeed = 0.9 + heartFactor * 0.5
	end

	-- Ear ringing: builds as sprint runs out
	if ringSound then
		approachVolume(ringSound, depleted * CONFIG.RING_MAX_VOLUME, deltaTime, 3)
	end

	-- Rain ambience: quieter and duller when there's a roof over you
	if weather.rainSound then
		local target = weather.rain * CONFIG.RAIN_MAX_VOLUME * (1 - weather.sheltered * 0.55)
		approachVolume(weather.rainSound, target, deltaTime, 3)
		if weather.rainEQ then
			weather.rainEQ.HighGain = -weather.sheltered * CONFIG.RAIN_INDOOR_MUFFLE
		end
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

	-- Straighten out of any crouch/crawl/sit first, so the joints are built from the standing pose
	stance.restore()

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
-- 6e. BLEEDING
--------------------------------------------------------------------------------
-- Called whenever you lose health in one hit. Bigger hits are more likely to make
-- you bleed, and bleed harder. Starvation and bleeding itself never call this.
local function tryStartBleed(damage, maxHealth)
	local fraction = damage / math.max(maxHealth, 1)
	if fraction < CONFIG.BLEED_HIT_FRACTION then return end

	local chance = math.clamp(0.5 + (fraction - CONFIG.BLEED_HIT_FRACTION) * 2.3, 0.5, 1)
	if math.random() > chance then return end

	local wasBleeding = bleedSeverity > 0
	bleedSeverity = math.clamp(bleedSeverity + 0.3 + fraction * 0.8, 0, 1)
	if not wasBleeding then
		showNotice("You're bleeding - equip the Bandage and click")
	end
end

-- Blood on the ground: a trail of small drops and the odd big splat while you walk,
-- and a pool that keeps spreading under you while you stand still.
local bloodPools = {}          -- oldest first
local bloodLastPos = nil
local bloodDist = 0
local bloodDropCount = 0
local bloodGrowTimer = 0

local function placeBlood(origin, character, diameter)
	local hit = firstSolidHit(origin, Vector3.new(0, -10, 0), character)
	if not hit or not hit.Instance.Anchored then return nil end

	local pool = Instance.new("Part")
	pool.Name = "RealismBlood"
	pool.Shape = Enum.PartType.Cylinder
	pool.Size = Vector3.new(0.05, diameter, diameter) -- thin disc: X is the thickness
	pool.Anchored = true
	pool.CanCollide = false
	pool.CanQuery = false
	pool.CanTouch = false
	pool.CastShadow = false
	pool.Material = Enum.Material.SmoothPlastic
	pool.Reflectance = 0.08
	pool.Color = Color3.fromRGB(math.random(85, 120), 5, 8)

	-- Lay the disc flat on the surface (a tiny height change per pool stops flickering overlaps)
	local normal = hit.Normal
	local pos = hit.Position + normal * (0.03 + (#bloodPools % 5) * 0.004)
	local up = math.abs(normal.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
	pool.CFrame = CFrame.lookAt(pos, pos + normal, up) * CFrame.Angles(0, math.pi / 2, 0)
	pool.Parent = Workspace

	table.insert(bloodPools, pool)
	if #bloodPools > CONFIG.BLOOD_MAX_POOLS then
		local oldest = table.remove(bloodPools, 1)
		oldest:Destroy()
	end
	return pool
end

local function updateBlood(dt, character, humanoid, hrp)
	if not CONFIG.ENABLE_BLOOD_POOLS or bleedSeverity <= 0 or humanoid.FloorMaterial == Enum.Material.Air then
		bloodLastPos = nil
		return
	end

	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local pos = hrp.Position
	if bloodLastPos then
		local moved = Vector3.new(pos.X - bloodLastPos.X, 0, pos.Z - bloodLastPos.Z)
		bloodDist = bloodDist + moved.Magnitude
	end
	bloodLastPos = pos

	local scale = 0.7 + bleedSeverity * 0.6
	local back = Vector3.zero
	if flat.Magnitude > 1 then back = -flat.Unit * 0.7 end -- a little behind your feet

	-- Walking: leave a drop every couple of studs (more often the worse the bleed)
	if bloodDist >= 2.2 - 1.2 * bleedSeverity then
		bloodDist = 0
		bloodDropCount = bloodDropCount + 1
		local big = bloodDropCount % 4 == 0
		local d = (big and (1.0 + math.random() * 0.7) or (0.35 + math.random() * 0.35)) * scale
		local jitter = Vector3.new(randRange(-0.4, 0.4), 0, randRange(-0.4, 0.4))
		placeBlood(pos + back + jitter, character, d)
	end

	-- Standing still: the pool underneath you keeps spreading
	if flat.Magnitude < 1 then
		bloodGrowTimer = bloodGrowTimer + dt
		if bloodGrowTimer >= 0.4 then
			bloodGrowTimer = 0
			local last = bloodPools[#bloodPools]
			local near = last and last.Parent
				and (Vector3.new(pos.X, last.Position.Y, pos.Z) - last.Position).Magnitude < last.Size.Y / 2 + 1.5
			if near then
				local d = math.min(last.Size.Y + 0.12, CONFIG.BLOOD_POOL_MAX * scale)
				last.Size = Vector3.new(0.05, d, d)
			else
				placeBlood(pos, character, 0.8 * scale)
			end
		end
	else
		bloodGrowTimer = 0
	end
end
--------------------------------------------------------------------------------
-- 6f. SCREEN DROPS (rain water + blood), RAIN, LIGHTNING & WEATHER
--------------------------------------------------------------------------------
local screenDrops = {}

local function createScreenDrops()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("RealismScreenDrops")
	if existing then existing:Destroy() end

	local gui = trackInstance(Instance.new("ScreenGui"))
	gui.Name = "RealismScreenDrops"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -3
	gui.Parent = playerGui

	for _ = 1, CONFIG.SCREEN_DROP_POOL do
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Transparency = 1
		stroke.Parent = frame

		table.insert(screenDrops, {
			frame = frame, stroke = stroke,
			active = false, blood = false,
			age = 0, life = 1, x = 0, y = 0, vy = 0,
		})
	end
end

createScreenDrops()

-- Real 3D rain: lots of thin streaks falling in a column around you. They are Beams
-- (solid colored ribbons), so no texture IDs are needed. A single invisible part
-- follows your camera and holds all the attachments.
local rainRig = nil
local rainStreaks = {}

-- Each drop remembers where it is in the WORLD and what is under it (roof, wall, ground or water),
-- so rain falls outside a window but not inside the room.
weather.rainRay = RaycastParams.new()
weather.rainRay.FilterType = Enum.RaycastFilterType.Exclude
weather.rainRay.IgnoreWater = false
weather.rainChar = nil

local function respawnStreak(s, y)
	local cp = Camera and Camera.CFrame.Position or Vector3.zero
	local angle, reach
	if Camera and math.random() < 0.5 then
		-- Half the drops go in front of you, so rain beyond doors and windows is visible
		local look = Camera.CFrame.LookVector
		angle = math.atan2(look.Z, look.X) + (math.random() - 0.5) * 1.7
		reach = CONFIG.RAIN_RADIUS * 1.5
	else
		angle = math.random() * math.pi * 2
		reach = CONFIG.RAIN_RADIUS
	end
	local r = 1.5 + math.sqrt(math.random()) * (reach - 1.5)
	s.wx = cp.X + math.cos(angle) * r
	s.wz = cp.Z + math.sin(angle) * r
	s.wy = cp.Y + y
	s.floor = nil
	local b = s.beam
	if b then
		-- Far drops are drawn a little wider so they stay visible
		b.Width0 = 0.03 + r * 0.003
		b.Width1 = 0.05 + r * 0.004
	end
end

local function createRainStreaks()
	local rig = trackInstance(Instance.new("Part"))
	rig.Name = "RealismRainRig"
	rig.Anchored = true
	rig.CanCollide = false
	rig.CanQuery = false
	rig.CanTouch = false
	rig.CastShadow = false
	rig.Transparency = 1
	rig.Size = Vector3.new(1, 1, 1)
	rig.Parent = Workspace

	-- Phones and tablets get half as many streaks (every streak is updated every frame)
	local streakCount = CONFIG.RAIN_STREAKS
	if UserInputService.TouchEnabled then
		streakCount = math.floor(streakCount / 2)
	end

	for _ = 1, streakCount do
		local top = Instance.new("Attachment")
		top.Parent = rig
		local bottom = Instance.new("Attachment")
		bottom.Parent = rig

		local beam = Instance.new("Beam")
		beam.Attachment0 = top
		beam.Attachment1 = bottom
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Width0 = 0.03
		beam.Width1 = 0.05
		beam.LightEmission = 0.4
		beam.LightInfluence = 0.6
		beam.Color = ColorSequence.new(Color3.fromRGB(215, 228, 245))
		beam.Transparency = NumberSequence.new(0.85, 0.45) -- faint tail, brighter head
		beam.Enabled = false
		beam.Parent = rig

		local s = {
			top = top, bottom = bottom, beam = beam, on = false,
			wx = 0, wy = 0, wz = 0, floor = nil, isWater = false, sleep = 0,
			speed = CONFIG.RAIN_SPEED * (0.85 + math.random() * 0.3),
		}
		respawnStreak(s, math.random() * (CONFIG.RAIN_HEIGHT + 10) - 10)
		table.insert(rainStreaks, s)
	end
	rainRig = rig
end

createRainStreaks()

-- Height where this drop's column is blocked (roof, ground, water). Returns (y, hitWater)
weather.rainFloor = function(s)
	local reach = CONFIG.RAIN_HEIGHT + 80
	local startY = Camera.CFrame.Position.Y + CONFIG.RAIN_HEIGHT
	local origin = Vector3.new(s.wx, startY, s.wz)
	for _ = 1, 3 do
		local hit = Workspace:Raycast(origin, Vector3.new(0, -reach, 0), weather.rainRay)
		if not hit then return startY - reach, false end
		local inst = hit.Instance
		if hit.Material == Enum.Material.Water then return hit.Position.Y, true end
		-- Solid things stop rain; glass, leaves-with-no-collision and invisible parts do not
		if inst.CanCollide and inst.Transparency < 0.5 then return hit.Position.Y, false end
		origin = Vector3.new(s.wx, hit.Position.Y - 0.05, s.wz)
	end
	return origin.Y, false
end

local function updateRainStreaks(dt)
	if not rainRig then return end
	local cam = Camera.CFrame.Position
	rainRig.CFrame = CFrame.new(cam)

	local ch = LocalPlayer.Character
	if ch ~= weather.rainChar then
		weather.rainChar = ch
		weather.rainRay.FilterDescendantsInstances = ch and { ch } or {}
	end

	-- How many drops are in play (a roof no longer switches them all off: each drop checks its own spot)
	local count = math.floor(weather.rain * #rainStreaks + 0.5)

	local dir = Vector3.new(CONFIG.RAIN_SLANT, -1, 0.04).Unit
	local half = dir * (CONFIG.RAIN_LENGTH * 0.5)
	local far2 = (CONFIG.RAIN_RADIUS * 1.7) ^ 2
	local budget = 28 -- raycasts allowed per frame

	for i, s in ipairs(rainStreaks) do
		local show = i <= count
		if show then
			if s.sleep > 0 then
				s.sleep = s.sleep - dt
				show = false
			else
				-- You walked away from this drop: bring it back around you
				local dx, dz = s.wx - cam.X, s.wz - cam.Z
				if dx * dx + dz * dz > far2 then respawnStreak(s, CONFIG.RAIN_HEIGHT) end

				if not s.floor then
					if budget > 0 then
						budget = budget - 1
						s.floor, s.isWater = weather.rainFloor(s)
						if s.floor >= s.wy - 1 then
							-- Roof or wall right here: no rain in this spot, try another soon
							s.sleep = 0.3 + math.random() * 0.4
							respawnStreak(s, math.random() * CONFIG.RAIN_HEIGHT)
							show = false
						end
					else
						show = false
					end
				end

				if show then
					s.wx = s.wx + dir.X * s.speed * dt
					s.wy = s.wy + dir.Y * s.speed * dt
					s.wz = s.wz + dir.Z * s.speed * dt
					if s.wy <= s.floor then
						if s.isWater and weather.onLand then weather.onLand(s.wx, s.floor, s.wz) end
						respawnStreak(s, CONFIG.RAIN_HEIGHT)
					else
						local center = Vector3.new(s.wx - cam.X, s.wy - cam.Y, s.wz - cam.Z)
						s.top.Position = center - half
						s.bottom.Position = center + half
					end
				end
			end
		end
		if s.on ~= show then
			s.on = show
			s.beam.Enabled = show
		end
	end
end

local function spawnScreenDrop(blood)
	for _, d in ipairs(screenDrops) do
		if not d.active then
			d.active = true
			d.blood = blood
			d.age = 0
			d.life = (blood and 3.5 or 2.5) + math.random() * 2.5
			d.x = 0.05 + math.random() * 0.9
			d.y = math.random() * 0.75
			d.vy = blood and (0.03 + math.random() * 0.04) or (0.01 + math.random() * 0.03)
			local size = (blood and 10 or 6) + math.random() * (blood and 14 or 12)
			d.frame.Size = UDim2.fromOffset(size, size * (blood and 1.3 or 1))
			d.frame.BackgroundColor3 = blood and Color3.fromRGB(110, 10, 10) or Color3.fromRGB(200, 220, 240)
			d.stroke.Color = blood and Color3.fromRGB(70, 0, 0) or WHITE
			d.frame.Visible = true
			return
		end
	end
end

local function clearScreenDrops()
	for _, d in ipairs(screenDrops) do
		d.active = false
		d.frame.Visible = false
	end
end

local function updateScreenDrops(dt)
	updateRainStreaks(dt)

	-- Water drops land on the "lens" in the open; blood drips while you bleed
	local rainRate = weather.rain * (1 - weather.sheltered * 0.9) * CONFIG.RAIN_DROP_RATE
	if math.random() < rainRate * dt then spawnScreenDrop(false) end
	if bleedSeverity > 0 and math.random() < bleedSeverity * CONFIG.BLOOD_DROP_RATE * dt then
		spawnScreenDrop(true)
	end

	for _, d in ipairs(screenDrops) do
		if d.active then
			d.age = d.age + dt
			local a = d.age / d.life
			if a >= 1 or d.y > 1.05 then
				d.active = false
				d.frame.Visible = false
			else
				-- Drops creep down the screen, speeding up as they get heavy
				d.y = d.y + d.vy * dt * (0.5 + a)
				local fade = 1
				if a < 0.1 then fade = a / 0.1 elseif a > 0.6 then fade = (1 - a) / 0.4 end
				local opacity = fade * (d.blood and 0.85 or 0.4)
				d.frame.Position = UDim2.fromScale(d.x, d.y)
				d.frame.BackgroundTransparency = 1 - opacity
				d.stroke.Transparency = 1 - fade * 0.5
			end
		end
	end
end

-- Invisible part that follows your camera and rains down on you
local function setupRain()
	local part = trackInstance(Instance.new("Part"))
	part.Name = "RealismRain"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(CONFIG.RAIN_AREA, 1, CONFIG.RAIN_AREA)
	part.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Rain"
	emitter.Texture = CONFIG.RAIN_TEXTURE
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Speed = NumberRange.new(75, 90)
	emitter.Lifetime = NumberRange.new(0.5, 0.6)
	emitter.Size = NumberSequence.new(0.4)
	emitter.Transparency = NumberSequence.new(0.55)
	emitter.Color = ColorSequence.new(Color3.fromRGB(190, 210, 235))
	emitter.LightEmission = 0.3
	emitter.LightInfluence = 1
	emitter.LockedToPart = false
	emitter.Rate = 0
	emitter.Parent = part

	weather.part = part
	weather.emitter = emitter
end

if CONFIG.RAIN_PARTICLES then setupRain() end

-- Triangle-shaped brightness pulse: rises from start to peak, falls to finish
local function pulse(t, start, peak, finish, amp)
	if t <= start or t >= finish then return 0 end
	if t < peak then return amp * (t - start) / (peak - start) end
	return amp * (finish - t) / (finish - peak)
end

-- Visible lightning bolt: a jagged glowing line (plus branches) from the clouds to the ground.
-- Stored as weather.* functions so no new local variables are used.
weather.spawnBolt = function(strike)
	if not CONFIG.LIGHTNING_BOLTS then return end
	local cam = Camera.CFrame
	local cp = cam.Position

	-- Where it strikes: mostly somewhere in front of you so you actually see it
	local base = math.atan2(cam.LookVector.Z, cam.LookVector.X)
	local ang
	if math.random() < 0.7 then
		ang = base + (math.random() - 0.5) * 2.0
	else
		ang = math.random() * math.pi * 2
	end
	local dist = CONFIG.BOLT_MIN_DIST + (math.random() ^ 1.4) * (CONFIG.BOLT_MAX_DIST - CONFIG.BOLT_MIN_DIST)
	local gx = cp.X + math.cos(ang) * dist
	local gz = cp.Z + math.sin(ang) * dist
	local hit = Workspace:Raycast(Vector3.new(gx, cp.Y + 400, gz), Vector3.new(0, -900, 0), weather.rainRay)
	local gy = hit and hit.Position.Y or (cp.Y - 4)
	local ground = Vector3.new(gx, gy, gz)
	local top = Vector3.new(
		gx + (math.random() - 0.5) * 80,
		math.max(gy, cp.Y) + math.clamp(dist * 0.6, 130, 300) + math.random() * 40,
		gz + (math.random() - 0.5) * 80
	)

	-- Closer strike = brighter flash, louder and sooner thunder
	strike.dist = dist
	strike.close = math.clamp(1 - dist / (CONFIG.BOLT_MAX_DIST * 1.2), 0, 1)
	strike.vol = math.clamp(1.25 - dist / 650, 0.3, 1)
	strike.thunderAt = 0.4 + dist / 150

	-- Midpoint displacement: split each segment in two and nudge the middle sideways
	local function jag(a, b, levels, amp)
		local pts = { a, b }
		for _ = 1, levels do
			local nxt = { pts[1] }
			for i = 1, #pts - 1 do
				local p, q = pts[i], pts[i + 1]
				local seg = q - p
				local len = seg.Magnitude
				local r = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
				if len > 0.001 then
					local d = seg / len
					r = r - d * r:Dot(d)
				end
				r = r.Magnitude > 0.001 and r.Unit or Vector3.xAxis
				table.insert(nxt, (p + q) / 2 + r * len * amp)
				table.insert(nxt, q)
			end
			pts = nxt
			amp = amp * 0.85
		end
		return pts
	end

	if not weather.boltFolder then
		weather.boltFolder = trackInstance(Instance.new("Folder"))
		weather.boltFolder.Name = "RealismBolts"
		weather.boltFolder.Parent = Workspace
	end
	local folder = Instance.new("Folder")
	folder.Parent = weather.boltFolder
	local core, glow = {}, {}

	local function addLine(pts, w)
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			local len = (b - a).Magnitude
			if len > 0.01 then
				local cf = CFrame.lookAt((a + b) / 2, b)
				for layer = 1, 2 do
					local p = Instance.new("Part")
					p.Anchored = true
					p.CanCollide = false
					p.CanQuery = false
					p.CanTouch = false
					p.CastShadow = false
					p.Material = Enum.Material.Neon
					p.Transparency = 1
					if layer == 1 then
						p.Color = Color3.new(1, 1, 1)
						p.Size = Vector3.new(w, w, len)
					else
						p.Color = Color3.fromRGB(170, 195, 255)
						p.Size = Vector3.new(w * 4, w * 4, len)
					end
					p.CFrame = cf
					p.Parent = folder
					table.insert(layer == 1 and core or glow, p)
				end
			end
		end
	end

	local width = math.clamp(dist * 0.009, 0.6, 4.5)
	local main = jag(top, ground, 5, 0.28)
	addLine(main, width)
	for _ = 1, math.random(2, 4) do
		local start = main[math.random(4, #main - 6)]
		local bdir = Vector3.new((math.random() - 0.5) * 1.6, -0.6 - math.random() * 0.5, (math.random() - 0.5) * 1.6).Unit
		local blen = (top - ground).Magnitude * (0.12 + math.random() * 0.18)
		addLine(jag(start, start + bdir * blen, 3, 0.3), width * 0.5)
	end

	-- Light on the ground where it hits
	local lp = Instance.new("Part")
	lp.Anchored = true
	lp.CanCollide = false
	lp.CanQuery = false
	lp.CanTouch = false
	lp.Transparency = 1
	lp.Size = Vector3.new(1, 1, 1)
	lp.Position = ground + Vector3.new(0, 6, 0)
	lp.Parent = folder
	local light = Instance.new("PointLight")
	light.Range = 90
	light.Brightness = 0
	light.Color = Color3.fromRGB(190, 210, 255)
	light.Shadows = false
	light.Parent = lp

	strike.bolt = { folder = folder, core = core, glow = glow, light = light }
end

weather.updateBolt = function(strike, a)
	local b = strike.bolt
	if not b then return end
	local f = a * (0.8 + math.random() * 0.2) -- slight flicker
	local tc = 1 - math.clamp(f * 1.2, 0, 1)
	local tg = 1 - math.clamp(f * 0.45, 0, 1)
	for _, p in ipairs(b.core) do p.Transparency = tc end
	for _, p in ipairs(b.glow) do p.Transparency = tg end
	b.light.Brightness = f * (3 + 5 * strike.close)
	if strike.t > 0.65 then weather.clearBolt(strike) end
end

weather.clearBolt = function(strike)
	local b = strike.bolt
	if b then
		strike.bolt = nil
		if b.folder then b.folder:Destroy() end
	end
end

-- Random strikes during heavy rain: a double flash, then thunder after a delay
local function updateLightning(dt)
	local w = weather
	local stormy = CONFIG.ENABLE_LIGHTNING and w.rain >= CONFIG.LIGHTNING_MIN_RAIN

	if stormy and not w.lightning then
		w.lightningTimer = w.lightningTimer - dt
		if w.lightningTimer <= 0 then
			w.lightning = { t = 0, thunderAt = 0.4 + math.random() * 3.5, thundered = false, dist = 250, close = 0.5, vol = 1 }
			safeCall("lightning bolt", weather.spawnBolt, w.lightning)
			w.lightningTimer = randRange(CONFIG.LIGHTNING_MIN_GAP, CONFIG.LIGHTNING_MAX_GAP)
		end
	end

	local flash = 0
	local strike = w.lightning
	if strike then
		strike.t = strike.t + dt
		local t = strike.t
		local raw = math.max(pulse(t, 0, 0.05, 0.28, 1), pulse(t, 0.22, 0.3, 0.6, 0.65))
		flash = raw * (0.45 + 0.55 * strike.close) -- far strikes light the whole scene less
		if strike.bolt then safeCall("lightning bolt", weather.updateBolt, strike, raw) end

		if not strike.thundered and t >= strike.thunderAt then
			strike.thundered = true
			if w.thunderSound then
				w.thunderSound.Volume = CONFIG.THUNDER_VOLUME * (1 - w.sheltered * 0.5) * strike.vol
				w.thunderSound.PlaybackSpeed = 0.85 + math.random() * 0.3
				w.thunderSound.TimePosition = 0
				w.thunderSound:Play()
			end
			landingVelocity = landingVelocity - (0.15 + 0.5 * strike.close) -- camera rumble, stronger when close
		end

		if strike.thundered and t > 0.7 then
			weather.clearBolt(strike)
			w.lightning = nil
		end
	end
	return flash
end

-- True if something solid and collidable (not leaves, glass or invisible parts) is overhead
local function roofAbove(character)
	local origin = Camera.CFrame.Position
	local filter = { character }
	for _ = 1, 6 do
		sharedRayParams.FilterDescendantsInstances = filter
		local result = Workspace:Raycast(origin, Vector3.new(0, CONFIG.SHELTER_CHECK_HEIGHT, 0), sharedRayParams)
		if not result then return false end
		if result.Instance.CanCollide and result.Instance.Transparency < 0.5 then return true end
		table.insert(filter, result.Instance)
	end
	return false
end

local function updateWeather(dt, character)
	local w = weather
	if not CONFIG.ENABLE_WEATHER then
		w.rain = 0
		w.flash = 0
		if w.emitter then w.emitter.Rate = 0 end
		return
	end

	-- Schedule: dry spell -> shower -> dry spell ... (every shower ends when its timer runs out)
	w.timer = w.timer - dt
	if w.timer <= 0 then
		if w.target > 0 then
			w.target = 0
			w.timer = randRange(CONFIG.CLEAR_MIN_TIME, CONFIG.CLEAR_MAX_TIME)
			showNotice("The rain is clearing")
		else
			w.target = randRange(CONFIG.RAIN_MIN_INTENSITY, 1)
			w.timer = randRange(CONFIG.RAIN_MIN_TIME, CONFIG.RAIN_MAX_TIME)
			showNotice("It starts to rain")
		end
	end

	-- Fade the rain in and out
	local step = dt / math.max(CONFIG.RAIN_FADE_TIME, 0.1)
	if w.rain < w.target then
		w.rain = math.min(w.target, w.rain + step)
	else
		w.rain = math.max(w.target, w.rain - step)
	end

	-- Is there a roof over your head? (throttled)
	w.shelterTimer = w.shelterTimer + dt
	if w.shelterTimer >= 0.15 then
		w.shelterTimer = 0
		w.shelterTarget = roofAbove(character) and 1 or 0
	end
	w.sheltered = w.sheltered + (w.shelterTarget - w.sheltered) * math.clamp(dt * 4, 0, 1)

	-- The ground soaks up rain and dries out slowly afterward
	if w.rain > 0.15 then
		w.wet = math.min(1, w.wet + dt * 0.12)
	else
		w.wet = math.max(0, w.wet - dt * 0.01)
	end

	-- Rain curtain follows the camera; nothing falls on you under a roof
	if w.part and w.emitter then
		w.part.CFrame = CFrame.new(Camera.CFrame.Position + Vector3.new(0, CONFIG.RAIN_HEIGHT, 0))
		w.emitter.Rate = w.rain * (1 - w.sheltered) * CONFIG.RAIN_RATE_MAX
	end

	w.flash = updateLightning(dt)
end

--------------------------------------------------------------------------------
-- 6f-2. WATER (terrain water look, splashes, ripples, wake, underwater)
--------------------------------------------------------------------------------
-- Everything lives in ONE table so it costs a single local variable.
-- Works on Terrain water. Water made from Parts is not touched.
local water = {
	cfg = {
		ENABLE = true,
		LOOK = true,                -- retune terrain water colour / clarity / waves with time + weather
		UNDERWATER = true,          -- tint, fog, blur, muffled sound, bubbles under the surface
		SPLASH_SOUND = "rbxasset://sounds/impact_water.mp3", -- built into the Roblox client
		SPLASH_VOLUME = 0.9,
		SPRAY_TEXTURE = "rbxasset://textures/particles/smoke_main.dds", -- built-in soft puff
	},
	terrain = nil,
	snd = nil,
	backup = nil,
	reverbBackup = nil,
	cur = nil,
	applyT = 0,
	rayParams = nil,
	folder = nil,
	rigs = {},
	rigIndex = 0,
	rings = {},
	wakePart = nil,
	wakeEmitter = nil,
	camPart = nil,
	dust = nil,
	bubPart = nil,
	bubbles = nil,
	cc = nil,
	blur = nil,
	char = nil,
	wasIn = nil,
	wasUnder = false,
	under = 0,
	underTime = 0,
	entryS = 0.3,
	prevVel = Vector3.zero,
	lastSurf = nil,
	stepT = 0,
	swimT = 0,
	rainT = 0,
	breathT = 4,
	reverbOn = false,
	pitters = {},
	pitIdx = 0,
	hitBudget = 5,
}

-- Is this point inside terrain water? Returns (true, surfaceY) or false.
-- Terrain is read in 4-stud voxels; the voxel's fill level gives the surface height.
water.probe = function(p)
	local t = water.terrain
	if not t then return false end
	local cx = math.floor(p.X / 4) * 4
	local cy = math.floor(p.Y / 4) * 4
	local cz = math.floor(p.Z / 4) * 4
	local ok, mats, occ = pcall(t.ReadVoxels, t, Region3.new(Vector3.new(cx, cy, cz), Vector3.new(cx + 4, cy + 4, cz + 4)), 4)
	if not ok or mats[1][1][1] ~= Enum.Material.Water then return false end
	local o = occ[1][1][1]
	local top = cy + 4 * o
	if p.Y >= top then return false end
	-- Full voxel: the surface may be a few voxels higher
	local steps = 0
	while o >= 0.99 and steps < 6 do
		steps = steps + 1
		cy = cy + 4
		local ok2, m2, o2 = pcall(t.ReadVoxels, t, Region3.new(Vector3.new(cx, cy, cz), Vector3.new(cx + 4, cy + 4, cz + 4)), 4)
		if not ok2 or m2[1][1][1] ~= Enum.Material.Water then break end
		o = o2[1][1][1]
		top = cy + 4 * o
	end
	return true, top
end

water.part = function(name, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.Parent = water.folder
	return p
end

water.emitter = function(part, props)
	local e = Instance.new("ParticleEmitter")
	e.Texture = water.cfg.SPRAY_TEXTURE
	e.Enabled = false
	e.Rate = 0
	for k, v in pairs(props) do e[k] = v end
	e.Parent = part
	return e
end

water.makeRing = function()
	local part = water.part("Ring", Vector3.new(1, 0.05, 1))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(200, 200)
	gui.LightInfluence = 0.6
	gui.Brightness = 1.4
	gui.Enabled = false
	gui.Parent = part
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(0.94, 0.94)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(235, 245, 255)
	stroke.Thickness = 4
	stroke.Transparency = 1
	stroke.Parent = f
	return { part = part, gui = gui, stroke = stroke, active = false, age = 0, life = 1, s0 = 1, s1 = 3, strength = 1 }
end

water.makeRig = function()
	local part = water.part("Splash", Vector3.new(0.2, 0.2, 0.2))
	local drops = water.emitter(part, {
		Color = ColorSequence.new(Color3.fromRGB(235, 245, 255)),
		Size = NumberSequence.new(0.24, 0.06),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.7, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.55, 1.0),
		Speed = NumberRange.new(9, 18),
		SpreadAngle = Vector2.new(35, 35),
		Acceleration = Vector3.new(0, -55, 0),
		EmissionDirection = Enum.NormalId.Top,
		LightEmission = 0.25,
		LightInfluence = 0.7,
		Drag = 0.4,
	})
	local mist = water.emitter(part, {
		Color = ColorSequence.new(Color3.fromRGB(225, 238, 245)),
		Size = NumberSequence.new(0.8, 3.6),
		Transparency = NumberSequence.new(0.5, 1),
		Lifetime = NumberRange.new(0.7, 1.2),
		Speed = NumberRange.new(1.5, 5),
		SpreadAngle = Vector2.new(70, 70),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		EmissionDirection = Enum.NormalId.Top,
		LightInfluence = 0.9,
		Drag = 2,
	})
	local snd = Instance.new("Sound")
	snd.SoundId = water.cfg.SPLASH_SOUND
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMaxDistance = 90
	snd.Parent = part
	return { part = part, drops = drops, mist = mist, snd = snd }
end

water.setup = function()
	local t = Workspace:FindFirstChildOfClass("Terrain")
	water.terrain = t
	water.snd = game:GetService("SoundService")
	water.reverbBackup = water.snd.AmbientReverb

	if t then
		water.backup = {
			color = t.WaterColor, clarity = t.WaterTransparency, refl = t.WaterReflectance,
			size = t.WaterWaveSize, speed = t.WaterWaveSpeed,
		}
		local b = water.backup
		water.cur = { color = b.color, clarity = b.clarity, refl = b.refl, size = b.size, speed = b.speed }
	end

	water.rayParams = RaycastParams.new()
	water.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	water.rayParams.IgnoreWater = false

	water.folder = trackInstance(Instance.new("Folder"))
	water.folder.Name = "RealismWater"
	water.folder.Parent = Workspace

	for _ = 1, 6 do table.insert(water.rigs, water.makeRig()) end
	for _ = 1, 16 do table.insert(water.rings, water.makeRing()) end

	-- Foam that trails behind you while wading or swimming at the surface
	water.wakePart = water.part("Wake", Vector3.new(1.5, 0.2, 1.5))
	water.wakeEmitter = water.emitter(water.wakePart, {
		Color = ColorSequence.new(Color3.fromRGB(235, 245, 250)),
		Size = NumberSequence.new(0.9, 2.8),
		Transparency = NumberSequence.new(0.55, 1),
		Lifetime = NumberRange.new(1.2, 1.8),
		Speed = NumberRange.new(0.2, 0.8),
		SpreadAngle = Vector2.new(80, 80),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
		EmissionDirection = Enum.NormalId.Top,
		LightInfluence = 0.9,
		Enabled = true,
	})

	-- Floating specks around the camera (gives depth underwater) and bubbles
	water.camPart = water.part("Dust", Vector3.new(26, 18, 26))
	water.dust = water.emitter(water.camPart, {
		Color = ColorSequence.new(Color3.fromRGB(190, 225, 225)),
		Size = NumberSequence.new(0.07),
		Transparency = NumberSequence.new(0.6),
		Lifetime = NumberRange.new(4, 6),
		Speed = NumberRange.new(0.1, 0.5),
		SpreadAngle = Vector2.new(180, 180),
		LightInfluence = 0.6,
		Shape = Enum.ParticleEmitterShape.Box,
		Enabled = true,
	})
	water.bubPart = water.part("Bubbles", Vector3.new(0.5, 0.5, 0.5))
	water.bubbles = water.emitter(water.bubPart, {
		Color = ColorSequence.new(Color3.fromRGB(220, 240, 245)),
		Size = NumberSequence.new(0.15, 0.4),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(1.2, 2.4),
		Speed = NumberRange.new(0.5, 1.5),
		SpreadAngle = Vector2.new(25, 25),
		Acceleration = Vector3.new(0, 4, 0),
		EmissionDirection = Enum.NormalId.Top,
		LightEmission = 0.4,
		LightInfluence = 0.6,
		Drag = 1.5,
	})

	-- Tiny crowns where raindrops hit the water (a few parts so several can pop in one frame)
	for _ = 1, 5 do
		local pp = water.part("Pitter", Vector3.new(0.2, 0.2, 0.2))
		local em = water.emitter(pp, {
			Color = ColorSequence.new(Color3.fromRGB(235, 245, 255)),
			Size = NumberSequence.new(0.13, 0.03),
			Transparency = NumberSequence.new(0.2, 1),
			Lifetime = NumberRange.new(0.25, 0.4),
			Speed = NumberRange.new(2.5, 5),
			SpreadAngle = Vector2.new(30, 30),
			Acceleration = Vector3.new(0, -30, 0),
			EmissionDirection = Enum.NormalId.Top,
			LightEmission = 0.3,
			LightInfluence = 0.7,
		})
		table.insert(water.pitters, { part = pp, em = em })
	end

	-- Our own colour grading + blur for being underwater (does not touch the main grading)
	water.cc = trackInstance(Instance.new("ColorCorrectionEffect"))
	water.cc.Name = "RealismWaterCC"
	water.cc.Enabled = false
	water.cc.Parent = Lighting
	water.blur = trackInstance(Instance.new("BlurEffect"))
	water.blur.Name = "RealismWaterBlur"
	water.blur.Size = 0
	water.blur.Enabled = false
	water.blur.Parent = Lighting
end

water.restore = function()
	local b, t = water.backup, water.terrain
	if b and t and t.Parent then
		t.WaterColor = b.color
		t.WaterTransparency = b.clarity
		t.WaterReflectance = b.refl
		t.WaterWaveSize = b.size
		t.WaterWaveSpeed = b.speed
	end
	if water.snd and water.reverbBackup then
		pcall(function() water.snd.AmbientReverb = water.reverbBackup end)
	end
end

-- Ring ripple on the surface (pooled; oldest is reused when all are busy)
water.ring = function(x, y, z, s0, s1, life, strength)
	local pick, oldest = nil, nil
	for _, r in ipairs(water.rings) do
		if not r.active then
			pick = r
			break
		end
		if not oldest or r.age / r.life > oldest.age / oldest.life then oldest = r end
	end
	pick = pick or oldest
	if not pick then return end
	pick.active = true
	pick.age = 0
	pick.life = life
	pick.s0 = s0
	pick.s1 = s1
	pick.strength = strength
	pick.part.CFrame = CFrame.new(x, y + 0.08, z)
	pick.part.Size = Vector3.new(s0, 0.05, s0)
	pick.gui.Enabled = true
end

water.updateRings = function(dt)
	for _, r in ipairs(water.rings) do
		if r.active then
			r.age = r.age + dt
			local a = r.age / r.life
			if a >= 1 then
				r.active = false
				r.gui.Enabled = false
			else
				local size = r.s0 + (r.s1 - r.s0) * (1 - (1 - a) * (1 - a))
				r.part.Size = Vector3.new(size, 0.05, size)
				r.stroke.Thickness = math.clamp(26 / size, 1.2, 14)
				local alpha = (1 - a) * (1 - a) * r.strength
				r.stroke.Transparency = 1 - alpha * 0.85
			end
		end
	end
end

-- Splash at the surface. s = strength 0..1 (jumping in from height = 1, a wading step = ~0.15)
water.splash = function(x, y, z, s, quiet)
	water.rigIndex = water.rigIndex % #water.rigs + 1
	local rig = water.rigs[water.rigIndex]
	rig.part.CFrame = CFrame.new(x, y + 0.15, z)
	rig.drops.Speed = NumberRange.new(5 + 8 * s, 10 + 16 * s)
	rig.drops.SpreadAngle = Vector2.new(40 - 20 * s, 40 - 20 * s)
	rig.drops:Emit(math.floor(8 + 62 * s))
	rig.mist:Emit(math.floor(3 + 16 * s))

	water.ring(x, y, z, 0.8, 3 + 7 * s, 0.9 + 0.7 * s, 0.6 + 0.4 * s)
	if s > 0.4 then
		water.ring(x, y, z, 0.4, 2 + 4 * s, 0.7 + 0.4 * s, 0.7)
	end

	rig.snd.Volume = water.cfg.SPLASH_VOLUME * (quiet and 0.35 or 1) * (0.3 + 0.7 * s)
	rig.snd.PlaybackSpeed = (quiet and 1.25 or 1.1) - 0.35 * s + math.random() * 0.12
	rig.snd:Play()
end

-- Terrain water colour, clarity, reflection and waves follow time of day and weather
water.look = function(dt, day, golden)
	local t, c = water.terrain, water.cur
	if not t or not c then return end
	local rain = weather.rain

	local col = Color3.fromRGB(8, 20, 34):Lerp(Color3.fromRGB(40, 104, 112), day)
	local storm = Color3.fromRGB(72, 90, 92):Lerp(Color3.fromRGB(18, 24, 30), 1 - day)
	col = col:Lerp(storm, rain * 0.75)

	local k = math.clamp(dt * 0.8, 0, 1)
	c.color = c.color:Lerp(col, k)
	c.clarity = c.clarity + ((0.78 - rain * 0.28 - (1 - day) * 0.15) - c.clarity) * k
	c.refl = c.refl + (math.clamp(0.9 - rain * 0.35 + golden * 0.1, 0, 1) - c.refl) * k
	c.size = c.size + ((0.16 + rain * 0.36) - c.size) * k
	c.speed = c.speed + ((10 + rain * 9) - c.speed) * k

	water.applyT = water.applyT + dt
	if water.applyT >= 0.15 then
		water.applyT = 0
		t.WaterColor = c.color
		t.WaterTransparency = c.clarity
		t.WaterReflectance = c.refl
		t.WaterWaveSize = c.size
		t.WaterWaveSpeed = c.speed
	end
end

water.update = function(dt, day, golden, humanoid, hrp)
	local cfg = water.cfg
	if not cfg.ENABLE or not water.terrain then return end
	local cam = Camera
	if not cam then return end

	-- New character (respawn): forget old state
	local char = hrp.Parent
	if char ~= water.char then
		water.char = char
		water.wasIn = nil
		water.wasUnder = false
		water.rayParams.FilterDescendantsInstances = { char }
	end

	if cfg.LOOK then water.look(dt, day, golden) end
	water.updateRings(dt)

	local pos = hrp.Position
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude

	-- Body in water? (the root part is roughly your waist)
	local bodyIn, bodySurf = water.probe(pos)
	if not bodyIn and humanoid:GetState() == Enum.HumanoidStateType.Swimming then
		bodyIn, bodySurf = true, pos.Y + 1
	end
	if water.wasIn == nil then water.wasIn = bodyIn end

	if bodyIn and not water.wasIn then
		-- Jumped or fell in: bigger and faster = bigger splash
		local pv = water.prevVel
		local s = math.clamp(0.2 + math.max(0, -pv.Y) / 55 + Vector3.new(pv.X, 0, pv.Z).Magnitude / 90, 0.2, 1)
		water.entryS = s
		water.splash(pos.X, bodySurf or pos.Y, pos.Z, s)
	elseif not bodyIn and water.wasIn then
		water.splash(pos.X, water.lastSurf or (pos.Y - 2), pos.Z, 0.22, true)
	end
	water.wasIn = bodyIn
	if bodySurf then water.lastSurf = bodySurf end
	water.prevVel = vel

	-- Camera in water?
	local camPos = cam.CFrame.Position
	local camIn, camSurf = water.probe(camPos)

	-- Wading: feet in water, body out. Splashy steps.
	local footDrop = humanoid.RigType == Enum.HumanoidRigType.R6 and 3 or (humanoid.HipHeight + hrp.Size.Y * 0.5)
	local feetY = pos.Y - footDrop + 0.2
	local feetIn, feetSurf = false, nil
	if not bodyIn then
		feetIn, feetSurf = water.probe(Vector3.new(pos.X, feetY, pos.Z))
	end
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local wading = feetIn and grounded and flat > 3
	water.stepT = water.stepT - dt
	if wading and water.stepT <= 0 then
		local depth = math.clamp(feetSurf - feetY, 0, 4)
		water.splash(pos.X, feetSurf, pos.Z, math.clamp(0.12 + flat / 70 + depth * 0.05, 0.1, 0.45), true)
		water.stepT = math.clamp(7.5 / flat, 0.22, 0.6)
	end

	-- Foam wake + swimming ripples at the surface
	local surfaceSwim = bodyIn and not camIn
	local wakeRate = 0
	if surfaceSwim and flat > 1 then
		wakeRate = math.clamp(flat * 1.4, 3, 22)
	elseif wading then
		wakeRate = math.clamp(flat * 0.6, 2, 10)
	end
	water.wakeEmitter.Rate = wakeRate
	if wakeRate > 0 then
		local sy = (surfaceSwim and bodySurf) or feetSurf or pos.Y
		water.wakePart.CFrame = CFrame.new(pos.X, sy + 0.1, pos.Z)
	end
	if surfaceSwim and bodySurf then
		water.swimT = water.swimT - dt
		if water.swimT <= 0 then
			water.swimT = flat > 1 and 0.5 or 0.9
			water.ring(pos.X, bodySurf, pos.Z, 1.4, 4.8, 1.5, 0.7)
		end
	end

	water.hitBudget = 5 -- raindrop splashes allowed before the next frame (see water.rainHit)

	-- Underwater look
	if not cfg.UNDERWATER then return end
	local u = water.under
	u = u + ((camIn and 1 or 0) - u) * math.clamp(dt * 10, 0, 1)
	if u < 0.01 then u = 0 end
	water.under = u

	local forward = cam.CFrame.LookVector
	if camIn and not water.wasUnder then
		-- Dunked: bubbles rush past the lens
		water.bubPart.CFrame = CFrame.new(camPos + forward * 1.0 - Vector3.new(0, 0.5, 0))
		water.bubbles:Emit(math.floor(18 + 40 * water.entryS))
		water.breathT = 3 + math.random() * 3
	elseif water.wasUnder and not camIn then
		-- Surfaced: water runs down the lens
		local n = math.clamp(math.floor(4 + water.underTime * 2), 4, 14)
		for _ = 1, n do spawnScreenDrop(false) end
	end
	water.wasUnder = camIn and true or false
	if camIn then water.underTime = water.underTime + dt else water.underTime = 0 end

	if u > 0 then
		local depth = camSurf and math.max(0, camSurf - camPos.Y) or 0
		local dark = math.clamp(depth / 60, 0, 0.7)
		local light = (0.25 + 0.75 * day) * (1 - dark)
		local fog = Color3.fromRGB(34, 110, 120):Lerp(Color3.new(0, 0, 0), 1 - light)

		atmosphere.Color = atmosphere.Color:Lerp(fog, u)
		atmosphere.Decay = atmosphere.Decay:Lerp(fog, u)
		atmosphere.Density = atmosphere.Density + (0.85 - atmosphere.Density) * u
		atmosphere.Haze = atmosphere.Haze * (1 - u)

		water.cc.Enabled = true
		water.cc.TintColor = WHITE:Lerp(Color3.fromRGB(150, 225, 225), u)
		water.cc.Saturation = -0.12 * u
		water.cc.Contrast = -0.05 * u
		water.cc.Brightness = -(0.04 + dark * 0.12) * u
		water.blur.Enabled = true
		water.blur.Size = 3.5 * u

		water.camPart.CFrame = CFrame.new(camPos)
		water.dust.Rate = 40 * u

		if camIn then
			water.breathT = water.breathT - dt
			if water.breathT <= 0 then
				water.breathT = 3 + math.random() * 3
				water.bubPart.CFrame = CFrame.new(camPos + forward * 0.9 - Vector3.new(0, 0.4, 0))
				water.bubbles:Emit(math.random(5, 9))
			end
		end
	else
		water.cc.Enabled = false
		water.blur.Enabled = false
		water.dust.Rate = 0
	end

	-- Muffled sound under the surface
	if u > 0.5 and not water.reverbOn then
		water.reverbOn = true
		pcall(function() water.snd.AmbientReverb = Enum.ReverbType.UnderWater end)
	elseif u < 0.2 and water.reverbOn then
		water.reverbOn = false
		pcall(function() water.snd.AmbientReverb = water.reverbBackup end)
	end
end

-- Called by the rain when a drop lands on water: tiny ring + crown, a few per frame
water.rainHit = function(x, y, z)
	if water.hitBudget <= 0 or not water.cfg.ENABLE or math.random() > 0.4 then return end
	water.hitBudget = water.hitBudget - 1
	water.ring(x, y, z, 0.25, 1.1 + weather.rain * 0.7, 0.45 + math.random() * 0.25, 0.5)
	water.pitIdx = water.pitIdx % #water.pitters + 1
	local pit = water.pitters[water.pitIdx]
	if pit then
		pit.part.CFrame = CFrame.new(x, y + 0.05, z)
		pit.em:Emit(2)
	end
end

safeCall("water setup", water.setup)
weather.onLand = function(x, y, z) water.rainHit(x, y, z) end

--------------------------------------------------------------------------------
-- 6g. TEMPERATURE
--------------------------------------------------------------------------------
-- Track every Fire object in the world so campfires (yours or the game's) can warm you
local function trackFire(d)
	if d:IsA("Fire") then temp.fires[d] = true end
end
pcall(function()
	for _, d in ipairs(Workspace:GetDescendants()) do trackFire(d) end
end)
track(Workspace.DescendantAdded:Connect(trackFire))
track(Workspace.DescendantRemoving:Connect(function(d)
	if d:IsA("Fire") then temp.fires[d] = nil end
end))

-- 0..1: how much warmth the nearest lit fire gives you at this position
local function fireWarmth(pos)
	local best = 0
	local radius = CONFIG.TEMP_FIRE_RADIUS
	for fire in pairs(temp.fires) do
		local holder = fire.Parent
		local firePos = nil
		if holder and holder:IsA("BasePart") then
			firePos = holder.Position
		elseif holder and holder:IsA("Attachment") then
			firePos = holder.WorldPosition
		end
		if fire.Enabled and firePos then
			local dist = (firePos - pos).Magnitude
			local warmth = math.clamp(1 - (dist - radius * 0.3) / (radius * 0.7), 0, 1)
			if warmth > best then best = warmth end
		end
	end
	return best
end

-- Light a campfire on the ground a few studs ahead of you
placeCampfire = function()
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	if weather.rain * (1 - weather.sheltered) > 0.6 then
		showNotice("It's too wet to light a fire out here")
		return
	end

	local origin = hrp.Position + hrp.CFrame.LookVector * 4
	local hit = firstSolidHit(origin, Vector3.new(0, -10, 0), character)
	if not hit then
		showNotice("No solid ground to light a fire on")
		return
	end

	-- One campfire at a time
	if temp.campfire and temp.campfire.folder then temp.campfire.folder:Destroy() end

	local folder = trackInstance(Instance.new("Folder"))
	folder.Name = "RealismCampfire"
	local base = CFrame.new(hit.Position + Vector3.new(0, 0.05, 0))

	local function part(name, shape, size, cf, color, material)
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = shape
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = folder
		return p
	end

	-- Ash bed, a ring of leaning logs, and glowing embers in the middle
	part("Ash", Enum.PartType.Cylinder, Vector3.new(0.1, 3, 3), base * UPRIGHT, Color3.fromRGB(45, 40, 38), Enum.Material.Slate)
	for i = 1, 5 do
		part("Log" .. i, Enum.PartType.Cylinder, Vector3.new(2.2, 0.35, 0.35),
			base * CFrame.Angles(0, math.rad(i * 72), 0) * CFrame.new(0.9, 0.5, 0) * CFrame.Angles(0, 0, math.rad(-25)),
			Color3.fromRGB(95, 62, 38), Enum.Material.Wood)
	end
	local embers = part("Embers", Enum.PartType.Ball, Vector3.new(1.1, 0.6, 1.1), base * CFrame.new(0, 0.3, 0),
		Color3.fromRGB(255, 120, 40), Enum.Material.Neon)
	embers.Transparency = 0.25

	local fire = Instance.new("Fire")
	fire.Size = 7
	fire.Heat = 9
	fire.Color = Color3.fromRGB(255, 150, 50)
	fire.SecondaryColor = Color3.fromRGB(200, 40, 10)
	fire.Parent = embers

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Range = 26
	light.Brightness = 2
	light.Parent = embers

	folder.Parent = Workspace
	temp.campfire = { folder = folder, fire = fire, light = light, embers = embers, born = os.clock() }
	showNotice("You light a campfire")
end

local function updateTemperature(dt, character, humanoid, hrp)
	-- Keep your campfire burning, flickering, then dying out
	local cf = temp.campfire
	if cf then
		local age = os.clock() - cf.born
		if not cf.folder.Parent then
			temp.campfire = nil
		elseif age > CONFIG.CAMPFIRE_LIFETIME + 20 then
			cf.folder:Destroy()
			temp.campfire = nil
		elseif age > CONFIG.CAMPFIRE_LIFETIME then
			cf.fire.Enabled = false
			cf.light.Brightness = math.max(0, cf.light.Brightness - dt * 0.5)
			cf.embers.Transparency = math.min(1, cf.embers.Transparency + dt * 0.05)
		else
			cf.light.Brightness = 2 + math.sin(os.clock() * 17) * 0.3 + math.random() * 0.4
		end
	end

	if not CONFIG.ENABLE_TEMPERATURE then
		temp.body = 0
		return
	end

	-- Shade and fire checks (throttled)
	temp.timer = temp.timer + dt
	if temp.timer >= 0.3 then
		temp.timer = 0
		local sunDir = Lighting:GetSunDirection()
		local blocked = sunDir.Y < -0.05 or firstSolidHit(Camera.CFrame.Position, sunDir * 500, character) ~= nil
		temp.shadeTarget = (blocked or weather.sheltered > 0.5) and 1 or 0
		temp.fire = fireWarmth(hrp.Position)
	end
	temp.shade = temp.shade + (temp.shadeTarget - temp.shade) * math.clamp(dt * 3, 0, 1)

	-- What the surroundings feel like right now: sun height sets heat and cold
	local sunHeight = Lighting:GetSunDirection().Y
	local hot = math.clamp((sunHeight - 0.45) / 0.5, 0, 1)
	local cold = math.clamp((0.1 - sunHeight) / 0.7, 0, 1)
	hot = hot * (1 - weather.rain * 0.5) * (1 - CONFIG.TEMP_SHADE_RELIEF * temp.shade)
	cold = cold * (1 - 0.3 * weather.sheltered) -- a roof blocks some of the wind
	local soaked = weather.rain * (1 - weather.sheltered) * 0.3 -- rain chills you
	local target = math.clamp(hot - cold - soaked + temp.fire * CONFIG.TEMP_FIRE_HEAT, -1, 1)

	-- Your body follows slowly, so a quick dash through the sun or cold barely matters
	temp.body = temp.body + (target - temp.body) * math.clamp(dt * CONFIG.TEMP_ADJUST_RATE, 0, 1)

	-- Staying at the extreme hurts
	local extreme = math.abs(temp.body)
	if extreme > CONFIG.TEMP_DAMAGE_START and humanoid.Health > 0 then
		local k = (extreme - CONFIG.TEMP_DAMAGE_START) / math.max(1 - CONFIG.TEMP_DAMAGE_START, 0.01)
		humanoid.Health = math.max(0, humanoid.Health - CONFIG.TEMP_DAMAGE_RATE * k * dt)
		lastHealth = humanoid.Health -- slow damage shouldn't trigger the adrenaline spike
	end

	if extreme > 0.6 and os.clock() - temp.warned > 60 then
		temp.warned = os.clock()
		if temp.body < 0 then
			showNotice("You're freezing - find shelter or a fire")
		else
			showNotice("You're overheating - find shade and drink")
		end
	end

	-- Shivering: small random tremors in the camera
	if temp.body < -0.3 then
		landingVelocity = landingVelocity + (math.random() - 0.5) * (-temp.body) * 1.2 * (dt * 60)
	end
end

--------------------------------------------------------------------------------
-- 6h. FALL INJURIES
--------------------------------------------------------------------------------
-- Called on a hard landing. Harder falls stack more on top of the normal fall damage:
-- a stumble first, then a sprained ankle (limp), then being knocked off your feet.
local function applyFallInjuries(character, humanoid, hrp, speed)
	local severity = math.clamp(
		(speed - CONFIG.FALL_STUMBLE_SPEED) / math.max(CONFIG.FALL_KNOCKDOWN_SPEED - CONFIG.FALL_STUMBLE_SPEED, 1),
		0, 1
	)

	-- Stumble: you stagger, lose some breath, and the screen lurches
	local dur = CONFIG.STUMBLE_MIN_TIME + (CONFIG.STUMBLE_MAX_TIME - CONFIG.STUMBLE_MIN_TIME) * severity
	fall.stumbleT = dur
	fall.stumbleDur = dur
	fall.dir = (math.random() < 0.5) and -1 or 1
	stamina = math.max(0, stamina - CONFIG.STUMBLE_STAMINA_COST * (0.5 + severity * 0.5))
	landingVelocity = landingVelocity - 3 - severity * 4
	showNotice("You stumble on the landing")

	-- Sprained ankle: you limp for a while, even at full health
	if speed > CONFIG.FALL_SPRAIN_SPEED then
		local s = math.clamp(
			(speed - CONFIG.FALL_SPRAIN_SPEED) / math.max(CONFIG.FALL_KNOCKDOWN_SPEED - CONFIG.FALL_SPRAIN_SPEED, 1),
			0, 1
		)
		fall.sprainLeft = math.max(fall.sprainLeft, CONFIG.SPRAIN_MIN_TIME + (CONFIG.SPRAIN_MAX_TIME - CONFIG.SPRAIN_MIN_TIME) * s)
		fall.sprainStrength = math.max(fall.sprainStrength, 0.5 + 0.5 * s)
		showNotice("You twisted your ankle")
	end

	-- Knockdown: thrown to the ground for a moment
	if speed >= CONFIG.FALL_KNOCKDOWN_SPEED and humanoid.Health > 0 and not ragdollData then
		local camLook = Camera.CFrame.LookVector
		local look = Vector3.new(camLook.X, 0, camLook.Z)
		if look.Magnitude < 0.01 then
			look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		end
		look = look.Unit
		fall.knock = { t = 0, dur = randRange(CONFIG.KNOCKDOWN_MIN_TIME, CONFIG.KNOCKDOWN_MAX_TIME), look = look }
		startRagdoll(character, look * 0.3)
	end
end

runFallTest = function(speed)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 and not faint then
		applyFallInjuries(char, hum, root, speed)
	end
end

local function updateKnockdown(dt, character, humanoid, hrp)
	local k = fall.knock
	if not k then return end
	if faint then
		fall.knock = nil
		return
	end

	peakFallSpeed = 0 -- tumbling shouldn't count as another fall
	k.t = k.t + dt
	if k.t >= k.dur then
		fall.knock = nil
		stopRagdoll(character, humanoid, hrp, k.look)
		fall.stumbleT = 0.8 -- wobbly as you get back up
		fall.stumbleDur = 0.8
	end
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
			bleedSeverity = 0
			bandaging = false
			blackAlpha, blackTarget = 1, 1
			startRagdoll(character)
		end
		updateDeathAudio(deltaTime)
		updateBlackout(0)
		return
	end

	updateFaint(deltaTime, character, humanoid, hrp)
	updateKnockdown(deltaTime, character, humanoid, hrp)
	safeCall("temperature", updateTemperature, deltaTime, character, humanoid, hrp)
	local coldAmt = math.max(0, -temp.body)
	local heatAmt = math.max(0, temp.body)

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

	if fall.knock then peakFallSpeed = 0 end

	if wasAirborne and not airborne then
		if peakFallSpeed > CONFIG.LANDING_MIN_SPEED then
			landingVelocity = landingVelocity - math.clamp(peakFallSpeed * 0.08, 0, 7)
		end

		if peakFallSpeed > CONFIG.FALL_DAMAGE_MIN_SPEED then
			local severity = math.clamp(
				(peakFallSpeed - CONFIG.FALL_DAMAGE_MIN_SPEED) / (CONFIG.FALL_DAMAGE_LETHAL_SPEED - CONFIG.FALL_DAMAGE_MIN_SPEED),
				0, 1
			)
			-- Set health directly like every other damage source here (TakeDamage can do nothing from a LocalScript)
			humanoid.Health = math.max(0, humanoid.Health - humanoid.MaxHealth * severity)
		end

		-- Fall injuries: stumble, then a sprained ankle, then a knockdown
		if peakFallSpeed > CONFIG.FALL_STUMBLE_SPEED and not faint and not fall.knock then
			applyFallInjuries(character, humanoid, hrp, peakFallSpeed)
		end

		peakFallSpeed = 0
	end
	wasAirborne = airborne

	-- A. Health check (damage triggers adrenaline, and big hits can cause bleeding)
	if humanoid.Health < lastHealth then
		adrenaline = 100
		tryStartBleed(lastHealth - humanoid.Health, humanoid.MaxHealth)
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

	-- C2. Sprint & stamina (you can only sprint while standing)
	local flatVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
	local isMoving = flatVelocity.Magnitude > 1.5
	local isAdrenalineActive = adrenaline > 1
	local wantsToSprint = (shiftPressed or mobileSprinting) and isMoving and stance.mode == "stand"

	if stamina <= 0 then
		exhausted = true
	elseif exhausted and stamina >= CONFIG.SPRINT_RESUME_THRESHOLD then
		exhausted = false
	end

	local isSprinting = wantsToSprint and not exhausted

	if isSprinting then
		local drainMultiplier = isAdrenalineActive and CONFIG.ADRENALINE_STAMINA_DRAIN_MULT or 1
		-- Heat drains you faster; strong legs make the sprint last longer
		local fitness = 1 - CONFIG.STAMINA_FITNESS_BONUS * (legStrength / 100)
		stamina = math.clamp(stamina - (CONFIG.STAMINA_DRAIN_RATE * drainMultiplier * fitness * (1 + heatAmt * CONFIG.TEMP_HOT_SPRINT_DRAIN) * deltaTime), 0, CONFIG.MAX_STAMINA)
	else
		-- Walking barely recovers stamina; standing still recovers it quickly
		local regen = isMoving and CONFIG.STAMINA_REGEN_WALK or CONFIG.STAMINA_REGEN_RATE
		regen = regen * (1 - CONFIG.TEMP_REGEN_PENALTY * math.max(coldAmt, heatAmt)) -- extreme temperatures slow recovery
		stamina = math.clamp(stamina + (regen * deltaTime), 0, CONFIG.MAX_STAMINA)
	end

	-- C2b. Pass out after walking too long while exhausted
	if not faint then
		if exhausted and isMoving then
			faintThreshold = faintThreshold or (CONFIG.FAINT_MIN_TIME + math.random() * (CONFIG.FAINT_MAX_TIME - CONFIG.FAINT_MIN_TIME))
			faintTimer = faintTimer + deltaTime
			if faintTimer >= faintThreshold and not fall.knock then
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

	-- C4. Mantling (only from a standing position)
	if not faint and not fall.knock and stance.mode == "stand" then
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
	-- Cold burns food faster; heat makes you thirstier
	hunger = math.clamp(hunger - (CONFIG.HUNGER_DECAY * (1 + coldAmt * CONFIG.TEMP_COLD_HUNGER) * deltaTime), 0, 100)
	thirst = math.clamp(thirst - (CONFIG.THIRST_DECAY * (1 + heatAmt * CONFIG.TEMP_HOT_THIRST) * deltaTime), 0, 100)

	-- E2. Starvation / dehydration damage (both empty = much more damage)
	local emptyBars = (hunger <= 0 and 1 or 0) + (thirst <= 0 and 1 or 0)
	if emptyBars > 0 and humanoid.Health > 0 then
		local rate = (emptyBars >= 2) and CONFIG.STARVE_DAMAGE_BOTH or CONFIG.STARVE_DAMAGE_SINGLE
		humanoid.Health = math.max(0, humanoid.Health - rate * deltaTime)
		lastHealth = humanoid.Health -- slow damage shouldn't trigger the adrenaline spike
	end

	-- E3. Bleeding: steady health drain until a Bandage stops it
	if bleedSeverity > 0 and humanoid.Health > 0 then
		local bleedRate = CONFIG.BLEED_DRAIN_MIN + (CONFIG.BLEED_DRAIN_MAX - CONFIG.BLEED_DRAIN_MIN) * bleedSeverity
		humanoid.Health = math.max(0, humanoid.Health - bleedRate * deltaTime)
		lastHealth = humanoid.Health -- slow damage shouldn't trigger the adrenaline spike or re-roll bleeding
	end

	-- E4. Blood trail on the ground
	safeCall("blood", updateBlood, deltaTime, character, humanoid, hrp)

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

	-- A twisted ankle from a hard fall also makes you limp, easing off over time
	if fall.sprainLeft > 0 then
		fall.sprainLeft = math.max(0, fall.sprainLeft - deltaTime)
		limpFactor = math.max(limpFactor, fall.sprainStrength * math.clamp(fall.sprainLeft / 8, 0, 1))
	else
		fall.sprainStrength = 0
	end
	targetSpeed = targetSpeed * (1 - CONFIG.LIMP_MAX_SLOWDOWN * limpFactor)

	-- Stumble: staggering after a hard landing (slower, with a swaying camera)
	if fall.stumbleT > 0 then
		fall.stumbleT = math.max(0, fall.stumbleT - deltaTime)
		local k = fall.stumbleT / math.max(fall.stumbleDur, 0.01)
		targetSpeed = targetSpeed * (1 - CONFIG.STUMBLE_SLOWDOWN * k)
		fall.roll = math.sin(os.clock() * 14) * math.rad(5) * k * fall.dir
	else
		fall.roll = 0
	end

	-- Wrapping a bandage slows you down
	if bandaging then
		targetSpeed = targetSpeed * CONFIG.BANDAGE_MOVE_MULT
	end

	-- Crouching, crawling and sitting slow you down (stance.cur.speed eases between stances)
	targetSpeed = targetSpeed * stance.cur.speed

	humanoid.WalkSpeed = targetSpeed
	Camera.FieldOfView = Camera.FieldOfView + (targetFOV - Camera.FieldOfView) * math.clamp(deltaTime * 5, 0, 1)

	-- F1b. Weather (rain, shelter, lightning) and screen drops (water + blood)
	safeCall("weather", updateWeather, deltaTime, character)
	safeCall("screen drops", updateScreenDrops, deltaTime)

	-- F2. Sun glare (clouds hide the sun while it rains)
	local sunTarget = getSunExposure(character) * (1 - weather.rain * 0.85)
	local glareRate = sunTarget > sunGlare and CONFIG.SUN_GLARE_RISE or CONFIG.SUN_GLARE_FALL
	sunGlare = sunGlare + (sunTarget - sunGlare) * math.clamp(deltaTime * glareRate, 0, 1)

	-- F2b. Eyes: blinking, and squinting based on how directly (and how strongly) the sun hits you
	safeCall("eyes", eyes.update, deltaTime)

	local day, golden = updateTimeOfDayLighting()
	safeCall("sky", sky.update, deltaTime, day, golden)
	safeCall("water", water.update, deltaTime, day, golden, humanoid, hrp)

	-- Lightning blows out the screen; a roof blocks about half of it
	local flash = weather.flash * (1 - weather.sheltered * 0.5)

	sunRays.Intensity = 0.18 + sunGlare * CONFIG.SUN_RAYS_MAX
	sunRays.Spread = 0.85 + sunGlare * 0.15
	bloom.Intensity = 0.45 + sunGlare * CONFIG.SUN_BLOOM_MAX + flash * 1.2 + heatAmt * 0.3
	bloom.Threshold = 0.92 - sunGlare * 0.4
	bloom.Size = 24 + sunGlare * 40
	atmosphere.Glare = 0.45 + sunGlare * 1.5
	Lighting.ExposureCompensation = sunGlare * CONFIG.SUN_EXPOSURE_MAX + (1 - day) * CONFIG.MOON_EXPOSURE + flash * CONFIG.LIGHTNING_EXPOSURE

	-- F3. Color grading
	local healthPercent = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
	local injury = 1 - healthPercent
	injuryVisual = injuryVisual + (injury - injuryVisual) * math.clamp(deltaTime * 4, 0, 1)
	local blend = math.clamp(deltaTime * 6, 0, 1)

	local targetBrightness = 0.02 + (0.13 * adrenalinePercent) + sunGlare * 0.2 + flash * 0.2
	local targetContrast = 0.15 + (0.05 * adrenalinePercent) - sunGlare * 0.1
	local targetSaturation = 0.1 + (0.1 * adrenalinePercent) - sunGlare * 0.25 - injuryVisual * 0.3 - staminaVisual * 0.15 - weather.rain * 0.12 - coldAmt * 0.1
	local targetTint = WHITE:Lerp(WARM_TINT, golden * day * 0.5 * (1 - weather.rain)):Lerp(CONFIG.COLD_TINT, coldAmt * 0.35):Lerp(CONFIG.HOT_TINT, heatAmt * 0.3):Lerp(PAIN_TINT, injuryVisual * CONFIG.INJURY_TINT_MAX)

	colorCorrection.Brightness = colorCorrection.Brightness + (targetBrightness - colorCorrection.Brightness) * blend
	colorCorrection.Contrast = colorCorrection.Contrast + (targetContrast - colorCorrection.Contrast) * blend
	colorCorrection.Saturation = colorCorrection.Saturation + (targetSaturation - colorCorrection.Saturation) * blend
	colorCorrection.TintColor = colorCorrection.TintColor:Lerp(targetTint, blend)

	-- Red edge glow from injury, with a slow throb while bleeding
	local bleedThrob = bleedSeverity * 0.15 * (0.5 + 0.5 * math.sin(os.clock() * 3))
	local vignetteAlpha = math.clamp(injuryVisual * CONFIG.INJURY_VIGNETTE_MAX + bleedThrob, 0, 1)
	for _, frame in ipairs(damageFrames) do
		frame.BackgroundTransparency = 1 - vignetteAlpha
	end

	local staminaAlpha = staminaVisual * CONFIG.STAMINA_VIGNETTE_MAX
	for _, frame in ipairs(staminaFrames) do
		frame.BackgroundTransparency = 1 - staminaAlpha
	end

	-- Frost creeps in from the edges when cold; a warm glare when hot
	local frostAlpha = math.max(0, (coldAmt - 0.15) / 0.85) * CONFIG.TEMP_VIGNETTE_MAX
	for _, frame in ipairs(coldFrames) do
		frame.BackgroundTransparency = 1 - frostAlpha
	end
	local heatAlpha = math.max(0, (heatAmt - 0.15) / 0.85) * CONFIG.TEMP_VIGNETTE_MAX * 0.5
	for _, frame in ipairs(heatFrames) do
		frame.BackgroundTransparency = 1 - heatAlpha
	end

	-- F3b. Audio
	safeCall("audio", updateAudio, deltaTime, humanoid, flatVelocity.Magnitude, healthPercent)

	-- F4. Dynamic depth of field
	local focusHit = firstSolidHit(Camera.CFrame.Position, Camera.CFrame.LookVector * 500, character)
	local targetFocus = focusHit and (focusHit.Position - Camera.CFrame.Position).Magnitude or 500
	focusDistance = focusDistance + (targetFocus - focusDistance) * math.clamp(deltaTime * CONFIG.DOF_FOCUS_SPEED, 0, 1)
	dof.FocusDistance = focusDistance
	dof.InFocusRadius = math.clamp(focusDistance * 0.6, 8, 60)

	-- G. HUD (the panel eases the bars, pulses low ones and shows clock/weather)
	local hudValues = bars.values
	hudValues.health = healthPercent
	hudValues.hunger = hunger / 100
	hudValues.thirst = thirst / 100
	hudValues.sprint = stamina / CONFIG.MAX_STAMINA
	hudValues.sprinting = isSprinting
	hudValues.strength = legStrength / 100
	hudValues.adrenaline = adrenaline / 100
	hudValues.temp = temp.body
	hudValues.bandaging = bandaging
	if bleedSeverity > 0 then
		-- While a bandage is being wrapped the bar drains toward empty
		local shown = bleedSeverity
		if bandaging then
			shown = bleedSeverity * (1 - math.clamp((os.clock() - bandageStart) / CONFIG.BANDAGE_USE_TIME, 0, 1))
		end
		hudValues.bleed = shown
	else
		hudValues.bleed = 0
	end
	safeCall("hud", bars.update, deltaTime)

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
	puddlePool, puddleIndex = {}, 0
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

	-- A fresh body: wounds heal, bandage cancelled, screen cleared. Weather carries on.
	bleedSeverity = 0
	bandaging = false
	bandageToken = bandageToken + 1
	weather.lightning = nil
	weather.flash = 0
	clearScreenDrops()

	-- Fresh body: comfortable temperature, no injuries
	temp.body = 0
	temp.shade, temp.shadeTarget, temp.fire = 0, 0, 0
	fall.stumbleT, fall.roll = 0, 0
	fall.sprainLeft, fall.sprainStrength = 0, 0
	fall.knock = nil

	-- Fresh eyes: open, no squint, no blink in progress
	eyes.reset()

	-- Standing again (the new character's joints are read in stance.setup)
	stance.ready = false
	stance.char = nil
	stance.joints = {}
	stance.mode = "stand"
	stance.dirty = false
	stance.lastCam = Vector3.zero
	stance.resetCur()
end

-- Each system starts on its own, so one failing never stops the others
local function initCharacter(char)
	safeCall("first-person setup", setupFirstPersonAndBobbing, char)
	task.spawn(safeCall, "gear creation", createClientGears)
	task.spawn(safeCall, "sound setup", setupSounds, char)
	task.spawn(safeCall, "stance setup", stance.setup, char)
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
	resetStateForNewCharacter()
	initCharacter(char)
end))

if LocalPlayer.Character then
	initCharacter(LocalPlayer.Character)
end

-- Stance controls: C cycles Stand > Crouch > Sit > Crawl. Jumping stands you back up.
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if CONFIG.ENABLE_STANCES and input.KeyCode == CONFIG.STANCE_KEY then
		safeCall("stance", stance.cycle)
	end
end))

track(UserInputService.JumpRequest:Connect(function()
	if CONFIG.ENABLE_STANCES and stance.mode ~= "stand" then
		safeCall("stance", stance.set, "stand")
	end
end))

-- Test keys: G = pass out, H = empty hunger and thirst, J = start bleeding, K = toggle a storm
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
		elseif input.KeyCode == Enum.KeyCode.J then
			forceBleed()
		elseif input.KeyCode == Enum.KeyCode.K then
			toggleStorm()
		end
	end))
end

__toast("v8 loaded OK. Tap the lightning squircle (top left) for test buttons. Stance button is above RUN (or press C).")

--------------------------------------------------------------------------------
-- CLEANUP (runs automatically if the script is executed again)
--------------------------------------------------------------------------------
_G.RealismCleanup = function()
	for _, c in ipairs(connections) do c:Disconnect() end
	for _, c in ipairs(charConnections) do c:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)

	-- Put the legs, hips and jump back the way they were
	pcall(stance.restore)
	pcall(sky.restore)
	pcall(water.restore)

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
				if GEAR_NAMES[item.Name] then
					item:Destroy()
				end
			end
		end
	end

	for _, pool in ipairs(bloodPools) do
		if pool then pool:Destroy() end
	end
	table.clear(bloodPools)

	_G.RealismCleanup = nil
end

end, function(e) return debug.traceback(tostring(e), 2) end)

if not __ok then
	__toast("SCRIPT CRASHED: " .. string.match(tostring(__err), "^[^\n]*"))
	warn(__err)
end
