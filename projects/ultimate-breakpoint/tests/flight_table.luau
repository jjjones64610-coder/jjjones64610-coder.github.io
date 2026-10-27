-- Prints the throw table used in docs/DESIGN.md §4.1, plus how the ranges fit
-- the fields in Config/Modes.
-- Run from the project root: lune run tests/flight_table.luau
local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local DiscPhysics = H.require("Disc/DiscPhysics")
local ThrowModel = H.require("Disc/ThrowModel")
local Modes = H.require("Config/Modes")

local ROOT = Vector3.new(0, 3, 0)

local function fly(throwType: string, hold: number, pitchDeg: number, bank: number)
	local launch = ThrowModel.launch({
		throwType = throwType,
		yaw = 0,
		pitch = math.rad(pitchDeg),
		holdTime = hold,
		bank = bank,
		height = "Mid",
	}, ROOT, Vector3.zero)
	return launch, DiscPhysics.simulate(launch.state, 12, nil, 0, 6)
end

-- Longest range over camera pitches -12..40 degrees: (range, pitch).
local function best(throwType: string, hold: number, bank: number): (number, number)
	local range, at = 0, 0
	for pitch = -12, 40 do
		local _, r = fly(throwType, hold, pitch, bank)
		if -r.landZ > range then
			range, at = -r.landZ, pitch
		end
	end
	return range, at
end

local cases = {
	{ "Backhand", 0.15, 4, 0 },
	{ "Backhand", 0.35, 4, 0 },
	{ "Backhand", 0.6, 4, 0 },
	{ "Forehand", 0.6, 4, 0 },
	{ "Hammer", 0.6, 0, 0 },
	{ "Scoober", 0.5, 0, 0 },
	{ "Blade", 0.6, 4, 0 },
	{ "Backhand", 0.6, 4, 1 },
	{ "Backhand", 0.6, 4, -1 },
}

print("| Throw | Hold | Bank | Release | Speed | Range | Hang | Apex | Lateral | Best aim |")
print("|---|---|---|---|---|---|---|---|---|---|")
for _, c in cases do
	local launch, r = fly(c[1], c[2], c[3], c[4])
	local bestRange, bestPitch = best(c[1], c[2], c[4])
	print(
		string.format(
			"| %s | %.2f s | %+d | %s | %.0f | %.0f | %.1f s | %.0f | %+.0f | %.0f (%+d°) |",
			c[1],
			c[2],
			c[4],
			launch.quality,
			launch.speed,
			-r.landZ,
			r.landT,
			r.maxHeight,
			r.landX,
			bestRange,
			bestPitch
		)
	)
end

-- Field fit: a full Perfect backhand pulled from one goal line (distances from it).
local _, flat = fly("Backhand", 0.6, 0, 0)
local pull = best("Backhand", 0.6, 0)
print("")
print("| Field | Goal line to far brick | Far goal line | Far back line | Perfect BH, 0° aim / best aim |")
print("|---|---|---|---|---|")
for _, name in { "Mini", "Normal" } do
	local f = Modes.Fields[name]
	print(
		string.format(
			"| %s | %d | %d | %d | %.0f / %.0f |",
			name,
			f.length - f.brick,
			f.length,
			f.length + f.endZone,
			-flat.landZ,
			pull
		)
	)
end
