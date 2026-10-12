local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local CatchGeometry = H.require("Rules/CatchGeometry")

local test, expect = H.test, H.expect

print("catching")

local ROOT = Vector3.new(0, 3, 0)
local FWD = Vector3.new(0, 0, -1)

local function body(extra)
	local b = { root = ROOT, facing = FWD, reaching = false, diving = false, sliding = false }
	for k, v in extra or {} do
		b[k] = v
	end
	return b
end

test("disc at the chest is a clean secure catch", function()
	local e = CatchGeometry.evaluate(CatchGeometry.zones(body()), ROOT + Vector3.new(0, 1, -0.4))
	expect(e and e.zone.kind == "Secure" and e.quality == "Clean", "clean secure")
end)

test("disc out of reach is not catchable without reaching", function()
	local p = ROOT + Vector3.new(4.8, 2.2, 0)
	expect(CatchGeometry.evaluate(CatchGeometry.zones(body()), p) == nil, "out of secure zone")
	local reach = CatchGeometry.zones(body({ reaching = true, reachDir = Vector3.new(1, 0.25, 0).Unit }))
	local e = CatchGeometry.evaluate(reach, p)
	expect(e and e.zone.kind == "Reach", "reach catches it")
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
	local edge = ROOT + Vector3.new(0, 1, -0.4) + Vector3.new(2.7, 0, 0)
	local e = CatchGeometry.evaluate(zones, edge)
	expect(e and e.quality == "Fingertip", "fingertip at the rim")
	local far = ROOT + Vector3.new(0, 1, -0.4) + Vector3.new(3.6, 0, 0)
	expect(CatchGeometry.evaluate(zones, far) == nil, "beyond rim")
	expect(CatchGeometry.evaluate(zones, far, 1.0) ~= nil, "slack accepts it")
end)

test("earliest touch wins; a near-simultaneous contest goes to the cleaner hand", function()
	local r = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.5, quality = "Clean", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.20, depth = 0.1, quality = "Clean", relativeSpeed = 30 },
	})
	expect(r.winner.id == 1 and not r.contested, "earlier wins outright")
	local c = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.55, quality = "Clean", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.03, depth = 0.20, quality = "Clean", relativeSpeed = 30 },
	})
	expect(c.winner.id == 2 and c.contested, "cleaner hand wins the contest")
end)

test("fingertip under pressure bobbles; clean catches never bobble", function()
	local r = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.8, quality = "Fingertip", relativeSpeed = 30 },
		{ id = 2, team = "B", t = 1.02, depth = 0.9, quality = "Fingertip", relativeSpeed = 30 },
	})
	expect(r.bobble, "contested fingertip bobbles")
	local fast =
		CatchGeometry.resolve({ { id = 1, team = "A", t = 1, depth = 0.8, quality = "Fingertip", relativeSpeed = 90 } })
	expect(fast.bobble, "fast fingertip bobbles")
	local clean = CatchGeometry.resolve({
		{ id = 1, team = "A", t = 1.00, depth = 0.3, quality = "Clean", relativeSpeed = 90 },
		{ id = 2, team = "B", t = 1.01, depth = 0.9, quality = "Fingertip", relativeSpeed = 90 },
	})
	expect(not clean.bobble, "clean is secure")
end)

test("mark zones: low hands stop low releases, high hands stop high ones", function()
	local marker = Vector3.new(0, 3, -3)
	local toward = Vector3.new(0, 0, 1)
	local lowDisc = Vector3.new(1.5, 2.0, -2.5)
	local highDisc = Vector3.new(0.5, 6.5, -2.5)
	expect(CatchGeometry.inMarkZone(marker, 0, toward, "Low", 0, lowDisc), "low stance blocks low")
	expect(not CatchGeometry.inMarkZone(marker, 0, toward, "Low", 0, highDisc), "low stance misses high")
	expect(CatchGeometry.inMarkZone(marker, 0, toward, "High", 0, highDisc), "high stance blocks high")
	expect(not CatchGeometry.inMarkZone(marker, 0, toward, "High", 0, lowDisc), "high stance misses low")
	expect(CatchGeometry.inMarkZone(marker, 0, toward, "Low", 4.5, highDisc), "jumping lifts the low zone")
	expect(
		not CatchGeometry.inMarkZone(marker, 0, toward, "Low", 0, Vector3.new(6, 2, -2.5)),
		"wide step-out beats the hands"
	)
end)

test("integration: mark counterplay (what beats a low mark, what beats a high mark)", function()
	local ThrowModel = H.require("Disc/ThrowModel")
	local DiscPhysics = H.require("Disc/DiscPhysics")
	local root = Vector3.new(0, 3, 0)
	local marker = Vector3.new(0, 3, -3.4)
	local toward = root - marker
	local function blocked(params, stance, jumpH, pivot)
		local s = ThrowModel.launch(params, root + (pivot or Vector3.zero), Vector3.zero).state
		while s.t < 0.3 do
			DiscPhysics.step(s, 1 / 120)
			if CatchGeometry.inMarkZone(marker, 0, toward, stance, jumpH or 0, Vector3.new(s.px, s.py, s.pz)) then
				return true
			end
		end
		return false
	end
	local function p(t, height, yaw)
		return { throwType = t, yaw = yaw or 0, pitch = 0, holdTime = 0.4, bank = 0, height = height }
	end
	expect(blocked(p("Backhand", "Mid"), "Low"), "mid backhand into a low mark is blocked")
	expect(blocked(p("Forehand", "Low", -0.35), "Low"), "a step-out alone does not beat a squared-up low mark")
	expect(
		not blocked(p("Forehand", "Low", -0.35), "Low", 0, Vector3.new(2.5, 0, 0)),
		"pivot + low forehand step-out gets around a low mark"
	)
	expect(not blocked(p("Hammer", "Mid"), "Low"), "hammer goes over a low mark")
	expect(blocked(p("Hammer", "Mid"), "High"), "a high mark stops the hammer")
	expect(not blocked(p("Backhand", "Mid", 0.35), "High"), "a breaking backhand beats a high mark")
	expect(blocked(p("Hammer", "Mid"), "Low", 4.5), "jumping lifts a low mark into the hammer")
	expect(blocked(p("Backhand", "Mid"), "Relaxed"), "a throw straight into a hands-down marker's body is stopped")
	expect(not blocked(p("Backhand", "Mid", 0.35), "Relaxed"), "but a hands-down marker cannot stop a break")
end)

return nil
