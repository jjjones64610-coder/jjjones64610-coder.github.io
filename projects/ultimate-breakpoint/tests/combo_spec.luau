local H = require("./harness")
local ComboEvaluator = H.require("Rules/ComboEvaluator")

local test, expect = H.test, H.expect

print("combos")

local function chain(list)
	local tr = ComboEvaluator.newTracker()
	local t = 0
	for _, item in list do
		t += 0.3
		ComboEvaluator.add(tr, item[1], item[2] or "Clean", t)
	end
	return tr, t
end

test("spamming one technique scores far less than a varied chain", function()
	local spam = chain({ { "SnapCut" }, { "SnapCut" }, { "SnapCut" }, { "SnapCut" }, { "SnapCut" } })
	local varied = chain({ { "FakeCommit" }, { "SnapCut" }, { "BurstStep" }, { "Dive" }, { "PrecisionLanding" } })
	local s1 = ComboEvaluator.total(spam.chain)
	local s2 = ComboEvaluator.total(varied.chain)
	expect(s2 > s1 * 2.5, string.format("spam %d vs varied %d", s1, s2))
end)

test("perfect execution beats sloppy execution", function()
	local p = chain({ { "SnapCut", "Perfect" }, { "BurstStep", "Perfect" }, { "Dive", "Perfect" } })
	local s = chain({ { "SnapCut", "Sloppy" }, { "BurstStep", "Sloppy" }, { "Dive", "Sloppy" } })
	expect(ComboEvaluator.total(p.chain) > ComboEvaluator.total(s.chain) * 2.5, "quality weighting")
end)

test("chains expire after the window", function()
	local tr = ComboEvaluator.newTracker()
	ComboEvaluator.add(tr, "SnapCut", "Clean", 0)
	expect(ComboEvaluator.expire(tr, 0.5) == nil, "still active")
	local s = ComboEvaluator.expire(tr, 2.0)
	expect(s ~= nil and not s.converted, "expired unconverted")
end)

test("only converted chains pay out (x2) and tier up", function()
	local tr, t = chain({
		{ "FakeCommit", "Perfect" },
		{ "SnapCut", "Perfect" },
		{ "BurstStep", "Perfect" },
		{ "Dive", "Perfect" },
	})
	local raw = ComboEvaluator.total(tr.chain)
	local s = ComboEvaluator.convert(tr, t + 0.4, "Layout Catch")
	expect(s and s.converted and s.score == raw * 2 and s.payoff == "Layout Catch", "conversion")
	expect(s.tier ~= nil, "tiered: " .. tostring(s.tier))
end)

test("a chain that just ended can still be converted inside the window", function()
	local tr, t = chain({ { "SnapCut" }, { "BurstStep" } })
	ComboEvaluator.expire(tr, t + 1.05)
	local s = ComboEvaluator.convert(tr, t + 1.15, "Catch")
	expect(s and s.converted, "late conversion")
	expect(ComboEvaluator.convert(tr, t + 1.2, "Catch") == nil, "cannot convert twice")
end)

test("jumps keep a chain alive but add no points", function()
	local tr = ComboEvaluator.newTracker()
	local added = ComboEvaluator.add(tr, "Jump", "Clean", 0)
	expect(added == 0, "jump scores zero")
	ComboEvaluator.add(tr, "AirRedirect", "Perfect", 0.4)
	expect(tr.chain.scoring == 1, "one scoring tech")
end)

return nil
