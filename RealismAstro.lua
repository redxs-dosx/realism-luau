-- RealismAstro LocalScript (single-file, client-only)
-- Space events you can trigger from a little menu (or hotkeys), or let them happen on their own:
--   BLACK HOLE  - glowing accretion disk, lensed light ring, pulls you in, time slows, red-shift, swallows you
--   PULSAR      - a neutron star in the sky whose beams sweep past you; every sweep is a flash + blip
--   SUPERNOVA   - a star swells, explodes, a blinding flash, then the shockwave rolls over you
--   METEORS     - a meteor shower of burning streaks
-- It is a separate script from Realism and only uses its own folder, GUI and post-effects,
-- so the two can run together. (With Realism v10, being flung by a black hole makes you tumble.)
-- Menu: tap the little star button on the left side of the screen.
-- Hotkeys: B black hole, P pulsar, N supernova, M meteors, X clear everything.

local __toasts = 0
local function __toast(text)
	text = "[RealismAstro] " .. tostring(text)
	print(text)
	if __toasts >= 6 then return end
	__toasts = __toasts + 1
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", {
					Title = "RealismAstro",
					Text = string.sub(text, 1, 230),
					Duration = 8,
				})
			end)
			if ok then return end
			task.wait(0.5)
		end
	end)
end

__toast("script started")

local __ok, __err = xpcall(function()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local BIND_NAME = "RealismAstroUpdate"

local rng = Random.new()
local function rand(a, b) return rng:NextNumber(a, b) end

--------------------------------------------------------------------------------
-- RE-RUN SAFETY
--------------------------------------------------------------------------------
if _G.RealismAstroCleanup then
	pcall(_G.RealismAstroCleanup)
end

local connections = {}
local created = {}
local function track(c) table.insert(connections, c) return c end
local function make(inst) table.insert(created, inst) return inst end

local reported = {}
local function reportError(where, err)
	local key = where .. "|" .. tostring(err)
	if not reported[key] then
		reported[key] = true
		warn("[RealismAstro] error in " .. where .. ": " .. tostring(err))
		__toast("error in " .. where .. ": " .. string.match(tostring(err), "^[^\n]*"))
	end
end

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
	AUTO_EVENTS = false,       -- random events on their own (the AUTO button in the menu toggles this)
	AUTO_MIN = 90,             -- seconds between automatic events (random between min and max)
	AUTO_MAX = 240,
	HOTKEYS = true,
	MAX_EVENTS = 5,
	SOUNDS = true,             -- low rumble / blips (uses a built-in Roblox sound)

	-- BLACK HOLE
	BH_HORIZON = 40,           -- radius of the black sphere (studs). The disk reaches 5x this
	BH_DIST_MIN = 380,         -- it appears this far away, up in the sky
	BH_DIST_MAX = 520,
	BH_GROW_TIME = 8,          -- seconds it takes to form
	BH_LIFE = 75,              -- seconds it stays at full size
	BH_SHRINK_TIME = 8,        -- seconds it takes to evaporate
	BH_DISK_PARTS = 170,       -- glowing pieces in the accretion disk (lower = faster on weak phones)
	BH_DISK_SPEED = 1.1,       -- how fast the inner disk spins (radians/second)
	BH_PULL_RADIUS = 650,      -- gravity reaches this far
	BH_PULL_ACCEL = 5,         -- pull (studs/s^2) at the edge of that radius; grows with 1/distance^2
	BH_PULL_MAX = 450,         -- strongest pull allowed
	BH_LIFT_ACCEL = 25,        -- once the pull is this strong it lifts you off the ground
	BH_MAX_SPEED = 300,        -- fastest you can be dragged
	BH_EFFECT_RADIUS = 520,    -- screen warping, red-shift and slow motion begin this close
	BH_KILLS = true,           -- true: falling in kills you. false: you are thrown back out instead

	-- PULSAR
	PULSAR_DIST_MIN = 480,
	PULSAR_DIST_MAX = 650,
	PULSAR_PERIOD = 3.2,       -- seconds per full spin (one flash per beam sweep, two beams = 2 flashes)
	PULSAR_LIFE = 80,
	PULSAR_BEAM_LENGTH = 1100,
	PULSAR_HIT_ANGLE = 6,      -- degrees: a beam this close to pointing at you counts as a hit
	PULSAR_HIT_DAMAGE = 0,     -- health lost per hit (0 = harmless light show)

	-- SUPERNOVA
	SN_DIST = 950,
	SN_BUILD_TIME = 5,         -- seconds the star swells before it blows
	SN_SHOCK_SPEED = 90,       -- studs/second the shockwave expands (950 studs = about 10 seconds to reach you)

	-- METEORS
	METEOR_DURATION = 20,      -- seconds the shower lasts
	METEOR_MAX = 40,           -- most meteors in the air at once
}

--------------------------------------------------------------------------------
-- SHARED SCREEN EFFECTS (every event adds to `fx`, applied once per frame)
--------------------------------------------------------------------------------
local fx = {}
local function resetFx()
	fx.blur, fx.red, fx.dark, fx.flash, fx.bloom, fx.shake, fx.timeScale = 0, 0, 0, 0, 0, 0, 1
end
resetFx()

local astro = { black = 0, blackTarget = 0, consuming = false, shaking = false, slowed = false, noticeT = 0 }

local function smooth(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local blurFx = make(Instance.new("BlurEffect"))
blurFx.Name = "RealismAstroBlur"
blurFx.Size = 0
blurFx.Parent = Lighting

local ccFx = make(Instance.new("ColorCorrectionEffect"))
ccFx.Name = "RealismAstroColor"
ccFx.Parent = Lighting

local bloomFx = make(Instance.new("BloomEffect"))
bloomFx.Name = "RealismAstroBloom"
bloomFx.Intensity = 0
bloomFx.Size = 32
bloomFx.Threshold = 0.85
bloomFx.Parent = Lighting

local folder = make(Instance.new("Folder"))
folder.Name = "RealismAstro"
folder.Parent = Workspace

local function newPart(shape, size, color, transparency, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Shape = shape or Enum.PartType.Block
	p.Material = material or Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency or 0
	p.Size = size
	p.Parent = folder
	return p
end

local function makeSound(id, volume, looped, speed)
	if not CONFIG.SOUNDS then return nil end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped or false
	s.PlaybackSpeed = speed or 1
	s.Parent = folder
	return s
end
local BASS = "rbxasset://sounds/bass.wav"

--------------------------------------------------------------------------------
-- GUI: overlays, notice text, test menu
--------------------------------------------------------------------------------
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("RealismAstroGui")
if old then old:Destroy() end

local gui = make(Instance.new("ScreenGui"))
gui.Name = "RealismAstroGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui.Parent = playerGui

local function overlay(color)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Active = false
	f.Parent = gui
	return f
end
local flashFrame = overlay(Color3.new(1, 1, 1))
local blackFrame = overlay(Color3.new(0, 0, 0))
blackFrame.ZIndex = 2

local noticeLabel = Instance.new("TextLabel")
noticeLabel.AnchorPoint = Vector2.new(0.5, 0)
noticeLabel.Position = UDim2.new(0.5, 0, 0, 70)
noticeLabel.Size = UDim2.fromOffset(420, 30)
noticeLabel.BackgroundTransparency = 1
noticeLabel.Font = Enum.Font.GothamBold
noticeLabel.TextSize = 18
noticeLabel.TextColor3 = Color3.fromRGB(200, 225, 255)
noticeLabel.TextStrokeTransparency = 0.5
noticeLabel.TextTransparency = 1
noticeLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
noticeLabel.ZIndex = 5
noticeLabel.Parent = gui

local function notice(text)
	noticeLabel.Text = text
	astro.noticeT = 5
end

--------------------------------------------------------------------------------
-- EVENT MANAGER
--------------------------------------------------------------------------------
local events = {}

local function removeKind(kind)
	for i = #events, 1, -1 do
		if events[i].kind == kind then
			pcall(events[i].destroy, events[i])
			table.remove(events, i)
		end
	end
end

-- A point up in the sky in front of the camera: returns (position, direction from camera)
local function skyPoint(cam, dist, elevMin, elevMax)
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
	local dir = CFrame.Angles(0, math.rad(rand(-40, 40)), 0) * flat.Unit
	local el = math.rad(rand(elevMin, elevMax))
	dir = dir * math.cos(el) + Vector3.yAxis * math.sin(el)
	return cam.CFrame.Position + dir * dist, dir
end

--------------------------------------------------------------------------------
-- BLACK HOLE
--------------------------------------------------------------------------------
local function spawnBlackHole()
	local cam = Workspace.CurrentCamera
	local Rh = CONFIG.BH_HORIZON
	local rin, rout = Rh * 1.9, Rh * 5
	local center = skyPoint(cam, rand(CONFIG.BH_DIST_MIN, CONFIG.BH_DIST_MAX), 8, 24)

	-- The disk is a flat ring, slightly tilted
	local tilt, ang = math.rad(rand(8, 22)), rand(0, math.pi * 2)
	local n = Vector3.new(math.cos(ang) * math.sin(tilt), math.cos(tilt), math.sin(ang) * math.sin(tilt)).Unit
	local u = n:Cross(Vector3.xAxis)
	if u.Magnitude < 0.1 then u = n:Cross(Vector3.zAxis) end
	u = u.Unit
	local v = n:Cross(u).Unit

	local e = { kind = "blackhole", t = 0, sizedK = -1 }
	e.parts, e.sizes, e.cfs = {}, {}, {}

	local function add(part, size)
		table.insert(e.parts, part)
		table.insert(e.sizes, size)
		table.insert(e.cfs, part.CFrame)
	end

	-- Hole itself (pure black)
	e.hole = newPart(Enum.PartType.Ball, Vector3.one * Rh * 2, Color3.new(0, 0, 0), 0)
	add(e.hole, e.hole.Size)

	-- Accretion disk: hot white-yellow inside, orange, then deep red outside, faster on the inside
	local white, orange, red = Color3.fromRGB(255, 244, 220), Color3.fromRGB(255, 150, 40), Color3.fromRGB(170, 40, 20)
	e.diskStart = #e.parts + 1
	e.diskR, e.diskA, e.diskW = {}, {}, {}
	for i = 1, CONFIG.BH_DISK_PARTS do
		local t = rng:NextNumber() ^ 1.5
		local r = rin + (rout - rin) * t
		local col = (t < 0.4) and white:Lerp(orange, t / 0.4) or orange:Lerp(red, (t - 0.4) / 0.6)
		local s = Rh * 0.07 * (1.3 - 0.6 * t)
		local size = Vector3.new(s, s * 0.4, s * 3.2)
		add(newPart(Enum.PartType.Block, size, col, rand(0.2, 0.55)), size)
		e.diskR[i] = r
		e.diskA[i] = rand(0, math.pi * 2)
		e.diskW[i] = CONFIG.BH_DISK_SPEED * (rin / r) ^ 1.5
	end
	e.diskCount = CONFIG.BH_DISK_PARTS

	-- Thin bright ring hugging the hole (always faces the camera)
	e.photonStart = #e.parts + 1
	e.photonCount = 56
	for i = 1, e.photonCount do
		local size = Vector3.new(Rh * 0.06, Rh * 0.06, Rh * 0.17)
		add(newPart(Enum.PartType.Block, size, Color3.fromRGB(255, 238, 210), 0.05), size)
	end

	-- Bent light from the far side of the disk: a bigger ring, brighter on one side (like Doppler beaming)
	e.lensStart = #e.parts + 1
	e.lensCount = 90
	for i = 1, e.lensCount do
		local a = (i / e.lensCount) * math.pi * 2
		local b = 0.55 + 0.45 * math.cos(a - math.pi)
		local size = Vector3.new(Rh * 0.05, Rh * 0.05, Rh * 0.2)
		add(newPart(Enum.PartType.Block, size, orange:Lerp(white, b * 0.6), 0.2 + 0.5 * (1 - b)), size)
	end

	e.sound = makeSound(BASS, 0, true, 0.35)
	if e.sound then e.sound:Play() end

	local function consume(self, hum, hrp)
		if astro.consuming then return end
		astro.consuming = true
		astro.blackTarget = 1
		notice("Past the event horizon")
		task.delay(0.6, function()
			pcall(function()
				if CONFIG.BH_KILLS then
					hum.Health = 0
				else
					local out = hrp.Position - center
					out = (out.Magnitude > 1) and out.Unit or Vector3.yAxis
					hrp.AssemblyLinearVelocity = Vector3.zero
					hrp.CFrame = CFrame.new(center + out * CONFIG.BH_PULL_RADIUS * 1.2 + Vector3.new(0, 20, 0))
				end
			end)
			task.delay(1.6, function()
				astro.blackTarget = 0
				task.delay(3, function() astro.consuming = false end)
			end)
		end)
	end

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		local G, S = CONFIG.BH_GROW_TIME, CONFIG.BH_SHRINK_TIME
		local life = G + CONFIG.BH_LIFE + S
		if self.t >= life then return false end
		local k
		if self.t < G then k = smooth(self.t / G)
		elseif self.t > life - S then k = smooth((life - self.t) / S)
		else k = 1 end
		k = math.max(k, 0.001)

		-- Resize while forming / evaporating
		if math.abs(k - self.sizedK) > 0.004 or (k == 1 and self.sizedK ~= 1) then
			self.sizedK = k
			for i, p in ipairs(self.parts) do p.Size = self.sizes[i] * k end
		end

		-- Positions
		local cfs = self.cfs
		cfs[1] = CFrame.new(center)
		for i = 1, self.diskCount do
			local a = self.diskA[i] + self.diskW[i] * dt
			self.diskA[i] = a
			local c, s = math.cos(a), math.sin(a)
			local pos = center + (u * c + v * s) * (self.diskR[i] * k)
			cfs[self.diskStart + i - 1] = CFrame.lookAt(pos, pos + (v * c - u * s))
		end
		local cf = ctx.cam.CFrame
		local right, up = cf.RightVector, cf.UpVector
		for i = 1, self.photonCount do
			local a = (i / self.photonCount) * math.pi * 2
			local c, s = math.cos(a), math.sin(a)
			local pos = center + (right * c + up * s) * (Rh * 1.08 * k)
			cfs[self.photonStart + i - 1] = CFrame.lookAt(pos, pos + (up * c - right * s))
		end
		for i = 1, self.lensCount do
			local a = (i / self.lensCount) * math.pi * 2
			local c, s = math.cos(a), math.sin(a)
			local pos = center + (right * c + up * s) * (Rh * 1.55 * k)
			cfs[self.lensStart + i - 1] = CFrame.lookAt(pos, pos + (up * c - right * s))
		end
		Workspace:BulkMoveTo(self.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)

		-- Gravity and what it does to you
		local prox = 0
		local hrp, hum = ctx.hrp, ctx.hum
		if hrp and hum then
			local to = center - hrp.Position
			local d = to.Magnitude
			local R = Rh * k
			local PR = CONFIG.BH_PULL_RADIUS * k
			if ctx.alive and d < PR and d > 0.5 and hum.Sit == false then
				local a = math.min(CONFIG.BH_PULL_ACCEL * (PR / d) ^ 2, CONFIG.BH_PULL_MAX) * k
				local vel = hrp.AssemblyLinearVelocity + (to / d) * a * dt
				if vel.Magnitude > CONFIG.BH_MAX_SPEED then vel = vel.Unit * CONFIG.BH_MAX_SPEED end
				hrp.AssemblyLinearVelocity = vel
				if a >= CONFIG.BH_LIFT_ACCEL and hum.FloorMaterial ~= Enum.Material.Air then
					hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.new(0, 10, 0)
					pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
				end
			end
			local E = CONFIG.BH_EFFECT_RADIUS * k
			prox = math.clamp((E - d) / math.max(E - R, 1), 0, 1)
			if ctx.alive and d <= R * 1.1 and k > 0.7 then consume(self, hum, hrp) end
		end

		-- Screen: blur, red-shift, darkening, shaking, slow motion
		local p2 = prox * prox
		fx.blur = math.max(fx.blur, 14 * p2 * prox)
		fx.red = math.max(fx.red, prox ^ 1.5)
		fx.dark = math.max(fx.dark, p2 * 0.8)
		fx.shake = math.max(fx.shake, p2 * 0.5)
		fx.bloom = math.max(fx.bloom, 0.3 * prox)
		fx.timeScale = math.min(fx.timeScale, 1 - 0.8 * p2)
		if self.sound then self.sound.Volume = 0.12 * k + 0.9 * prox * k end
		return true
	end

	e.destroy = function(self)
		for _, p in ipairs(self.parts) do p:Destroy() end
		if self.sound then self.sound:Destroy() end
	end

	notice("A black hole is forming in the sky")
	return e
end

--------------------------------------------------------------------------------
-- PULSAR
--------------------------------------------------------------------------------
local function spawnPulsar()
	local cam = Workspace.CurrentCamera
	local center, dir = skyPoint(cam, rand(CONFIG.PULSAR_DIST_MIN, CONFIG.PULSAR_DIST_MAX), 18, 40)
	local toCam = -dir

	-- Spin axis: tilted away from the line to you, so the beams sweep across you each turn
	local ang = math.rad(rand(35, 75))
	local perp = toCam:Cross(Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1)))
	if perp.Magnitude < 0.1 then perp = toCam:Cross(Vector3.xAxis) end
	perp = perp.Unit
	local axis = (toCam * math.cos(ang) + perp * math.sin(ang)).Unit
	local u = axis:Cross(Vector3.yAxis)
	if u.Magnitude < 0.1 then u = axis:Cross(Vector3.xAxis) end
	u = u.Unit
	local v = axis:Cross(u).Unit

	local L = CONFIG.PULSAR_BEAM_LENGTH
	local e = { kind = "pulsar", t = 0, alpha = ang, hot = false }
	local blue, paleBlue = Color3.fromRGB(140, 200, 255), Color3.fromRGB(90, 150, 255)
	e.core = newPart(Enum.PartType.Ball, Vector3.one * 7, Color3.fromRGB(200, 230, 255), 0)
	e.halo = newPart(Enum.PartType.Ball, Vector3.one * 24, blue, 0.8)
	e.beams = {
		newPart(Enum.PartType.Block, Vector3.new(4, 4, L), blue, 0.35),
		newPart(Enum.PartType.Block, Vector3.new(4, 4, L), blue, 0.35),
		newPart(Enum.PartType.Block, Vector3.new(22, 22, L), paleBlue, 0.88),
		newPart(Enum.PartType.Block, Vector3.new(22, 22, L), paleBlue, 0.88),
	}
	e.core.CFrame = CFrame.new(center)
	e.halo.CFrame = CFrame.new(center)
	e.blip = makeSound(BASS, 0.35, false, 3)

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		local life = CONFIG.PULSAR_LIFE
		if self.t >= life then return false end
		local k = math.min(smooth(self.t / 3), smooth((life - self.t) / 4))
		k = math.max(k, 0.001)

		local phase = self.t * (2 * math.pi / CONFIG.PULSAR_PERIOD)
		local camPos = ctx.cam.CFrame.Position
		local c = camPos - center
		local cd = math.max(c.Magnitude, 1)
		c = c / cd

		-- The beams stay tilted so they keep sweeping across wherever you are
		local obs = math.acos(math.clamp(axis:Dot(c), -1, 1))
		self.alpha = self.alpha + (obs - self.alpha) * math.min(1, dt * 0.8)
		local b = axis * math.cos(self.alpha) + (u * math.cos(phase) + v * math.sin(phase)) * math.sin(self.alpha)

		local len = L * k
		for i, beam in ipairs(self.beams) do
			beam.Size = Vector3.new(beam.Size.X, beam.Size.Y, len)
			local sgn = (i % 2 == 1) and 1 or -1
			local dirb = b * sgn
			beam.CFrame = CFrame.lookAt(center + dirb * len / 2, center + dirb * len)
		end
		self.core.Size = Vector3.one * 7 * k

		-- How close is a beam to pointing straight at you?
		local ang2 = math.acos(math.clamp(math.abs(b:Dot(c)), 0, 1))
		local pulse = math.clamp(1 - ang2 / math.rad(CONFIG.PULSAR_HIT_ANGLE), 0, 1)
		pulse = pulse * pulse
		self.halo.Size = Vector3.one * (24 + 30 * pulse) * k
		self.halo.Transparency = 0.8 - 0.6 * pulse

		fx.flash = math.max(fx.flash, pulse * 0.35)
		fx.bloom = math.max(fx.bloom, pulse * 1.5)
		if pulse > 0.5 and not self.hot then
			self.hot = true
			fx.shake = math.max(fx.shake, 0.15)
			if self.blip then self.blip.TimePosition = 0 self.blip:Play() end
			if CONFIG.PULSAR_HIT_DAMAGE > 0 and ctx.hum and ctx.alive then
				ctx.hum.Health = math.max(0, ctx.hum.Health - CONFIG.PULSAR_HIT_DAMAGE)
			end
		elseif pulse < 0.2 then
			self.hot = false
		end
		return true
	end

	e.destroy = function(self)
		self.core:Destroy()
		self.halo:Destroy()
		for _, p in ipairs(self.beams) do p:Destroy() end
		if self.blip then self.blip:Destroy() end
	end

	notice("A pulsar is sweeping the sky")
	return e
end

--------------------------------------------------------------------------------
-- SUPERNOVA
--------------------------------------------------------------------------------
local function spawnSupernova()
	local cam = Workspace.CurrentCamera
	local center, dir = skyPoint(cam, CONFIG.SN_DIST, 15, 40)
	local BUILD = CONFIG.SN_BUILD_TIME

	local e = { kind = "supernova", t = 0, blasted = false, hit = false, hitT = 0, flashA = 0 }
	e.star = newPart(Enum.PartType.Ball, Vector3.one * 6, Color3.fromRGB(255, 110, 50), 0)
	e.shock = newPart(Enum.PartType.Ball, Vector3.one, Color3.fromRGB(150, 200, 255), 1)
	e.star.CFrame = CFrame.new(center)
	e.shock.CFrame = CFrame.new(center)
	e.neb = {}
	local nebColors = { Color3.fromRGB(180, 90, 255), Color3.fromRGB(80, 140, 255), Color3.fromRGB(255, 120, 60) }
	for i = 1, 6 do
		local off = Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1)) * 90
		local part = newPart(Enum.PartType.Ball, Vector3.one * 30, nebColors[(i % 3) + 1], 1)
		part.CFrame = CFrame.new(center + off)
		table.insert(e.neb, { part = part, off = off, base = rand(30, 60) })
	end
	e.boom = makeSound(BASS, 1, false, 0.3)

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		local t = self.t
		local NEB_LIFE = 40
		if t >= BUILD + NEB_LIFE then return false end

		if t < BUILD then
			-- Swelling, flickering, turning from red to white
			local p = t / BUILD
			local flicker = 1 + 0.06 * math.sin(t * 40)
			self.star.Size = Vector3.one * (6 + 24 * p * p) * flicker
			self.star.Color = Color3.fromRGB(255, 110, 50):Lerp(Color3.new(1, 1, 1), p)
			fx.bloom = math.max(fx.bloom, 0.5 * p)
			return true
		end

		local bt = t - BUILD
		if not self.blasted then
			self.blasted = true
			-- The flash is strongest if you're looking at it
			local facing = math.max(0, ctx.cam.CFrame.LookVector:Dot(dir))
			self.flashA = 0.25 + 0.75 * facing
			notice("SUPERNOVA")
			self.shock.Transparency = 0.75
		end
		self.flashA = self.flashA * math.exp(-dt * 0.8)
		fx.flash = math.max(fx.flash, self.flashA * 0.95)
		fx.bloom = math.max(fx.bloom, self.flashA * 2)

		-- The star collapses away
		local starSize = math.max(0.01, 60 * (1 - bt / 6))
		self.star.Size = Vector3.one * starSize
		self.star.Transparency = math.clamp(bt / 6, 0, 1)

		-- The shockwave (a hollow sphere, so you see it arrive and then pass over you)
		local radius = math.min(bt * CONFIG.SN_SHOCK_SPEED, 1000)
		self.shock.Size = Vector3.one * math.max(radius * 2, 1)
		if radius >= 1000 then
			self.shock.Transparency = math.min(1, self.shock.Transparency + dt * 0.5)
		end
		local d = (ctx.cam.CFrame.Position - center).Magnitude
		if not self.hit and radius >= d then
			self.hit = true
			notice("The shockwave hits")
			if self.boom then self.boom:Play() end
		end
		if self.hit then
			self.hitT = self.hitT + dt
			fx.shake = math.max(fx.shake, 1.2 * math.exp(-self.hitT * 0.9))
			fx.flash = math.max(fx.flash, 0.7 * math.exp(-self.hitT * 2))
			fx.blur = math.max(fx.blur, 8 * math.exp(-self.hitT * 1.2))
		end

		-- Glowing gas left behind, drifting and fading
		for _, n in ipairs(self.neb) do
			n.part.Size = Vector3.one * n.base * (1 + bt * 0.35)
			n.part.Transparency = 0.8 + 0.2 * math.clamp(bt / NEB_LIFE, 0, 1)
		end
		return true
	end

	e.destroy = function(self)
		self.star:Destroy()
		self.shock:Destroy()
		for _, n in ipairs(self.neb) do n.part:Destroy() end
		if self.boom then self.boom:Destroy() end
	end

	notice("A star is going critical")
	return e
end

--------------------------------------------------------------------------------
-- METEOR SHOWER
--------------------------------------------------------------------------------
local function spawnMeteors()
	local e = { kind = "meteors", t = 0, nextSpawn = 0, list = {} }

	local function one(camPos)
		local fireball = rng:NextNumber() < 0.15
		local pos = camPos + Vector3.new(rand(-500, 500), rand(350, 550), rand(-500, 500))
		local vel = Vector3.new(rand(-1, 1), -rand(0.5, 1), rand(-1, 1)).Unit * rand(260, 420)
		local size = fireball and Vector3.new(3, 3, 14) or Vector3.new(1.2, 1.2, 8)
		local part = newPart(Enum.PartType.Block, size, Color3.fromRGB(255, 205, 130), 0)

		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, size.Y / 2, 0)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -size.Y / 2, 0)
		a1.Parent = part
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = fireball and 1.1 or 0.7
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 140), Color3.fromRGB(255, 80, 30))
		trail.Transparency = NumberSequence.new(0, 1)
		trail.Parent = part
		if fireball then
			local light = Instance.new("PointLight")
			light.Range = 40
			light.Brightness = 2
			light.Color = Color3.fromRGB(255, 160, 70)
			light.Parent = part
		end
		part.CFrame = CFrame.lookAt(pos, pos + vel)
		table.insert(e.list, { part = part, pos = pos, vel = vel, life = rand(1.6, 2.4) })
	end

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		if self.t < CONFIG.METEOR_DURATION then
			self.nextSpawn = self.nextSpawn - dt
			while self.nextSpawn <= 0 do
				self.nextSpawn = self.nextSpawn + rand(0.08, 0.25)
				if #self.list < CONFIG.METEOR_MAX then one(ctx.cam.CFrame.Position) end
			end
		end
		for i = #self.list, 1, -1 do
			local m = self.list[i]
			m.life = m.life - dt
			if m.life <= 0 then
				m.part:Destroy()
				table.remove(self.list, i)
			else
				m.pos = m.pos + m.vel * dt
				m.part.CFrame = CFrame.lookAt(m.pos, m.pos + m.vel)
			end
		end
		return self.t < CONFIG.METEOR_DURATION or #self.list > 0
	end

	e.destroy = function(self)
		for _, m in ipairs(self.list) do m.part:Destroy() end
		table.clear(self.list)
	end

	notice("Meteor shower")
	return e
end

local spawners = {
	blackhole = spawnBlackHole,
	pulsar = spawnPulsar,
	supernova = spawnSupernova,
	meteors = spawnMeteors,
}

local function startEvent(kind)
	local fn = spawners[kind]
	if not fn then return end
	if kind == "blackhole" or kind == "pulsar" then removeKind(kind) end
	if #events >= CONFIG.MAX_EVENTS then
		notice("Too many events at once")
		return
	end
	if not Workspace.CurrentCamera then return end
	local ok, e = xpcall(fn, function(err) return debug.traceback(tostring(err), 2) end)
	if ok and e then
		table.insert(events, e)
	elseif not ok then
		reportError("start " .. kind, e)
	end
end

local function clearAll()
	for i = #events, 1, -1 do
		pcall(events[i].destroy, events[i])
		events[i] = nil
	end
	astro.blackTarget = 0
	astro.consuming = false
	notice("Sky cleared")
end

--------------------------------------------------------------------------------
-- MENU
--------------------------------------------------------------------------------
do
	local toggle = Instance.new("TextButton")
	toggle.Name = "AstroToggle"
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 10, 0.5, -40)
	toggle.Size = UDim2.fromOffset(44, 44)
	toggle.BackgroundColor3 = Color3.fromRGB(20, 22, 40)
	toggle.BackgroundTransparency = 0.2
	toggle.Text = "✦"
	toggle.TextSize = 24
	toggle.TextColor3 = Color3.fromRGB(190, 215, 255)
	toggle.Font = Enum.Font.GothamBold
	toggle.ZIndex = 10
	toggle.Parent = gui
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0.3, 0)
	tc.Parent = toggle
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(120, 160, 255)
	ts.Transparency = 0.5
	ts.Thickness = 2
	ts.Parent = toggle

	local menu = Instance.new("Frame")
	menu.Name = "AstroMenu"
	menu.Position = UDim2.new(0, 64, 0.5, -40)
	menu.AnchorPoint = Vector2.new(0, 0)
	menu.AutomaticSize = Enum.AutomaticSize.XY
	menu.Size = UDim2.fromOffset(0, 0)
	menu.BackgroundColor3 = Color3.fromRGB(12, 14, 26)
	menu.BackgroundTransparency = 0.3
	menu.BorderSizePixel = 0
	menu.Visible = false
	menu.ZIndex = 10
	menu.Parent = gui
	local mc = Instance.new("UICorner")
	mc.CornerRadius = UDim.new(0, 12)
	mc.Parent = menu
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = menu
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(104, 32)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.FillDirectionMaxCells = 2
	grid.Parent = menu

	track(toggle.Activated:Connect(function()
		menu.Visible = not menu.Visible
	end))

	local order = 0
	local function button(text, onClick)
		order = order + 1
		local b = Instance.new("TextButton")
		b.LayoutOrder = order
		b.BackgroundColor3 = Color3.fromRGB(34, 38, 64)
		b.BackgroundTransparency = 0.15
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.ZIndex = 11
		b.Parent = menu
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		track(b.Activated:Connect(function() onClick(b) end))
		return b
	end

	button("BLACK HOLE", function() startEvent("blackhole") end)
	button("PULSAR", function() startEvent("pulsar") end)
	button("SUPERNOVA", function() startEvent("supernova") end)
	button("METEORS", function() startEvent("meteors") end)
	button("CLEAR", clearAll)
	local function autoText() return CONFIG.AUTO_EVENTS and "AUTO: ON" or "AUTO: OFF" end
	local autoBtn
	autoBtn = button(autoText(), function()
		CONFIG.AUTO_EVENTS = not CONFIG.AUTO_EVENTS
		autoBtn.Text = autoText()
	end)
end

if CONFIG.HOTKEYS then
	local keys = {
		[Enum.KeyCode.B] = "blackhole",
		[Enum.KeyCode.P] = "pulsar",
		[Enum.KeyCode.N] = "supernova",
		[Enum.KeyCode.M] = "meteors",
	}
	track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if keys[input.KeyCode] then
			startEvent(keys[input.KeyCode])
		elseif input.KeyCode == Enum.KeyCode.X then
			clearAll()
		end
	end))
end

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------
local autoTimer = rand(CONFIG.AUTO_MIN, CONFIG.AUTO_MAX)

local function setTimeScale(hum, scale)
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then return end
	if scale < 0.99 then
		astro.slowed = true
		for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do tr:AdjustSpeed(scale) end
	elseif astro.slowed then
		astro.slowed = false
		for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do tr:AdjustSpeed(1) end
	end
end

local function step(dt)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")

	resetFx()
	local ctx = { cam = cam, hum = hum, hrp = hrp, alive = hum ~= nil and hum.Health > 0 }

	for i = #events, 1, -1 do
		local e = events[i]
		local ok, alive = xpcall(e.update, function(err) return debug.traceback(tostring(err), 2) end, e, dt, ctx)
		if not ok then
			reportError(e.kind, alive)
			alive = false
		end
		if not alive then
			pcall(e.destroy, e)
			table.remove(events, i)
		end
	end

	-- Random events
	if CONFIG.AUTO_EVENTS then
		autoTimer = autoTimer - dt
		if autoTimer <= 0 then
			autoTimer = rand(CONFIG.AUTO_MIN, CONFIG.AUTO_MAX)
			local kinds = { "blackhole", "pulsar", "supernova", "meteors", "meteors", "pulsar" }
			startEvent(kinds[math.random(1, #kinds)])
		end
	end

	-- Fade to black when swallowed
	local diff = astro.blackTarget - astro.black
	astro.black = astro.black + math.clamp(diff, -dt * 2, dt * 2)

	-- Apply
	blurFx.Size = fx.blur
	ccFx.TintColor = Color3.new(1, 1 - 0.45 * fx.red, 1 - 0.7 * fx.red)
	ccFx.Saturation = -0.6 * fx.red
	ccFx.Brightness = -0.3 * fx.dark
	ccFx.Contrast = 0.25 * fx.red
	bloomFx.Intensity = fx.bloom
	flashFrame.BackgroundTransparency = 1 - math.clamp(fx.flash, 0, 1)
	blackFrame.BackgroundTransparency = 1 - math.clamp(astro.black, 0, 1)

	if hum then
		if fx.shake > 0.01 then
			astro.shaking = true
			hum.CameraOffset = Vector3.new(rand(-1, 1), rand(-1, 1), 0) * fx.shake
		elseif astro.shaking then
			astro.shaking = false
			hum.CameraOffset = Vector3.zero
		end
		setTimeScale(hum, fx.timeScale)
	end

	-- Notice text fades out
	if astro.noticeT > 0 then
		astro.noticeT = astro.noticeT - dt
		noticeLabel.TextTransparency = 1 - math.clamp(astro.noticeT, 0, 1)
		noticeLabel.TextStrokeTransparency = 1 - 0.5 * math.clamp(astro.noticeT, 0, 1)
	end
end

RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value + 1, function(dt)
	local ok, err = xpcall(step, function(e) return debug.traceback(tostring(e), 2) end, dt)
	if not ok then reportError("main loop", err) end
end)

__toast("loaded. Tap the star button (left side) or press B / P / N / M. X clears.")

--------------------------------------------------------------------------------
-- CLEANUP (runs automatically if the script is executed again)
--------------------------------------------------------------------------------
_G.RealismAstroCleanup = function()
	for _, c in ipairs(connections) do c:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)
	for i = #events, 1, -1 do
		pcall(events[i].destroy, events[i])
	end
	table.clear(events)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
		pcall(setTimeScale, hum, 1)
	end
	for _, inst in ipairs(created) do
		if inst and inst.Parent then inst:Destroy() end
	end
	_G.RealismAstroCleanup = nil
end

end, function(e) return debug.traceback(tostring(e), 2) end)

if not __ok then
	__toast("SCRIPT CRASHED: " .. string.match(tostring(__err), "^[^\n]*"))
	warn(__err)
end
