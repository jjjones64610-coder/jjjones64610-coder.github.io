local H = require("./harness")
local Signatures = H.require("Rules/Signatures")
local Config = H.require("Config/Signatures")
local ComboEvaluator = H.require("Rules/ComboEvaluator")

local test, expect = H.test, H.expect

print("signature moves")

-- Feeds a list of events (times are filled in 0.1 s apart unless given) and
-- returns every hit id in order.
local function play(events)
	local tr = Signatures.new()
	local hits = {}
	local t = 0
	for _, e in events do
		t = e.t or (t + 0.1)
		e.t = t
		for _, h in Signatures.feed(tr, e) do
			table.insert(hits, h.id)
		end
	end
	return hits, tr
end

local function tech(name, quality, info, t)
	return { kind = "Tech", tech = name, quality = quality or "Clean", info = info, t = t }
end

local function has(list, id)
	return table.find(list, id) ~= nil
end

test("tip reset pays once, when the reset is used in the air", function()
	local hits = play({
		tech("Jump"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		tech("Dive", "Clean", "Air"),
		{ kind = "Land" },
	})
	expect(#hits == 1 and hits[1] == "TipReset", "one Tip Reset, got " .. table.concat(hits, ","))
	local none = play({ tech("Jump"), { kind = "Tip", discId = "d1" }, { kind = "Land" } })
	expect(#none == 0, "a tip without using the reset is not a Tip Reset")
end)

test("reset grab: tip, air move, catch the same disc before landing", function()
	local hits = play({
		tech("Jump"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		{ kind = "Catch", discId = "d1", airborne = true, height = 2 },
	})
	expect(has(hits, "TipReset") and hits[#hits] == "ResetGrab", "Reset Grab, got " .. table.concat(hits, ","))
	local landedFirst = play({
		tech("Jump"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		{ kind = "Land" },
		{ kind = "Catch", discId = "d1", airborne = false },
	})
	expect(not has(landedFirst, "ResetGrab"), "landing first is no Reset Grab")
	local otherDisc = play({
		tech("Jump"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		{ kind = "Catch", discId = "d2", airborne = true, height = 1 },
	})
	expect(not has(otherDisc, "ResetGrab"), "catching another disc is no Reset Grab")
end)

test("a catch confirmed after the landing still counts in its own airtime", function()
	-- the server answers a round trip later: the landing arrives first
	local hits = play({
		tech("Jump", "Clean", nil, 0),
		{ kind = "Tip", discId = "d1", t = 0.2 },
		tech("AirRedirect", "Clean", nil, 0.3),
		{ kind = "Land", t = 0.5 },
		{ kind = "Catch", discId = "d1", airborne = true, height = 1, t = 0.45 },
	})
	expect(hits[#hits] == "ResetGrab", "Reset Grab, got " .. table.concat(hits, ","))
end)

test("double tip and wall tip outrank reset grab (one pays per catch)", function()
	local dbl = play({
		tech("Jump"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		{ kind = "Tip", discId = "d1" },
		tech("Dive", "Clean", "Air"),
		{ kind = "Catch", discId = "d1", airborne = true, height = 1 },
	})
	expect(dbl[#dbl] == "DoubleTip" and not has(dbl, "ResetGrab"), "Double Tip only, got " .. table.concat(dbl, ","))
	local wall = play({
		tech("Jump"),
		tech("WallRebound"),
		{ kind = "Tip", discId = "d1" },
		tech("AirRedirect"),
		{ kind = "Catch", discId = "d1", airborne = true, height = 1 },
	})
	expect(wall[#wall] == "WallTip", "Wall Tip, got " .. table.concat(wall, ","))
end)

test("double layout: layout, Perfect pop-up, air layout, catch", function()
	local hits = play({
		tech("Dive"),
		{ kind = "Land" },
		tech("RecoveryChain", "Perfect", "Jump"),
		tech("Dive", "Clean", "Air"),
		{ kind = "Catch", discId = "d1", airborne = true, height = 1 },
	})
	expect(hits[#hits] == "DoubleLayout", "Double Layout, got " .. table.concat(hits, ","))
	local clean = play({
		tech("Dive"),
		{ kind = "Land" },
		tech("RecoveryChain", "Clean", "Jump"),
		tech("Dive", "Clean", "Air"),
		{ kind = "Catch", discId = "d1", airborne = true, height = 1 },
	})
	expect(not has(clean, "DoubleLayout"), "a Clean pop-up is not enough")
end)

test("skyball needs real height; a ground catch never is one", function()
	local sky =
		play({ tech("Jump"), { kind = "Catch", discId = "d1", airborne = true, height = Config.SkyHeight + 0.5 } })
	expect(sky[1] == "Skyball", "Skyball")
	local low = play({ tech("Jump"), { kind = "Catch", discId = "d1", airborne = true, height = 2 } })
	expect(#low == 0, "a normal jump catch is nothing special")
end)

test("reset loop: landing reset, burst, Perfect snap cut, twice", function()
	local loop = {
		tech("PrecisionLanding", "Perfect", "Reset"),
		tech("BurstStep"),
		tech("SnapCut", "Perfect"),
	}
	local once = play(loop)
	expect(#once == 0, "one loop is not yet a Reset Loop")
	local events = {}
	for _ = 1, 2 do
		for _, e in loop do
			table.insert(events, tech(e.tech, e.quality, e.info))
		end
	end
	local twice = play(events)
	expect(twice[1] == "ResetLoop", "two loops, got " .. table.concat(twice, ","))
	local sloppy = play({
		tech("PrecisionLanding", "Perfect", "Reset"),
		tech("BurstStep"),
		tech("SnapCut", "Clean"),
		tech("PrecisionLanding", "Perfect", "Reset"),
		tech("BurstStep"),
		tech("SnapCut", "Perfect"),
	})
	expect(#sloppy == 0, "a Clean cut breaks the loop")
	local slow = play({
		tech("PrecisionLanding", "Perfect", "Reset", 0),
		tech("BurstStep", "Clean", nil, 1.5),
		tech("SnapCut", "Perfect", nil, 1.6),
	})
	expect(#slow == 0, "each step must follow quickly")
end)

test("self-D: a defender's tip and then their own catch", function()
	local hits = play({
		{ kind = "Tip", discId = "d1", defender = true },
		{ kind = "Catch", discId = "d1", airborne = false, interception = true },
	})
	expect(hits[1] == "SelfD", "Self-D, got " .. table.concat(hits, ","))
	local late = play({
		{ kind = "Tip", discId = "d1", defender = true, t = 0 },
		{ kind = "Catch", discId = "d1", airborne = false, interception = true, t = Config.SelfDWindow + 1 },
	})
	expect(#late == 0, "too late")
end)

test("the greatest is passed straight through", function()
	local hits = play({ { kind = "Greatest" } })
	expect(hits[1] == "Greatest", "Greatest")
end)

test("every signature has a definition and a place in the order", function()
	for id, def in Config.List do
		expect(def.id == id and def.points > 0 and def.name ~= "", "bad def " .. id)
		expect(table.find(Config.Order, id) ~= nil, id .. " missing from Order")
	end
	for _, id in Config.Order do
		expect(Config.List[id] ~= nil, "Order names an unknown move " .. id)
	end
end)

test("signature points join the combo chain as scoring entries", function()
	local tr = ComboEvaluator.newTracker()
	ComboEvaluator.add(tr, "SnapCut", "Clean", 0)
	local pts, total = ComboEvaluator.signature(tr, "RESET GRAB", 2000, 0.4)
	expect(pts == 2000 and total >= 2000, "points added")
	local c = ComboEvaluator.active(tr, 0.5)
	expect(c ~= nil and c.scoring == 2, "counts as a scoring entry")
	local s = ComboEvaluator.convert(tr, 0.6, "Catch")
	expect(s ~= nil and s.score >= 4000, "a converted chain doubles it")
end)

return nil
