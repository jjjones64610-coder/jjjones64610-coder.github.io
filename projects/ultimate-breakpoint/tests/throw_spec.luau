local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local ThrowModel = H.require("Disc/ThrowModel")
local Solver = H.require("Disc/Solver")
local DiscPhysics = H.require("Disc/DiscPhysics")
local DiscConfig = H.require("Config/Disc")
local MovementConfig = H.require("Config/Movement")

local test, expect = H.test, H.expect
local T = DiscConfig.Throw
local HD = MovementConfig.Holding
local R = HD.StepRadius

print("throwing")

local P = Vector3.new(0, 3, 0) -- pivot foot (root height); yaw 0 aims -Z, right is +X

local function params(extra)
	local p = { throwType = "Backhand", yaw = 0, pitch = 0, holdTime = 0.4, bank = 0, height = "Mid" }
	for k, v in extra or {} do
		p[k] = v
	end
	return p
end

-- Release offset from P in the throw frame: (lateral, up, forward).
local function offsetFromPivot(p, root)
	local rel = ThrowModel.releasePosition(p, root or P) - P
	local forward, right = ThrowModel.basis(p.yaw)
	return rel:Dot(right), rel.Y, rel:Dot(forward)
end

local function sideOf(throwType)
	return ThrowModel.typeInfo(throwType).Side
end

test("charge: partial is Clean, peak window is Perfect, late is Over", function()
	local p1, q1 = ThrowModel.charge(0.2, "Backhand")
	local p2, q2, s2 = ThrowModel.charge(T.ChargeTime + 0.05, "Backhand")
	local p3, q3, s3 = ThrowModel.charge(T.ChargeTime + 0.5, "Backhand")
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
	local p = ThrowModel.sanitize({
		throwType = "Hammer",
		bank = 9,
		holdTime = 1e9,
		pitch = 0 / 0,
		height = "Moon",
		pivot = Vector3.new(0 / 0, 0, 0),
		swinging = "yes",
		releaseT = math.huge,
		rootPos = "here",
	})
	expect(p ~= nil, "valid type accepted")
	expect(p.bank == 1 and p.holdTime == 5 and p.pitch == 0 and p.height == "Mid", "clamped")
	expect(p.pivot == nil and p.swinging == false, "junk pivot / flag dropped")
	expect(p.releaseT == nil and p.rootPos == nil, "junk transport fields dropped")
	expect(p.step == Vector3.zero, "no step = squared up")
	local ok = ThrowModel.sanitize({
		throwType = "Forehand",
		pivot = P,
		step = Vector3.new(1, 0, 0),
		swinging = true,
		releaseT = 12.5,
		rootPos = P,
	})
	expect(ok.pivot == P and ok.step == Vector3.new(1, 0, 0) and ok.swinging, "legal pivot fields kept")
	expect(ok.releaseT == 12.5 and ok.rootPos == P, "transport fields kept")
end)

test("sanitize clamps hostile steps into the pivot's reach", function()
	local function check(step, yaw)
		local p = ThrowModel.sanitize({ throwType = "Backhand", yaw = yaw or 0, step = step })
		local s = p.step
		local forward = ThrowModel.basis(p.yaw)
		expect(s.Y == 0, "step is flat")
		expect(s.Magnitude <= R + 1e-6, "step within R: " .. s.Magnitude)
		expect(s:Dot(forward) <= HD.ForwardMax * R + 1e-6, "forward part capped")
		expect(s:Dot(forward) >= -HD.BackMax * R - 1e-6, "back part capped")
		return s
	end
	local big = check(Vector3.new(100, 50, 0))
	H.near(big.Magnitude, R, 1e-6, "a huge sideways step is a full step")
	local lunge = check(Vector3.new(0, 0, -100))
	H.near(lunge.Magnitude, HD.ForwardMax * R, 1e-6, "a huge lunge stops at the forward cap")
	local drop = check(Vector3.new(0, 0, 100))
	H.near(drop.Magnitude, HD.BackMax * R, 1e-6, "a huge drop step stops at the back cap")
	-- the forward cap is in the throw frame: aiming +X, a +X step is a lunge
	local turned = check(Vector3.new(100, 0, 0), -math.pi / 2)
	H.near(turned.Magnitude, HD.ForwardMax * R, 1e-6, "the cap follows the aim")
	for _, junk in { Vector3.new(0 / 0, 0, 1), Vector3.new(math.huge, 0, 0), "left", 7, true } do
		expect(check(junk) == Vector3.zero, "junk step -> squared up")
	end
	local legal = check(Vector3.new(-1.2, 0, 0.5))
	expect((legal - Vector3.new(-1.2, 0, 0.5)).Magnitude < 1e-6, "a legal step is untouched")
end)

test("off-balance throws are capped", function()
	local base = params({ holdTime = 0.6 })
	local normal = ThrowModel.launch(base, Vector3.zero, Vector3.zero)
	base.offBalance = true
	local air = ThrowModel.launch(base, Vector3.zero, Vector3.zero)
	expect(air.speed < normal.speed and air.quality ~= "Perfect", "off-balance cap")
end)

test("without a pivot: low release comes out lower and wider than mid; high release higher", function()
	local root = Vector3.new(0, 3, 0)
	local mid = ThrowModel.releasePosition(params({ throwType = "Forehand" }), root)
	local low = ThrowModel.releasePosition(params({ throwType = "Forehand", height = "Low" }), root)
	local high = ThrowModel.releasePosition(params({ throwType = "Forehand", height = "High" }), root)
	expect(low.Y < mid.Y and math.abs(low.X) > math.abs(mid.X), "low release")
	expect(high.Y > mid.Y, "high release")
end)

test("pivot release: P + step + side offset, squared up and at full step-out", function()
	for _, throwType in { "Backhand", "Forehand" } do
		local side = sideOf(throwType)
		local out = if side >= 0 then 1 else -1 -- the throw's own side
		local lat0, up0, fwd0 = offsetFromPivot(params({ throwType = throwType, pivot = P }))
		H.near(lat0, side * T.PivotSideScale, 1e-6, throwType .. " squared-up lateral")
		H.near(up0, DiscConfig.Heights.Mid, 1e-6, throwType .. " mid height")
		H.near(fwd0, T.ReleaseForward, 1e-6, throwType .. " in front of the body")
		local step = Vector3.new(out * R, 0, 0)
		local latS = offsetFromPivot(params({ throwType = throwType, pivot = P, step = step }))
		H.near(latS, out * R + side * T.PivotSideScale, 1e-6, throwType .. " full step-out")
		local latL, upL = offsetFromPivot(params({ throwType = throwType, pivot = P, step = step, height = "Low" }))
		H.near(latL - latS, out * T.LowReach, 1e-6, throwType .. " low extends further out")
		expect(upL < up0, throwType .. " low is lower")
		expect(math.abs(latL) > math.abs(latS) and math.abs(latS) > math.abs(lat0), throwType .. " reach grows")
	end
end)

test("pivot release depends on P and the step, not on where the root drifted", function()
	local p = params({ throwType = "Forehand", pivot = P, step = Vector3.new(2, 0, 0) })
	local a = ThrowModel.releasePosition(p, P + Vector3.new(2 * HD.BodyShare, 0, 0))
	local b = ThrowModel.releasePosition(p, P + Vector3.new(-1.5, 0, 0.7)) -- lagged / wrong root
	expect((a - b).Magnitude < 1e-6, "same release")
	-- hostile step inside params is still clamped by releasePosition
	local wild = ThrowModel.releasePosition(params({ pivot = P, step = Vector3.new(-90, 0, 0) }), P)
	H.near(wild.X - P.X, -R + sideOf("Backhand") * T.PivotSideScale, 1e-6, "release stays within reach")
end)

test("High from the pivot is the release height plus the hop", function()
	local high = params({ pivot = P, height = "High" })
	local _, upGround = offsetFromPivot(high, P)
	H.near(upGround, DiscConfig.Heights.High, 1e-6, "no hop seen: plain High")
	local _, upHop = offsetFromPivot(high, P + Vector3.new(0, 2, 0))
	H.near(upHop - upGround, 2, 1e-6, "hop adds its height")
	local _, upCap = offsetFromPivot(high, P + Vector3.new(0, 50, 0))
	H.near(upCap - upGround, T.MaxHopLift, 1e-6, "hop is capped")
	local _, upSunk = offsetFromPivot(high, P - Vector3.new(0, 3, 0))
	H.near(upSunk, upGround, 1e-6, "a root below P never lowers the release")
	local _, upMid = offsetFromPivot(params({ pivot = P }), P)
	local _, upLow = offsetFromPivot(params({ pivot = P, height = "Low" }), P)
	expect(upGround > upMid and upMid > upLow, "High > Mid > Low")
	local _, upHammer = offsetFromPivot(params({ throwType = "Hammer", pivot = P }), P)
	H.near(upHammer, DiscConfig.OverheadHeight, 1e-6, "overheads release overhead")
end)

test("pivot offsets rotate with the aim", function()
	for _, yaw in { 0.7, -2.1, math.pi } do
		local forward, right = ThrowModel.basis(yaw)
		local step = right * (R * 0.8)
		local rel = ThrowModel.releasePosition(params({ throwType = "Forehand", yaw = yaw, pivot = P, step = step }), P)
			- P
		H.near(rel:Dot(right), R * 0.8 + sideOf("Forehand") * T.PivotSideScale, 1e-6, "lateral in the aim frame")
		H.near(rel:Dot(forward), T.ReleaseForward, 1e-6, "forward in the aim frame")
	end
end)

test("left-handed: side offsets mirror, the step does not", function()
	for _, height in { "Mid", "Low" } do
		local rStep = Vector3.new(-R, 0, 0) -- right-hander's BH step-out (left)
		local right = ThrowModel.releasePosition(params({ pivot = P, step = rStep, height = height }), P)
		local lStep = Vector3.new(R, 0, 0) -- left-hander's BH step-out (right)
		local left =
			ThrowModel.releasePosition(params({ pivot = P, step = lStep, height = height, leftHanded = true }), P)
		H.near(right.X - P.X, -(left.X - P.X), 1e-6, height .. " mirrored release")
		H.near(right.Y, left.Y, 1e-6, height .. " same height")
		-- the same world step: the lefty releases on the other side of the foot
		local same =
			ThrowModel.releasePosition(params({ pivot = P, step = rStep, height = height, leftHanded = true }), P)
		expect(same.X > right.X, height .. " side offset flips, step stays")
	end
end)

test("left-handed throws mirror right-handed ones (root and pivot releases)", function()
	for _, pivot in { false, true } do
		local base = params({ pitch = 0.05, holdTime = 0.3, bank = 0.2 })
		if pivot then
			base.pivot = P
			base.step = Vector3.new(-2, 0, 0.5)
		end
		local r = DiscPhysics.simulate(ThrowModel.launch(base, P, Vector3.zero).state)
		base.leftHanded = true
		if pivot then
			base.step = Vector3.new(2, 0, 0.5)
		end
		local l = DiscPhysics.simulate(ThrowModel.launch(base, P, Vector3.zero).state)
		expect(
			math.abs(r.landX + l.landX) < 0.05 and math.abs(r.landZ - l.landZ) < 0.05,
			string.format("mirror %.3f vs %.3f", r.landX, l.landX)
		)
	end
end)

test("from a pivot there is no run-up: no carry, no moving-spin penalty", function()
	local sideways = Vector3.new(20, 0, 0)
	local still = ThrowModel.launch(params({ pivot = P }), P, Vector3.zero)
	local shuffling = ThrowModel.launch(params({ pivot = P }), P, sideways)
	expect((still.velocity - shuffling.velocity).Magnitude < 1e-9, "root shuffle adds nothing")
	expect(still.spinFactor == shuffling.spinFactor, "and costs no spin")
	local run = ThrowModel.launch(params(), P, sideways)
	local stand = ThrowModel.launch(params(), P, Vector3.zero)
	expect(run.velocity.X > stand.velocity.X, "on the run (no pivot) the run-up carries")
	expect(run.spinFactor < stand.spinFactor, "and costs spin")
end)

test("releasing mid swing costs spin, never power", function()
	local calm = ThrowModel.launch(params({ pivot = P, holdTime = 0.6 }), P, Vector3.zero)
	local swing = ThrowModel.launch(params({ pivot = P, holdTime = 0.6, swinging = true }), P, Vector3.zero)
	H.near(swing.spinFactor, calm.spinFactor * T.SwingSpinPenalty, 1e-9, "spin cost")
	expect(swing.speed == calm.speed and swing.power == calm.power, "power kept")
	expect(swing.quality == calm.quality, "quality kept")
end)

test("a throw from the ground after a layout ignores the pivot", function()
	local p = params({ pivot = P, step = Vector3.new(3, 0, 0), groundThrow = true })
	local withPivot = ThrowModel.releasePosition(p, Vector3.new(5, 1, 5))
	p.pivot = nil
	local without = ThrowModel.releasePosition(p, Vector3.new(5, 1, 5))
	expect((withPivot - without).Magnitude < 1e-9, "ground throw comes from the body")
end)

test("server step check: trust a consistent step, else use the server root", function()
	local step = Vector3.new(-3, 0, 0)
	local root = P + step * HD.BodyShare
	local s, ok = ThrowModel.resolveStep(step, P, root + Vector3.new(0.5, 0, 0.3), 0.05, 0)
	expect(ok and s == step, "within tolerance")
	local lagged = root + Vector3.new(T.StepCheckBase + 1.0, 0, 0)
	local _, noPingOk = ThrowModel.resolveStep(step, P, lagged, 0, 0)
	local _, lagOk = ThrowModel.resolveStep(step, P, lagged, 0.2, 0)
	expect(not noPingOk and lagOk, "ping widens the tolerance")
	local fallback, bad = ThrowModel.resolveStep(Vector3.new(R, 0, 0), P, root, 0, 0)
	expect(not bad, "a step the server can't see is rejected")
	expect((fallback - step).Magnitude < 1e-6, "and replaced by the step implied by the server root")
	local junk, junkOk = ThrowModel.resolveStep("x", P, P, 0 / 0, 0)
	expect(junkOk and junk == Vector3.zero, "junk step from a squared-up body is squared up")
	local far = ThrowModel.stepFromRoot(P + Vector3.new(-40, 7, 0), P, 0)
	H.near(far.Magnitude, R, 1e-6, "implied step is clamped too")
	expect(far.Y == 0, "and flat")
end)

test("solver hits a stationary receiver", function()
	local target = Vector3.new(20, 4, -70)
	local sol = Solver.solve({ rootPos = Vector3.new(0, 3, 0), throwType = "Backhand", target = target })
	expect(sol ~= nil, "solution found")
	expect(sol.miss < 2.0, "miss " .. sol.miss)
end)

test("solver covers the whole range: a short dump and a long huck", function()
	local short = Solver.solve({ rootPos = P, throwType = "Backhand", target = Vector3.new(-6, 4, -14) })
	expect(short ~= nil and short.miss < 2.0, "short miss " .. (short and short.miss or -1))
	local long = Solver.solve({ rootPos = P, throwType = "Backhand", target = Vector3.new(10, 4, -160) })
	expect(long ~= nil and long.miss < 3.0, "huck miss " .. (long and long.miss or -1))
	expect(long.params.holdTime > short.params.holdTime, "a huck needs more power")
end)

test("solver from a pivot launches from P + step and returns both", function()
	local step = Vector3.new(-R, 0, 0)
	local target = Vector3.new(-30, 4, -60)
	local sol = Solver.solve({
		rootPos = P + step * HD.BodyShare,
		pivot = P,
		step = step,
		throwType = "Backhand",
		target = target,
	})
	expect(sol ~= nil and sol.miss < 2.0, "miss " .. (sol and sol.miss or -1))
	expect(sol.params.pivot == P and (sol.params.step - step).Magnitude < 1e-6, "params carry the pivot")
	local launch = ThrowModel.launch(sol.params, P + step * HD.BodyShare, Vector3.zero)
	local expected = ThrowModel.releasePosition(sol.params, P)
	expect((launch.releasePos - expected).Magnitude < 1e-6, "released from the pivot")
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
		-- a huck from a pivot step-out to a deep cutter (~145 studs)
		{ type = "Backhand", start = Vector3.new(12, 3, -90), vel = Vector3.new(0, 0, -22), pivot = true },
	}
	for _, c in cases do
		local step = if c.pivot then Vector3.new(R * 0.8, 0, 0) else nil
		local root = if step then P + step * HD.BodyShare else P
		local sol = Solver.solve({
			rootPos = root,
			pivot = if step then P else nil,
			step = step,
			throwType = c.type,
			target = c.start + Vector3.new(0, 1, 0),
			targetVel = c.vel,
		})
		expect(sol ~= nil, c.type .. " solved")
		local s = ThrowModel.launch(sol.params, root, Vector3.zero).state
		local caught = false
		while s.t < 6 and s.py > 0.2 and not caught do
			DiscPhysics.step(s, DiscConfig.Physics.Dt)
			local body = c.start + c.vel * s.t
			local zones = CatchGeometry.zones({
				root = body,
				facing = Vector3.new(0, 0, 1),
				reaching = true,
				reachDir = (Vector3.new(s.px, s.py, s.pz) - body).Unit,
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
