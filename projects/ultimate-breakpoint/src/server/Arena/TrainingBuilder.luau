--!strict
--[[
	TrainingBuilder — the Training Grounds hall (built once at startup).

	All positions are relative to Arenas.TrainingOrigin. Layout (top view,
	+Z = north):

	  z 150..230  Interception Drill (W)        | Throwing Range targets (E)
	  z   0..140  Aerial Catch (W) | Combo Lab  | Throwing Range lane (E)
	  z -130..-10 Movement School  | Cutting    | Momentum Shuttle
	              (W)              | Course (C) | (E)
]]

local CollectionService = game:GetService("CollectionService")

local Build = require(script.Parent.Build)

local TrainingBuilder = {}

export type Station = {
	id: string,
	title: string,
	subtitle: string,
	terminal: Vector3,
	start: Vector3,
	facing: Vector3,
}

export type Layout = {
	model: Model,
	origin: Vector3,
	entry: CFrame,
	stations: { [string]: Station },
	gates: { { a: Vector3, b: Vector3 } },
	shuttleA: number, -- world z of shuttle line A
	shuttleB: number,
	shuttleX: { number },
	launcher: Vector3,
	catchMark: Vector3,
	throwMark: Vector3,
	targets: { { pos: Vector3, radius: number, points: number, name: string } },
	mover: { center: Vector3, amplitude: number, period: number, radius: number, points: number },
	interception: { thrower: Vector3, receiverStart: Vector3, playerStart: Vector3 },
	prompts: { [string]: ProximityPrompt },
}

local FLOOR = Color3.fromRGB(40, 46, 58)
local LINE = Color3.fromRGB(90, 230, 255)
local CONE = Color3.fromRGB(255, 110, 20)

local function cone(parent: Instance, pos: Vector3, color: Color3?)
	Build.part(parent, {
		Name = "Cone",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.4, 1.4, 1.4),
		CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color or CONE,
		Material = Enum.Material.Neon,
	})
end

local function terminal(parent: Instance, pos: Vector3, title: string, subtitle: string, id: string): ProximityPrompt
	local base = Build.part(parent, {
		Name = "Terminal_" .. id,
		Size = Vector3.new(4, 4, 2),
		CFrame = CFrame.new(pos + Vector3.new(0, 2, 0)),
		Color = Color3.fromRGB(24, 28, 36),
		solid = true,
	})
	Build.part(parent, {
		Name = "TerminalGlow",
		Size = Vector3.new(4.2, 0.3, 2.2),
		CFrame = CFrame.new(pos + Vector3.new(0, 4.1, 0)),
		Color = LINE,
		Material = Enum.Material.Neon,
	})
	Build.sign(base, title, subtitle, LINE)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Start"
	prompt.ObjectText = title
	prompt.KeyboardKeyCode = Enum.KeyCode.G
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Drill", id)
	prompt.Parent = base
	return prompt
end

function TrainingBuilder.build(origin: Vector3, parent: Instance): Layout
	local old = parent:FindFirstChild("TrainingGrounds")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "TrainingGrounds"
	local function at(x: number, z: number, y: number?): Vector3
		return origin + Vector3.new(x, y or 0, z)
	end

	-- hall
	local W, Z0, Z1, H = 170, -140, 240, 64
	Build.part(model, {
		Name = "Floor",
		Size = Vector3.new(2 * W, 1, Z1 - Z0),
		CFrame = CFrame.new(at(0, (Z0 + Z1) / 2, -0.5)),
		Color = FLOOR,
		Material = Enum.Material.SmoothPlastic,
		solid = true,
	})
	-- floor grid
	for x = -W + 20, W - 20, 20 do
		Build.part(model, { Name = "Grid", Size = Vector3.new(0.2, 0.04, Z1 - Z0), CFrame = CFrame.new(at(x, (Z0 + Z1) / 2, 0.02)), Color = Color3.fromRGB(60, 70, 88) })
	end
	for z = Z0 + 20, Z1 - 20, 20 do
		Build.part(model, { Name = "Grid", Size = Vector3.new(2 * W, 0.04, 0.2), CFrame = CFrame.new(at(0, z, 0.02)), Color = Color3.fromRGB(60, 70, 88) })
	end
	local wallColor = Color3.fromRGB(28, 32, 42)
	Build.part(model, { Name = "Wall", Size = Vector3.new(2, H, Z1 - Z0), CFrame = CFrame.new(at(-W, (Z0 + Z1) / 2, H / 2)), Color = wallColor, solid = true })
	Build.part(model, { Name = "Wall", Size = Vector3.new(2, H, Z1 - Z0), CFrame = CFrame.new(at(W, (Z0 + Z1) / 2, H / 2)), Color = wallColor, solid = true })
	Build.part(model, { Name = "Wall", Size = Vector3.new(2 * W, H, 2), CFrame = CFrame.new(at(0, Z0, H / 2)), Color = wallColor, solid = true })
	Build.part(model, { Name = "Wall", Size = Vector3.new(2 * W, H, 2), CFrame = CFrame.new(at(0, Z1, H / 2)), Color = wallColor, solid = true })
	Build.part(model, { Name = "Roof", Size = Vector3.new(2 * W, 2, Z1 - Z0), CFrame = CFrame.new(at(0, (Z0 + Z1) / 2, H + 1)), Color = wallColor, solid = true })
	for x = -W + 40, W - 40, 60 do
		for z = Z0 + 40, Z1 - 40, 60 do
			local panel = Build.part(model, {
				Name = "LightPanel",
				Size = Vector3.new(26, 0.4, 12),
				CFrame = CFrame.new(at(x, z, H - 1)),
				Color = Color3.fromRGB(235, 245, 255),
				Material = Enum.Material.Neon,
			})
			Build.light(panel, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 60, Angle = 120, Brightness = 2.5, Shadows = false })
		end
	end
	for _, z in { Z0 + 0.8, Z1 - 0.8 } do
		Build.part(model, { Name = "Strip", Size = Vector3.new(2 * W, 0.8, 0.4), CFrame = CFrame.new(at(0, z, 10)), Color = LINE, Material = Enum.Material.Neon })
	end

	local entry = CFrame.lookAt(at(0, -125, 3.5), at(0, 0, 3.5))
	local entryPad = Build.part(model, {
		Name = "EntryPad",
		Size = Vector3.new(14, 0.4, 10),
		CFrame = CFrame.new(at(0, -125, 0.2)),
		Color = LINE,
		Material = Enum.Material.Neon,
		Transparency = 0.5,
	})
	Build.sign(entryPad, "TRAINING GROUNDS", "Walk up to a terminal and press G to start a drill", LINE)

	local stations: { [string]: Station } = {}
	local prompts: { [string]: ProximityPrompt } = {}
	local function station(id: string, title: string, subtitle: string, term: Vector3, start: Vector3, facing: Vector3)
		stations[id] = { id = id, title = title, subtitle = subtitle, terminal = term, start = start, facing = facing }
		prompts[id] = terminal(model, term, title, subtitle, id)
	end

	-- Movement School
	station("Tutorial", "MOVEMENT SCHOOL", "Learn every technique, step by step", at(-120, -118), at(-110, -90), Vector3.new(0, 0, 1))
	-- Cutting course: zig-zag gates
	local gates = {}
	local courseFolder = Build.folder(model, "CuttingCourse")
	local gx = { 0, -18, 14, -10, 20, -20, 8, 0 }
	for i, x in gx do
		local z = -112 + (i - 1) * 13
		local a, b = at(x - 3.2, z), at(x + 3.2, z)
		cone(courseFolder, a, if i == 1 or i == #gx then Color3.fromRGB(80, 255, 140) else nil)
		cone(courseFolder, b, if i == 1 or i == #gx then Color3.fromRGB(80, 255, 140) else nil)
		table.insert(gates, { a = a, b = b })
	end
	station("Cutting", "CUTTING COURSE", "Slalom through every gate. Keep your speed.", at(-30, -126), at(0, -124), Vector3.new(0, 0, 1))

	-- Momentum shuttle
	local shuttleFolder = Build.folder(model, "Shuttle")
	local zA, zB = -118, -82
	for _, z in { zA, zB } do
		Build.part(shuttleFolder, {
			Name = "ShuttleLine",
			Size = Vector3.new(56, 0.06, 0.8),
			CFrame = CFrame.new(at(110, z, 0.04)),
			Color = if z == zA then Color3.fromRGB(80, 255, 140) else Color3.fromRGB(255, 200, 60),
			Material = Enum.Material.Neon,
		})
	end
	station("Shuttle", "MOMENTUM SHUTTLE", "A-B-A-B-A. Reverse fast without losing it.", at(146, -126), at(110, -126), Vector3.new(0, 0, 1))

	-- Aerial catch: launcher at the north end of the west side
	local launcher = at(-100, 128, 4)
	Build.part(model, { Name = "LauncherBase", Size = Vector3.new(6, 6, 6), CFrame = CFrame.new(launcher - Vector3.new(0, 1, 0)), Color = Color3.fromRGB(50, 56, 70), solid = true })
	Build.part(model, {
		Name = "LauncherBarrel",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 2.4, 2.4),
		CFrame = CFrame.lookAt(launcher + Vector3.new(0, 2, 0), at(-100, 40, 4)) * CFrame.Angles(0, math.rad(90), 0),
		Color = LINE,
		Material = Enum.Material.Neon,
	})
	local catchMark = at(-100, 40)
	Build.part(model, {
		Name = "CatchMark",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.1, 6, 6),
		CFrame = CFrame.new(catchMark + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 200, 60),
		Material = Enum.Material.Neon,
	})
	station("Aerial", "AERIAL CATCH", "10 launches: floaters, skimmers, layouts", at(-150, 20), catchMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))
	station("Launcher", "FREE LAUNCHER", "Custom launches (opens the launcher panel)", at(-150, 60), catchMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))

	-- Throwing range (east): throw north from the mark
	local throwMark = at(70, 20)
	Build.part(model, {
		Name = "ThrowMark",
		Size = Vector3.new(6, 0.08, 6),
		CFrame = CFrame.new(throwMark + Vector3.new(0, 0.05, 0)),
		Color = Color3.fromRGB(80, 255, 140),
		Material = Enum.Material.Neon,
		Transparency = 0.3,
	})
	local targets = {}
	local function target(name: string, x: number, z: number, y: number, radius: number, points: number)
		local pos = at(x, z, y)
		local ring = Build.part(model, {
			Name = "Target_" .. name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, radius * 2, radius * 2),
			CFrame = CFrame.lookAt(pos, throwMark + Vector3.new(0, y, 0)) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(255, 80, 120),
			Material = Enum.Material.Neon,
			Transparency = 0.55,
		})
		Build.part(model, { Name = "TargetPole", Size = Vector3.new(0.4, y - radius, 0.4), CFrame = CFrame.new(at(x, z, (y - radius) / 2)), Color = Color3.fromRGB(200, 200, 210) })
		Build.sign(ring, name, points .. " pts", Color3.fromRGB(255, 80, 120))
		CollectionService:AddTag(ring, "UBTarget")
		table.insert(targets, { pos = pos, radius = radius, points = points, name = name })
	end
	target("40", 62, 60, 5, 4.5, 100)
	target("70", 88, 90, 6, 4, 150)
	target("100", 52, 120, 7, 4, 200)
	target("140", 80, 160, 8, 4.5, 300)
	local moverCenter = at(70, 200, 6)
	local mover = { center = moverCenter, amplitude = 38, period = 7, radius = 4.5, points = 250 }
	local moverPart = Build.part(model, {
		Name = "MovingTarget",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 9, 9),
		CFrame = CFrame.lookAt(moverCenter, throwMark + Vector3.new(0, 6, 0)) * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.fromRGB(255, 200, 60),
		Material = Enum.Material.Neon,
		Transparency = 0.45,
	})
	moverPart:SetAttribute("Amplitude", mover.amplitude)
	moverPart:SetAttribute("Period", mover.period)
	moverPart:SetAttribute("Center", moverCenter)
	CollectionService:AddTag(moverPart, "UBMover")
	Build.part(model, { Name = "Rail", Size = Vector3.new(mover.amplitude * 2 + 10, 0.4, 0.6), CFrame = CFrame.new(moverCenter - Vector3.new(0, 5, 0)), Color = Color3.fromRGB(90, 96, 110) })
	station("Range", "THROWING RANGE", "10 throws at the rings (and the mover)", at(100, 8), throwMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))

	-- Interception drill (north-west)
	local interception = {
		thrower = at(-140, 160, 3),
		receiverStart = at(-70, 160, 3),
		playerStart = at(-100, 175, 3),
	}
	Build.part(model, {
		Name = "DrillZone",
		Size = Vector3.new(110, 0.05, 80),
		CFrame = CFrame.new(at(-100, 190, 0.03)),
		Color = Color3.fromRGB(255, 120, 30),
		Material = Enum.Material.Neon,
		Transparency = 0.9,
	})
	station("Interception", "INTERCEPTION DRILL", "Read the throw. Get the D.", at(-150, 145), interception.playerStart, Vector3.new(0, 0, 1))

	-- Combo lab with rebound walls
	local lab = Build.folder(model, "ComboLab")
	for i, x in { -26, -6 } do
		local wall = Build.part(lab, {
			Name = "LabRebound" .. i,
			Size = Vector3.new(1, 16, 40),
			CFrame = CFrame.new(at(x, 70, 8)),
			Color = Color3.fromRGB(255, 90, 200),
			Material = Enum.Material.Neon,
			Transparency = 0.5,
			solid = true,
		})
		CollectionService:AddTag(wall, "Rebound")
	end
	station("Combo", "COMBO LAB", "Chain challenges. Rebound walls inside.", at(-16, 10), at(-16, 30, 3), Vector3.new(0, 0, 1))

	model.Parent = parent
	return {
		model = model,
		origin = origin,
		entry = entry,
		stations = stations,
		gates = gates,
		shuttleA = origin.Z + zA,
		shuttleB = origin.Z + zB,
		shuttleX = { origin.X + 82, origin.X + 138 },
		launcher = launcher + Vector3.new(0, 2, 0),
		catchMark = catchMark,
		throwMark = throwMark,
		targets = targets,
		mover = mover,
		interception = interception,
		prompts = prompts,
	}
end

-- Moving target position at server time t (clients use the same formula).
function TrainingBuilder.moverPosition(center: Vector3, amplitude: number, period: number, t: number): Vector3
	return center + Vector3.new(math.sin(t * 2 * math.pi / period) * amplitude, 0, 0)
end

return TrainingBuilder
