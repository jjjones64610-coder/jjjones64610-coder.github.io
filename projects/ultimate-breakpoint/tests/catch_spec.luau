local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local CatchGeometry = H.require("Rules/CatchGeometry")
local DiscConfig = H.require("Config/Disc")

local test, expect = H.test, H.expect
local C = DiscConfig.Catch
local M = DiscConfig.Mark

print("catching")

local ROOT = Vector3.new(0, 3, 0)
local FWD = Vector3.new(0, 0, -1)
local CHEST = ROOT + Vector3.new(0, C.ChestHeight, -0.4)

local function body(extra)
	local b = { root = ROOT, facing = FWD, reaching = false, diving = false, sliding = false }
	for k, v in extra or {} do
		b[k] = v
	end
	return b
end

-- Disc samples every 1/120 s along a straight line (closest-approach tests).
local function path(from, vel, seconds)
	local samples = {}
	local n = math.floor(seconds * 120 + 0.5)
	for k = 0, n do
		local t = k / 120
		table.insert(samples, { t = t, pos = from + vel * t })
	end
	return samples
end

-- First sample inside any zone, as the client sees it on first contact.
local function firstContact(zones, samples)
	for i, s in samples do
		local ev = CatchGeometry.evaluate(zones, s.pos)
		if ev then
			return ev, i
		end
	end
	return nil, nil
end

test("disc at the chest is a clean secure catch", function()
	local e = CatchGeometry.evaluate(CatchGeometry.zones(body()), CHEST)
	expect(e and e.zone.kind == "Secure" and e.quality == "Clean", "clean secure")
end)

test("disc out of reach is not catchable without reaching", function()
	local p = ROOT + Vector3.new(4.8, 2.2, 0)
	expect(CatchGeometry.evaluate(CatchGeometry.zones(body()), p) == nil, "out of secure zone")
	local reach = CatchGeometry.zones(body({ reaching = true, reachDir = Vector3.new(1, 0.25, 0).Unit }))
	local e = CatchGeometry.evaluate(reach, p)
	expect(e and e.zone.kind == "Reach", "reach catches it")
end)

test("reach shoulder slides smoothly: a straight-ahead reach never flips sides", function()
	local function shoulder(dir)
		for _, z in CatchGeometry.zones(body({ reaching = true, reachDir = dir })) do
			if z.kind == "Reach" then
				return z.a
			end
		end
		error("no reach zone")
	end
	local slightlyLeft = shoulder(Vector3.new(-0.02, 0, -1).Unit)
	local slightlyRight = shoulder(Vector3.new(0.02, 0, -1).Unit)
	expect((slightlyLeft - slightlyRight).Magnitude < 0.25, "tiny facing difference moves the shoulder a little")
	local wideRight = shoulder(Vector3.new(1, 0, -0.2).Unit)
	local wideLeft = shoulder(Vector3.new(-1, 0, -0.2).Unit)
	H.near(wideRight.X - ROOT.X, C.ShoulderWidth, 1e-6, "a wide reach uses the full shoulder offset")
	H.near(wideLeft.X - ROOT.X, -C.ShoulderWidth, 1e-6, "mirrored on the other side")
end)

test("diving extends reach along the dive direction only", function()
	local ahead = ROOT + Vector3.new(0, -0.5, -6)
	local behind = ROOT + Vector3.new(0, -0.5, 6)
	local zones = CatchGeometry.zones(body({ diving = true, diveDir = FWD }))
	expect(CatchGeometry.evaluate(zones, ahead) ~= nil, "layout reaches ahead")
	expect(CatchGeometry.evaluate(zones, behind) == nil, "but not behind")
end)

test("rim contact is a fingertip catch; slack widens zones server-side", function()
	local zones = CatchGeometry.zones(body())
	local edge = CHEST + Vector3.new(2.85, 0, 0)
	local e = CatchGeometry.evaluate(zones, edge)
	expect(e and e.quality == "Fingertip", "fingertip at the rim")
	local far = CHEST + Vector3.new(3.6, 0, 0)
	expect(CatchGeometry.evaluate(zones, far) == nil, "beyond rim")
	expect(CatchGeometry.evaluate(zones, far, 1.0) ~= nil, "slack accepts it")
end)

test("quality is judged at closest approach: a head-on firm catch is Clean", function()
	local zones = CatchGeometry.zones(body())
	-- a firm 60 studs/s pass straight into the chest
	local samples = path(CHEST + Vector3.new(0, 0, -6), Vector3.new(0, 0, 60), 0.2)
	local first, i = firstContact(zones, samples)
	expect(first and first.quality == "Fingertip", "the first touch is at the rim")
	local window = table.move(samples, i :: number, (i :: number) + C.QualitySamples, 1, {})
	local best = CatchGeometry.bestOverPath(zones, window, window[1].t)
	expect(best and best.quality == "Clean" and best.depth < 0.2, "but it passes through the core")
	expect(best and (best.t :: number) > window[1].t, "closest approach comes after first contact")
end)

test("quality window: a rim graze stays a Fingertip catch", function()
	local zones = CatchGeometry.zones(body())
	local r = C.SecureRadius + DiscConfig.Physics.Radius * 0.5
	local samples = path(CHEST + Vector3.new(0.9 * r, 0, -6), Vector3.new(0, 0, 60), 0.2)
	local best = CatchGeometry.bestOverPath(zones, samples, 0)
	expect(best ~= nil and best.quality == "Fingertip", "graze is fingertip")
	H.near((best :: any).depth, 0.9, 0.02, "graze depth")
end)

test("quality window follows a receiver running across the disc's path", function()
	-- The receiver sprints sideways and meets the disc chest-first at the end
	-- of the window. Zones are built at t0; with the body velocity each
	-- sample is judged in the body's moving frame.
	local run = Vector3.new(28, 0, 0)
	local discVel = Vector3.new(0, 0, 60)
	local window = C.QualitySamples / 120
	local meet = CHEST + run * window
	local samples = path(meet - discVel * window, discVel, window)
	local zones = CatchGeometry.zones(body())
	local frozen = CatchGeometry.bestOverPath(zones, samples, 0)
	local moving = CatchGeometry.bestOverPath(zones, samples, 0, run)
	expect(moving ~= nil and moving.quality == "Clean" and moving.depth < 0.1, "clean in the body frame")
	expect(frozen == nil or frozen.quality == "Fingertip", "a frozen body would only have fingertips on it")
end)

test("slack grows with ping and body speed and is capped", function()
	expect(CatchGeometry.slack(0, 0) == C.BaseSlack, "base slack")
	expect(CatchGeometry.slack(0.1, 0) > CatchGeometry.slack(0, 0), "ping adds slack")
	expect(CatchGeometry.slack(0.1, 28) > CatchGeometry.slack(0.1, 0), "speed adds slack")
	expect(CatchGeometry.slack(5, 500) == C.MaxSlack, "capped")
	expect(CatchGeometry.slack(0 / 0, math.huge) == C.BaseSlack, "junk counts as zero")
	expect(CatchGeometry.slack(-1, -10) == C.BaseSlack, "negatives count as zero")
end)

test("claimRoot trusts a nearby client body and leads a lagged server one", function()
	local server = Vector3.new(0, 3, 0)
	local vel = Vector3.new(0, 0, -28)
	local near = server + Vector3.new(0, 0, -3) -- the client is ahead of the server's view
	local root, ok = CatchGeometry.claimRoot(near, server, vel, 0)
	expect(ok and root == near, "client root within tolerance is used")
	local far = server + Vector3.new(0, 0, -40)
	root, ok = CatchGeometry.claimRoot(far, server, vel, 0)
	expect(not ok and (root - (server + vel * C.ClientRootLead)).Magnitude < 1e-6, "far client root falls back")
	local _, still = CatchGeometry.claimRoot(server + Vector3.new(3, 0, 0), server, Vector3.zero, 0)
	expect(not still, "standing still allows only the base tolerance")
	local _, cap = CatchGeometry.claimRoot(server + Vector3.new(0, 0, -C.ClientRootMax - 0.5), server, vel, 10)
	expect(not cap, "tolerance is capped")
	for _, junk in { "x", 5, Vector3.new(0 / 0, 0, 0), Vector3.new(math.huge, 0, 0), nil } do
		local r, accepted = CatchGeometry.claimRoot(junk, server, Vector3.zero, 0)
		expect(not accepted and r == server, "junk client root falls back to the server root")
	end
end)

test("earliest touch wins; a near-simultaneous contest goes to the cleaner hand", function()
	local r = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.5, quality = "Clean", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.00 + C.ContestWindow * 3, depth = 0.1, quality = "Clean", relativeSpeed = 30 },
	})
	expect(r.winner.id == 1 and not r.contested, "earlier wins outright")
	local c = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.55, quality = "Clean", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.00 + C.ContestWindow * 0.75, depth = 0.20, quality = "Clean", relativeSpeed = 30 },
	})
	expect(c.winner.id == 2 and c.contested, "cleaner hand wins the contest")
end)

test("fingertip under pressure bobbles; clean catches never bobble", function()
	local r = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.85, quality = "Fingertip", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.02, depth = 0.9, quality = "Fingertip", relativeSpeed = 30 },
	})
	expect(r.bobble, "contested fingertip bobbles")
	local fast = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1, depth = 0.85, quality = "Fingertip", relativeSpeed = C.BobbleSpeed + 5 },
	})
	expect(fast.bobble, "fast fingertip bobbles")
	local firm = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1, depth = 0.85, quality = "Fingertip", relativeSpeed = C.BobbleSpeed - 5 },
	})
	expect(not firm.bobble, "a firm (not extreme) pass to the fingertips sticks")
	local clean = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.3, quality = "Clean", relativeSpeed = 120 },
		{ id = 2, team = "B", t = 1.01, depth = 0.9, quality = "Fingertip", relativeSpeed = 120 },
	})
	expect(not clean.bobble, "clean is secure")
end)

test("a defender blocks only at the rim; deeper touches are interceptions", function()
	local function defender(depth)
		local res = CatchGeometry.resolve({
			{
				id = 9,
				team = "D",
				t = 1,
				depth = depth,
				quality = CatchGeometry.qualityFor(depth),
				relativeSpeed = 40,
			},
		})
		return CatchGeometry.outcome(res :: any, true)
	end
	expect(defender(C.BlockDepth + 0.05) == "Block", "rim touch is a block")
	expect(defender((C.CleanFraction + C.BlockDepth) / 2) == "Catch", "a fingertip defender intercepts")
	expect(defender(0.3) == "Catch", "a clean defender intercepts")
	local attacker = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1, depth = C.BlockDepth + 0.05, quality = "Fingertip", relativeSpeed = 40 },
	})
	expect(CatchGeometry.outcome(attacker :: any, false) == "Catch", "receivers never 'block'")
	local bobbled = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1, depth = 0.85, quality = "Fingertip", relativeSpeed = C.BobbleSpeed + 10 },
	})
	expect(CatchGeometry.outcome(bobbled :: any, false) == "Bobble", "bobbles are reported")
end)

---------------------------------------------------------------------------
-- the mark
---------------------------------------------------------------------------

local P = Vector3.new(0, 3, 0) -- thrower's pivot foot (root height), aiming -Z

test("mark box faces between the marker's facing and P, never more than the cap", function()
	local marker = P + Vector3.new(0, 0, -M.MarkDistance)
	local toP = Vector3.new(0, 0, 1)
	local function offDeg(facing)
		local f = CatchGeometry.markForward(marker, facing, P)
		return math.deg(math.acos(math.clamp(f:Dot(toP), -1, 1)))
	end
	H.near(offDeg(toP), 0, 1e-4, "facing P")
	local small = math.rad(40)
	H.near(offDeg(Vector3.new(math.sin(small), 0, math.cos(small))), 40 * M.FacingBlend, 1e-3, "blended half way")
	H.near(offDeg(Vector3.new(1, 0, 0)), M.MaxFacingOff, 1e-3, "capped when facing sideways")
	H.near(offDeg(Vector3.new(0, 0, -1)), M.MaxFacingOff, 1e-3, "facing away still faces P within the cap")
	H.near(offDeg(Vector3.zero), 0, 1e-4, "no facing = face P")
end)

test("mark zones: low hands stop low releases, high hands stop high ones", function()
	local marker = Vector3.new(0, 3, -3)
	local facing = Vector3.new(0, 0, 1)
	local lowDisc = Vector3.new(1.5, 2.0, -2.5)
	local highDisc = Vector3.new(0.5, 6.5, -2.5)
	local function hit(stance, p, jump)
		return CatchGeometry.inMarkZone(marker, facing, P, stance, p, 0, jump)
	end
	expect(hit("Low", lowDisc), "low stance blocks low")
	expect(not hit("Low", highDisc), "low stance misses high")
	expect(hit("High", highDisc), "high stance blocks high")
	expect(not hit("High", lowDisc), "high stance misses low")
	expect(hit("Low", highDisc, 3), "jumping lifts the low zone")
	expect(not hit("Low", Vector3.new(6, 2, -2.5)), "wide step-out beats the hands")
	expect(not hit("Low", Vector3.new(0, 2, -6)), "behind the marker is not in the hands")
	expect(hit("Relaxed", marker + Vector3.new(0, C.ChestHeight, 0.5)), "relaxed: body contact")
	expect(not hit("Relaxed", lowDisc), "relaxed: small zone")
end)

test("disc space is measured from the pivot, so a lunge can't trigger it", function()
	local marker = P + Vector3.new(0, 0, -M.MarkDistance)
	local ThrowModel = H.require("Disc/ThrowModel")
	local MovementConfig = H.require("Config/Movement")
	local lunge = ThrowModel.clampStep(Vector3.new(0, 0, -100), 0) -- the longest legal forward step
	local root = P + lunge * MovementConfig.Holding.BodyShare
	local rootDist = Vector3.new(marker.X - root.X, 0, marker.Z - root.Z).Magnitude
	expect(rootDist < M.DiscSpace, "measured from the root a full lunge would be inside disc space")
	expect(not CatchGeometry.isDiscSpace(marker, P), "measured from P it is not")
	expect(CatchGeometry.markDistance(marker, P) <= M.StallRange, "and the marker is in stall range")
	expect(CatchGeometry.isDiscSpace(P + Vector3.new(0, 0, -(M.DiscSpace - 0.3)), P), "a marker stepping in is")
end)

test("hand-block rewind favours the thrower and is capped", function()
	expect(CatchGeometry.markerRewind(0) == M.RewindBase, "base rewind")
	expect(CatchGeometry.markerRewind(0.1) > CatchGeometry.markerRewind(0), "more ping, more rewind")
	expect(CatchGeometry.markerRewind(3) == M.RewindMax, "capped")
	expect(CatchGeometry.markerRewind(0 / 0) == M.RewindBase, "junk ping")
end)

-- Geometry table (diag_3 §3): a right-handed thrower on P aims straight
-- upfield (-Z); BH is the left (-X) side. The marker stands MarkDistance
-- upfield, shaded Shade toward the BH side (forcing FH), facing P, in a Low
-- stance. A throw is blocked if any of its first HandBlockCheckTime seconds
-- of flight passes through the hands.
local function markCase()
	local ThrowModel = H.require("Disc/ThrowModel")
	local DiscPhysics = H.require("Disc/DiscPhysics")
	local MovementConfig = H.require("Config/Movement")
	local R = MovementConfig.Holding.StepRadius
	local share = MovementConfig.Holding.BodyShare
	local function blocked(o)
		local marker = P + Vector3.new(o.markerX or -M.Shade, 0, -M.MarkDistance)
		local facing = o.facing or (P - marker)
		local stepX = (o.step or 0) * R * (if o.throwType == "Forehand" then 1 else -1)
		local step = Vector3.new(stepX, 0, 0)
		local params = {
			throwType = o.throwType,
			yaw = math.rad(o.outward or 0) * (if o.throwType == "Forehand" then -1 else 1),
			pitch = 0,
			holdTime = 0.4,
			bank = 0,
			height = o.height or "Mid",
			pivot = P,
			step = step,
		}
		local root = P + step * share + Vector3.new(0, o.hop or 0, 0)
		local launch = ThrowModel.launch(params, root, Vector3.zero)
		local box = CatchGeometry.markBox(marker, facing, P, o.stance or "Low", 0, o.jump)
		if CatchGeometry.inMarkBox(box, launch.releasePos) then
			return true
		end
		local s = launch.state
		while s.t < DiscConfig.Throw.HandBlockCheckTime do
			DiscPhysics.step(s, DiscConfig.Physics.Dt)
			if CatchGeometry.inMarkBox(box, Vector3.new(s.px, s.py, s.pz)) then
				return true
			end
		end
		return false
	end
	-- smallest outward aim (degrees) that gets the throw past the hands
	local function outwardNeeded(o)
		for deg = 0, 90 do
			o.outward = deg
			if not blocked(o) then
				return deg
			end
		end
		return math.huge
	end
	return blocked, outwardNeeded
end

test("mark table: the open side needs a half step (or a little outward aim)", function()
	local blocked, outwardNeeded = markCase()
	expect(blocked({ throwType = "Forehand" }), "squared-up FH straight into the shade's hands")
	expect(not blocked({ throwType = "Forehand", step = 0.5 }), "a 0.5R FH step-out is open")
	expect(not blocked({ throwType = "Forehand", step = 0.5, height = "Low" }), "low too")
	local aim = outwardNeeded({ throwType = "Forehand" })
	expect(aim > 0 and aim <= 25, "squared up only needs a modest outward aim: " .. aim)
end)

test("mark table: the break side needs a full Low step, or a full step and a little aim", function()
	local blocked, outwardNeeded = markCase()
	expect(not blocked({ throwType = "Backhand", step = 1, height = "Low" }), "a full Low BH step-out breaks the mark")
	expect(blocked({ throwType = "Backhand", step = 0.75, height = "Low" }), "a 0.75R Low step alone does not")
	expect(blocked({ throwType = "Backhand", step = 1 }), "a full Mid step alone does not")
	local full = outwardNeeded({ throwType = "Backhand", step = 1 })
	local partial = outwardNeeded({ throwType = "Backhand", step = 0.75, height = "Low" })
	local squared = outwardNeeded({ throwType = "Backhand" })
	expect(full <= 15, "full Mid step + a little outward aim: " .. full)
	expect(partial <= 15, "0.75R Low step + a little outward aim: " .. partial)
	expect(squared > 45, "squared up the break needs a huge angle: " .. squared)
	expect(squared > full and full >= partial, "the more you step, the less you need to aim around")
end)

test("mark table: a marker who mirrors the step closes the break", function()
	local blocked = markCase()
	local break_ = { throwType = "Backhand", step = 1, height = "Low" }
	expect(not blocked(break_), "against the shade the break is open")
	break_.markerX = -M.Shade - 1.0 -- the marker mirrors one stud toward the step
	expect(blocked(break_), "a mirrored marker blocks it")
	local unshaded = markCase()
	expect(not unshaded({ throwType = "Forehand", step = 0.75, markerX = 0 }), "unshaded: FH 0.75R is open")
	expect(not unshaded({ throwType = "Backhand", step = 0.75, markerX = 0 }), "unshaded: BH 0.75R is open too")
end)

test("mark table: the marker's facing aims the hands", function()
	local blocked = markCase()
	local break_ = { throwType = "Backhand", step = 1, height = "Low", markerX = -2.2 }
	expect(not blocked(break_), "facing P from -2.2 just misses the full Low break")
	break_.facing = Vector3.new(0, 0, 1) -- squared to the field, hands toward the break lane
	expect(blocked(break_), "aiming the hands down the break lane covers it")
end)

test("mark table: release height vs stance", function()
	local blocked = markCase()
	expect(not blocked({ throwType = "Backhand", height = "High" }), "a High release clears Low hands")
	expect(blocked({ throwType = "Backhand", height = "High", jump = 2 }), "a jumping Low marker covers it")
	expect(not blocked({ throwType = "Backhand", height = "High", hop = 2.5, jump = 2 }), "unless the hop goes higher")
	expect(not blocked({ throwType = "Backhand", stance = "High" }), "Mid goes under High hands")
	expect(not blocked({ throwType = "Backhand", height = "Low", stance = "High" }), "Low goes under High hands")
	expect(not blocked({ throwType = "Hammer" }), "a hammer goes over a Low mark")
	expect(blocked({ throwType = "Hammer", jump = 4 }), "unless the marker jumps")
	expect(blocked({ throwType = "Hammer", stance = "High" }), "a High mark stops the hammer")
	expect(blocked({ throwType = "Backhand", stance = "Relaxed", markerX = 0 }), "into a hands-down marker's body")
	expect(
		not blocked({ throwType = "Backhand", stance = "Relaxed", markerX = 0, step = 0.5 }),
		"a step beats hands-down"
	)
end)

return nil
