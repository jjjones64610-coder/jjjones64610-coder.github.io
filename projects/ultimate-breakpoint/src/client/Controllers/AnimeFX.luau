--!strict
--[[
	AnimeFX — anime-style flair on top of the poses (PoseController) and the
	plain technique effects (EffectsController):

	  * Speed lines: radial streaks at the screen edge once you pass run
	    speed, denser the faster you go; a burst of them on every Perfect.
	  * Afterimages: neon ghost copies of the body that fade out, left behind
	    by dashes, dodges, cuts and dives (everyone sees everyone's).
	  * Impact frames: on your own Perfect techs, two frames of high-contrast
	    black-and-white with a colour tint, then back to normal.
	  * Slash arcs: a bright flat ring that snaps open where a cut, wavedash
	    or plant stop bit into the ground.

	Setting AnimeEffects (default on) turns all of it off; the speed lines
	also follow CameraShake's spirit and stay subtle.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Theme = require(script.Parent.Parent.UI.Theme)
local Art = require(ReplicatedStorage:WaitForChild("Shared").Config.Art)

local AnimeFX = {}

local controllers: any
local player = Players.LocalPlayer

local LINE_COUNT = 28
local LINE_START = 25 -- studs/s where speed lines begin
local LINE_FULL = 42
local GHOST_LIFE = 0.32
local GHOST_MAX_PARTS = 16
local IMPACT_TIME = 0.07

-- which techs leave afterimages, and how many ghosts
local GHOSTS: { [string]: number } = {
	Cut = 1,
	Juke = 1,
	BurstKick = 2,
	AirDodge = 2,
	Wavedash = 2,
	ReverseSnap = 3,
	BurstDive = 3,
	Layout = 2,
	TechRoll = 1,
	SlideHop = 1,
	ResetFlip = 3,
	ZapDash = 3,
	WallKick = 2,
	Stall = 1,
	-- classic engine
	SnapCut = 1,
	BurstStep = 2,
	Dive = 2,
	AirRedirect = 2,
}

local SLASH: { [string]: boolean } = { Cut = true, Wavedash = true, PlantStop = true, Juke = true, ZapDash = true }
local SHOCK: { [string]: boolean } = {
	Wavedash = true,
	PlantStop = true,
	LandingSlide = true,
	Sky = true,
	WallKick = true,
	Stall = true,
	TechRoll = true,
}
local SPARKLE: { [string]: boolean } =
	{ FlipReset = true, DiscReset = true, PerfectCatch = true, ResetFlip = true, Pinch = true }
local DASH_SOUND: { [string]: boolean } =
	{ AirDodge = true, ZapDash = true, BurstDive = true, ReverseSnap = true, BurstKick = true, WallKick = true }

local lines: { Frame } = {}
local lineGui: ScreenGui? = nil
local pulseUntil = 0
local impact: ColorCorrectionEffect? = nil
local fxFolder: Folder? = nil

local function enabled(): boolean
	return controllers.SettingsController.get("AnimeEffects") ~= false
end

local function folder(): Folder
	local f = fxFolder
	if f and f.Parent then
		return f
	end
	local parent = workspace:FindFirstChild("UBVisuals")
	if not parent then
		local nf = Instance.new("Folder")
		nf.Name = "UBVisuals"
		nf.Parent = workspace
		parent = nf
	end
	local created = Instance.new("Folder")
	created.Name = "AnimeFX"
	created.Parent = parent
	fxFolder = created
	return created
end

---------------------------------------------------------------------------
-- afterimages
---------------------------------------------------------------------------

-- Leaves `count` fading neon copies of the body, the first one now.
function AnimeFX.afterimage(model: Model, color: Color3, count: number?)
	if not enabled() then
		return
	end
	local n = math.clamp(count or 1, 1, 4)
	for i = 0, n - 1 do
		task.delay(i * 0.045, function()
			if not model.Parent then
				return
			end
			local made = 0
			for _, part in model:GetDescendants() do
				if made >= GHOST_MAX_PARTS then
					break
				end
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 0.9 then
					local accessory = part.Parent and part.Parent:IsA("Accessory")
					if not accessory then
						made += 1
						local g = Instance.new("Part")
						g.Name = "Ghost"
						g.Anchored = true
						g.CanCollide = false
						g.CanQuery = false
						g.CanTouch = false
						g.CastShadow = false
						g.Material = Enum.Material.Neon
						g.Color = color
						g.Size = part.Size
						g.CFrame = part.CFrame
						g.Transparency = 0.45 + i * 0.12
						g.Parent = folder()
						TweenService:Create(g, TweenInfo.new(GHOST_LIFE), { Transparency = 1 }):Play()
						task.delay(GHOST_LIFE + 0.05, function()
							g:Destroy()
						end)
					end
				end
			end
		end)
	end
end

---------------------------------------------------------------------------
-- slash arcs
---------------------------------------------------------------------------

-- A flat effect part lying on the ground at `pos`, facing `look`, with an
-- optional texture (Config/Art.Vfx) on top; falls back to a neon slab.
local function groundSprite(name: string, pos: Vector3, look: Vector3, color: Color3): (Part, Decal?)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = CFrame.lookAt(pos, pos + look)
	local tex = Art.vfx(name)
	local decal: Decal? = nil
	if tex then
		p.Transparency = 1
		local d = Instance.new("Decal")
		d.Face = Enum.NormalId.Top
		d.Texture = tex
		d.Color3 = color
		d.Parent = p
		decal = d
	else
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = 0.1
	end
	p.Parent = folder()
	return p, decal
end

local function fadeOut(p: Part, decal: Decal?, size: Vector3, time: number)
	local info = TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if decal then
		TweenService:Create(p, info, { Size = size }):Play()
		TweenService:Create(decal, info, { Transparency = 1 }):Play()
	else
		TweenService:Create(p, info, { Size = size, Transparency = 1 }):Play()
	end
	task.delay(time + 0.08, function()
		p:Destroy()
	end)
end

-- A slash arc where a cut bites into the ground.
function AnimeFX.slash(pos: Vector3, dir: Vector3, color: Color3)
	if not enabled() then
		return
	end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	local p, decal = groundSprite("Slash", pos, look, color)
	p.Size = if decal then Vector3.new(2, 0.05, 1.2) else Vector3.new(0.15, 0.08, 1)
	fadeOut(p, decal, if decal then Vector3.new(9, 0.05, 4.5) else Vector3.new(7, 0.08, 1.4), 0.24)
end

-- A ring that bursts out along the ground (wavedash, plant stop, resets).
function AnimeFX.shockwave(pos: Vector3, color: Color3, radius: number?)
	if not enabled() then
		return
	end
	local r = radius or 5
	local p, decal = groundSprite("Shockwave", pos, Vector3.new(0, 0, -1), color)
	p.Size = Vector3.new(1, 0.05, 1)
	fadeOut(p, decal, Vector3.new(r * 2, 0.05, r * 2), 0.3)
end

-- A spiky anime impact star that pops at `pos` facing the camera.
function AnimeFX.impactBurst(pos: Vector3, color: Color3, size: number?)
	if not enabled() then
		return
	end
	local tex = Art.vfx("Impact")
	if not tex then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "ImpactAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(pos)
	anchor.Parent = folder()
	local s0 = size or 6
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(s0 * 0.4, s0 * 0.4)
	bb.LightInfluence = 0
	bb.AlwaysOnTop = false
	bb.Parent = anchor
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = tex
	img.ImageColor3 = color
	img.Rotation = math.random(0, 359)
	img.Parent = bb
	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(bb, info, { Size = UDim2.fromScale(s0, s0) }):Play()
	TweenService:Create(img, info, { ImageTransparency = 1, Rotation = img.Rotation + 25 }):Play()
	task.delay(0.28, function()
		anchor:Destroy()
	end)
end

---------------------------------------------------------------------------
-- impact frame
---------------------------------------------------------------------------

function AnimeFX.impactFrame(tint: Color3)
	if not enabled() then
		return
	end
	local cc = impact
	if not cc or not cc.Parent then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "UBImpactFrame"
		made.Enabled = false
		made.Parent = Lighting
		cc = made
		impact = made
	end
	local e = cc :: ColorCorrectionEffect
	e.Contrast = 0.9
	e.Saturation = -1
	e.Brightness = 0.05
	e.TintColor = tint
	e.Enabled = true
	controllers.AudioController.play("Impact", 0.06)
	task.delay(IMPACT_TIME, function()
		e.Enabled = false
	end)
	pulseUntil = os.clock() + 0.25
end

---------------------------------------------------------------------------
-- speed lines
---------------------------------------------------------------------------

local function buildLines()
	local g = Instance.new("ScreenGui")
	g.Name = "UBSpeedLines"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = 2
	g.Parent = player:WaitForChild("PlayerGui")
	for i = 1, LINE_COUNT do
		local f = Instance.new("Frame")
		f.Name = "Line" .. i
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BorderSizePixel = 0
		f.BackgroundTransparency = 1
		f.Parent = g
		table.insert(lines, f)
	end
	lineGui = g
end

local rng = Random.new()
local lineClock = 0

local function updateLines(dt: number)
	local g = lineGui
	if not g then
		return
	end
	local root = controllers.MovementController.root()
	local speed = 0
	if root then
		local v = root.AssemblyLinearVelocity
		speed = Vector3.new(v.X, 0, v.Z).Magnitude
	end
	local k = math.clamp((speed - LINE_START) / (LINE_FULL - LINE_START), 0, 1)
	local pulse = os.clock() < pulseUntil
	if pulse then
		k = math.max(k, 0.8)
	end
	if not enabled() or k <= 0 then
		if g.Enabled then
			g.Enabled = false
		end
		return
	end
	g.Enabled = true
	lineClock += dt
	if lineClock < 0.05 then
		return
	end
	lineClock = 0
	-- re-scatter the streaks around the edge each tick (the flicker)
	local shown = math.floor(LINE_COUNT * (0.35 + 0.65 * k))
	for i, f in lines do
		if i > shown then
			f.BackgroundTransparency = 1
		else
			local a = rng:NextNumber() * math.pi * 2
			local r = 0.42 + rng:NextNumber() * 0.12
			local len = 60 + 140 * k * rng:NextNumber()
			f.Position = UDim2.fromScale(0.5 + math.cos(a) * r, 0.5 + math.sin(a) * r * 0.9)
			f.Size = UDim2.fromOffset(len, 2)
			f.Rotation = math.deg(a)
			f.BackgroundColor3 = if pulse then Theme.Colors.Perfect else Color3.new(1, 1, 1)
			f.BackgroundTransparency = 0.75 - 0.4 * k
		end
	end
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

-- Called by EffectsController for every technique, local or remote.
function AnimeFX.tech(model: Model, tech: string, quality: string, dir: Vector3)
	if not enabled() then
		return
	end
	local color = (Theme.TechColors :: any)[tech] or Theme.Colors.Accent
	local perfect = quality == "Perfect"
	local ghosts = GHOSTS[tech]
	if ghosts then
		AnimeFX.afterimage(model, if perfect then Theme.Colors.Perfect else color, ghosts + (if perfect then 1 else 0))
	end
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local tint = if perfect then Theme.Colors.Perfect else color
	if root then
		local feet = root.Position - Vector3.new(0, 2.8, 0)
		if SLASH[tech] then
			AnimeFX.slash(feet, dir, tint)
		end
		if SHOCK[tech] then
			AnimeFX.shockwave(feet + Vector3.new(0, 0.05, 0), tint, if perfect then 6 else 4)
		end
		if SPARKLE[tech] then
			controllers.EffectsController.burst(root.Position, tint, 10, 9, Art.vfx("Sparkle"))
		end
		-- every Perfect pops an impact star that everyone sees
		if perfect and tech ~= "Plant" then
			AnimeFX.impactBurst(root.Position + Vector3.new(0, 0.5, 0), tint, 6)
		end
	end
	if model == player.Character then
		if perfect and tech ~= "Plant" then
			AnimeFX.impactFrame(color)
		end
		if DASH_SOUND[tech] then
			controllers.AudioController.play("Dash", 0.08)
		end
	end
end

function AnimeFX.Init(c: any)
	controllers = c
end

function AnimeFX.Start()
	buildLines()
	RunService.RenderStepped:Connect(updateLines)
end

return AnimeFX
