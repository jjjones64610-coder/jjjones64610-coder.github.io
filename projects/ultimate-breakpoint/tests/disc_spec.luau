local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local DiscPhysics = H.require("Disc/DiscPhysics")
local ThrowModel = H.require("Disc/ThrowModel")
local DiscConfig = H.require("Config/Disc")
local Modes = H.require("Config/Modes")

local test, expect = H.test, H.expect

local ROOT = Vector3.new(0, 3, 0)
local FULL = DiscConfig.Throw.ChargeTime + DiscConfig.Throw.PerfectWindow * 0.5 -- a Perfect full charge

local function fly(throwType, hold, pitchDeg, bank, wind)
	local launch = ThrowModel.launch({
		throwType = throwType,
		yaw = 0, -- forward is -Z, right is +X
		pitch = math.rad(pitchDeg or 0),
		holdTime = hold,
		bank = bank or 0,
		height = "Mid",
	}, ROOT, Vector3.zero)
	local r = DiscPhysics.simulate(launch.state, 12, wind, 0, 6)
	r.distance = -r.landZ
	r.lateral = r.landX
	r.launch = launch
	return r
end

-- Longest flat-ground range over camera pitches (the best a thrower can aim).
local function bestRange(throwType, hold)
	local best = 0
	for pitch = -12, 40, 1 do
		best = math.max(best, fly(throwType, hold, pitch).distance)
	end
	return best
end

print("disc physics")

test("simulation is deterministic", function()
	local a = fly("Backhand", 0.4, 5, 0.3)
	local b = fly("Backhand", 0.4, 5, 0.3)
	expect(a.landX == b.landX and a.landZ == b.landZ and a.landT == b.landT, "identical inputs gave different flights")
end)

test("power increases range monotonically (flat backhand)", function()
	local last = 0
	for _, hold in { 0.05, 0.15, 0.25, 0.35, 0.45, 0.55 } do
		local r = fly("Backhand", hold, 0)
		expect(r.distance > last, string.format("hold %.2f range %.1f <= %.1f", hold, r.distance, last))
		last = r.distance
	end
end)

test("field fit (Normal): a full Perfect pull from the goal line lands around the receivers' brick", function()
	local f = Modes.Fields.Normal
	local toBrick = f.length - f.brick -- pull from one goal line toward the far brick
	local flat = fly("Backhand", FULL, 0).distance
	local best = bestRange("Backhand", FULL)
	expect(
		math.abs(flat - toBrick) < 0.1 * f.length and math.abs(best - toBrick) < 0.1 * f.length,
		string.format("flat %.0f / best %.0f vs brick at %.0f", flat, best, toBrick)
	)
	expect(best < f.length + f.endZone, "the pull stays in the field: " .. best)
	expect(best > f.length / 2, "a full throw crosses midfield")
end)

test("field fit (Mini): a full pull reaches the end zone but stays in bounds", function()
	local f = Modes.Fields.Mini
	local best = bestRange("Backhand", FULL)
	expect(best > f.length and best < f.length + f.endZone, string.format("best %.0f on a %d field", best, f.length))
end)

test("light touches stay short: power spans dumps to hucks", function()
	local full = fly("Backhand", FULL, 0).distance
	local touch = fly("Backhand", 0.1, 0).distance
	local dump = fly("Backhand", 0, 0).distance
	expect(touch < full * 0.35, string.format("0.1 s touch %.0f vs full %.0f", touch, full))
	expect(dump < full * 0.2, "a no-charge flick is a short dump: " .. dump)
	expect(dump < touch and touch < full, "ordered")
end)

test("full-power flat backhand holds a fairly straight line (a slight S-curve)", function()
	local r = fly("Backhand", FULL, 0)
	local right = fly("Backhand", FULL, 0, 1)
	local left = fly("Backhand", FULL, 0, -1)
	expect(math.abs(r.lateral) < r.distance * 0.1, string.format("lateral %.1f over %.1f", r.lateral, r.distance))
	expect(
		math.abs(r.lateral) < 0.6 * math.min(math.abs(right.lateral), math.abs(left.lateral)),
		"flat drifts much less than a banked curve"
	)
end)

test("touch backhand fades left, touch forehand fades right (right-handed)", function()
	local bh = fly("Backhand", 0.2, 3)
	local fh = fly("Forehand", 0.2, 3)
	expect(bh.lateral < -1, "backhand lateral " .. bh.lateral)
	expect(fh.lateral > 1, "forehand lateral " .. fh.lateral)
end)

test("bank steers the curve both ways", function()
	local right = fly("Backhand", 0.6, 0, 1)
	local left = fly("Backhand", 0.6, 0, -1)
	expect(right.lateral > 20, "right bank lateral " .. right.lateral)
	expect(left.lateral < -20, "left bank lateral " .. left.lateral)
end)

test("hammer inverts in flight and still travels", function()
	local r = fly("Hammer", 0.6, 0)
	expect(r.final.ny < -0.5, "hammer final normal y " .. r.final.ny)
	expect(r.distance > 70, "hammer range " .. r.distance)
	expect(r.maxHeight > 12, "hammer arcs high: " .. r.maxHeight)
end)

test("scoober is a short inverted flip that breaks right", function()
	local s = fly("Scoober", 0.5, 0)
	local h = fly("Hammer", 0.5, 0)
	expect(s.distance < h.distance, "scoober shorter than hammer")
	expect(s.final.ny < 0, "scoober inverted")
	expect(s.lateral > 0, "scoober breaks right: " .. s.lateral)
end)

test("blade is fast and short-lived compared with a floaty backhand", function()
	local blade = fly("Blade", 0.6, 4)
	local bh = fly("Backhand", 0.6, 4)
	expect(blade.landT < bh.landT * 0.6, string.format("blade %.2fs vs backhand %.2fs", blade.landT, bh.landT))
	expect(blade.distance > 60, "blade range " .. blade.distance)
end)

test("an overcharged (low-spin) release rolls more than a perfect one", function()
	local perfect = fly("Backhand", 0.6, 0)
	local over = fly("Backhand", 1.4, 0)
	expect(perfect.launch.quality == "Perfect", "perfect window")
	expect(over.launch.quality == "Over", "overcharged")
	local rollP = 1 - perfect.final.ny
	local rollO = 1 - over.final.ny
	expect(rollO > rollP * 1.5, string.format("roll perfect %.3f over %.3f", rollP, rollO))
end)

test("crosswind pushes the disc downwind, consistently", function()
	local calm = fly("Backhand", 0.4, 4)
	local windy = fly("Backhand", 0.4, 4, 0, { x = 8, y = 0, z = 0 })
	expect(windy.lateral > calm.lateral + 3, string.format("calm %.1f windy %.1f", calm.lateral, windy.lateral))
	local again = fly("Backhand", 0.4, 4, 0, { x = 8, y = 0, z = 0 })
	expect(again.landX == windy.landX, "wind is deterministic")
end)

test("advanceTo stops at the interpolated contact point, like simulate()", function()
	local launch = ThrowModel.launch(
		{ throwType = "Backhand", yaw = -0.4, pitch = 0.1, holdTime = 0.3, bank = 0.3, height = "Mid" },
		ROOT,
		Vector3.zero
	)
	local r = DiscPhysics.simulate(launch.state, 12, nil, 0)
	local s = DiscPhysics.copy(launch.state)
	local alive = DiscPhysics.advanceTo(s, 12, nil, 0)
	expect(not alive, "landed")
	H.near(s.px, r.landX, 1e-9, "landing x")
	H.near(s.pz, r.landZ, 1e-9, "landing z")
	H.near(s.t, r.landT, 1e-9, "landing time")
	H.near(s.py, DiscConfig.Physics.GroundContact, 1e-9, "on the ground")
end)

test("advanceTo matches manual fixed stepping", function()
	local launch = ThrowModel.launch(
		{ throwType = "Forehand", yaw = 0.3, pitch = 0.05, holdTime = 0.4, bank = -0.4, height = "Mid" },
		ROOT,
		Vector3.zero
	)
	local a = DiscPhysics.copy(launch.state)
	DiscPhysics.advanceTo(a, 1.0, nil, -1000)
	local b = DiscPhysics.copy(launch.state)
	for _ = 1, 120 do
		DiscPhysics.step(b, 1 / 120)
	end
	expect(a.px == b.px and a.py == b.py and a.pz == b.pz, "advanceTo diverged from fixed stepping")
end)

return nil
