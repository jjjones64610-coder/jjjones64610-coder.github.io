--!strict
--[[
	TestFieldBuilder — the empty test field for tuning movement (stage 1 of
	docs/CORE_DESIGN.md). A flat, bright grass field with nothing on it but
	reference marks, so speed, turn width and cut quality are easy to read:

	  * a 10-stud grid (faint) and 50-stud lines (bright), so you can see how
	    wide a turn is and how far a skid carries
	  * a row of cones every 10 studs down the middle: run the slalom with
	    planted cuts, then with sloppy yanks, and compare speed in the HUD
	  * a run-up lane: 60 studs to reach full speed before the first cone

	Built once at startup at Arenas.TestFieldOrigin, away from the arena and
	the training hall. Entered from the main menu (TEST FIELD).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Build = require(script.Parent.Build)
local Art = require(ReplicatedStorage:WaitForChild("Shared").Config.Art)

local TestFieldBuilder = {}

export type Layout = {
	model: Model,
	entry: CFrame,
}

local GRASS = Color3.fromRGB(70, 200, 95) -- anime-bright turf
local GRID = Color3.fromRGB(110, 225, 130)
local LINE = Color3.fromRGB(245, 250, 255)
local CONE = Color3.fromRGB(255, 120, 30)

local HALF_W = 150 -- studs either side of the middle (x)
local HALF_L = 200 -- studs either side of the middle (z)

function TestFieldBuilder.build(origin: Vector3, parent: Instance): Layout
	local old = parent:FindFirstChild("TestField")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "TestField"
	local function at(x: number, z: number, y: number?): Vector3
		return origin + Vector3.new(x, y or 0, z)
	end

	local turf = Build.part(model, {
		Name = "Turf",
		Size = Vector3.new(2 * HALF_W, 1, 2 * HALF_L),
		CFrame = CFrame.new(at(0, 0, -0.5)),
		Color = GRASS,
		Material = Enum.Material.SmoothPlastic,
		solid = true,
	})
	-- ForgeGUI tiling grass (Config/Art Turf); plain colour when empty
	local tex = Art.image("Turf")
	if tex then
		local t = Instance.new("Texture")
		t.Texture = tex
		t.Face = Enum.NormalId.Top
		t.StudsPerTileU = 20
		t.StudsPerTileV = 20
		t.Parent = turf
	end
	-- a wide apron so running off the edge never drops you
	Build.part(model, {
		Name = "Apron",
		Size = Vector3.new(2 * HALF_W + 200, 1, 2 * HALF_L + 200),
		CFrame = CFrame.new(at(0, 0, -0.52)),
		Color = Color3.fromRGB(55, 165, 80),
		Material = Enum.Material.SmoothPlastic,
		solid = true,
	})
	for x = -HALF_W, HALF_W, 10 do
		local major = x % 50 == 0
		Build.part(model, {
			Name = "Grid",
			Size = Vector3.new(if major then 0.4 else 0.15, 0.04, 2 * HALF_L),
			CFrame = CFrame.new(at(x, 0, 0.02)),
			Color = if major then LINE else GRID,
		})
	end
	for z = -HALF_L, HALF_L, 10 do
		local major = z % 50 == 0
		Build.part(model, {
			Name = "Grid",
			Size = Vector3.new(2 * HALF_W, 0.04, if major then 0.4 else 0.15),
			CFrame = CFrame.new(at(0, z, 0.02)),
			Color = if major then LINE else GRID,
		})
	end
	-- the slalom: cones every 10 studs down the middle, after a 60-stud run-up
	for i = 0, 12 do
		local z = -HALF_L + 80 + i * 10
		Build.part(model, {
			Name = "Cone",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.6, 1.4, 1.4),
			CFrame = CFrame.new(at(if i % 2 == 0 then -3 else 3, z, 0.8)) * CFrame.Angles(0, 0, math.rad(90)),
			Color = CONE,
			Material = Enum.Material.Neon,
		})
	end
	model.Parent = parent
	local spawnAt = at(0, -HALF_L + 15, 4)
	return {
		model = model,
		entry = CFrame.lookAt(spawnAt, spawnAt + Vector3.new(0, 0, 1)),
	}
end

return TestFieldBuilder
