local H = require("./harness")
local ComboEvaluator = H.require("Rules/ComboEvaluator")
local Config = H.require("Config/Movement")

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

test("the chain window is the movement config's (1.5 s) and convert window is longer", function()
	expect(ComboEvaluator.ChainWindow == Config.ChainWindow, "same window as the sim")
	expect(ComboEvaluator.ChainWindow >= 1.5, "chain window " .. ComboEvaluator.ChainWindow)
	expect(ComboEvaluator.ConvertWindow > ComboEvaluator.ChainWindow, "convert window")
end)

test("a chain is visible from its first technique and expires with a summary", function()
	local tr = ComboEvaluator.newTracker()
	ComboEvaluator.add(tr, "SnapCut", "Clean", 0)
	expect(ComboEvaluator.active(tr, 0.1) ~= nil, "one technique is already a chain")
	expect(ComboEvaluator.windowLeft(tr, 0) > 0.99, "full bar after a technique")
	local mid = ComboEvaluator.windowLeft(tr, ComboEvaluator.ChainWindow * 0.5)
	expect(mid > 0.4 and mid < 0.6, "bar drains: " .. mid)
	ComboEvaluator.add(tr, "BurstStep", "Perfect", ComboEvaluator.ChainWindow * 0.9)
	expect(ComboEvaluator.expire(tr, ComboEvaluator.ChainWindow * 1.5) == nil, "still active")
	local s = ComboEvaluator.expire(tr, 10)
	expect(s ~= nil and not s.converted, "expired unconverted")
	expect(s.count == 2 and s.total > 0 and #s.techs == 2, "card data: count/total/techs")
	expect(s.tier == ComboEvaluator.tier(s.total), "tier of the total")
	expect(ComboEvaluator.expire(tr, 11) == nil, "summary returned once")
end)

test("converted chains pay x2 and tier up", function()
	local tr, t = chain({
		{ "FakeCommit", "Perfect" },
		{ "SnapCut", "Perfect" },
		{ "BurstStep", "Perfect" },
		{ "Dive", "Perfect" },
	})
	local raw = ComboEvaluator.total(tr.chain)
	local s = ComboEvaluator.convert(tr, t + 0.4, "Layout Catch")
	expect(s and s.converted and s.score == raw * 2 and s.payoff == "Layout Catch", "conversion")
	expect(s.xpScore == s.score, "converted XP uses the doubled score")
	expect(s.tier ~= nil, "tiered: " .. tostring(s.tier))
end)

test("a chain that just ended can still be converted inside the window", function()
	local tr, t = chain({ { "SnapCut" }, { "BurstStep" } })
	local ended = ComboEvaluator.expire(tr, t + ComboEvaluator.ChainWindow + 0.05)
	expect(ended ~= nil, "ended")
	local s = ComboEvaluator.convert(tr, t + ComboEvaluator.ConvertWindow - 0.05, "Catch")
	expect(s and s.converted, "late conversion")
	expect(ComboEvaluator.convert(tr, t + ComboEvaluator.ConvertWindow - 0.01, "Catch") == nil, "cannot convert twice")
	expect(#ComboEvaluator.settle(tr, t + 10) == 0, "a converted chain is never settled as unconverted")
end)

test("unconverted chains pay a 25% share exactly once, after they can't convert", function()
	local tr, t = chain({ { "SnapCut" }, { "BurstStep" }, { "Dive" } })
	local ended = ComboEvaluator.expire(tr, t + ComboEvaluator.ChainWindow + 0.05) :: any
	expect(ended.xpScore == math.floor(ended.total * ComboEvaluator.UnconvertedShare), "xpScore is the share")
	expect(ended.xpScore < ended.total, "share is smaller than the chain")
	expect(#ComboEvaluator.settle(tr, t + 2) == 0, "not yet: it could still convert")
	local paid = ComboEvaluator.settle(tr, t + ComboEvaluator.ChainWindow + ComboEvaluator.ConvertWindow + 0.2)
	expect(#paid == 1 and paid[1] == ended, "settled once")
	expect(#ComboEvaluator.settle(tr, t + 20) == 0, "never twice")
	expect(ComboEvaluator.convert(tr, t + 4, "Catch") == nil, "a settled chain cannot be converted")

	-- a new chain makes the previous one final immediately
	local tr2 = ComboEvaluator.newTracker()
	ComboEvaluator.add(tr2, "SnapCut", "Clean", 0)
	ComboEvaluator.add(tr2, "Slide", "Clean", 3)
	local paid2 = ComboEvaluator.settle(tr2, 3.1)
	expect(#paid2 == 1 and paid2[1].techs[1] == "SnapCut", "replaced chain settled")
end)

test("jumps keep a chain alive and add a few points", function()
	local tr = ComboEvaluator.newTracker()
	local added = ComboEvaluator.add(tr, "Jump", "Clean", 0)
	expect(added > 0 and added < ComboEvaluator.add(tr, "AirRedirect", "Perfect", 0.4), "jump scores a little")
	expect(tr.chain.scoring == 2, "both count")
	expect(ComboEvaluator.add(tr, "Jump", "Clean", 0.8) < added, "repeated jumps score less")
end)

test("Break: fake -> swing -> release inside the window scores a Break", function()
	local swing = Config.Holding.SwingTime
	local tr = ComboEvaluator.newTracker()
	ComboEvaluator.add(tr, "PivotSwing", "Perfect", 1) -- Perfect = sold (within 0.35 s of a fake)
	local pts, total = ComboEvaluator.release(tr, 1 + swing + 0.1)
	expect(pts and pts > 0 and total and total > pts, "break added: " .. tostring(pts))
	expect(tr.chain.entries[#tr.chain.entries].tech == "Break", "Break link in the chain")

	local plain = ComboEvaluator.newTracker()
	ComboEvaluator.add(plain, "PivotSwing", "Clean", 1)
	expect(ComboEvaluator.release(plain, 1 + swing + 0.1) == nil, "no fake, no Break")

	local late = ComboEvaluator.newTracker()
	ComboEvaluator.add(late, "PivotSwing", "Perfect", 1)
	expect(ComboEvaluator.release(late, 1 + swing + ComboEvaluator.BreakWindow + 0.05) == nil, "too late")

	local quick = ComboEvaluator.newTracker()
	ComboEvaluator.add(quick, "PivotSwing", "Perfect", 1)
	expect(ComboEvaluator.breakQuality(quick, 1 + swing) == "Perfect", "instant release is Perfect")
	expect(Config.ComboPoints.Break > Config.ComboPoints.PivotSwing, "Break is worth more than the swing")
end)

return nil
