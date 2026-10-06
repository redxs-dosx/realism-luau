-- Realism Phone (companion LocalScript, single-file, client-only)
-- Pairs with the Realism script. Gives you a "Phone" gear that looks like a smartphone.
-- Equip it and a phone screen slides up. Unequip it and it goes back in your pocket.
-- Apps: Status (reads the Realism HUD), Weather, Clock, Flashlight, Calculator, Notes.
-- Run it AFTER the Realism script (the Status and Weather apps read its HUD).
-- Re-running cleans up the previous run (_G.RealismPhoneCleanup). Touches nothing inside Realism.

local __toasts = 0
local function __toast(text)
	text = "[Phone] " .. tostring(text)
	print(text)
	if __toasts >= 6 then return end
	__toasts = __toasts + 1
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", {
					Title = "Phone",
					Text = string.sub(text, 1, 230),
					Duration = 8,
				})
			end)
			if ok then return end
			task.wait(0.5)
		end
	end)
end

local __ok, __err = xpcall(function()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

if _G.RealismPhoneCleanup then
	pcall(_G.RealismPhoneCleanup)
end

local connections, instances = {}, {}
local function track(c) table.insert(connections, c) return c end
local function own(i) table.insert(instances, i) return i end

local reported = {}
local function reportError(where, err)
	local key = where .. "|" .. tostring(err)
	if reported[key] then return end
	reported[key] = true
	warn("[Phone] error in " .. where .. ": " .. tostring(err))
	__toast("error in " .. where .. ": " .. string.match(tostring(err), "^[^\n]*"))
end
local function safeCall(where, fn, ...)
	local ok, r = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
	if not ok then reportError(where, r) end
	return ok, r
end

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
	TOOL_NAME = "Phone",
	DISPLAY_ORDER = 4,             -- just under the Realism eyelids (5) so blinks cover the phone; the HUD (10) stays on top
	ASPECT = 0.48,                 -- phone width / height
	SIZE_PC = 0.74,                -- phone height as a fraction of the screen
	SIZE_TOUCH = 0.62,             -- smaller on phones/tablets so you can still see and steer
	START_BATTERY = 100,
	BATTERY_DRAIN = 0.03,          -- % per second while the screen is on (about 55 minutes)
	FLASHLIGHT_DRAIN = 0.06,       -- extra % per second while the flashlight is on
	BATTERY_RECHARGE = 0.02,       -- % per second while the phone is in your pocket
	MIN_BOOT = 5,                  -- a dead phone needs this much charge to turn back on
	LOW_BATTERY = 20,
	FLASHLIGHT_RANGE = 45,
	FLASHLIGHT_ANGLE = 55,
	FLASHLIGHT_BRIGHTNESS = 3,
	CLICK_SOUND = "rbxasset://sounds/switch.wav", -- built-in; silent if the file is missing
}

local COL = {
	bezel = Color3.fromRGB(12, 13, 16),
	card = Color3.fromRGB(32, 36, 46),
	text = Color3.fromRGB(240, 244, 250),
	dim = Color3.fromRGB(160, 170, 185),
	accent = Color3.fromRGB(90, 160, 255),
	orange = Color3.fromRGB(255, 159, 10),
	good = Color3.fromRGB(80, 220, 120),
	bad = Color3.fromRGB(235, 75, 75),
}

--------------------------------------------------------------------------------
-- STATE (one table = one local)
--------------------------------------------------------------------------------
local phone = {
	tool = nil, handle = nil, screenPart = nil, flashPart = nil, light = nil,
	gui = nil, body = nil, click = nil,
	pages = {}, updaters = {}, current = "home",
	battery = CONFIG.START_BATTERY,
	open = false, screenOn = true, dead = false, flash = false, warned = false,
	token = 0, tick = 0,
	timeText = nil, battText = nil, battFill = nil, wallGrad = nil,
	offBtn = nil, offText = nil, flashBtn = nil, flashLabel = nil,
	homeClock = nil, homePhase = nil, homeWeather = nil,
	statusRows = {}, statusNote = nil,
	wIcon = nil, wMain = nil, wSub = nil, wFeel = nil,
	cGame = nil, cPhase = nil, cReal = nil,
}

-- Where you dragged the phone (pixels away from its default spot); kept between opens
phone.dragX, phone.dragY = 0, 0
phone.drag = nil     -- active drag: { input, start, x, y }
phone.dragPill = nil

local function shownPos() return UDim2.new(0.5, phone.dragX, 1, -12 + phone.dragY) end
local function hiddenPos() return UDim2.new(0.5, phone.dragX, 1.5, 0) end

-- Keeps the phone (and its drag bar) fully on screen
local function clampDrag()
	local gui, body = phone.gui, phone.body
	if not gui or not body then return end
	local sw, sh = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
	local w, h = body.AbsoluteSize.X, body.AbsoluteSize.Y
	if sw <= 0 or sh <= 0 then return end
	local maxX = math.max(0, sw / 2 - w / 2)
	phone.dragX = math.clamp(phone.dragX, -maxX, maxX)
	phone.dragY = math.clamp(phone.dragY, math.min(0, h + 34 - sh + 12), 12)
end

--------------------------------------------------------------------------------
-- SMALL HELPERS
--------------------------------------------------------------------------------
local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end

local function corner(o, scale)
	return make("UICorner", { CornerRadius = UDim.new(scale, 0) }, o)
end

local function text(parent, props)
	local p = {
		BackgroundTransparency = 1, TextColor3 = COL.text, Font = Enum.Font.GothamMedium,
		TextScaled = true, Text = "", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0,
	}
	local max = props.Max or 40
	props.Max = nil
	for k, v in pairs(props) do p[k] = v end
	local l = make("TextLabel", p, parent)
	make("UITextSizeConstraint", { MaxTextSize = max, MinTextSize = 6 }, l)
	return l
end

local function tap()
	if phone.click then pcall(function() phone.click:Play() end) end
end

local function button(parent, props, fn)
	local p = {
		BackgroundColor3 = COL.card, TextColor3 = COL.text, Font = Enum.Font.GothamBold,
		TextScaled = true, Text = "", AutoButtonColor = true, BorderSizePixel = 0,
	}
	local max = props.Max or 28
	props.Max = nil
	for k, v in pairs(props) do p[k] = v end
	local b = make("TextButton", p, parent)
	make("UITextSizeConstraint", { MaxTextSize = max, MinTextSize = 6 }, b)
	b.Activated:Connect(function()
		tap()
		fn()
	end)
	return b
end

local function fmtClock(h)
	return string.format("%02d:%02d", math.floor(h) % 24, math.floor((h % 1) * 60))
end

local function phaseOf(h)
	if h >= 5 and h < 7 then return "Dawn" end
	if h >= 7 and h < 12 then return "Morning" end
	if h >= 12 and h < 17 then return "Afternoon" end
	if h >= 17 and h < 21 then return "Evening" end
	return "Night"
end

local function titleCase(s)
	return string.sub(s, 1, 1) .. string.lower(string.sub(s, 2))
end

-- The Realism HUD panel (nil if the Realism script isn't running)
local function getPanel()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = pg and pg:FindFirstChild("RealismHUD")
	return hud and hud:FindFirstChild("Panel")
end

-- Weather as the Realism HUD reports it: icon, headline, detail
local function weatherInfo()
	local panel = getPanel()
	local info = panel and panel:FindFirstChild("Info")
	local raw = info and info.Text or ""
	local cond = string.match(raw, "%d+:%d+%s+(.+)$") or ""
	local night = Lighting:GetSunDirection().Y < -0.05
	if string.find(cond, "^RAIN") then
		local left = string.match(cond, "RAIN%s+(%S+)") or "?"
		return "\u{1F327}", "Raining", "Ends in about " .. left
	elseif string.find(cond, "^CLEARING") then
		return "\u{1F326}", "Clearing up", "The rain is easing off"
	elseif string.find(cond, "^CLEAR") then
		return night and "\u{1F319}" or "\u{2600}", "Clear skies", "Dry for now"
	end
	return "\u{2754}", "No data", "Realism HUD not found"
end

--------------------------------------------------------------------------------
-- PHONE STATE: screen, flashlight, open / close
--------------------------------------------------------------------------------
local function refreshScreen()
	local on = phone.screenOn and not phone.dead
	if phone.offBtn then
		phone.offBtn.Visible = not on
		phone.offText.Text = phone.dead and "Battery dead\n\nIt recharges slowly\nin your pocket" or ""
	end
	local sp = phone.screenPart
	if sp then
		local lit = on and phone.open
		sp.Material = lit and Enum.Material.Neon or Enum.Material.SmoothPlastic
		sp.Color = lit and Color3.fromRGB(40, 90, 150) or Color3.fromRGB(6, 8, 12)
	end
end

local function setFlash(on)
	if on and (phone.dead or phone.battery <= 0) then on = false end
	phone.flash = on
	if phone.light then phone.light.Enabled = on end
	local fp = phone.flashPart
	if fp then
		fp.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
		fp.Color = on and Color3.fromRGB(255, 250, 220) or Color3.fromRGB(80, 80, 70)
	end
	if phone.flashBtn then
		phone.flashBtn.BackgroundColor3 = on and Color3.fromRGB(255, 225, 120) or COL.card
		phone.flashBtn.TextColor3 = on and Color3.fromRGB(30, 30, 30) or COL.text
		phone.flashBtn.Text = on and "ON" or "OFF"
	end
	if phone.flashLabel then
		phone.flashLabel.Text = on and "Flashlight is on (uses more battery)" or "Tap to turn on the flashlight"
	end
end

local function go(name)
	for n, f in pairs(phone.pages) do f.Visible = (n == name) end
	phone.current = name
	local u = phone.updaters[name]
	if u then safeCall("page " .. name, u) end
end

local function setOpen(open)
	if not phone.gui or not phone.body then return end
	if open == phone.open then return end
	phone.token = phone.token + 1
	local token = phone.token
	phone.open = open
	if open then
		phone.gui.Enabled = true
		phone.tick = 1
		go(phone.current)
		clampDrag()
		TweenService:Create(phone.body, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = shownPos() }):Play()
	else
		setFlash(false)
		phone.drag = nil
		if phone.dragPill then phone.dragPill.BackgroundTransparency = 0.25 end
		TweenService:Create(phone.body, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = hiddenPos() }):Play()
		task.delay(0.3, function()
			if token == phone.token and not phone.open and phone.gui then
				phone.gui.Enabled = false
			end
		end)
	end
	refreshScreen()
end

--------------------------------------------------------------------------------
-- THE GEAR (looks like a smartphone)
--------------------------------------------------------------------------------
local function deco(tool, handle, name, shape, size, offset, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CFrame = handle.CFrame * offset
	local w = Instance.new("Weld")
	w.Part0 = handle
	w.Part1 = p
	w.C0 = offset
	w.C1 = CFrame.new()
	w.Parent = p
	p.Parent = tool
	return p
end

local function buildTool()
	local tool = Instance.new("Tool")
	tool.Name = CONFIG.TOOL_NAME
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Take out your phone"
	-- Tilts the phone a little so the screen faces you. Tweak the angle if it looks off.
	tool.Grip = CFrame.new(0, -0.15, 0) * CFrame.Angles(math.rad(-20), 0, 0)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.55, 1.1, 0.07)
	handle.Color = Color3.fromRGB(28, 30, 36)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	-- Screen glass on the face that points at you (+Z)
	phone.screenPart = deco(tool, handle, "Screen", Enum.PartType.Block, Vector3.new(0.5, 1.02, 0.012),
		CFrame.new(0, 0, 0.04), Color3.fromRGB(6, 8, 12))
	-- Notch
	deco(tool, handle, "Notch", Enum.PartType.Block, Vector3.new(0.14, 0.03, 0.014),
		CFrame.new(0, 0.47, 0.043), Color3.fromRGB(3, 3, 5))
	-- Camera bump on the back
	local sideways = CFrame.Angles(0, math.rad(90), 0) -- turns a cylinder so it points along Z
	deco(tool, handle, "LensRing", Enum.PartType.Cylinder, Vector3.new(0.03, 0.2, 0.2),
		CFrame.new(-0.13, 0.4, -0.05) * sideways, Color3.fromRGB(70, 72, 80), Enum.Material.Metal)
	deco(tool, handle, "Lens", Enum.PartType.Cylinder, Vector3.new(0.045, 0.12, 0.12),
		CFrame.new(-0.13, 0.4, -0.055) * sideways, Color3.fromRGB(8, 10, 16), Enum.Material.Glass)
	phone.flashPart = deco(tool, handle, "Flash", Enum.PartType.Cylinder, Vector3.new(0.03, 0.06, 0.06),
		CFrame.new(0.1, 0.42, -0.05) * sideways, Color3.fromRGB(80, 80, 70))

	-- Flashlight beam: shines out of the back (-Z = away from you)
	local light = Instance.new("SpotLight")
	light.Name = "PhoneFlashlight"
	light.Face = Enum.NormalId.Front
	light.Range = CONFIG.FLASHLIGHT_RANGE
	light.Angle = CONFIG.FLASHLIGHT_ANGLE
	light.Brightness = CONFIG.FLASHLIGHT_BRIGHTNESS
	light.Color = Color3.fromRGB(255, 244, 220)
	light.Shadows = true
	light.Enabled = false
	light.Parent = handle
	phone.light = light
	phone.handle = handle

	return tool
end

local function giveTool()
	task.wait(0.25) -- let the new Backpack exist after a respawn
	local backpack = LocalPlayer:WaitForChild("Backpack")
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
	end)

	for _, folder in ipairs({ backpack, LocalPlayer.Character }) do
		if folder then
			for _, item in ipairs(folder:GetChildren()) do
				if item.Name == CONFIG.TOOL_NAME and item:IsA("Tool") then item:Destroy() end
			end
		end
	end

	local tool = own(buildTool())
	phone.tool = tool
	tool.Equipped:Connect(function() safeCall("open phone", setOpen, true) end)
	tool.Unequipped:Connect(function() safeCall("close phone", setOpen, false) end)
	tool.Parent = backpack
	refreshScreen()
	setFlash(false)
end

--------------------------------------------------------------------------------
-- THE PHONE SCREEN (GUI)
--------------------------------------------------------------------------------
local function newPage(parent, name)
	local f = make("Frame", {
		Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false,
	}, parent)
	phone.pages[name] = f
	return f
end

local function pageTitle(page, title)
	return text(page, {
		Text = title, Size = UDim2.fromScale(0.9, 0.07), Position = UDim2.fromScale(0.05, 0.015),
		Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Max = 26,
	})
end

local VITALS = {
	{ "Health", "HealthRow" }, { "Hunger", "HungerRow" }, { "Thirst", "ThirstRow" },
	{ "Sprint", "SprintRow" }, { "Leg strength", "Leg StrengthRow" }, { "Adrenaline", "AdrenalineRow" },
	{ "Bleeding", "BleedingRow" }, { "Body temp", "TemperatureRow" },
}

local function buildStatus(page)
	pageTitle(page, "Status")
	phone.statusNote = text(page, {
		Text = "", Size = UDim2.fromScale(0.9, 0.05), Position = UDim2.fromScale(0.05, 0.08),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Max = 12,
	})
	local list = make("Frame", {
		Size = UDim2.fromScale(0.9, 0.82), Position = UDim2.fromScale(0.05, 0.14), BackgroundTransparency = 1,
	}, page)
	make("UIListLayout", { Padding = UDim.new(0.01, 0), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	for i, v in ipairs(VITALS) do
		local row = make("Frame", {
			Size = UDim2.new(1, 0, 0.095, 0), BackgroundColor3 = COL.card, BackgroundTransparency = 0.15,
			BorderSizePixel = 0, LayoutOrder = i, ClipsDescendants = true,
		}, list)
		corner(row, 0.3)
		local fill = make("Frame", {
			Size = UDim2.fromScale(0, 1), BackgroundColor3 = COL.accent, BackgroundTransparency = 0.25, BorderSizePixel = 0,
		}, row)
		local name = text(row, {
			Text = v[1], Size = UDim2.fromScale(0.6, 0.7), Position = UDim2.fromScale(0.04, 0.15),
			TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, Max = 14,
		})
		local val = text(row, {
			Text = "-", Size = UDim2.fromScale(0.3, 0.7), Position = UDim2.fromScale(0.66, 0.15),
			TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBold, Max = 14,
		})
		table.insert(phone.statusRows, { fill = fill, name = name, val = val, title = v[1], src = v[2] })
	end

	phone.updaters.status = function()
		local panel = getPanel()
		phone.statusNote.Text = panel and "Live from your body" or "Realism HUD not found"
		for _, r in ipairs(phone.statusRows) do
			local src = panel and panel:FindFirstChild(r.src)
			if src and src.Visible then
				local f = src:FindFirstChild("Fill")
				local val = src:FindFirstChild("Value")
				local lab = src:FindFirstChild("Label")
				r.fill.Size = UDim2.fromScale(f and f.Size.X.Scale or 0, 1)
				if f then r.fill.BackgroundColor3 = f.BackgroundColor3 end
				r.val.Text = (val and val.Text ~= "") and val.Text or ""
				if (r.src == "BleedingRow" or r.src == "TemperatureRow") and lab then
					r.name.Text = titleCase(lab.Text)
				else
					r.name.Text = r.title
				end
			else
				r.fill.Size = UDim2.fromScale(0, 1)
				r.name.Text = r.title
				r.val.Text = "-"
			end
		end
	end
end

local function buildWeather(page)
	pageTitle(page, "Weather")
	phone.wIcon = text(page, { Size = UDim2.fromScale(0.5, 0.2), Position = UDim2.fromScale(0.25, 0.14), Max = 80 })
	phone.wMain = text(page, {
		Size = UDim2.fromScale(0.9, 0.09), Position = UDim2.fromScale(0.05, 0.36),
		Font = Enum.Font.GothamBold, Max = 30,
	})
	phone.wSub = text(page, {
		Size = UDim2.fromScale(0.9, 0.06), Position = UDim2.fromScale(0.05, 0.46),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, Max = 16,
	})
	local card = make("Frame", {
		Size = UDim2.fromScale(0.9, 0.16), Position = UDim2.fromScale(0.05, 0.6),
		BackgroundColor3 = COL.card, BackgroundTransparency = 0.15, BorderSizePixel = 0,
	}, page)
	corner(card, 0.2)
	text(card, {
		Text = "You feel", Size = UDim2.fromScale(0.9, 0.3), Position = UDim2.fromScale(0.05, 0.1),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Max = 13,
	})
	phone.wFeel = text(card, {
		Size = UDim2.fromScale(0.9, 0.45), Position = UDim2.fromScale(0.05, 0.45),
		Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Max = 22,
	})

	phone.updaters.weather = function()
		local icon, main, sub = weatherInfo()
		phone.wIcon.Text, phone.wMain.Text, phone.wSub.Text = icon, main, sub
		local panel = getPanel()
		local t = panel and panel:FindFirstChild("TemperatureRow")
		local lab = t and t:FindFirstChild("Label")
		if t and t.Visible and lab then
			phone.wFeel.Text = lab.Text == "COLD" and "Cold" or "Hot"
			phone.wFeel.TextColor3 = lab.Text == "COLD" and Color3.fromRGB(110, 190, 255) or Color3.fromRGB(255, 140, 60)
		else
			phone.wFeel.Text = "Comfortable"
			phone.wFeel.TextColor3 = COL.good
		end
	end
end

local function buildClock(page)
	pageTitle(page, "Clock")
	text(page, {
		Text = "Game time", Size = UDim2.fromScale(0.9, 0.05), Position = UDim2.fromScale(0.05, 0.14),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, Max = 14,
	})
	phone.cGame = text(page, {
		Size = UDim2.fromScale(0.9, 0.18), Position = UDim2.fromScale(0.05, 0.19),
		Font = Enum.Font.GothamBold, Max = 70,
	})
	phone.cPhase = text(page, {
		Size = UDim2.fromScale(0.9, 0.07), Position = UDim2.fromScale(0.05, 0.38),
		TextColor3 = COL.accent, Font = Enum.Font.GothamBold, Max = 22,
	})
	text(page, {
		Text = "Real time", Size = UDim2.fromScale(0.9, 0.05), Position = UDim2.fromScale(0.05, 0.56),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, Max = 14,
	})
	phone.cReal = text(page, {
		Size = UDim2.fromScale(0.9, 0.1), Position = UDim2.fromScale(0.05, 0.61),
		Font = Enum.Font.GothamBold, Max = 36,
	})
	phone.updaters.clock = function()
		local h = Lighting.ClockTime
		phone.cGame.Text = fmtClock(h)
		phone.cPhase.Text = phaseOf(h)
		phone.cReal.Text = os.date("%H:%M:%S")
	end
end

local function buildFlashlight(page)
	pageTitle(page, "Flashlight")
	local b = button(page, {
		Size = UDim2.fromScale(0.5, 0.26), Position = UDim2.fromScale(0.25, 0.22), Text = "OFF", Max = 34,
	}, function() setFlash(not phone.flash) end)
	make("UIAspectRatioConstraint", { AspectRatio = 1 }, b)
	corner(b, 0.5)
	phone.flashBtn = b
	phone.flashLabel = text(page, {
		Text = "Tap to turn on the flashlight", Size = UDim2.fromScale(0.86, 0.1), Position = UDim2.fromScale(0.07, 0.7),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, TextWrapped = true, Max = 15,
	})
end

local function buildCalculator(page)
	local DIV, MUL, SUB, NEG, BACK = "\u{00F7}", "\u{00D7}", "\u{2212}", "\u{00B1}", "\u{232B}"
	local ops = {
		["+"] = function(a, b) return a + b end,
		[SUB] = function(a, b) return a - b end,
		[MUL] = function(a, b) return a * b end,
		[DIV] = function(a, b) if b ~= 0 then return a / b end return nil end,
	}
	local calc = { disp = "0", acc = nil, op = nil, fresh = true }

	local function fmt(n)
		if n ~= n or n == math.huge or n == -math.huge then return "Error" end
		if n == 0 then return "0" end
		if n == math.floor(n) and math.abs(n) < 1e12 then return string.format("%.0f", n) end
		return string.format("%.8g", n)
	end

	local display = text(page, {
		Text = "0", Size = UDim2.fromScale(0.92, 0.16), Position = UDim2.fromScale(0.04, 0.04),
		TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.Gotham, Max = 44,
	})

	local function press(k)
		if calc.disp == "Error" and k ~= "C" and not string.match(k, "^%d$") and k ~= "." then return end
		if string.match(k, "^%d$") then
			if calc.fresh or calc.disp == "0" then
				calc.disp = k
			elseif #calc.disp < 12 then
				calc.disp = calc.disp .. k
			end
			calc.fresh = false
		elseif k == "." then
			if calc.fresh then
				calc.disp = "0."
				calc.fresh = false
			elseif not string.find(calc.disp, "%.") then
				calc.disp = calc.disp .. "."
			end
		elseif k == "C" then
			calc.disp, calc.acc, calc.op, calc.fresh = "0", nil, nil, true
		elseif k == BACK then
			if calc.fresh then return end
			calc.disp = string.sub(calc.disp, 1, -2)
			if calc.disp == "" or calc.disp == "-" then calc.disp = "0" end
		elseif k == NEG then
			local n = tonumber(calc.disp)
			if n then calc.disp = fmt(-n) end
		elseif k == "%" then
			local n = tonumber(calc.disp)
			if n then calc.disp = fmt(n / 100) end
		else -- + - x / =
			local cur = tonumber(calc.disp) or 0
			if calc.op and not calc.fresh then
				local result = ops[calc.op](calc.acc, cur)
				if result == nil then
					calc.disp, calc.acc, calc.op, calc.fresh = "Error", nil, nil, true
					display.Text = calc.disp
					return
				end
				calc.acc = result
				calc.disp = fmt(result)
			elseif not calc.op then
				calc.acc = cur
			end
			calc.op = (k ~= "=") and k or nil
			calc.fresh = true
		end
		display.Text = calc.disp
	end

	local grid = make("Frame", {
		Size = UDim2.fromScale(0.92, 0.76), Position = UDim2.fromScale(0.04, 0.22), BackgroundTransparency = 1,
	}, page)
	make("UIGridLayout", {
		CellSize = UDim2.new(0.23, 0, 0.18, 0), CellPadding = UDim2.new(0.0267, 0, 0.02, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)

	local keys = {
		"C", NEG, "%", DIV, "7", "8", "9", MUL, "4", "5", "6", SUB,
		"1", "2", "3", "+", BACK, "0", ".", "=",
	}
	for i, k in ipairs(keys) do
		local isOp = (k == DIV or k == MUL or k == SUB or k == "+" or k == "=")
		local isFn = (k == "C" or k == NEG or k == "%" or k == BACK)
		local b = button(grid, {
			Text = k, LayoutOrder = i, Max = 24,
			BackgroundColor3 = isOp and COL.orange or (isFn and Color3.fromRGB(70, 76, 90) or COL.card),
		}, function() press(k) end)
		corner(b, 0.5)
	end
end

local function buildNotes(page)
	pageTitle(page, "Notes")
	local box = make("TextBox", {
		Size = UDim2.fromScale(0.92, 0.82), Position = UDim2.fromScale(0.04, 0.12),
		BackgroundColor3 = COL.card, BackgroundTransparency = 0.15, BorderSizePixel = 0,
		TextColor3 = COL.text, PlaceholderText = "Write a note...", PlaceholderColor3 = COL.dim,
		Text = _G.RealismPhoneNotes or "", MultiLine = true, ClearTextOnFocus = false,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Gotham, TextSize = 14,
	}, page)
	corner(box, 0.05)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	}, box)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		_G.RealismPhoneNotes = box.Text -- survives respawns and re-runs
	end)
end

local APPS = {
	{ "status", "Status", "\u{2764}", Color3.fromRGB(220, 70, 80) },
	{ "weather", "Weather", "\u{26C5}", Color3.fromRGB(70, 130, 220) },
	{ "clock", "Clock", "\u{23F0}", Color3.fromRGB(90, 90, 105) },
	{ "flashlight", "Light", "\u{1F526}", Color3.fromRGB(230, 180, 50) },
	{ "calculator", "Calc", "\u{1F522}", Color3.fromRGB(240, 140, 30) },
	{ "notes", "Notes", "\u{1F4DD}", Color3.fromRGB(70, 180, 110) },
}

local function buildHome(page)
	phone.homeClock = text(page, {
		Size = UDim2.fromScale(0.9, 0.13), Position = UDim2.fromScale(0.05, 0.03),
		Font = Enum.Font.GothamBold, Max = 60,
	})
	phone.homePhase = text(page, {
		Size = UDim2.fromScale(0.9, 0.045), Position = UDim2.fromScale(0.05, 0.165),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, Max = 15,
	})
	phone.homeWeather = text(page, {
		Size = UDim2.fromScale(0.9, 0.05), Position = UDim2.fromScale(0.05, 0.215), Max = 16,
	})

	local grid = make("Frame", {
		Size = UDim2.fromScale(0.92, 0.62), Position = UDim2.fromScale(0.04, 0.32), BackgroundTransparency = 1,
	}, page)
	make("UIGridLayout", {
		CellSize = UDim2.new(0.3, 0, 0.3, 0), CellPadding = UDim2.new(0.05, 0, 0.06, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)

	for i, app in ipairs(APPS) do
		local cell = make("Frame", { BackgroundTransparency = 1, LayoutOrder = i }, grid)
		local icon = button(cell, {
			Size = UDim2.fromScale(1, 0.74), BackgroundColor3 = app[4], Text = app[3], Max = 30,
		}, function() go(app[1]) end)
		corner(icon, 0.28)
		text(cell, {
			Text = app[2], Size = UDim2.fromScale(1, 0.2), Position = UDim2.fromScale(0, 0.8), Max = 12,
		})
	end

	phone.updaters.home = function()
		local h = Lighting.ClockTime
		phone.homeClock.Text = fmtClock(h)
		phone.homePhase.Text = phaseOf(h)
		local icon, main = weatherInfo()
		phone.homeWeather.Text = icon .. "  " .. main
	end
end

local function updateChrome()
	local h = Lighting.ClockTime
	phone.timeText.Text = fmtClock(h)
	local pct = math.floor(phone.battery + 0.5)
	phone.battText.Text = pct .. "%"
	phone.battFill.Size = UDim2.fromScale(math.clamp(phone.battery / 100, 0, 1), 1)
	phone.battFill.BackgroundColor3 = phone.battery < CONFIG.LOW_BATTERY and COL.bad or COL.good

	-- Wallpaper follows the sun
	local day = math.clamp((Lighting:GetSunDirection().Y + 0.1) / 0.4, 0, 1)
	local top = Color3.fromRGB(12, 16, 34):Lerp(Color3.fromRGB(60, 130, 210), day)
	local bottom = Color3.fromRGB(30, 24, 56):Lerp(Color3.fromRGB(150, 200, 240), day)
	phone.wallGrad.Color = ColorSequence.new(top, bottom)
end

local function buildGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("RealismPhone")
	if old then old:Destroy() end

	local gui = own(make("ScreenGui", {
		Name = "RealismPhone", ResetOnSpawn = false, IgnoreGuiInset = true,
		DisplayOrder = CONFIG.DISPLAY_ORDER, Enabled = false,
	}, playerGui))
	phone.gui = gui
	phone.click = make("Sound", { Name = "Click", SoundId = CONFIG.CLICK_SOUND, Volume = 0.4 }, gui)

	local heightScale = UserInputService.TouchEnabled and CONFIG.SIZE_TOUCH or CONFIG.SIZE_PC
	local body = make("Frame", {
		Name = "Body", AnchorPoint = Vector2.new(0.5, 1), Position = hiddenPos(),
		Size = UDim2.fromScale(0.5, heightScale), BackgroundColor3 = COL.bezel, BorderSizePixel = 0,
	}, gui)
	make("UIAspectRatioConstraint", {
		AspectRatio = CONFIG.ASPECT, AspectType = Enum.AspectType.FitWithinMaxSize,
		DominantAxis = Enum.DominantAxis.Height,
	}, body)
	corner(body, 0.14)
	make("UIStroke", { Color = Color3.fromRGB(70, 74, 84), Thickness = 2 }, body)
	phone.body = body

	-- Drag bar: a little pill hovering above the phone. Hold it and move to reposition the phone.
	local handle = make("TextButton", {
		Name = "DragBar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -2),
		Size = UDim2.new(0.6, 0, 0, 30), BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		BorderSizePixel = 0,
	}, body)
	local pill = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.55, 0, 0, 7), BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.25, BorderSizePixel = 0,
	}, handle)
	corner(pill, 0.5)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.6, Thickness = 1 }, pill)
	phone.dragPill = pill
	handle.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
		phone.drag = { input = input, start = input.Position, x = phone.dragX, y = phone.dragY }
		pill.BackgroundTransparency = 0
	end)

	-- Side power button: turns the screen on and off
	local power = make("TextButton", {
		Name = "Power", AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(1, 0, 0.2, 0),
		Size = UDim2.fromScale(0.03, 0.09), BackgroundColor3 = Color3.fromRGB(50, 54, 62),
		Text = "", AutoButtonColor = true, BorderSizePixel = 0,
	}, body)
	corner(power, 0.4)
	power.Activated:Connect(function()
		tap()
		if phone.dead then return end
		phone.screenOn = not phone.screenOn
		if not phone.screenOn then setFlash(phone.flash) end
		refreshScreen()
	end)

	local screen = make("Frame", {
		Name = "Screen", Position = UDim2.fromScale(0.045, 0.022), Size = UDim2.fromScale(0.91, 0.956),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ClipsDescendants = true,
	}, body)
	corner(screen, 0.11)
	phone.wallGrad = make("UIGradient", {
		Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(60, 130, 210), Color3.fromRGB(150, 200, 240)),
	}, screen)

	-- Status bar: game time on the left, battery on the right
	local bar = make("Frame", { Size = UDim2.fromScale(1, 0.055), BackgroundTransparency = 1 }, screen)
	phone.timeText = text(bar, {
		Size = UDim2.fromScale(0.35, 0.7), Position = UDim2.fromScale(0.07, 0.15),
		TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, Max = 13,
	})
	phone.battText = text(bar, {
		Size = UDim2.fromScale(0.25, 0.7), Position = UDim2.fromScale(0.5, 0.15),
		TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBold, Max = 12,
	})
	local battOutline = make("Frame", {
		Size = UDim2.fromScale(0.09, 0.4), Position = UDim2.fromScale(0.82, 0.3),
		BackgroundColor3 = Color3.fromRGB(20, 22, 28), BackgroundTransparency = 0.3, BorderSizePixel = 0,
		ClipsDescendants = true,
	}, bar)
	corner(battOutline, 0.3)
	phone.battFill = make("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = COL.good, BorderSizePixel = 0,
	}, battOutline)

	-- Pages
	local content = make("Frame", {
		Name = "Content", Position = UDim2.fromScale(0, 0.055), Size = UDim2.fromScale(1, 0.865),
		BackgroundTransparency = 1,
	}, screen)
	buildHome(newPage(content, "home"))
	buildStatus(newPage(content, "status"))
	buildWeather(newPage(content, "weather"))
	buildClock(newPage(content, "clock"))
	buildFlashlight(newPage(content, "flashlight"))
	buildCalculator(newPage(content, "calculator"))
	buildNotes(newPage(content, "notes"))

	-- Home pill at the bottom
	local nav = make("Frame", {
		Position = UDim2.fromScale(0, 0.92), Size = UDim2.fromScale(1, 0.08), BackgroundTransparency = 1,
	}, screen)
	local pill = make("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.36, 0.3),
		BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.25, Text = "",
		AutoButtonColor = false, BorderSizePixel = 0,
	}, nav)
	corner(pill, 0.5)
	pill.Activated:Connect(function()
		tap()
		go("home")
	end)

	-- Off / dead screen (covers everything; tap it to wake the phone)
	local off = make("TextButton", {
		Name = "Off", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
		Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 100, Visible = false,
	}, screen)
	phone.offBtn = off
	phone.offText = text(off, {
		Size = UDim2.fromScale(0.8, 0.3), Position = UDim2.fromScale(0.1, 0.35),
		TextColor3 = COL.dim, Font = Enum.Font.Gotham, ZIndex = 101, Max = 16,
	})
	off.Activated:Connect(function()
		if phone.dead then return end
		tap()
		phone.screenOn = true
		refreshScreen()
	end)
end

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------
local function step(dt)
	-- Battery
	if phone.open then
		local drain = 0
		if phone.screenOn and not phone.dead then drain = drain + CONFIG.BATTERY_DRAIN end
		if phone.flash then drain = drain + CONFIG.FLASHLIGHT_DRAIN end
		phone.battery = math.max(0, phone.battery - drain * dt)
	else
		phone.battery = math.min(100, phone.battery + CONFIG.BATTERY_RECHARGE * dt)
	end

	if not phone.dead and phone.battery <= 0 then
		phone.dead = true
		setFlash(false)
		refreshScreen()
		__toast("Your phone died")
	elseif phone.dead and phone.battery >= CONFIG.MIN_BOOT then
		phone.dead = false
		refreshScreen()
	end

	if phone.open and phone.battery < CONFIG.LOW_BATTERY and not phone.dead and not phone.warned then
		phone.warned = true
		__toast("Phone battery low")
	elseif phone.battery > CONFIG.LOW_BATTERY + 10 then
		phone.warned = false
	end

	if not phone.open then return end
	phone.tick = phone.tick + dt
	if phone.tick < 0.25 then return end
	phone.tick = 0
	if phone.screenOn and not phone.dead then
		updateChrome()
		local u = phone.updaters[phone.current]
		if u then u() end
	end
end

--------------------------------------------------------------------------------
-- START
--------------------------------------------------------------------------------
safeCall("build gui", buildGui)
safeCall("start page", go, "home")
if phone.pages.home then phone.pages.home.Visible = true end

track(RunService.Heartbeat:Connect(function(dt)
	safeCall("phone loop", step, dt)
end))

-- Dragging the phone by its bar
track(UserInputService.InputChanged:Connect(function(input)
	local d = phone.drag
	if not d or not phone.body then return end
	local t = input.UserInputType
	if (t == Enum.UserInputType.Touch and input == d.input) or t == Enum.UserInputType.MouseMovement then
		phone.dragX = d.x + (input.Position.X - d.start.X)
		phone.dragY = d.y + (input.Position.Y - d.start.Y)
		clampDrag()
		phone.body.Position = shownPos()
	end
end))

track(UserInputService.InputEnded:Connect(function(input)
	local d = phone.drag
	if not d then return end
	local same = input == d.input
		or (input.UserInputType == Enum.UserInputType.MouseButton1 and d.input.UserInputType == Enum.UserInputType.MouseButton1)
	if same then
		phone.drag = nil
		if phone.dragPill then phone.dragPill.BackgroundTransparency = 0.25 end
	end
end))

track(LocalPlayer.CharacterAdded:Connect(function()
	setOpen(false)
	phone.screenOn = true
	task.spawn(safeCall, "give phone", giveTool)
end))

task.spawn(safeCall, "give phone", giveTool)

__toast("loaded. Find the Phone in your hotbar and equip it.")

--------------------------------------------------------------------------------
-- CLEANUP (runs automatically if the script is executed again)
--------------------------------------------------------------------------------
_G.RealismPhoneCleanup = function()
	for _, c in ipairs(connections) do c:Disconnect() end
	setFlash(false)
	for _, inst in ipairs(instances) do
		if inst and inst.Parent then inst:Destroy() end
	end
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	for _, folder in ipairs({ backpack, LocalPlayer.Character }) do
		if folder then
			for _, item in ipairs(folder:GetChildren()) do
				if item.Name == CONFIG.TOOL_NAME and item:IsA("Tool") then item:Destroy() end
			end
		end
	end
	_G.RealismPhoneCleanup = nil
end

end, function(e) return debug.traceback(tostring(e), 2) end)

if not __ok then
	__toast("SCRIPT CRASHED: " .. string.match(tostring(__err), "^[^\n]*"))
	warn(__err)
end
