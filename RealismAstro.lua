-- RealismAstro LocalScript (single-file, client-only)
-- Space events you can trigger from a menu (or hotkeys), or let them happen on their own:
--   BLACK HOLE  - forms high in the sky, then sucks up EVERYTHING (parts and terrain) and you with it
--   PULSAR      - a neutron star whose beams spin too fast to see; the whole atmosphere turns brown
--   SUPERNOVA   - a star explodes and the shockwave WIPES OUT everything it passes, including you
--   METEORS     - a meteor shower
-- When you die (or press CLEAR) every event stops and the world is put back exactly as it was:
-- every part, the terrain, the atmosphere and the lighting colours.
-- NOTE: this is a LocalScript, so the destruction is only visible to YOU, never to the server.
-- Menu: the star button sits right under Realism's lightning button.
-- Hotkeys: B black hole, P pulsar, N supernova, M meteors, X clear + restore everything.

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
local terrain = Workspace:FindFirstChildOfClass("Terrain")

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
local function traceback(e) return debug.traceback(tostring(e), 2) end

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
	AUTO_EVENTS = false,       -- random events on their own (the AUTO button in the menu toggles this)
	AUTO_MIN = 90,
	AUTO_MAX = 240,
	HOTKEYS = true,
	MAX_EVENTS = 5,
	SOUNDS = true,

	-- WORLD DESTRUCTION (local to you; undone when you die or press CLEAR)
	AFFECT_WORLD = true,       -- false = events are only visual, nothing in the map is touched
	TERRAIN = true,            -- also remove / restore terrain (a bit heavy on weak devices)
	TERRAIN_Y_MIN = -64,       -- terrain is only scanned between these heights (multiples of 4)
	TERRAIN_Y_MAX = 320,
	RESTORE_BUDGET = 1500,     -- parts put back per frame while restoring
	TERRAIN_RESTORE_BUDGET = 3,-- terrain columns put back per frame

	-- BLACK HOLE
	BH_HORIZON = 100,          -- radius of the black sphere (studs). The disk reaches 5x this
	BH_DIST_MIN = 1000,        -- how far away it forms
	BH_DIST_MAX = 1250,
	BH_ELEV_MIN = 38,          -- degrees above the horizon: it forms HIGH in the sky
	BH_ELEV_MAX = 62,
	BH_GROW_TIME = 10,
	BH_LIFE = 120,
	BH_SHRINK_TIME = 10,
	BH_DISK_PARTS = 220,
	BH_DISK_SPEED = 1.1,
	BH_PULL_RADIUS = 3200,     -- gravity on YOU reaches this far
	BH_PULL_ACCEL = 3,         -- studs/s^2 at the edge of that radius; grows with 1/distance^2
	BH_PULL_MAX = 500,
	BH_LIFT_ACCEL = 25,        -- once the pull is this strong it lifts you off the ground
	BH_MAX_SPEED = 350,
	BH_EFFECT_RADIUS = 1600,   -- screen warping, red-shift and slow motion begin this close
	BH_KILLS = true,           -- true: falling in kills you. false: you are thrown back out instead
	BH_CAPTURE_SPEED = 170,    -- the sucked-up region grows this fast (studs/s), nearest things first
	BH_RELEASE_RATE = 140,     -- parts torn loose per second
	BH_MAX_ACTIVE = 300,       -- most parts flying toward the hole at once
	BH_GHOST_ACCEL = 70,       -- how hard loose parts are pulled
	BH_GHOST_MAXSPEED = 900,
	BH_TERRAIN_RADIUS = 1100,  -- terrain around you that gets sucked up
	BH_TERRAIN_BUDGET = 1,     -- terrain columns (64 studs wide) removed per frame

	-- PULSAR
	PULSAR_DIST_MIN = 700,
	PULSAR_DIST_MAX = 900,
	PULSAR_LIFE = 90,
	PULSAR_BEAM_LENGTH = 1500,
	PULSAR_FAN = 18,           -- beams drawn per side. They spin far too fast to see, so you see a glowing cone
	PULSAR_CONE_TOL = 12,      -- degrees: you are 'in the beam' when you are this close to the cone
	PULSAR_HIT_DAMAGE = 0,     -- health per second while you are in the beam (0 = harmless)
	PULSAR_BROWN_TIME = 8,     -- seconds for the atmosphere to turn fully brown

	-- SUPERNOVA
	SN_DIST = 1100,
	SN_BUILD_TIME = 5,
	SN_WIPE_SPEED = 260,       -- studs/s the destruction front moves
	SN_KILLS = true,           -- the front kills you when it reaches you
	SN_PART_BUDGET = 1500,     -- parts removed per frame
	SN_TERRAIN_BUDGET = 2,     -- terrain columns removed per frame
	SN_TERRAIN_RADIUS = 1500,
	SN_WIPE_RADIUS = 4000,     -- the destruction front stops growing here

	-- METEORS
	METEOR_DURATION = 20,
	METEOR_MAX = 40,
}

--------------------------------------------------------------------------------
-- SHARED STATE
--------------------------------------------------------------------------------
local fx = {}
local function resetFx()
	fx.blur, fx.red, fx.dark, fx.flash, fx.bloom, fx.shake, fx.timeScale = 0, 0, 0, 0, 0, 0, 1
	fx.brown, fx.dusk, fx.ash, fx.white = 0, 0, 0, 0
	fx.threat = 0 -- 0..1, sent to Realism so events raise adrenaline (and so stress)
end
resetFx()

local astro = {
	black = 0, swallow = false, blackHold = 0,
	shaking = false, slowed = false, noticeT = 0, dead = false,
}

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
-- GUI. Overlay (flash / black / notice) is on top; the menu sits UNDER Realism's HUD (order 10)
-- so Realism's own menu is never covered.
--------------------------------------------------------------------------------
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
for _, n in ipairs({ "RealismAstroGui", "RealismAstroMenuGui" }) do
	local o = playerGui:FindFirstChild(n)
	if o then o:Destroy() end
end

local gui = make(Instance.new("ScreenGui"))
gui.Name = "RealismAstroGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui.Parent = playerGui

local menuGui = make(Instance.new("ScreenGui"))
menuGui.Name = "RealismAstroMenuGui"
menuGui.ResetOnSpawn = false
menuGui.DisplayOrder = 9
menuGui.Parent = playerGui

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
noticeLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
noticeLabel.TextStrokeTransparency = 1
noticeLabel.TextTransparency = 1
noticeLabel.ZIndex = 5
noticeLabel.Parent = gui

local function notice(text)
	noticeLabel.Text = text
	astro.noticeT = 5
end

--------------------------------------------------------------------------------
-- ENVIRONMENT (atmosphere + lighting colours). Other scripts (Realism) rewrite these every
-- frame, so each frame we read what is there NOW as the "original", blend our effect on top,
-- and when every effect is gone we simply stop writing, so it returns to normal by itself.
--------------------------------------------------------------------------------
local C = Color3.fromRGB
local TARGETS = {
	brown = { atmColor = C(150, 110, 70), atmDecay = C(100, 65, 30), density = 0.55, haze = 3.2,
		outdoor = C(110, 80, 50), ambient = C(80, 60, 40), fog = C(130, 95, 60), shift = C(200, 140, 80) },
	dusk = { atmColor = C(70, 30, 30), atmDecay = C(120, 30, 20), density = 0.45, haze = 2,
		outdoor = C(40, 25, 30), ambient = C(25, 18, 22), fog = C(40, 20, 20), shift = C(120, 40, 30) },
	ash = { atmColor = C(110, 100, 95), atmDecay = C(170, 110, 70), density = 0.6, haze = 4,
		outdoor = C(95, 85, 80), ambient = C(70, 62, 60), fog = C(105, 95, 90), shift = C(160, 120, 90) },
	white = { atmColor = C(255, 250, 240), atmDecay = C(255, 255, 255), density = 0.7, haze = 6,
		outdoor = C(255, 255, 255), ambient = C(255, 255, 255), fog = C(255, 255, 255), shift = C(255, 255, 255) },
}
local ORDER = { "dusk", "brown", "ash", "white" }

local PROPS = {
	{ key = "atmColor", obj = "atm", prop = "Color" },
	{ key = "atmDecay", obj = "atm", prop = "Decay" },
	{ key = "density", obj = "atm", prop = "Density" },
	{ key = "haze", obj = "atm", prop = "Haze" },
	{ key = "outdoor", obj = "light", prop = "OutdoorAmbient" },
	{ key = "ambient", obj = "light", prop = "Ambient" },
	{ key = "fog", obj = "light", prop = "FogColor" },
	{ key = "shift", obj = "light", prop = "ColorShift_Top" },
}
for _, d in ipairs(PROPS) do d.st = { base = nil, last = nil, inst = nil } end

local env = { amt = { brown = 0, dusk = 0, ash = 0, white = 0 }, active = false, madeAtm = nil }

local function same(a, b)
	if typeof(a) == "Color3" then
		return math.abs(a.R - b.R) < 0.003 and math.abs(a.G - b.G) < 0.003 and math.abs(a.B - b.B) < 0.003
	end
	return math.abs(a - b) < 0.002
end
local function blend(a, b, t)
	if typeof(a) == "Color3" then return a:Lerp(b, t) end
	return a + (b - a) * t
end

env.restore = function()
	for _, d in ipairs(PROPS) do
		local st = d.st
		if st.inst and st.inst.Parent and st.base ~= nil then
			pcall(function() st.inst[d.prop] = st.base end)
		end
		st.base, st.last, st.inst = nil, nil, nil
	end
	if env.madeAtm then
		pcall(function() env.madeAtm:Destroy() end)
		env.madeAtm = nil
	end
	env.active = false
end

env.resetNow = function()
	for k in pairs(env.amt) do env.amt[k] = 0 end
	env.restore()
end

env.apply = function()
	local anyOn = false
	for _, k in ipairs(ORDER) do
		if env.amt[k] > 0.002 then anyOn = true end
	end
	if not anyOn then
		if env.active then env.restore() end
		return
	end
	env.active = true

	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm then
		atm = Instance.new("Atmosphere")
		atm.Density, atm.Offset, atm.Glare, atm.Haze = 0, 0, 0, 0
		atm.Parent = Lighting
		env.madeAtm = atm
	end

	for _, d in ipairs(PROPS) do
		local inst = (d.obj == "atm") and atm or Lighting
		local st = d.st
		local cur = inst[d.prop]
		if st.base == nil or st.inst ~= inst or st.last == nil or not same(cur, st.last) then
			st.base = cur -- someone else changed it (or first frame): that is the new "original"
		end
		st.inst = inst
		local v = st.base
		for _, k in ipairs(ORDER) do
			local a = env.amt[k]
			if a > 0.002 then v = blend(v, TARGETS[k][d.key], a) end
		end
		inst[d.prop] = v
		st.last = inst[d.prop]
	end
end

env.step = function(dt)
	local a = env.amt
	local function approach(key, target, up, down)
		local v = a[key]
		if target > v then v = math.min(target, v + up * dt) else v = math.max(target, v - down * dt) end
		a[key] = v
	end
	approach("brown", fx.brown, 1 / math.max(CONFIG.PULSAR_BROWN_TIME, 0.1), 0.06)
	approach("dusk", fx.dusk, 0.15, 0.2)
	approach("ash", fx.ash, 0.2, 0.05)
	a.white = fx.white
	env.apply()
end

--------------------------------------------------------------------------------
-- WORLD: hides parts / terrain locally and flies "ghost" copies toward the hole. Everything
-- changed is recorded so it can be put back exactly.
--------------------------------------------------------------------------------
local AIR = Enum.Material.Air
local COL = 64 -- terrain column width (studs)

local world = {
	recs = {},          -- [part] = original state of every part we hid
	ghosts = {},        -- parts currently flying toward a black hole
	gparts = {}, gcfs = {},
	tsaved = {},        -- terrain columns we removed (sparse copies)
	tdone = {},         -- column keys already handled
	restoreList = nil, restoreIdx = 1,
	tqueue = nil, tIdx = 1,
}

local ghostFolder = Instance.new("Folder")
ghostFolder.Name = "Ghosts"
ghostFolder.Parent = folder

local function isCandidate(d)
	if not d:IsA("BasePart") or d:IsA("Terrain") then return false end
	if d:IsDescendantOf(folder) then return false end
	local char = LocalPlayer.Character
	if char and d:IsDescendantOf(char) then return false end
	local cam = Workspace.CurrentCamera
	if cam and d:IsDescendantOf(cam) then return false end
	return true
end

local function childList(part)
	local list
	for _, ch in ipairs(part:GetChildren()) do
		local prop
		if ch:IsA("Decal") then prop = "Transparency"
		elseif ch:IsA("ParticleEmitter") or ch:IsA("Light") or ch:IsA("Beam") or ch:IsA("Trail")
			or ch:IsA("Fire") or ch:IsA("Smoke") or ch:IsA("Sparkles") or ch:IsA("SurfaceGui")
			or ch:IsA("BillboardGui") or ch:IsA("Highlight") then
			prop = "Enabled"
		end
		if prop then
			list = list or {}
			list[#list + 1] = { ch, prop, ch[prop] }
		end
	end
	return list
end

world.hide = function(part)
	if world.recs[part] or not part.Parent then return false end
	local rec = { t = part.Transparency, c = part.CanCollide, kids = childList(part) }
	world.recs[part] = rec
	part.Transparency = 1
	part.CanCollide = false
	if rec.kids then
		for _, k in ipairs(rec.kids) do
			pcall(function() k[1][k[2]] = (k[2] == "Enabled") and false or 1 end)
		end
	end
	return true
end

-- Scanning: walks the whole workspace a few thousand instances per frame, then sorts by distance
local function newScan(center)
	return { center = center, all = Workspace:GetDescendants(), i = 1, list = {}, idx = 1, ready = false }
end
local function scanStep(s, n)
	if s.ready then return end
	local all = s.all
	local last = math.min(#all, s.i + n - 1)
	for i = s.i, last do
		local d = all[i]
		if isCandidate(d) then
			s.list[#s.list + 1] = { part = d, dist = (d.Position - s.center).Magnitude }
		end
	end
	s.i = last + 1
	if s.i > #all then
		table.sort(s.list, function(a, b) return a.dist < b.dist end)
		s.all = nil
		s.ready = true
	end
end

-- Terrain: a list of 64-stud columns around `origin`, nearest to the hole first
local function newTerrainState(origin, radius, center)
	local st = { idx = 1, cols = {}, processed = 0, found = false, off = not (CONFIG.TERRAIN and CONFIG.AFFECT_WORLD and terrain) }
	if st.off then return st end
	local x0, x1 = math.floor((origin.X - radius) / COL), math.floor((origin.X + radius) / COL)
	local z0, z1 = math.floor((origin.Z - radius) / COL), math.floor((origin.Z + radius) / COL)
	for gx = x0, x1 do
		for gz = z0, z1 do
			local mx, mz = gx * COL + COL / 2, gz * COL + COL / 2
			if math.sqrt((mx - origin.X) ^ 2 + (mz - origin.Z) ^ 2) <= radius then
				st.cols[#st.cols + 1] = { gx * COL, gz * COL, (Vector3.new(mx, 0, mz) - center).Magnitude }
			end
		end
	end
	table.sort(st.cols, function(a, b) return a[3] < b[3] end)
	return st
end

local airMats, airOcc
local function airArrays(nx, ny, nz)
	if airMats and #airMats == nx and #airMats[1] == ny then return airMats, airOcc end
	airMats, airOcc = {}, {}
	for x = 1, nx do
		local mx, ox = {}, {}
		for y = 1, ny do
			local my, oy = {}, {}
			for z = 1, nz do my[z] = AIR; oy[z] = 0 end
			mx[y], ox[y] = my, oy
		end
		airMats[x], airOcc[x] = mx, ox
	end
	return airMats, airOcc
end

-- Reads one column, saves it (sparse), and replaces it with air. Returns solid?, topY, topMaterial
local function carveColumn(cx, cz)
	local y0, y1 = CONFIG.TERRAIN_Y_MIN, CONFIG.TERRAIN_Y_MAX
	local region = Region3.new(Vector3.new(cx, y0, cz), Vector3.new(cx + COL, y1, cz + COL))
	local ok, mats, occ = pcall(terrain.ReadVoxels, terrain, region, 4)
	if not ok then return false end
	local nx, ny, nz = #mats, #mats[1], #mats[1][1]
	local idxs, ms, os_ = {}, {}, {}
	local topY, topMat = nil, nil
	for x = 1, nx do
		local mx, ox = mats[x], occ[x]
		for y = 1, ny do
			local my, oy = mx[y], ox[y]
			for z = 1, nz do
				local m = my[z]
				if m ~= AIR then
					local o = oy[z]
					if o > 0 then
						local n = #idxs + 1
						idxs[n] = ((x - 1) * ny + (y - 1)) * nz + z
						ms[n] = m
						os_[n] = o
						if m ~= Enum.Material.Water and (not topY or y > topY) then topY, topMat = y, m end
					end
				end
			end
		end
	end
	if #idxs == 0 then return false end
	world.tsaved[#world.tsaved + 1] = {
		min = Vector3.new(cx, y0, cz), max = Vector3.new(cx + COL, y1, cz + COL),
		nx = nx, ny = ny, nz = nz, idxs = idxs, mats = ms, occs = os_,
	}
	local am, ao = airArrays(nx, ny, nz)
	pcall(terrain.WriteVoxels, terrain, region, 4, am, ao)
	return true, y0 + (topY or 1) * 4, topMat
end

local function restoreColumn(col)
	local nx, ny, nz = col.nx, col.ny, col.nz
	local mats, occ = {}, {}
	for x = 1, nx do
		local mx, ox = {}, {}
		for y = 1, ny do
			local my, oy = {}, {}
			for z = 1, nz do my[z] = AIR; oy[z] = 0 end
			mx[y], ox[y] = my, oy
		end
		mats[x], occ[x] = mx, ox
	end
	for i = 1, #col.idxs do
		local id = col.idxs[i] - 1
		local z = id % nz + 1
		local y = math.floor(id / nz) % ny + 1
		local x = math.floor(id / (nz * ny)) + 1
		mats[x][y][z] = col.mats[i]
		occ[x][y][z] = col.occs[i]
	end
	pcall(terrain.WriteVoxels, terrain, Region3.new(col.min, col.max), 4, mats, occ)
end

-- Ghosts: a visual copy of a part that flies toward the hole while the real one stays hidden
local function makeGhostPart(part)
	local g
	local plain = part.ClassName == "Part" or part:IsA("MeshPart") or part:IsA("UnionOperation") or part:IsA("WedgePart")
	if plain and not part:IsA("Seat") and not part:IsA("VehicleSeat") and not part:IsA("SpawnLocation") then
		local ok, c = pcall(function() return part:Clone() end)
		if ok and c then
			for _, ch in ipairs(c:GetChildren()) do
				if not (ch:IsA("DataModelMesh") or ch:IsA("Decal") or ch:IsA("SurfaceAppearance")) then ch:Destroy() end
			end
			g = c
		end
	end
	if not g then
		g = Instance.new("Part")
		g.Size = part.Size
		g.Color = part.Color
		g.Material = part.Material
		g.Transparency = part.Transparency
	end
	g.Anchored = true
	g.CanCollide = false
	g.CanQuery = false
	g.CanTouch = false
	g.CastShadow = false
	g.Locked = true
	g.Parent = ghostFolder
	return g
end

local function addGhost(src, gpart, pos, rot, vel)
	local axis = Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1))
	if axis.Magnitude < 0.1 then axis = Vector3.yAxis end
	world.ghosts[#world.ghosts + 1] = {
		part = gpart, pos = pos, rot = rot, vel = vel,
		axis = axis.Unit, w = rand(0.3, 2.2), size = gpart.Size, src = src,
	}
end

world.release = function(src, part)
	if world.recs[part] or not part.Parent then return end
	local g = makeGhostPart(part) -- copy first, THEN hide the real one
	world.hide(part)
	local cf = part.CFrame
	local to = src.center - cf.Position
	local dir = (to.Magnitude > 1) and to.Unit or Vector3.yAxis
	local vel = Vector3.new(rand(-6, 6), 25, rand(-6, 6)) + dir * 20
	addGhost(src, g, cf.Position, cf.Rotation, vel)
end

world.debris = function(src, x, y, z, mat)
	local s = rand(10, 26)
	local color = Color3.fromRGB(110, 90, 70)
	pcall(function() color = terrain:GetMaterialColor(mat) end)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Material = Enum.Material.Slate
	p.Color = color
	p.Size = Vector3.new(s, s * rand(0.5, 1), s)
	p.Parent = ghostFolder
	addGhost(src, p, Vector3.new(x, y, z), CFrame.Angles(rand(0, 6), rand(0, 6), rand(0, 6)),
		Vector3.new(rand(-8, 8), 30, rand(-8, 8)))
end

-- One step of terrain removal. onSolid(cx, cz, topY, mat) is called for every column that had terrain.
world.terrainStep = function(st, front, budget, onSolid)
	if st.off then return end
	for _ = 1, budget do
		local c = st.cols[st.idx]
		if not c or c[3] > front then return end
		st.idx = st.idx + 1
		local key = c[1] .. "," .. c[2]
		if not world.tdone[key] then
			world.tdone[key] = true
			local solid, topY, mat = carveColumn(c[1], c[2])
			st.processed = st.processed + 1
			if solid then
				st.found = true
				if onSolid then onSolid(c[1], c[2], topY, mat) end
			elseif not st.found and st.processed >= 150 then
				st.off = true -- nothing near you: this map has no terrain to remove
				return
			end
		end
	end
end

world.updateGhosts = function(dt)
	local ghosts = world.ghosts
	for i = #ghosts, 1, -1 do
		local g = ghosts[i]
		local src = g.src
		local remove = src.dead
		if not remove then
			local to = src.center - g.pos
			local d = to.Magnitude
			if d <= src.R * 1.02 then
				remove = true
			else
				local dir = to / d
				local a = math.min(CONFIG.BH_GHOST_ACCEL * (1000 / d) ^ 1.5 * src.k, 1500)
				local tang = src.normal:Cross(dir)
				g.vel = g.vel + (dir * a + tang * (a * 0.4)) * dt
				if g.vel.Magnitude > CONFIG.BH_GHOST_MAXSPEED then g.vel = g.vel.Unit * CONFIG.BH_GHOST_MAXSPEED end
				g.pos = g.pos + g.vel * dt
				g.rot = CFrame.fromAxisAngle(g.axis, g.w * dt) * g.rot
				if d < src.R * 3 then
					g.part.Size = g.size * math.clamp((d - src.R) / (src.R * 2), 0.05, 1)
				end
			end
		end
		if remove then
			g.part:Destroy()
			ghosts[i] = ghosts[#ghosts]
			ghosts[#ghosts] = nil
		end
	end
	local n = #ghosts
	if n == 0 then return end
	local parts, cfs = world.gparts, world.gcfs
	for i = 1, n do
		local g = ghosts[i]
		parts[i] = g.part
		cfs[i] = CFrame.new(g.pos) * g.rot
	end
	for i = #parts, n + 1, -1 do parts[i] = nil; cfs[i] = nil end
	Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

world.dropGhosts = function()
	for _, g in ipairs(world.ghosts) do pcall(function() g.part:Destroy() end) end
	table.clear(world.ghosts)
	table.clear(world.gparts)
	table.clear(world.gcfs)
end

-- Queue everything we changed to be put back
world.beginRestore = function()
	world.dropGhosts()
	local list = world.restoreList or {}
	if not world.restoreList then world.restoreIdx = 1 end
	for part, rec in pairs(world.recs) do list[#list + 1] = { part, rec } end
	table.clear(world.recs)
	world.restoreList = (#list > 0) and list or nil
	if #world.tsaved > 0 then
		world.tqueue = world.tqueue or {}
		for _, col in ipairs(world.tsaved) do world.tqueue[#world.tqueue + 1] = col end
		table.clear(world.tsaved)
	end
	table.clear(world.tdone)
end

world.restoring = function()
	return world.restoreList ~= nil or (world.tqueue ~= nil and world.tIdx <= #world.tqueue)
end

local function restorePart(item)
	local part, rec = item[1], item[2]
	if part.Parent then
		part.Transparency = rec.t
		part.CanCollide = rec.c
		if rec.kids then
			for _, k in ipairs(rec.kids) do
				pcall(function() k[1][k[2]] = k[3] end)
			end
		end
	end
end

world.stepRestore = function(unlimited)
	local list = world.restoreList
	if list then
		local n = 0
		local cap = unlimited and math.huge or CONFIG.RESTORE_BUDGET
		while world.restoreIdx <= #list and n < cap do
			restorePart(list[world.restoreIdx])
			world.restoreIdx = world.restoreIdx + 1
			n = n + 1
		end
		if world.restoreIdx > #list then
			world.restoreList = nil
			world.restoreIdx = 1
		end
	end
	local q = world.tqueue
	if q then
		local n = 0
		local cap = unlimited and math.huge or CONFIG.TERRAIN_RESTORE_BUDGET
		while world.tIdx <= #q and n < cap do
			restoreColumn(q[world.tIdx])
			q[world.tIdx] = false
			world.tIdx = world.tIdx + 1
			n = n + 1
		end
		if world.tIdx > #q then
			world.tqueue = nil
			world.tIdx = 1
		end
	end
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

local function skyPoint(cam, dist, elevMin, elevMax)
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
	local dir = CFrame.Angles(0, math.rad(rand(-40, 40)), 0) * flat.Unit
	local el = math.rad(rand(elevMin, elevMax))
	dir = dir * math.cos(el) + Vector3.yAxis * math.sin(el)
	return cam.CFrame.Position + dir * dist, dir
end

local function groundPoint(cam)
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	return hrp and hrp.Position or cam.CFrame.Position
end

-- Falls into the hole / front: fade to black, then kill (or throw you back out)
local function swallowPlayer(hum, hrp, kills, outFrom)
	if astro.swallow then return end
	astro.swallow = true
	notice(kills and "Past the event horizon" or "Thrown back out")
	task.delay(0.6, function()
		pcall(function()
			if kills then
				hum.Health = 0
			else
				local out = hrp.Position - outFrom
				out = (out.Magnitude > 1) and out.Unit or Vector3.yAxis
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.CFrame = CFrame.new(outFrom + out * CONFIG.BH_PULL_RADIUS * 1.2 + Vector3.new(0, 20, 0))
			end
		end)
		task.delay(1.6, function() astro.swallow = false end)
	end)
end

--------------------------------------------------------------------------------
-- BLACK HOLE
--------------------------------------------------------------------------------
local function spawnBlackHole()
	local cam = Workspace.CurrentCamera
	local Rh = CONFIG.BH_HORIZON
	local rin, rout = Rh * 1.9, Rh * 5
	local center = skyPoint(cam, rand(CONFIG.BH_DIST_MIN, CONFIG.BH_DIST_MAX), CONFIG.BH_ELEV_MIN, CONFIG.BH_ELEV_MAX)

	local tilt, ang = math.rad(rand(8, 22)), rand(0, math.pi * 2)
	local n = Vector3.new(math.cos(ang) * math.sin(tilt), math.cos(tilt), math.sin(ang) * math.sin(tilt)).Unit
	local u = n:Cross(Vector3.xAxis)
	if u.Magnitude < 0.1 then u = n:Cross(Vector3.zAxis) end
	u = u.Unit
	local v = n:Cross(u).Unit

	local e = { kind = "blackhole", t = 0, sizedK = -1, front = nil, relAcc = 0 }
	e.src = { center = center, R = 0, k = 0, normal = n, dead = false }
	e.parts, e.sizes, e.cfs = {}, {}, {}

	local function add(part, size)
		table.insert(e.parts, part)
		table.insert(e.sizes, size)
		table.insert(e.cfs, part.CFrame)
	end

	e.hole = newPart(Enum.PartType.Ball, Vector3.one * Rh * 2, Color3.new(0, 0, 0), 0)
	add(e.hole, e.hole.Size)

	local white, orange, red = C(255, 244, 220), C(255, 150, 40), C(170, 40, 20)
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

	e.photonStart = #e.parts + 1
	e.photonCount = 56
	for _ = 1, e.photonCount do
		local size = Vector3.new(Rh * 0.06, Rh * 0.06, Rh * 0.17)
		add(newPart(Enum.PartType.Block, size, C(255, 238, 210), 0.05), size)
	end

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

	if CONFIG.AFFECT_WORLD then
		e.scan = newScan(center)
		e.tstate = newTerrainState(groundPoint(cam), CONFIG.BH_TERRAIN_RADIUS, center)
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
		self.k = k
		self.src.k = k
		self.src.R = Rh * k

		if math.abs(k - self.sizedK) > 0.004 or (k == 1 and self.sizedK ~= 1) then
			self.sizedK = k
			for i, p in ipairs(self.parts) do p.Size = self.sizes[i] * k end
		end

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

		-- Tear the world loose: nearest things first, the region grows outward
		if self.scan then
			if not self.scan.ready then
				scanStep(self.scan, 2500)
			elseif k > 0.25 and not astro.dead then
				local list = self.scan.list
				if not self.front then self.front = (list[1] and list[1].dist or 0) - 20 end
				self.front = self.front + CONFIG.BH_CAPTURE_SPEED * dt
				self.relAcc = math.min(self.relAcc + CONFIG.BH_RELEASE_RATE * dt, 40)
				local idx, silent = self.scan.idx, 0
				while idx <= #list and list[idx].dist <= self.front and silent < 400 do
					local part = list[idx].part
					if part.Parent and not world.recs[part] then
						local sz = part.Size
						local small = math.max(sz.X, sz.Y, sz.Z) < 1.2
						if part.Transparency >= 0.95 or small then
							world.hide(part)
							silent = silent + 1
						elseif self.relAcc >= 1 and #world.ghosts < CONFIG.BH_MAX_ACTIVE then
							world.release(self.src, part)
							self.relAcc = self.relAcc - 1
						else
							break
						end
					end
					idx = idx + 1
				end
				self.scan.idx = idx
			end
		end
		if self.tstate and self.front and k > 0.25 and not astro.dead then
			local src = self.src
			world.terrainStep(self.tstate, self.front, CONFIG.BH_TERRAIN_BUDGET, function(cx, cz, topY, mat)
				if #world.ghosts < CONFIG.BH_MAX_ACTIVE and rng:NextNumber() < 0.7 then
					world.debris(src, cx + rand(0, COL), topY, cz + rand(0, COL), mat)
				end
			end)
		end

		-- Gravity on you
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
			if ctx.alive and d <= R * 1.1 and k > 0.7 then
				swallowPlayer(hum, hrp, CONFIG.BH_KILLS, center)
			end
		end

		local p2 = prox * prox
		fx.blur = math.max(fx.blur, 14 * p2 * prox)
		fx.red = math.max(fx.red, prox ^ 1.5)
		fx.dark = math.max(fx.dark, p2 * 0.8)
		fx.shake = math.max(fx.shake, p2 * 0.5)
		fx.bloom = math.max(fx.bloom, 0.3 * prox)
		fx.dusk = math.max(fx.dusk, 0.55 * k + 0.45 * prox)
		fx.timeScale = math.min(fx.timeScale, 1 - 0.8 * p2)
		fx.threat = math.max(fx.threat, 0.25 * k + 0.75 * prox)
		if self.sound then self.sound.Volume = 0.12 * k + 0.9 * prox * k end
		return true
	end

	e.destroy = function(self)
		self.src.dead = true
		for _, p in ipairs(self.parts) do p:Destroy() end
		if self.sound then self.sound:Destroy() end
	end

	notice("A black hole is forming in the sky")
	return e
end

--------------------------------------------------------------------------------
-- PULSAR (spins far too fast to see: a glowing cone of light, and the sky turns brown)
--------------------------------------------------------------------------------
local function spawnPulsar()
	local cam = Workspace.CurrentCamera
	local center, dir = skyPoint(cam, rand(CONFIG.PULSAR_DIST_MIN, CONFIG.PULSAR_DIST_MAX), 25, 45)
	local toCam = -dir

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
	local N = CONFIG.PULSAR_FAN
	local e = { kind = "pulsar", t = 0, irr = 0, sizedK = -1 }
	local blue, paleBlue = C(150, 205, 255), C(90, 150, 255)
	e.core = newPart(Enum.PartType.Ball, Vector3.one * 9, C(210, 235, 255), 0)
	e.halo = newPart(Enum.PartType.Ball, Vector3.one * 32, paleBlue, 0.75)
	e.core.CFrame = CFrame.new(center)
	e.halo.CFrame = CFrame.new(center)

	-- The real beams make thousands of turns a minute. All you can see is the cone they paint.
	e.beams, e.cfs = {}, {}
	for i = 1, N * 2 do
		e.beams[i] = newPart(Enum.PartType.Block, Vector3.new(3, 3, L), (i % 2 == 0) and paleBlue or blue, 0.78)
		e.cfs[i] = e.beams[i].CFrame
	end
	e.buzz = makeSound(BASS, 0, true, 5)
	if e.buzz then e.buzz:Play() end

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		local life = CONFIG.PULSAR_LIFE
		if self.t >= life then return false end
		local k = math.max(math.min(smooth(self.t / 3), smooth((life - self.t) / 4)), 0.001)

		if math.abs(k - self.sizedK) > 0.01 then
			self.sizedK = k
			for _, b in ipairs(self.beams) do b.Size = Vector3.new(3, 3, L * k) end
			self.core.Size = Vector3.one * 9 * k
			self.halo.Size = Vector3.one * 32 * k
		end

		local len = L * k
		local ca, sa = math.cos(ang), math.sin(ang)
		local drift = self.t * 0.35
		for i = 1, N do
			local ph = (i / N) * math.pi * 2 + drift
			local b = axis * ca + (u * math.cos(ph) + v * math.sin(ph)) * sa
			self.cfs[i * 2 - 1] = CFrame.lookAt(center + b * len / 2, center + b * len)
			self.cfs[i * 2] = CFrame.lookAt(center - b * len / 2, center - b * len)
		end
		Workspace:BulkMoveTo(self.beams, self.cfs, Enum.BulkMoveMode.FireCFrameChanged)

		-- Are you standing in the cone? (Smoothed, so it is a steady glow and never a strobe)
		local c = ctx.cam.CFrame.Position - center
		c = c / math.max(c.Magnitude, 1)
		local obs = math.acos(math.clamp(axis:Dot(c), -1, 1))
		local dev = math.min(math.abs(obs - ang), math.abs(obs - (math.pi - ang)))
		local target = smooth(1 - dev / math.rad(CONFIG.PULSAR_CONE_TOL))
		self.irr = self.irr + (target - self.irr) * math.min(1, dt * 3)
		local irr = self.irr * k

		fx.flash = math.max(fx.flash, irr * 0.22)
		fx.bloom = math.max(fx.bloom, irr * 1.2)
		fx.shake = math.max(fx.shake, irr * 0.08)
		fx.brown = math.max(fx.brown, k)
		fx.threat = math.max(fx.threat, 0.15 * k + 0.25 * irr)
		if self.buzz then self.buzz.Volume = 0.25 * irr end
		if CONFIG.PULSAR_HIT_DAMAGE > 0 and ctx.hum and ctx.alive and irr > 0.5 then
			ctx.hum.Health = math.max(0, ctx.hum.Health - CONFIG.PULSAR_HIT_DAMAGE * dt)
		end
		return true
	end

	e.destroy = function(self)
		self.core:Destroy()
		self.halo:Destroy()
		for _, b in ipairs(self.beams) do b:Destroy() end
		if self.buzz then self.buzz:Destroy() end
	end

	notice("A pulsar is poisoning the sky")
	return e
end

--------------------------------------------------------------------------------
-- SUPERNOVA (wipes out everything the front reaches)
--------------------------------------------------------------------------------
local function spawnSupernova()
	local cam = Workspace.CurrentCamera
	local center, dir = skyPoint(cam, CONFIG.SN_DIST, 20, 45)
	local BUILD = CONFIG.SN_BUILD_TIME

	local e = { kind = "supernova", t = 0, blasted = false, flashA = 0, front = 0, killed = false }
	e.star = newPart(Enum.PartType.Ball, Vector3.one * 6, C(255, 110, 50), 0)
	e.shock = newPart(Enum.PartType.Ball, Vector3.one, C(150, 200, 255), 1)
	e.star.CFrame = CFrame.new(center)
	e.shock.CFrame = CFrame.new(center)
	e.neb = {}
	local nebColors = { C(180, 90, 255), C(80, 140, 255), C(255, 120, 60) }
	for i = 1, 6 do
		local off = Vector3.new(rand(-1, 1), rand(-1, 1), rand(-1, 1)) * 90
		local part = newPart(Enum.PartType.Ball, Vector3.one * 30, nebColors[(i % 3) + 1], 1)
		part.CFrame = CFrame.new(center + off)
		table.insert(e.neb, { part = part, base = rand(30, 60) })
	end
	e.boom = makeSound(BASS, 1, false, 0.3)

	if CONFIG.AFFECT_WORLD then
		e.scan = newScan(center)
		e.tstate = newTerrainState(groundPoint(cam), CONFIG.SN_TERRAIN_RADIUS, center)
	end

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		local t = self.t
		local NEB_LIFE = 40
		if t >= BUILD + NEB_LIFE then return false end

		if self.scan then scanStep(self.scan, 4000) end

		if t < BUILD then
			local p = t / BUILD
			self.star.Size = Vector3.one * (6 + 24 * p * p) * (1 + 0.06 * math.sin(t * 40))
			self.star.Color = C(255, 110, 50):Lerp(Color3.new(1, 1, 1), p)
			fx.bloom = math.max(fx.bloom, 0.5 * p)
			fx.threat = math.max(fx.threat, 0.2 * p)
			return true
		end

		local bt = t - BUILD
		if not self.blasted then
			self.blasted = true
			local facing = math.max(0, ctx.cam.CFrame.LookVector:Dot(dir))
			self.flashA = 0.25 + 0.75 * facing
			self.shock.Transparency = 0.75
			notice("SUPERNOVA")
			if _G.RealismAstroEvent then pcall(_G.RealismAstroEvent, "supernova", 1) end
		end
		self.flashA = self.flashA * math.exp(-dt * 0.8)
		fx.flash = math.max(fx.flash, self.flashA * 0.95)
		fx.bloom = math.max(fx.bloom, self.flashA * 2)
		fx.white = math.max(fx.white, self.flashA)
		fx.ash = math.max(fx.ash, math.clamp(bt / 6, 0, 1))
		local dPl = ctx.hrp and (ctx.hrp.Position - center).Magnitude or 1000
		fx.threat = math.max(fx.threat, (0.5 + 0.5 * math.clamp(self.front / math.max(dPl, 1), 0, 1)) * math.clamp(1 - bt / 30, 0.2, 1))

		self.star.Size = Vector3.one * math.max(0.01, 60 * (1 - bt / 6))
		self.star.Transparency = math.clamp(bt / 6, 0, 1)

		-- The front: everything inside it is gone
		if not astro.dead then self.front = self.front + CONFIG.SN_WIPE_SPEED * dt end
		local radius = math.min(self.front, 1000)
		self.shock.Size = Vector3.one * math.max(radius * 2, 1)
		if self.front >= 1000 then
			self.shock.Transparency = math.min(1, self.shock.Transparency + dt * 0.5)
		end

		if self.scan and self.scan.ready and not astro.dead and self.front < CONFIG.SN_WIPE_RADIUS then
			local list, idx, n = self.scan.list, self.scan.idx, 0
			while idx <= #list and list[idx].dist <= self.front and n < CONFIG.SN_PART_BUDGET do
				local part = list[idx].part
				if part.Parent then world.hide(part) end
				idx = idx + 1
				n = n + 1
			end
			self.scan.idx = idx
		end
		if self.tstate and not astro.dead then
			world.terrainStep(self.tstate, self.front, CONFIG.SN_TERRAIN_BUDGET, nil)
		end

		-- It reaches you
		local hrp, hum = ctx.hrp, ctx.hum
		if hrp and hum and ctx.alive and not self.killed then
			local d = (hrp.Position - center).Magnitude
			if self.front >= d then
				self.killed = true
				if self.boom then self.boom:Play() end
				fx.shake = 1.5
				if CONFIG.SN_KILLS then swallowPlayer(hum, hrp, true, center) end
			end
		end
		if self.killed then
			self.hitT = (self.hitT or 0) + dt
			fx.shake = math.max(fx.shake, 1.2 * math.exp(-self.hitT * 0.9))
			fx.flash = math.max(fx.flash, 0.7 * math.exp(-self.hitT * 2))
			fx.blur = math.max(fx.blur, 8 * math.exp(-self.hitT * 1.2))
		end

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
		local part = newPart(Enum.PartType.Block, size, C(255, 205, 130), 0)

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
		trail.Color = ColorSequence.new(C(255, 220, 140), C(255, 80, 30))
		trail.Transparency = NumberSequence.new(0, 1)
		trail.Parent = part
		if fireball then
			local light = Instance.new("PointLight")
			light.Range = 40
			light.Brightness = 2
			light.Color = C(255, 160, 70)
			light.Parent = part
		end
		part.CFrame = CFrame.lookAt(pos, pos + vel)
		table.insert(e.list, { part = part, pos = pos, vel = vel, life = rand(1.6, 2.4) })
	end

	e.update = function(self, dt, ctx)
		self.t = self.t + dt
		if self.t < CONFIG.METEOR_DURATION then
			fx.threat = math.max(fx.threat, 0.2)
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
	local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if astro.dead or (hum and hum.Health <= 0) then return end
	if kind == "blackhole" or kind == "pulsar" then removeKind(kind) end
	if #events >= CONFIG.MAX_EVENTS then
		notice("Too many events at once")
		return
	end
	if not Workspace.CurrentCamera then return end
	local ok, e = xpcall(fn, traceback)
	if ok and e then
		table.insert(events, e)
		local spike = { blackhole = 0.6, pulsar = 0.3, supernova = 0.4, meteors = 0.4 }
		if _G.RealismAstroEvent then pcall(_G.RealismAstroEvent, kind, spike[kind] or 0.4) end
	elseif not ok then
		reportError("start " .. kind, e)
	end
end

--------------------------------------------------------------------------------
-- RESET: stop every event and put the whole world back (runs when you die, or on CLEAR)
--------------------------------------------------------------------------------
local function fullReset(withBlack)
	for i = #events, 1, -1 do
		pcall(events[i].destroy, events[i])
		events[i] = nil
	end
	world.beginRestore()
	env.resetNow()
	resetFx()
	_G.RealismAstroThreat = 0
	astro.swallow = false
	if withBlack then
		astro.black = 1
		astro.blackHold = 1.4
	end
	local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end
	blurFx.Size = 0
	notice("Everything has been restored")
end

--------------------------------------------------------------------------------
-- MENU (right under Realism's lightning button, which is at (10, 70) and 44 x 44)
--------------------------------------------------------------------------------
do
	local toggle = Instance.new("TextButton")
	toggle.Name = "AstroToggle"
	toggle.Position = UDim2.new(0, 10, 0, 124)
	toggle.Size = UDim2.fromOffset(44, 44)
	toggle.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	toggle.BackgroundTransparency = 0.25
	toggle.Text = "\u{2726}"
	toggle.TextSize = 24
	toggle.Font = Enum.Font.GothamBold
	toggle.TextColor3 = Color3.fromRGB(190, 215, 255)
	toggle.AutoButtonColor = false
	toggle.Parent = menuGui
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0.3, 0)
	tc.Parent = toggle
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(120, 160, 255)
	ts.Thickness = 2
	ts.Transparency = 0.5
	ts.Parent = toggle

	local menu = Instance.new("Frame")
	menu.Name = "AstroMenu"
	menu.Position = UDim2.new(0, 64, 0, 124)
	menu.AutomaticSize = Enum.AutomaticSize.XY
	menu.Size = UDim2.fromOffset(0, 0)
	menu.BackgroundColor3 = Color3.fromRGB(12, 14, 26)
	menu.BackgroundTransparency = 0.3
	menu.BorderSizePixel = 0
	menu.Visible = false
	menu.Parent = menuGui
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
		toggle.BackgroundColor3 = menu.Visible and Color3.fromRGB(30, 40, 70) or Color3.fromRGB(30, 30, 30)
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
	button("CLEAR + RESTORE", function() fullReset(false) end)
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
			fullReset(false)
		end
	end))
end

--------------------------------------------------------------------------------
-- DEATH: the moment you die, everything resets
--------------------------------------------------------------------------------
local diedConn = nil
local function hookCharacter(char)
	if diedConn then diedConn:Disconnect() diedConn = nil end
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then return end
	astro.dead = false
	diedConn = hum.Died:Connect(function()
		if astro.dead then return end
		astro.dead = true
		fullReset(true)
	end)
end
track(LocalPlayer.CharacterAdded:Connect(function(char)
	task.spawn(hookCharacter, char)
end))
if LocalPlayer.Character then task.spawn(hookCharacter, LocalPlayer.Character) end

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

	-- Safety net in case the Died event was missed
	if hum and hum.Health <= 0 and not astro.dead then
		astro.dead = true
		fullReset(true)
	elseif hum and hum.Health > 0 and astro.dead and #events == 0 then
		astro.dead = false
	end

	resetFx()
	local alive = hum ~= nil and hum.Health > 0
	local ctx = { cam = cam, hum = hum, hrp = hrp, alive = alive }

	for i = #events, 1, -1 do
		local e = events[i]
		local ok, running = xpcall(e.update, traceback, e, dt, ctx)
		if not ok then
			reportError(e.kind, running)
			running = false
		end
		if not running then
			pcall(e.destroy, e)
			table.remove(events, i)
		end
	end

	world.updateGhosts(dt)
	if world.restoring() then world.stepRestore(false) end

	if CONFIG.AUTO_EVENTS and alive then
		autoTimer = autoTimer - dt
		if autoTimer <= 0 then
			autoTimer = rand(CONFIG.AUTO_MIN, CONFIG.AUTO_MAX)
			local kinds = { "blackhole", "pulsar", "supernova", "meteors", "meteors", "pulsar" }
			startEvent(kinds[math.random(1, #kinds)])
		end
	end

	-- Black screen: swallowed by something, or holding after a reset
	if astro.blackHold > 0 then astro.blackHold = astro.blackHold - dt end
	local blackTarget = (astro.swallow or astro.blackHold > 0) and 1 or 0
	local diff = blackTarget - astro.black
	astro.black = astro.black + math.clamp(diff, -dt * 2, dt * 2)

	env.step(dt)

	_G.RealismAstroThreat = alive and math.clamp(fx.threat, 0, 1) or 0

	blurFx.Size = fx.blur
	local tint = Color3.new(1, 1 - 0.45 * fx.red, 1 - 0.7 * fx.red)
	ccFx.TintColor = tint:Lerp(C(240, 200, 150), env.amt.brown * 0.5)
	ccFx.Saturation = -0.6 * fx.red - 0.15 * env.amt.brown
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

	if astro.noticeT > 0 then
		astro.noticeT = astro.noticeT - dt
		local a = math.clamp(astro.noticeT, 0, 1)
		noticeLabel.TextTransparency = 1 - a
		noticeLabel.TextStrokeTransparency = 1 - 0.5 * a
	end
end

RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value + 1, function(dt)
	local ok, err = xpcall(step, traceback, dt)
	if not ok then reportError("main loop", err) end
end)

__toast("loaded. Star button is under the lightning button. B / P / N / M start events, X restores everything.")

--------------------------------------------------------------------------------
-- CLEANUP (runs automatically if the script is executed again)
--------------------------------------------------------------------------------
_G.RealismAstroCleanup = function()
	for _, c in ipairs(connections) do c:Disconnect() end
	if diedConn then diedConn:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)
	for i = #events, 1, -1 do
		pcall(events[i].destroy, events[i])
	end
	table.clear(events)
	-- Put the whole map back right now
	pcall(world.beginRestore)
	pcall(world.stepRestore, true)
	pcall(env.resetNow)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
		pcall(setTimeScale, hum, 1)
	end
	for _, inst in ipairs(created) do
		if inst and inst.Parent then inst:Destroy() end
	end
	_G.RealismAstroThreat = nil
	_G.RealismAstroCleanup = nil
end

end, function(e) return debug.traceback(tostring(e), 2) end)

if not __ok then
	__toast("SCRIPT CRASHED: " .. string.match(tostring(__err), "^[^\n]*"))
	warn(__err)
end
