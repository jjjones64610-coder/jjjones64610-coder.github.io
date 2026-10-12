-- Prints the throw table used in docs/DESIGN.md §4.1.
-- Run from the project root: lune run tests/flight_table.luau
local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local DiscPhysics = H.require("Disc/DiscPhysics")
local ThrowModel = H.require("Disc/ThrowModel")

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

print("| Throw | Hold | Bank | Release | Speed | Range | Hang | Apex | Lateral |")
print("|---|---|---|---|---|---|---|---|---|")
for _, c in cases do
	local launch = ThrowModel.launch({
		throwType = c[1],
		yaw = 0,
		pitch = math.rad(c[3]),
		holdTime = c[2],
		bank = c[4],
		height = "Mid",
	}, Vector3.new(0, 3, 0), Vector3.zero)
	local r = DiscPhysics.simulate(launch.state, 10, nil, 0, 6)
	print(
		string.format(
			"| %s | %.2f s | %+d | %s | %.0f | %.0f | %.1f s | %.0f | %+.0f |",
			c[1],
			c[2],
			c[4],
			launch.quality,
			launch.speed,
			-r.landZ,
			r.landT,
			r.maxHeight,
			r.landX
		)
	)
end
