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

local Theme = require(script.Parent.Parent.UI.Theme)

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

function AnimeFX.slash(pos: Vector3, dir: Vector3, color: Color3)
	if not enabled() then
		return
	end
	local p = Instance.new("Part")
	p.Name = "Slash"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.15, 0.08, 1)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	p.CFrame = CFrame.lookAt(pos, pos + look)
	p.Transparency = 0.1
	p.Parent = folder()
	TweenService:Create(p, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(7, 0.08, 1.4),
		Transparency = 1,
	}):Play()
	task.delay(0.3, function()
		p:Destroy()
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
	if root and SLASH[tech] then
		AnimeFX.slash(root.Position - Vector3.new(0, 2.8, 0), dir, if perfect then Theme.Colors.Perfect else color)
	end
	if perfect and model == player.Character and tech ~= "Plant" then
		AnimeFX.impactFrame(color)
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
