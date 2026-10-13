--!strict
--[[
	ArenaBuilder — procedurally builds the field and its surroundings.

	The playing surface follows the mode (Config/Modes.Fields: Mini 3v3 or
	Normal 7v7) and is the same in every arena, so spacing and muscle memory
	carry over; only the theme, lighting, wind and optional rebound walls
	change. Theme dressing (stands, lights, trees, skyline, crowd) is laid out
	relative to the field size, the big Normal field gets a scoreboard at each
	end, and every theme has a team bench on each half of the -Z sideline
	(FieldGeometry.benchCenter, team A west / B east as MatchPlan.BenchSign),
	returned in Built.benches for the substitutes' teleports.
	Everything is generated from code, so the place file needs no hand-built
	geometry and every arena can be rebuilt between matches.

	Decorations are CanQuery = false so client ground/wall raycasts only ever
	see the field, the out-of-bounds surround and tagged Rebound walls.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared.Util.Rng)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local MatchPlan = require(Shared.Rules.MatchPlan)
local TeamsConfig = require(Shared.Config.Teams)
local Build = require(script.Parent.Build)

local ArenaBuilder = {}

export type FieldSpec = { width: number, length: number, endZone: number, brick: number }

export type Built = {
	model: Model,
	endZones: { [string]: BasePart },
	spawn: SpawnLocation,
	margin: number,
	benches: { [string]: CFrame }, -- team -> centre of its bench spots, facing the field
}

local MARGIN = 34
-- Dressing that used to be laid out for a 270-stud field scales from here.
local BASE_HALF_TOTAL = 135
local WHITE = Color3.fromRGB(250, 250, 250)
local CONE = Color3.fromRGB(255, 110, 20)

local SKIN = {
	Color3.fromRGB(255, 220, 190),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(198, 140, 100),
	Color3.fromRGB(141, 92, 62),
	Color3.fromRGB(96, 62, 42),
}

local SHIRTS = {
	Color3.fromRGB(32, 140, 255),
	Color3.fromRGB(255, 120, 30),
	Color3.fromRGB(240, 240, 240),
	Color3.fromRGB(40, 40, 50),
	Color3.fromRGB(220, 60, 70),
	Color3.fromRGB(60, 190, 120),
	Color3.fromRGB(250, 210, 60),
	Color3.fromRGB(120, 90, 220),
}

local function pick<T>(rng: Rng.Rng, list: { T }): T
	return list[rng:int(1, #list)]
end

-- Half the total length (playing field + both end zones).
local function halfTotal(f: FieldSpec): number
	return f.length / 2 + f.endZone
end

-- How much bigger than the original field this one is (never below 1).
local function dressScale(f: FieldSpec): number
	return math.max(1, halfTotal(f) / BASE_HALF_TOTAL)
end

-- The big (Normal) field gets a scoreboard at each end.
local function bigField(f: FieldSpec): boolean
	return 2 * halfTotal(f) >= 300
end

---------------------------------------------------------------------------
-- lighting
---------------------------------------------------------------------------

local function applyLighting(arena: any)
	for k, v in arena.Lighting do
		pcall(function()
			(Lighting :: any)[k] = v
		end)
	end
	local function effect(className: string, name: string, props: { [string]: any })
		local e = Lighting:FindFirstChild(name)
		if not e then
			e = Instance.new(className)
			e.Name = name
			e.Parent = Lighting
		end
		for k, v in props do
			pcall(function()
				(e :: any)[k] = v
			end)
		end
	end
	effect("Atmosphere", "UBAtmosphere", arena.Atmosphere)
	effect("ColorCorrectionEffect", "UBColor", arena.ColorCorrection)
	effect("BloomEffect", "UBBloom", arena.Bloom)
	effect("SunRaysEffect", "UBSunRays", { Intensity = if arena.Theme == "Coastal" then 0.12 else 0.04, Spread = 0.6 })
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		sky = Instance.new("Sky")
		sky.Parent = Lighting
	end
	local s = sky :: Sky
	s.StarCount = if arena.Theme == "Rooftop" or arena.Theme == "Stadium" then 3000 else 600
	s.CelestialBodiesShown = arena.Theme ~= "Indoor"
end

---------------------------------------------------------------------------
-- the field itself
---------------------------------------------------------------------------

local function buildField(model: Model, arena: any, f: FieldSpec): { [string]: BasePart }
	local L = f.length / 2
	local E = f.endZone
	local W = f.width / 2
	local HL = L + E
	local fieldFolder = Build.folder(model, "Field")

	-- out-of-bounds surround (walkable)
	Build.part(fieldFolder, {
		Name = "Surround",
		Size = Vector3.new(2 * HL + 2 * MARGIN + 220, 1, 2 * W + 2 * MARGIN + 200),
		CFrame = CFrame.new(0, -0.5, 0),
		Material = arena.Surround.Material,
		Color = arena.Surround.Color,
		solid = true,
	})

	-- mowed stripes
	local stripeW = 20
	local count = math.ceil((2 * HL + 24) / stripeW)
	local startX = -count * stripeW / 2
	for i = 0, count - 1 do
		Build.part(fieldFolder, {
			Name = "Turf",
			Size = Vector3.new(stripeW, 0.2, 2 * W + 16),
			CFrame = CFrame.new(startX + stripeW * (i + 0.5), -0.08, 0),
			Material = arena.Ground.Material,
			Color = if i % 2 == 0 then arena.Ground.A else arena.Ground.B,
			solid = true,
		})
	end

	local lineMat = if arena.Theme == "Rooftop" then Enum.Material.Neon else Enum.Material.SmoothPlastic
	local lineColor = arena.LineColor or WHITE
	local function line(name: string, size: Vector3, cf: CFrame)
		Build.part(fieldFolder, {
			Name = name,
			Size = size,
			CFrame = cf,
			Color = lineColor,
			Material = lineMat,
		})
	end
	local y = 0.035
	line("Sideline", Vector3.new(2 * HL, 0.05, 0.6), CFrame.new(0, y, W))
	line("Sideline", Vector3.new(2 * HL, 0.05, 0.6), CFrame.new(0, y, -W))
	line("EndLine", Vector3.new(0.6, 0.05, 2 * W), CFrame.new(HL, y, 0))
	line("EndLine", Vector3.new(0.6, 0.05, 2 * W), CFrame.new(-HL, y, 0))
	line("GoalLine", Vector3.new(0.8, 0.05, 2 * W), CFrame.new(L, y, 0))
	line("GoalLine", Vector3.new(0.8, 0.05, 2 * W), CFrame.new(-L, y, 0))
	for x = -L + 20, L - 20, 20 do
		line("Hash", Vector3.new(0.4, 0.05, 2.5), CFrame.new(x, y, W - 4))
		line("Hash", Vector3.new(0.4, 0.05, 2.5), CFrame.new(x, y, -(W - 4)))
	end
	for _, sx in { 1, -1 } do
		local bx = sx * (L - f.brick)
		line("Brick", Vector3.new(3.4, 0.05, 0.5), CFrame.new(bx, y, 0) * CFrame.Angles(0, math.rad(45), 0))
		line("Brick", Vector3.new(3.4, 0.05, 0.5), CFrame.new(bx, y, 0) * CFrame.Angles(0, math.rad(-45), 0))
	end

	-- centre logo
	local logo = Build.part(fieldFolder, {
		Name = "Logo",
		Size = Vector3.new(46, 0.02, 12),
		CFrame = CFrame.new(0, 0.045, 0),
		Transparency = 1,
	})
	Build.topText(logo, "BREAKPOINT", lineColor, 0.55)

	-- end zone overlays (recoloured each point by MatchService)
	local endZones: { [string]: BasePart } = {}
	for _, side in { "East", "West" } do
		local sx = if side == "East" then 1 else -1
		local ez = Build.part(fieldFolder, {
			Name = "EndZone" .. side,
			Size = Vector3.new(E - 0.8, 0.04, 2 * W - 0.6),
			CFrame = CFrame.new(sx * (L + E / 2), 0.03, 0),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(200, 200, 210),
			Transparency = 0.86,
		})
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Label"
		gui.Face = Enum.NormalId.Top
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 12
		gui.LightInfluence = 0.4
		gui.Parent = ez
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundTransparency = 1
		text.Size = UDim2.fromScale(1, 0.5)
		text.Position = UDim2.fromScale(0, 0.25)
		text.Rotation = if side == "East" then -90 else 90
		text.Font = Enum.Font.GothamBlack
		text.TextScaled = true
		text.TextTransparency = 0.45
		text.TextColor3 = Color3.new(1, 1, 1)
		text.Text = ""
		text.Parent = gui
		CollectionService:AddTag(ez, "UBEndZone")
		ez:SetAttribute("Side", side)
		endZones[side] = ez
	end

	-- pylons
	for _, cx in { L, -L, HL, -HL } do
		for _, cz in { W, -W } do
			Build.part(fieldFolder, {
				Name = "Cone",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.8, 1.3, 1.3),
				CFrame = CFrame.new(cx, 0.9, cz) * CFrame.Angles(0, 0, math.rad(90)),
				Color = CONE,
				Material = Enum.Material.Neon,
			})
		end
	end

	-- invisible boundary
	local wallH = 60
	local walls = Build.folder(model, "Bounds")
	for _, sx in { 1, -1 } do
		Build.part(walls, {
			Name = "BoundX",
			Size = Vector3.new(2, wallH, 2 * W + 2 * MARGIN + 4),
			CFrame = CFrame.new(sx * (HL + MARGIN), wallH / 2, 0),
			Transparency = 1,
			solid = true,
		})
		Build.part(walls, {
			Name = "BoundZ",
			Size = Vector3.new(2 * HL + 2 * MARGIN + 4, wallH, 2),
			CFrame = CFrame.new(0, wallH / 2, sx * (W + MARGIN)),
			Transparency = 1,
			solid = true,
		})
	end
	Build.part(walls, {
		Name = "Ceiling",
		Size = Vector3.new(2 * HL + 2 * MARGIN + 4, 2, 2 * W + 2 * MARGIN + 4),
		CFrame = CFrame.new(0, wallH + 1, 0),
		Transparency = 1,
		solid = true,
	})

	if arena.Rebound then
		for i, sz in { 1, -1 } do
			local wall = Build.part(walls, {
				Name = "Rebound" .. i,
				Size = Vector3.new(2 * L, 18, 1),
				CFrame = CFrame.new(0, 9, sz * (W + 7)),
				Material = Enum.Material.Neon,
				Color = arena.LineColor,
				Transparency = 0.55,
				solid = true,
			})
			CollectionService:AddTag(wall, "Rebound")
		end
	end
	return endZones
end

---------------------------------------------------------------------------
-- surroundings
---------------------------------------------------------------------------

local function crowdFigure(parent: Instance, rng: Rng.Rng, pos: Vector3, facing: Vector3)
	local fan = Instance.new("Model")
	fan.Name = "Fan"
	local cf = CFrame.lookAt(pos, pos + facing)
	local torso = Build.part(fan, {
		Name = "Torso",
		Size = Vector3.new(1.5, 1.8, 0.9),
		CFrame = cf * CFrame.new(0, 0.9, 0),
		Color = pick(rng, SHIRTS),
	})
	Build.part(fan, {
		Name = "Head",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.1, 1.1, 1.1),
		CFrame = cf * CFrame.new(0, 2.35, 0),
		Color = pick(rng, SKIN),
	})
	fan.PrimaryPart = torso
	fan:SetAttribute("Phase", rng:next() * 6.28)
	CollectionService:AddTag(fan, "UBCrowd")
	fan.Parent = parent
end

-- Stepped stand along one side. axis = "Z" (sideline) or "X" (end).
local function stand(
	parent: Instance,
	rng: Rng.Rng,
	center: Vector3,
	length: number,
	outward: Vector3,
	rows: number,
	crowd: number,
	color: Color3,
	fanBudget: { n: number }
)
	local m = Build.model(parent, "Stand")
	local along = Vector3.new(-outward.Z, 0, outward.X)
	local rowDepth, rowRise = 3, 2
	for r = 0, rows - 1 do
		local h = rowRise * (r + 1)
		local c = center + outward * (r * rowDepth + rowDepth / 2) + Vector3.new(0, h / 2, 0)
		Build.part(m, {
			Name = "Tier",
			Size = Vector3.new(length, h, rowDepth),
			CFrame = CFrame.lookAt(c, c + outward),
			Color = if r % 2 == 0 then color else color:Lerp(Color3.new(0, 0, 0), 0.15),
			Material = Enum.Material.Concrete,
			CastShadow = true,
		})
		local seatTop = center + outward * (r * rowDepth + rowDepth / 2) + Vector3.new(0, h, 0)
		for s = -length / 2 + 2, length / 2 - 2, 3 do
			if fanBudget.n > 0 and rng:next() < crowd then
				fanBudget.n -= 1
				crowdFigure(m, rng, seatTop + along * (s + rng:range(-0.4, 0.4)), -outward)
			end
		end
	end
	-- back wall and roof edge
	local back = center + outward * (rows * rowDepth + 1) + Vector3.new(0, rows * rowRise / 2 + 3, 0)
	Build.part(m, {
		Name = "BackWall",
		Size = Vector3.new(length, rows * rowRise + 6, 2),
		CFrame = CFrame.lookAt(back, back + outward),
		Color = color:Lerp(Color3.new(0, 0, 0), 0.35),
		Material = Enum.Material.Concrete,
	})
	return m
end

local function floodlights(parent: Instance, f: FieldSpec, brightness: number, color: Color3)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local rig = Build.folder(parent, "Floodlights")
	for x = -L + 20, L - 20, 55 do
		for _, z in { -W * 0.5, W * 0.5 } do
			local p = Build.part(rig, {
				Name = "Lamp",
				Size = Vector3.new(1, 1, 1),
				CFrame = CFrame.new(x, 52, z),
				Transparency = 1,
			})
			Build.light(p, "SpotLight", {
				Face = Enum.NormalId.Bottom,
				Range = 60,
				Angle = 130,
				Brightness = brightness,
				Color = color,
				Shadows = false,
			})
		end
	end
	-- towers (visual) at the corners
	for _, sx in { 1, -1 } do
		for _, sz in { 1, -1 } do
			local base = Vector3.new(sx * (L + MARGIN + 18), 0, sz * (W + MARGIN + 24))
			Build.part(rig, {
				Name = "Pole",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(80, 2.4, 2.4),
				CFrame = CFrame.new(base + Vector3.new(0, 40, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				Color = Color3.fromRGB(150, 155, 165),
				Material = Enum.Material.Metal,
			})
			local headPos = base + Vector3.new(0, 82, 0)
			local head = Build.part(rig, {
				Name = "LampHead",
				Size = Vector3.new(18, 8, 2),
				CFrame = CFrame.lookAt(headPos, Vector3.new(0, 0, 0)),
				Color = Color3.fromRGB(255, 250, 235),
				Material = Enum.Material.Neon,
			})
			Build.light(head, "SpotLight", {
				Face = Enum.NormalId.Front,
				Range = 60,
				Angle = 70,
				Brightness = 3,
				Color = color,
				Shadows = false,
			})
		end
	end
end

local function scoreboard(parent: Instance, pos: Vector3, facing: Vector3)
	local board = Build.part(parent, {
		Name = "Scoreboard",
		Size = Vector3.new(56, 20, 2),
		CFrame = CFrame.lookAt(pos, pos + facing),
		Color = Color3.fromRGB(14, 16, 22),
	})
	Build.part(parent, {
		Name = "ScoreboardFrame",
		Size = Vector3.new(58, 22, 1),
		CFrame = CFrame.lookAt(pos - facing * 0.8, pos + facing),
		Color = Color3.fromRGB(90, 230, 255),
		Material = Enum.Material.Neon,
	})
	Build.part(parent, {
		Name = "ScoreboardLeg",
		Size = Vector3.new(3, pos.Y, 3),
		CFrame = CFrame.new(pos.X - facing.X * 2, pos.Y / 2, pos.Z - facing.Z * 2),
		Color = Color3.fromRGB(60, 62, 70),
		Material = Enum.Material.Metal,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.Parent = board
	local function label(name: string, x: number, w: number, y: number, h: number, text: string, color: Color3)
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Position = UDim2.fromScale(x, y)
		t.Size = UDim2.fromScale(w, h)
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = color
		t.Text = text
		t.Parent = gui
	end
	label("TeamA", 0.02, 0.3, 0.06, 0.25, "TIDE", Color3.fromRGB(32, 140, 255))
	label("TeamB", 0.68, 0.3, 0.06, 0.25, "BLAZE", Color3.fromRGB(255, 120, 30))
	label("ScoreA", 0.02, 0.3, 0.32, 0.55, "0", Color3.new(1, 1, 1))
	label("ScoreB", 0.68, 0.3, 0.32, 0.55, "0", Color3.new(1, 1, 1))
	label("Clock", 0.34, 0.32, 0.12, 0.3, "8:00", Color3.fromRGB(255, 220, 90))
	label("Phase", 0.34, 0.32, 0.48, 0.18, "WARMUP", Color3.fromRGB(190, 200, 215))
	label("Info", 0.34, 0.32, 0.7, 0.16, "", Color3.fromRGB(150, 160, 175))
	CollectionService:AddTag(board, "UBScoreboard")
end

local function palm(parent: Instance, rng: Rng.Rng, pos: Vector3)
	local m = Build.model(parent, "Palm")
	local height = rng:range(16, 26)
	local lean = rng:range(-0.25, 0.25)
	local segments = 6
	local top = pos
	for i = 1, segments do
		local a = pos + Vector3.new(lean * (i - 1) * height / segments, (i - 1) * height / segments, 0)
		local b = pos + Vector3.new(lean * i * height / segments, i * height / segments, 0)
		local mid = (a + b) / 2
		Build.part(m, {
			Name = "Trunk",
			Size = Vector3.new(1.2 - i * 0.08, (b - a).Magnitude + 0.2, 1.2 - i * 0.08),
			CFrame = CFrame.lookAt(mid, b) * CFrame.Angles(math.rad(90), 0, 0),
			Color = Color3.fromRGB(130, 96, 60),
			Material = Enum.Material.Wood,
		})
		top = b
	end
	for k = 0, 6 do
		local ang = k / 7 * math.pi * 2
		local dir = Vector3.new(math.cos(ang), -0.35, math.sin(ang)).Unit
		local c = top + dir * 4
		Build.part(m, {
			Name = "Frond",
			Size = Vector3.new(1.6, 0.2, 8),
			CFrame = CFrame.lookAt(c, c + dir),
			Color = Color3.fromRGB(60, 150, 70),
			Material = Enum.Material.Grass,
		})
	end
end

local function tree(parent: Instance, rng: Rng.Rng, pos: Vector3)
	local m = Build.model(parent, "Tree")
	local h = rng:range(10, 16)
	Build.part(m, {
		Name = "Trunk",
		Size = Vector3.new(1.6, h, 1.6),
		CFrame = CFrame.new(pos + Vector3.new(0, h / 2, 0)),
		Color = Color3.fromRGB(110, 80, 52),
		Material = Enum.Material.Wood,
	})
	for _ = 1, 3 do
		local s = rng:range(7, 11)
		Build.part(m, {
			Name = "Canopy",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(s, s, s),
			CFrame = CFrame.new(pos + Vector3.new(rng:range(-2.5, 2.5), h + rng:range(-1, 2.5), rng:range(-2.5, 2.5))),
			Color = Color3.fromRGB(70 + rng:int(0, 30), 130 + rng:int(0, 40), 60),
			Material = Enum.Material.Grass,
		})
	end
end

local function windFlags(parent: Instance, f: FieldSpec, wind: Vector3)
	if wind.Magnitude < 0.1 then
		return
	end
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local dir = Vector3.new(wind.X, 0, wind.Z).Unit
	for _, sx in { 1, -1 } do
		for _, sz in { 1, -1 } do
			local base = Vector3.new(sx * (L + 6), 0, sz * (W + 6))
			Build.part(parent, {
				Name = "FlagPole",
				Size = Vector3.new(0.4, 14, 0.4),
				CFrame = CFrame.new(base + Vector3.new(0, 7, 0)),
				Color = Color3.fromRGB(220, 220, 225),
				Material = Enum.Material.Metal,
			})
			local fc = base + Vector3.new(0, 12.6, 0) + dir * 2.2
			local flag = Build.part(parent, {
				Name = "Flag",
				Size = Vector3.new(0.1, 2.4, 4.2),
				CFrame = CFrame.lookAt(fc, fc + dir) * CFrame.Angles(0, math.rad(90), 0),
				Color = Color3.fromRGB(255, 90, 60),
			})
			flag:SetAttribute("Strength", wind.Magnitude)
			CollectionService:AddTag(flag, "UBFlag")
		end
	end
end

local function themeStadium(model: Model, arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	local budget = { n = math.floor(320 * arena.Crowd * dressScale(f)) }
	local color = Color3.fromRGB(58, 62, 74)
	stand(
		props,
		rng,
		Vector3.new(0, 0, W + MARGIN + 2),
		2 * L,
		Vector3.new(0, 0, 1),
		9,
		0.75 * arena.Crowd,
		color,
		budget
	)
	stand(
		props,
		rng,
		Vector3.new(0, 0, -(W + MARGIN + 2)),
		2 * L,
		Vector3.new(0, 0, -1),
		9,
		0.75 * arena.Crowd,
		color,
		budget
	)
	stand(
		props,
		rng,
		Vector3.new(L + MARGIN + 2, 0, 0),
		2 * W + 20,
		Vector3.new(1, 0, 0),
		6,
		0.6 * arena.Crowd,
		color,
		budget
	)
	floodlights(props, f, 1.4, Color3.fromRGB(255, 248, 230))
	scoreboard(props, Vector3.new(-(L + MARGIN + 14), 26, 0), Vector3.new(1, 0, 0))
	if bigField(f) then
		-- above and behind the +X end stand
		scoreboard(props, Vector3.new(L + MARGIN + 30, 34, 0), Vector3.new(-1, 0, 0))
	end
end

local function themeCoastal(model: Model, arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	local budget = { n = math.floor(200 * arena.Crowd) }
	stand(
		props,
		rng,
		Vector3.new(0, 0, -(W + MARGIN + 2)),
		2 * L * 0.7,
		Vector3.new(0, 0, -1),
		5,
		0.7,
		Color3.fromRGB(220, 220, 225),
		budget
	)
	-- the sea beyond the far sideline
	workspace.Terrain:FillBlock(
		CFrame.new(0, -6, W + MARGIN + 160),
		Vector3.new(2 * L + 900, 12, 260),
		Enum.Material.Water
	)
	workspace.Terrain:FillBlock(CFrame.new(0, -9, W + MARGIN + 30), Vector3.new(2 * L + 900, 6, 60), Enum.Material.Sand)
	for x = -L - 40, L + 40, 26 do
		palm(props, rng, Vector3.new(x + rng:range(-6, 6), 0, W + MARGIN + rng:range(8, 20)))
	end
	-- lifeguard tower
	local base = Vector3.new(L + MARGIN + 30, 0, W + MARGIN + 10)
	for _, o in { Vector3.new(-2, 0, -2), Vector3.new(2, 0, -2), Vector3.new(-2, 0, 2), Vector3.new(2, 0, 2) } do
		Build.part(props, {
			Name = "Leg",
			Size = Vector3.new(0.6, 10, 0.6),
			CFrame = CFrame.new(base + o + Vector3.new(0, 5, 0)),
			Color = Color3.fromRGB(240, 240, 240),
		})
	end
	Build.part(props, {
		Name = "Hut",
		Size = Vector3.new(6, 4, 6),
		CFrame = CFrame.new(base + Vector3.new(0, 12, 0)),
		Color = Color3.fromRGB(230, 70, 60),
	})
	scoreboard(props, Vector3.new(-(L + MARGIN + 14), 20, 0), Vector3.new(1, 0, 0))
	if bigField(f) then
		scoreboard(props, Vector3.new(L + MARGIN + 14, 20, 0), Vector3.new(-1, 0, 0))
	end
end

local function themeRooftop(model: Model, arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	-- rooftop edge railing
	for _, sz in { 1, -1 } do
		Build.part(props, {
			Name = "Rail",
			Size = Vector3.new(2 * L + 2 * MARGIN, 0.4, 0.4),
			CFrame = CFrame.new(0, 3.6, sz * (W + MARGIN - 1)),
			Color = arena.LineColor,
			Material = Enum.Material.Neon,
		})
	end
	-- skyline ring
	local neon = {
		Color3.fromRGB(255, 80, 200),
		Color3.fromRGB(90, 230, 255),
		Color3.fromRGB(255, 200, 80),
		Color3.fromRGB(140, 120, 255),
	}
	local ring = dressScale(f)
	for i = 0, 46 do
		local ang = i / 47 * math.pi * 2
		local radius = rng:range(330, 470) * ring
		local pos = Vector3.new(math.cos(ang) * radius * 1.2, 0, math.sin(ang) * radius)
		local h = rng:range(80, 260)
		local w = rng:range(30, 60)
		Build.part(props, {
			Name = "Tower",
			Size = Vector3.new(w, h, w),
			CFrame = CFrame.new(pos + Vector3.new(0, h / 2 - 60, 0)),
			Color = Color3.fromRGB(22, 24, 36),
			Material = Enum.Material.Glass,
		})
		local strip = pick(rng, neon)
		for k = 1, 3 do
			Build.part(props, {
				Name = "Window",
				Size = Vector3.new(w + 0.4, 1.2, w + 0.4),
				CFrame = CFrame.new(pos + Vector3.new(0, -60 + h * (k / 4), 0)),
				Color = strip,
				Material = Enum.Material.Neon,
				Transparency = 0.2,
			})
		end
	end
	-- billboards
	for _, sx in { 1, -1 } do
		local p = Vector3.new(sx * (L + MARGIN + 10), 18, 0)
		local b = Build.part(props, {
			Name = "Billboard",
			Size = Vector3.new(2, 14, 44),
			CFrame = CFrame.new(p),
			Color = Color3.fromRGB(16, 16, 24),
		})
		local gui = Instance.new("SurfaceGui")
		gui.Face = if sx > 0 then Enum.NormalId.Left else Enum.NormalId.Right
		gui.LightInfluence = 0
		gui.Brightness = 3
		gui.Parent = b
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = pick(rng, neon)
		t.Text = "BREAKPOINT"
		t.Parent = gui
	end
	scoreboard(props, Vector3.new(0, 30, -(W + MARGIN + 20)), Vector3.new(0, 0, 1))
	if bigField(f) then
		scoreboard(props, Vector3.new(0, 30, W + MARGIN + 20), Vector3.new(0, 0, -1))
	end
end

local function themeBeach(model: Model, _arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	workspace.Terrain:FillBlock(
		CFrame.new(L + MARGIN + 150, -6, 0),
		Vector3.new(260, 12, 2 * W + 900),
		Enum.Material.Water
	)
	for _ = 1, math.floor(14 * L / BASE_HALF_TOTAL + 0.5) do
		local pos =
			Vector3.new(rng:range(-L, L), 0, (if rng:next() < 0.5 then 1 else -1) * (W + rng:range(22, MARGIN - 4)))
		Build.part(props, {
			Name = "Pole",
			Size = Vector3.new(0.3, 7, 0.3),
			CFrame = CFrame.new(pos + Vector3.new(0, 3.5, 0)),
			Color = Color3.new(1, 1, 1),
		})
		Build.part(props, {
			Name = "Umbrella",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 8, 8),
			CFrame = CFrame.new(pos + Vector3.new(0, 7, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Color = pick(rng, SHIRTS),
		})
	end
	for x = -L, L, 40 do
		palm(props, rng, Vector3.new(x, 0, -(W + MARGIN + 16)))
	end
	scoreboard(props, Vector3.new(-(L + MARGIN + 14), 18, 0), Vector3.new(1, 0, 0))
	if bigField(f) then
		scoreboard(props, Vector3.new(L + MARGIN + 14, 18, 0), Vector3.new(-1, 0, 0))
	end
end

local function themeIndoor(model: Model, arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	local hx, hz, h = L + MARGIN + 30, W + MARGIN + 30, 70
	local wallColor = Color3.fromRGB(30, 34, 42)
	for _, sx in { 1, -1 } do
		Build.part(props, {
			Name = "Wall",
			Size = Vector3.new(2, h, 2 * hz),
			CFrame = CFrame.new(sx * hx, h / 2, 0),
			Color = wallColor,
		})
		Build.part(props, {
			Name = "Wall",
			Size = Vector3.new(2 * hx, h, 2),
			CFrame = CFrame.new(0, h / 2, sx * hz),
			Color = wallColor,
		})
		for k = 1, 4 do
			Build.part(props, {
				Name = "Strip",
				Size = Vector3.new(2 * hx, 0.6, 2.2),
				CFrame = CFrame.new(0, k * 14, sx * (hz - 0.2)),
				Color = Color3.fromRGB(90, 230, 255),
				Material = Enum.Material.Neon,
			})
		end
	end
	Build.part(props, {
		Name = "Roof",
		Size = Vector3.new(2 * hx, 2, 2 * hz),
		CFrame = CFrame.new(0, h, 0),
		Color = wallColor,
		CastShadow = true,
	})
	for x = -L, L, 45 do
		for _, z in { -W * 0.5, W * 0.5 } do
			local panel = Build.part(props, {
				Name = "LightPanel",
				Size = Vector3.new(24, 0.4, 10),
				CFrame = CFrame.new(x, h - 1.4, z),
				Color = Color3.fromRGB(240, 250, 255),
				Material = Enum.Material.Neon,
			})
			Build.light(
				panel,
				"SurfaceLight",
				{ Face = Enum.NormalId.Bottom, Range = 60, Angle = 120, Brightness = 2.2, Shadows = false }
			)
		end
	end
	local budget = { n = math.floor(220 * arena.Crowd * dressScale(f)) }
	stand(
		props,
		rng,
		Vector3.new(0, 0, W + MARGIN + 2),
		2 * L,
		Vector3.new(0, 0, 1),
		6,
		0.6,
		Color3.fromRGB(44, 48, 60),
		budget
	)
	stand(
		props,
		rng,
		Vector3.new(0, 0, -(W + MARGIN + 2)),
		2 * L,
		Vector3.new(0, 0, -1),
		6,
		0.6,
		Color3.fromRGB(44, 48, 60),
		budget
	)
	scoreboard(props, Vector3.new(-(L + MARGIN + 14), 30, 0), Vector3.new(1, 0, 0))
	if bigField(f) then
		scoreboard(props, Vector3.new(L + MARGIN + 14, 30, 0), Vector3.new(-1, 0, 0))
	end
end

local function themePark(model: Model, arena: any, f: FieldSpec, rng: Rng.Rng)
	local L = f.length / 2 + f.endZone
	local W = f.width / 2
	local props = Build.folder(model, "Props")
	for _ = 1, math.floor(34 * L / BASE_HALF_TOTAL + 0.5) do
		local side = if rng:next() < 0.5 then 1 else -1
		local pos = Vector3.new(rng:range(-L - 60, L + 60), 0, side * (W + MARGIN + rng:range(8, 70)))
		tree(props, rng, pos)
	end
	-- playground
	local pg = Vector3.new(L + MARGIN + 40, 0, -20)
	local red, yellow, blue = Color3.fromRGB(230, 60, 60), Color3.fromRGB(250, 210, 60), Color3.fromRGB(40, 120, 230)
	Build.part(
		props,
		{ Name = "Tower", Size = Vector3.new(8, 8, 8), CFrame = CFrame.new(pg + Vector3.new(0, 4, 0)), Color = blue }
	)
	Build.part(
		props,
		{ Name = "Roof", Size = Vector3.new(9, 1, 9), CFrame = CFrame.new(pg + Vector3.new(0, 11, 0)), Color = red }
	)
	Build.part(props, {
		Name = "Slide",
		Size = Vector3.new(3, 0.6, 14),
		CFrame = CFrame.new(pg + Vector3.new(0, 4, 10)) * CFrame.Angles(math.rad(-30), 0, 0),
		Color = yellow,
	})
	local swing = pg + Vector3.new(0, 0, -20)
	for _, o in { -6, 6 } do
		Build.part(props, {
			Name = "SwingLeg",
			Size = Vector3.new(0.6, 12, 0.6),
			CFrame = CFrame.new(swing + Vector3.new(o, 6, 0)),
			Color = red,
		})
	end
	Build.part(props, {
		Name = "SwingBar",
		Size = Vector3.new(13, 0.6, 0.6),
		CFrame = CFrame.new(swing + Vector3.new(0, 12, 0)),
		Color = red,
	})
	for _, o in { -2.5, 2.5 } do
		Build.part(props, {
			Name = "Seat",
			Size = Vector3.new(2, 0.3, 1),
			CFrame = CFrame.new(swing + Vector3.new(o, 3, 0)),
			Color = Color3.fromRGB(40, 40, 40),
		})
	end
	-- park benches and a couple of spectators, behind the team benches
	local budget = { n = math.floor(60 * arena.Crowd * dressScale(f)) + 12 }
	local z = -(W + FieldGeometry.BenchOffset + 12)
	for x = -L + 10, L - 10, 30 do
		Build.part(props, {
			Name = "ParkBench",
			Size = Vector3.new(8, 1.2, 2),
			CFrame = CFrame.new(x, 0.6, z),
			Color = Color3.fromRGB(120, 86, 56),
			Material = Enum.Material.Wood,
		})
		if budget.n > 0 then
			budget.n -= 1
			crowdFigure(props, rng, Vector3.new(x, 1.2, z), Vector3.new(0, 0, 1))
		end
	end
	scoreboard(props, Vector3.new(-(L + MARGIN + 14), 14, 0), Vector3.new(1, 0, 0))
	if bigField(f) then
		scoreboard(props, Vector3.new(L + MARGIN + 14, 14, 0), Vector3.new(-1, 0, 0))
	end
end

-- Team benches on the -Z sideline (every theme). Substitutes stand on the
-- coloured mat in front of the seat (FieldGeometry.benchSpots); returns the
-- centre of each team's spots facing the field.
local function teamBenches(model: Model, f: FieldSpec): { [string]: CFrame }
	local folder = Build.folder(model, "Benches")
	local geo = FieldGeometry.new({
		center = Vector3.zero,
		width = f.width,
		length = f.length,
		endZone = f.endZone,
		brick = f.brick,
	})
	local len = math.max(16, 0.12 * f.length)
	local out: { [string]: CFrame } = {}
	for _, team in { "A", "B" } do
		local sign = if team == "A" then MatchPlan.BenchSign.A else MatchPlan.BenchSign.B
		local cfg = if team == "A" then TeamsConfig.A else TeamsConfig.B
		local c = FieldGeometry.benchCenter(geo, sign)
		local seat = c + Vector3.new(0, 0, -2.6)
		Build.part(folder, {
			Name = "Mat",
			Size = Vector3.new(len, 0.05, 4),
			CFrame = CFrame.new(c.X, 0.03, c.Z),
			Color = cfg.Color,
			Transparency = 0.55,
		})
		Build.part(folder, {
			Name = "Seat",
			Size = Vector3.new(len, 1.2, 1.6),
			CFrame = CFrame.new(seat.X, 0.6, seat.Z),
			Color = cfg.Color,
			solid = true,
		})
		Build.part(folder, {
			Name = "Backrest",
			Size = Vector3.new(len, 2.4, 0.4),
			CFrame = CFrame.new(seat.X, 1.8, seat.Z - 0.9),
			Color = cfg.Dark,
		})
		local sign2 = Build.part(folder, {
			Name = "BenchLabel",
			Size = Vector3.new(math.min(len, 18), 0.05, 2.4),
			CFrame = CFrame.new(c.X, 0.04, c.Z - 0.2),
			Transparency = 1,
		})
		Build.topText(sign2, cfg.Name .. " BENCH", Color3.new(1, 1, 1), 0.35)
		out[team] = CFrame.lookAt(c, c + Vector3.new(0, 0, 1))
	end
	return out
end

local THEMES = {
	Stadium = themeStadium,
	Coastal = themeCoastal,
	Rooftop = themeRooftop,
	Beach = themeBeach,
	Indoor = themeIndoor,
	Park = themePark,
}

---------------------------------------------------------------------------
-- public
---------------------------------------------------------------------------

function ArenaBuilder.build(arena: any, f: FieldSpec, parent: Instance): Built
	local old = parent:FindFirstChild("Arena")
	if old then
		old:Destroy()
	end
	workspace.Terrain:Clear()
	applyLighting(arena)

	local model = Instance.new("Model")
	model.Name = "Arena"
	model:SetAttribute("ArenaId", arena.id)
	local rng = Rng.new(#arena.id * 7919 + 17)
	local endZones = buildField(model, arena, f)
	local theme = (THEMES :: any)[arena.Theme] or themeStadium
	theme(model, arena, f, rng)
	windFlags(model, f, arena.Wind)
	local benches = teamBenches(model, f)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Sideline"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(14, 1, 10)
	spawn.CFrame = CFrame.new(0, 0.5, -(f.width / 2 + 16))
	spawn.Transparency = 0.6
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(90, 230, 255)
	spawn.CanCollide = true
	spawn.Parent = model

	model.Parent = parent
	return { model = model, endZones = endZones, spawn = spawn, margin = MARGIN, benches = benches }
end

ArenaBuilder.Margin = MARGIN

return ArenaBuilder
