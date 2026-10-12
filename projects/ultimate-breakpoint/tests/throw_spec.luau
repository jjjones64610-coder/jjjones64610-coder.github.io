local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local ThrowModel = H.require("Disc/ThrowModel")
local Solver = H.require("Disc/Solver")
local DiscPhysics = H.require("Disc/DiscPhysics")
local DiscConfig = H.require("Config/Disc")

local test, expect = H.test, H.expect

print("throwing")

test("charge: partial is Clean, peak window is Perfect, late is Over", function()
	local p1, q1 = ThrowModel.charge(0.2, "Backhand")
	local p2, q2, s2 = ThrowModel.charge(DiscConfig.Throw.ChargeTime + 0.05, "Backhand")
	local p3, q3, s3 = ThrowModel.charge(DiscConfig.Throw.ChargeTime + 0.5, "Backhand")
	expect(q1 == "Clean" and p1 < 1, "partial")
	expect(q2 == "Perfect" and p2 == 1 and s2 > 1, "perfect")
	expect(q3 == "Over" and p3 == 1 and s3 < 1, "over")
end)

test("forehand charges faster than backhand", function()
	local pb = ThrowModel.charge(0.3, "Backhand")
	local pf = ThrowModel.charge(0.3, "Forehand")
	expect(pf > pb, "forehand charge mult")
end)

test("sanitize rejects junk and clamps ranges", function()
	expect(ThrowModel.sanitize(nil) == nil, "nil rejected")
	expect(ThrowModel.sanitize({ throwType = "Laser" }) == nil, "unknown type rejected")
	local p = ThrowModel.sanitize({ throwType = "Hammer", bank = 9, holdTime = 1e9, pitch = 0 / 0, height = "Moon" })
	expect(p ~= nil, "valid type accepted")
	expect(p.bank == 1 and p.holdTime == 5 and p.pitch == 0 and p.height == "Mid", "clamped")
end)

test("off-balance throws are capped", function()
	local base = { throwType = "Backhand", yaw = 0, pitch = 0, holdTime = 0.6, bank = 0, height = "Mid" }
	local normal = ThrowModel.launch(base, Vector3.zero, Vector3.zero)
	base.offBalance = true
	local air = ThrowModel.launch(base, Vector3.zero, Vector3.zero)
	expect(air.speed < normal.speed and air.quality ~= "Perfect", "off-balance cap")
end)

test("low release comes out lower and wider than mid; high release higher", function()
	local root = Vector3.new(0, 3, 0)
	local mid = ThrowModel.releasePosition(
		{ throwType = "Forehand", yaw = 0, pitch = 0, holdTime = 0, bank = 0, height = "Mid" },
		root
	)
	local low = ThrowModel.releasePosition(
		{ throwType = "Forehand", yaw = 0, pitch = 0, holdTime = 0, bank = 0, height = "Low" },
		root
	)
	local high = ThrowModel.releasePosition(
		{ throwType = "Forehand", yaw = 0, pitch = 0, holdTime = 0, bank = 0, height = "High" },
		root
	)
	expect(low.Y < mid.Y and math.abs(low.X) > math.abs(mid.X), "low release")
	expect(high.Y > mid.Y, "high release")
end)

test("left-handed throws mirror right-handed ones", function()
	local base = { throwType = "Backhand", yaw = 0, pitch = 0.05, holdTime = 0.3, bank = 0.2, height = "Mid" }
	local r = DiscPhysics.simulate(ThrowModel.launch(base, Vector3.new(0, 3, 0), Vector3.zero).state)
	base.leftHanded = true
	local l = DiscPhysics.simulate(ThrowModel.launch(base, Vector3.new(0, 3, 0), Vector3.zero).state)
	expect(
		math.abs(r.landX + l.landX) < 0.05 and math.abs(r.landZ - l.landZ) < 0.05,
		string.format("mirror %.3f vs %.3f", r.landX, l.landX)
	)
end)

test("solver hits a stationary receiver", function()
	local target = Vector3.new(20, 4, -70)
	local sol = Solver.solve({ rootPos = Vector3.new(0, 3, 0), throwType = "Backhand", target = target })
	expect(sol ~= nil, "solution found")
	expect(sol.miss < 2.0, "miss " .. sol.miss)
end)

test("solver leads a moving receiver", function()
	local start = Vector3.new(-10, 4, -40)
	local vel = Vector3.new(0, 0, -24)
	local sol =
		Solver.solve({ rootPos = Vector3.new(0, 3, 0), throwType = "Forehand", target = start, targetVel = vel })
	expect(sol ~= nil, "solution found")
	local launch = ThrowModel.launch(sol.params, Vector3.new(0, 3, 0), Vector3.zero)
	local s = launch.state
	local best = math.huge
	while s.t < 6 and s.py > 0.2 do
		DiscPhysics.step(s, DiscConfig.Physics.Dt)
		local rx, rz = start.X + vel.X * s.t, start.Z + vel.Z * s.t
		local d = math.sqrt((s.px - rx) ^ 2 + (s.py - start.Y) ^ 2 + (s.pz - rz) ^ 2)
		best = math.min(best, d)
	end
	expect(best < 2.5, "lead pass miss " .. best)
end)

test("coarse solver (client assist) is still close", function()
	local sol = Solver.solve({
		rootPos = Vector3.new(0, 3, 0),
		throwType = "Backhand",
		target = Vector3.new(-25, 4, -90),
		coarse = true,
	})
	expect(sol ~= nil and sol.miss < 3.5, "coarse miss " .. (sol and sol.miss or -1))
end)

test("integration: solver lead passes enter a moving receiver's catch zone", function()
	local CatchGeometry = H.require("Rules/CatchGeometry")
	local cases = {
		{ type = "Backhand", start = Vector3.new(-8, 3, -45), vel = Vector3.new(0, 0, -22) },
		{ type = "Forehand", start = Vector3.new(15, 3, -60), vel = Vector3.new(14, 0, -14) },
		{ type = "Backhand", start = Vector3.new(5, 3, -70), vel = Vector3.new(0, 0, -20) },
		{ type = "Hammer", start = Vector3.new(-20, 3, -55), vel = Vector3.new(0, 0, -8) },
	}
	for _, c in cases do
		local sol = Solver.solve({
			rootPos = Vector3.new(0, 3, 0),
			throwType = c.type,
			target = c.start + Vector3.new(0, 1, 0),
			targetVel = c.vel,
		})
		expect(sol ~= nil, c.type .. " solved")
		local s = ThrowModel.launch(sol.params, Vector3.new(0, 3, 0), Vector3.zero).state
		local caught = false
		while s.t < 6 and s.py > 0.2 and not caught do
			DiscPhysics.step(s, DiscConfig.Physics.Dt)
			local root = c.start + c.vel * s.t
			local zones = CatchGeometry.zones({
				root = root,
				facing = Vector3.new(0, 0, 1),
				reaching = true,
				reachDir = (Vector3.new(s.px, s.py, s.pz) - root).Unit,
				diving = false,
				sliding = false,
			})
			if CatchGeometry.evaluate(zones, Vector3.new(s.px, s.py, s.pz)) then
				caught = true
			end
		end
		expect(caught, c.type .. " lead pass was not catchable")
	end
end)

return nil
