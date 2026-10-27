local H = require("./harness")
local Modes = H.require("Config/Modes")
local MatchPlan = H.require("Rules/MatchPlan")
local FieldGeometry = H.require("Rules/FieldGeometry")
local Rng = H.require("Util/Rng")
local Vector3 = require("@lune/roblox").Vector3

local test, expect = H.test, H.expect

print("modes / match plan")

local PUBLIC = { privateServer = false, studio = false }

local function humans(n: number, rated: boolean?)
	local list = {}
	for i = 1, n do
		table.insert(list, { id = i, rating = if rated then 800 + ((i * 337) % 900) else nil })
	end
	return list
end

-- Registers bots the way TeamService does after botWork (fake negative ids).
local nextBot = 0
local function applyBots(plan)
	local work = MatchPlan.botWork(plan)
	for _, id in work.remove do
		MatchPlan.removeBot(plan, id)
	end
	for _, team in { "A", "B" } do
		for _ = 1, work.spawn[team] do
			nextBot -= 1
			MatchPlan.addBot(plan, team, nextBot)
		end
	end
end

local function teamOf(plan, id)
	local team = MatchPlan.slot(plan, id)
	return team
end

---------------------------------------------------------------------------
-- Modes
---------------------------------------------------------------------------

test("exactly two modes, Mini 3v3 and Normal 7v7, in Order", function()
	local n = 0
	for id, m in Modes.List do
		n += 1
		expect(m.id == id, "id matches key " .. id)
		expect(Modes.Fields[m.Field] ~= nil, id .. " field exists")
		expect(table.find(Modes.Order, id) ~= nil, id .. " in Order")
		expect(m.Ranked == false, id .. ": presets are never ranked by themselves")
		expect(m.FillWithBots and m.RankedEligible and m.UsePull, id .. " flags")
		expect(m.PreviewFraction >= 0 and m.PreviewFraction <= 1, id .. " preview")
	end
	expect(n == 2 and #Modes.Order == 2, "two modes")
	expect(Modes.List.Mini.TeamSize == 3 and Modes.List.Normal.TeamSize == 7, "team sizes")
	expect(Modes.Order[1] == "Mini" and Modes.Order[2] == "Normal", "smallest first")
	expect(Modes.has(Modes.Default), "default exists")
	for _, old in { "Casual", "Ranked", "Rush", "Clutch" } do
		expect(not Modes.has(old), old .. " removed")
	end
end)

test("Normal is the bigger game: bigger field, longer cap, at least the stall count", function()
	local mini, normal = Modes.List.Mini, Modes.List.Normal
	expect(normal.TimeCap > mini.TimeCap, "time cap")
	expect(normal.StallMax >= mini.StallMax, "stall")
	expect(normal.PullTimeout >= mini.PullTimeout, "pull timeout")
	expect(normal.PreviewFraction <= mini.PreviewFraction, "less preview on the big field")
end)

test("field dimensions are sane and Normal is bigger than Mini in every direction", function()
	for name, f in Modes.Fields do
		expect(f.width > 0 and f.length > 0 and f.endZone > 0, name .. " positive")
		expect(f.brick > 0 and f.brick < f.length / 2, name .. " brick inside its own half")
		expect(f.length > f.width, name .. " longer than wide")
		expect(f.endZone < f.length / 2, name .. " end zones shorter than half the field")
	end
	local mini, normal = Modes.Fields.Mini, Modes.Fields.Normal
	expect(normal.width > mini.width, "width")
	expect(normal.length > mini.length, "length")
	expect(normal.endZone > mini.endZone, "end zone")
	expect(normal.brick > mini.brick, "brick")
	-- the space each player has to cut into is about the same in both modes
	local function perPlayer(f, size)
		return f.width * f.length / (2 * size)
	end
	local a = perPlayer(mini, Modes.List.Mini.TeamSize)
	local b = perPlayer(normal, Modes.List.Normal.TeamSize)
	expect(math.abs(a - b) / math.max(a, b) < 0.25, string.format("space per player %d vs %d", a, b))
end)

test("a full line-up fits on its own mode's goal line", function()
	for _, id in Modes.Order do
		local m = Modes.List[id]
		local spec = Modes.Fields[m.Field]
		local f = FieldGeometry.new({
			center = Vector3.new(0, 0, 0),
			width = spec.width,
			length = spec.length,
			endZone = spec.endZone,
			brick = spec.brick,
		})
		local spots = FieldGeometry.lineup(f, "West", m.TeamSize)
		expect(#spots == m.TeamSize, id .. " spot count")
		for i, p in spots do
			expect(math.abs(p.Z) <= f.halfWidth - 8 + 1e-6, id .. " inside the sidelines")
			if i > 1 then
				expect(p.Z - spots[i - 1].Z >= 12, id .. " at least 12 studs apart")
			end
		end
	end
end)

test("eligible(): the head count decides; only 7-9 humans get a choice", function()
	for n = 0, 16 do
		local options, default = Modes.eligible(n)
		expect(table.find(options, default) ~= nil, n .. ": default is an option")
		-- options keep Modes.Order
		local last = 0
		for _, id in options do
			local i = table.find(Modes.Order, id) :: number
			expect(i > last, n .. ": ordered")
			last = i
		end
		if n <= 6 then
			expect(#options == 1 and default == "Mini", n .. " humans: Mini only")
		elseif n <= 9 then
			expect(#options == 2, n .. " humans: vote between both")
			expect(default == (if n == 7 then "Mini" else "Normal"), n .. " humans default " .. default)
		else
			expect(#options == 1 and default == "Normal", n .. " humans: Normal only")
		end
	end
end)

test("copy() is a fresh table; unknown ids give the default mode", function()
	local c = Modes.copy("Normal")
	c.PointsToWin = 99
	expect(Modes.List.Normal.PointsToWin ~= 99, "preset not mutated")
	expect(Modes.copy("Casual").id == Modes.Default, "old id falls back")
	expect(Modes.copy(nil).id == Modes.Default, "nil falls back")
end)

test("ranked rules: preset plus RankedOverrides, flagged Ranked", function()
	for _, id in Modes.Order do
		local r = Modes.resolve(id, { ranked = true })
		expect(r.id == id and r.Ranked, id .. " ranked")
		for k, v in Modes.RankedOverrides do
			expect((r :: any)[k] == v, id .. " override " .. k)
		end
		expect(r.SpecialArenas == false, "no special arenas in ranked")
		expect(r.PreviewFraction < Modes.List[id].PreviewFraction, "shorter preview in ranked")
		expect(r.TeamSize == Modes.List[id].TeamSize and r.PointsToWin == Modes.List[id].PointsToWin, "rest kept")
	end
	expect(Modes.List.Mini.Ranked == false, "overrides never leak into the preset")
end)

test("private config never applies to a ranked match", function()
	local private = { Mode = "Normal", PointsToWin = 1, PreviewFraction = 1, FillWithBots = false }
	local r = Modes.resolve("Mini", { ranked = true, private = private })
	local plain = Modes.resolve("Mini", { ranked = true })
	expect(r.id == "Mini", "host cannot switch the mode")
	for k, v in plain :: any do
		expect((r :: any)[k] == v, "same as plain ranked: " .. k)
	end
end)

test("private config: host picks the mode, values are clamped, junk is ignored", function()
	local r = Modes.resolve("Mini", {
		private = {
			Mode = "Normal",
			PointsToWin = 100,
			TimeCap = -5,
			StallInterval = 1.0 - 0.1,
			UsePull = "yes", -- wrong type
			TeamSize = 12, -- not editable
			Field = "Mini", -- not editable: the field follows the mode
			FillWithBots = false,
		},
	})
	local spec = Modes.Editable
	expect(r.id == "Normal" and r.TeamSize == 7 and r.Field == "Normal", "mode from host")
	expect(r.PointsToWin == spec.PointsToWin.max, "clamped up")
	expect(r.TimeCap == spec.TimeCap.min, "clamped down")
	expect(r.StallInterval == 0.9, "tidy float: " .. tostring(r.StallInterval))
	expect(r.UsePull == Modes.List.Normal.UsePull, "wrong type ignored")
	expect(r.FillWithBots == false, "bool applied")
	expect(r.Ranked == false, "never ranked")
	expect(Modes.resolve("Mini", { private = { Mode = "Rush" } }).id == "Mini", "unknown mode ignored")
	expect(Modes.sanitize("PointsToWin", 3.6) == 4, "whole-number keys take whole numbers")
	expect(Modes.sanitize("PointsToWin", 0 / 0) == nil, "NaN rejected")
	expect(Modes.sanitize("Nope", 1) == nil, "unknown key")
end)

test("Editable: the host list, in a fixed order, with legal defaults for both modes", function()
	local want = {
		"Mode",
		"FillWithBots",
		"PointsToWin",
		"TimeCap",
		"StallMax",
		"StallInterval",
		"UsePull",
		"PreviewFraction",
		"LandingShadow",
	}
	local count = 0
	for key, spec in Modes.Editable do
		count += 1
		expect(table.find(Modes.EditableOrder, key) ~= nil, key .. " ordered")
		expect(type(spec.label) == "string", key .. " label")
	end
	expect(count == #want and #Modes.EditableOrder == #want, "editable count")
	for _, key in want do
		expect(Modes.Editable[key] ~= nil, key .. " editable")
	end
	for _, id in Modes.Order do
		local d = Modes.editableDefaults(id)
		expect(d.Mode == id, "Mode default is the preset")
		for _, key in Modes.EditableOrder do
			expect(d[key] ~= nil, id .. " default for " .. key)
			expect(Modes.sanitize(key, d[key]) == d[key], id .. " default is legal: " .. key)
		end
	end
end)

---------------------------------------------------------------------------
-- MatchPlan: teams, lines, bench
---------------------------------------------------------------------------

local function checkPlan(plan, rules, total: number, label: string)
	local c = MatchPlan.counts(plan)
	expect(math.abs(c.A.humans - c.B.humans) <= 1, label .. ": human counts within one")
	expect(c.A.humans + c.B.humans == total, label .. ": everyone placed")
	local seen = {}
	for _, team in { "A", "B" } do
		local tc = c[team]
		expect(tc.line <= rules.TeamSize, label .. ": line capped at TeamSize")
		expect(tc.line == math.min(rules.TeamSize, tc.humans), label .. ": nobody benched while a spot is free")
		expect(tc.bench == tc.humans - tc.line, label .. ": overflow is benched")
		if rules.FillWithBots then
			expect(tc.line + tc.botsWanted == rules.TeamSize, label .. ": bots fill to exactly TeamSize")
		else
			expect(tc.botsWanted == 0, label .. ": no bots when FillWithBots is off")
		end
		for _, id in MatchPlan.benchFor(plan, team) do
			local t, role = MatchPlan.slot(plan, id)
			expect(t == team and role == "Bench", label .. ": bench role")
		end
	end
	for _, m in MatchPlan.members(plan) do
		expect(not seen[m.id], label .. ": placed once")
		seen[m.id] = true
	end
	-- the side with fewer humans never gets fewer bots
	if c.A.humans < c.B.humans then
		expect(c.A.botsWanted >= c.B.botsWanted, label .. ": short side gets the extra bot")
	elseif c.B.humans < c.A.humans then
		expect(c.B.botsWanted >= c.A.botsWanted, label .. ": short side gets the extra bot")
	end
end

test("splits for 1..16 humans in both modes: balanced, capped, benched, bot-filled", function()
	for _, id in Modes.Order do
		local rules = Modes.List[id]
		for n = 1, 16 do
			local plan = MatchPlan.new(rules, humans(n, n % 2 == 0))
			checkPlan(plan, rules, n, id .. " " .. n)
			applyBots(plan)
			for _, team in { "A", "B" } do
				expect(
					#MatchPlan.lineFor(plan, team) == rules.TeamSize,
					id .. " " .. n .. ": exactly TeamSize on field"
				)
			end
			local w = MatchPlan.botWork(plan)
			expect(#w.remove == 0 and w.spawn.A == 0 and w.spawn.B == 0, "nothing left to do after applying")
		end
	end
end)

test("odd head count: the side with fewer humans gets one more bot", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(5))
	local c = MatchPlan.counts(plan)
	local big, small = if c.A.humans > c.B.humans then c.A else c.B, if c.A.humans > c.B.humans then c.B else c.A
	expect(big.humans == 3 and small.humans == 2, "3 + 2")
	expect(small.botsWanted == big.botsWanted + 1, "one more bot on the short side")
end)

test("FillWithBots off: lines are just the humans", function()
	local rules = Modes.resolve("Mini", { private = { FillWithBots = false } })
	local plan = MatchPlan.new(rules, humans(3))
	checkPlan(plan, rules, 3, "no bots")
	applyBots(plan)
	expect(#MatchPlan.lineFor(plan, "A") + #MatchPlan.lineFor(plan, "B") == 3, "3 on the field")
end)

-- Strength gap between two teams: rating totals, with the short side's empty
-- spot counted as an average player.
local function strengthGap(list, teamOf: (number) -> string): number
	local sum, cnt, mean = { A = 0, B = 0 }, { A = 0, B = 0 }, 0
	for _, e in list do
		local t = teamOf(e.id)
		sum[t] += e.rating
		cnt[t] += 1
		mean += e.rating / #list
	end
	local size = math.max(cnt.A, cnt.B)
	return math.abs((sum.A + (size - cnt.A) * mean) - (sum.B + (size - cnt.B) * mean))
end

test("split balances ratings better than simple alternation, and works unrated", function()
	local rng = Rng.new(11)
	for _ = 1, 60 do
		local n = rng:int(2, 16)
		local list = {}
		for i = 1, n do
			table.insert(list, { id = i, rating = math.floor(rng:range(700, 2000)) })
		end
		local plan = MatchPlan.new(Modes.List.Normal, list)
		local planGap = strengthGap(list, function(id)
			return teamOf(plan, id)
		end)
		-- alternate by id, and alternate strongest-first
		local byRating = table.clone(list)
		table.sort(byRating, function(x, y)
			return x.rating > y.rating
		end)
		local rank = {}
		for i, e in byRating do
			rank[e.id] = i
		end
		local altId = strengthGap(list, function(id)
			return if id % 2 == 1 then "A" else "B"
		end)
		local altRank = strengthGap(list, function(id)
			return if rank[id] % 2 == 1 then "A" else "B"
		end)
		expect(
			planGap <= altId + 1e-6 and planGap <= altRank + 1e-6,
			string.format("gap %d vs %d / %d", planGap, altId, altRank)
		)
	end
	-- unrated: everyone counts the same, still within one
	local plan = MatchPlan.new(Modes.List.Mini, humans(4))
	local c = MatchPlan.counts(plan)
	expect(c.A.humans == 2 and c.B.humans == 2, "2 + 2 unrated")
end)

test("line(): one pick per point, repeated calls return the same line", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(10))
	local first = MatchPlan.line(plan, 1)
	local again = MatchPlan.line(plan, 1)
	expect(table.concat(first.A, ",") == table.concat(again.A, ","), "point 1 cached")
	local two = MatchPlan.line(plan, 2)
	local twoAgain = MatchPlan.line(plan, 2)
	expect(table.concat(two.B, ",") == table.concat(twoAgain.B, ","), "point 2 cached")
	expect(table.concat(two.A, ",") ~= table.concat(first.A, ","), "a bench rotates in at point 2")
end)

test("rotation is fair over many points: nobody sits twice while others play twice", function()
	for _, case in { { "Mini", 10 }, { "Mini", 9 }, { "Normal", 16 }, { "Normal", 15 } } do
		local rules = Modes.List[case[1]]
		local plan = MatchPlan.new(rules, humans(case[2], true))
		local played, streak, worst = {}, {}, {}
		local points = 24
		for p = 1, points do
			local line = MatchPlan.line(plan, p)
			for _, m in MatchPlan.members(plan) do
				local on = table.find(line[m.team], m.id) ~= nil
				played[m.id] = (played[m.id] or 0) + (if on then 1 else 0)
				streak[m.id] = if on then 0 else (streak[m.id] or 0) + 1
				worst[m.id] = math.max(worst[m.id] or 0, streak[m.id])
			end
		end
		local c = MatchPlan.counts(plan)
		for _, team in { "A", "B" } do
			local lo, hi = math.huge, -math.huge
			local maxStreak = math.ceil(c[team].bench / rules.TeamSize)
			for _, m in MatchPlan.members(plan) do
				if m.team == team then
					lo, hi = math.min(lo, played[m.id]), math.max(hi, played[m.id])
					expect(worst[m.id] <= maxStreak, case[1] .. ": sat out at most " .. maxStreak .. " in a row")
				end
			end
			expect(hi - lo <= 1, string.format("%s %d team %s: points played %d..%d", case[1], case[2], team, lo, hi))
		end
	end
end)

test("late joiner: team with fewer humans, Bench now, takes a bot's spot next point", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(3))
	applyBots(plan)
	local c = MatchPlan.counts(plan)
	local short = if c.A.humans < c.B.humans then "A" else "B"
	local team, role = MatchPlan.join(plan, { id = 50 })
	expect(team == short and role == "Bench", "joins the short side on the bench: " .. team)
	expect(table.find(MatchPlan.lineFor(plan, team), 50) == nil, "not on the field mid-point")
	local botsBefore = MatchPlan.counts(plan)[team].bots
	local line = MatchPlan.line(plan, 2)
	expect(table.find(line[team], 50) ~= nil, "on the line next point")
	local w = MatchPlan.botWork(plan)
	expect(#w.remove == 1 and w.spawn[team] == 0, "one bot leaves for the joiner")
	applyBots(plan)
	expect(MatchPlan.counts(plan)[team].bots == botsBefore - 1, "bot replaced")
	expect(#MatchPlan.lineFor(plan, team) == 3, "still exactly 3")
	local _, again = MatchPlan.join(plan, { id = 50 })
	expect(again == "Match", "joining twice keeps the slot")
end)

test("late joiner on a full team sits one point, then rotates in ahead of players who just played", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(6))
	local team, role = MatchPlan.join(plan, { id = 70 })
	expect(role == "Bench", "bench")
	local line = MatchPlan.line(plan, 2)
	expect(table.find(line[team], 70) ~= nil, "joiner plays point 2")
	expect(#line[team] == 3, "line still capped")
	expect(#MatchPlan.benchFor(plan, team) == 1, "someone else sits")
end)

test("a late joiner then rotates like everyone else (no catch-up either way)", function()
	for _, case in { { "Mini", 6, 12 }, { "Normal", 15, 16 } } do
		local plan = MatchPlan.new(Modes.List[case[1]], humans(case[2], true))
		for p = 1, 9 do
			MatchPlan.line(plan, p)
		end
		local team = MatchPlan.join(plan, { id = 900, rating = 1200 })
		local played = {}
		for p = 10, 9 + case[3] do
			local line = MatchPlan.line(plan, p)
			if p == 10 then
				expect(table.find(line[team], 900) ~= nil, case[1] .. ": joiner plays the next point")
			end
			for _, m in MatchPlan.members(plan) do
				if m.team == team then
					played[m.id] = (played[m.id] or 0) + (if table.find(line[team], m.id) then 1 else 0)
				end
			end
		end
		local lo, hi = math.huge, -math.huge
		for _, n in played do
			lo, hi = math.min(lo, n), math.max(hi, n)
		end
		expect(hi - lo <= 1, string.format("%s: points played since the join %d..%d", case[1], lo, hi))
	end
end)

test("equal head counts: a joiner goes to the weaker team", function()
	local list =
		{ { id = 1, rating = 1600 }, { id = 2, rating = 1000 }, { id = 3, rating = 1500 }, { id = 4, rating = 1200 } }
	local plan = MatchPlan.new(Modes.List.Mini, list)
	local sum = { A = 0, B = 0 }
	for _, m in MatchPlan.members(plan) do
		sum[m.team] += list[m.id].rating
	end
	local team = MatchPlan.join(plan, { id = 9, rating = 1000 })
	local weaker = if sum.A < sum.B then "A" elseif sum.B < sum.A then "B" else "A"
	expect(team == weaker, "joined " .. team .. " (A " .. sum.A .. ", B " .. sum.B .. ")")
end)

test("leaver on the field: a bot takes the spot at once", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(4))
	applyBots(plan)
	local victim = MatchPlan.line(plan, 1).A[1]
	local res = MatchPlan.leave(plan, victim)
	expect(res and res.team == "A" and res.wasOnLine and not res.rankedLoss, "leave result")
	local w = MatchPlan.botWork(plan)
	expect(w.spawn.A == 1 and #w.remove == 0, "spawn one bot for A")
	applyBots(plan)
	expect(#MatchPlan.lineFor(plan, "A") == 3, "A back to 3")
	expect(MatchPlan.slot(plan, victim) == nil, "gone")
	expect(MatchPlan.leave(plan, victim) == nil, "leaving twice is a no-op")
end)

test("leavers never leave the human counts two apart: a benched player switches", function()
	-- 8 humans in Mini: 4 + 4, one on each bench
	local plan = MatchPlan.new(Modes.List.Mini, humans(8))
	local B = MatchPlan.line(plan, 1).B
	MatchPlan.leave(plan, B[1])
	MatchPlan.leave(plan, B[2])
	local c = MatchPlan.counts(plan)
	expect(c.A.humans == 3 and c.B.humans == 3, string.format("rebalanced now: %d v %d", c.A.humans, c.B.humans))
	expect(c.A.line == 3, "A's line was not touched mid-point")
	local line = MatchPlan.line(plan, 2)
	expect(#line.A == 3 and #line.B == 3, "3 v 3 humans next point")
	expect(MatchPlan.counts(plan).B.botsWanted == 0, "B needs no bots any more")

	-- 4 humans: nobody on a bench, so the switch waits for the next point
	local p2 = MatchPlan.new(Modes.List.Mini, humans(4))
	local b2 = MatchPlan.line(p2, 1).B
	MatchPlan.leave(p2, b2[1])
	MatchPlan.leave(p2, b2[2])
	local c2 = MatchPlan.counts(p2)
	expect(c2.A.humans == 2 and c2.B.humans == 0, "nobody pulled off the field mid-point")
	MatchPlan.line(p2, 2)
	local c3 = MatchPlan.counts(p2)
	expect(c3.A.humans == 1 and c3.B.humans == 1, "1 v 1 humans at the next point")
	checkPlan(p2, Modes.List.Mini, 2, "after switch")
end)

test("line-up index follows lineFor; bench players have none", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(8))
	applyBots(plan)
	for _, team in { "A", "B" } do
		for i, id in MatchPlan.lineFor(plan, team) do
			local idx, count = MatchPlan.lineIndex(plan, id)
			expect(idx == i and count == 3, "index")
		end
		for _, id in MatchPlan.benchFor(plan, team) do
			expect(MatchPlan.lineIndex(plan, id) == nil, "bench has no spot")
		end
	end
	local _, bc = MatchPlan.lineIndex(plan, 12345)
	expect(bc == 0, "unknown actor")
end)

---------------------------------------------------------------------------
-- MatchPlan: ranked
---------------------------------------------------------------------------

test("ranked needs a public server, an eligible mode and all-human lines", function()
	for _, id in Modes.Order do
		local rules = Modes.List[id]
		local need = MatchPlan.rankedNeed(rules)
		expect(need == 2 * rules.TeamSize, "need")
		for n = 1, 16 do
			local ok = MatchPlan.rankedEligible(rules, n, PUBLIC)
			expect(ok == (n >= need), string.format("%s with %d humans: %s", id, n, tostring(ok)))
			if ok then
				local plan = MatchPlan.new(rules, humans(n), { ranked = true })
				local c = MatchPlan.counts(plan)
				expect(c.A.botsWanted == 0 and c.B.botsWanted == 0, "ranked lines have no bots")
				expect(c.A.line == rules.TeamSize and c.B.line == rules.TeamSize, "full lines")
			end
		end
		local full = need
		expect(not MatchPlan.rankedEligible(rules, full, { privateServer = true, studio = false }), "private")
		expect(not MatchPlan.rankedEligible(rules, full, { privateServer = false, studio = true }), "studio")
		local off = table.clone(rules)
		off.RankedEligible = false
		expect(not MatchPlan.rankedEligible(off, full, PUBLIC), "mode not eligible")
	end
	local _, why = MatchPlan.rankedEligible(Modes.List.Mini, 4, PUBLIC)
	expect(string.find(why, "4/6", 1, true) ~= nil, "reason shows progress: " .. why)
	expect(MatchPlan.rankedReady(Modes.List.Mini, 4) == "4/6", "ready string")
	expect(MatchPlan.rankedReady(Modes.List.Normal, 16) == "14/14", "ready string caps")
end)

test("ranked with substitutes can be switched off (exactly TeamSize humans each)", function()
	local saved = MatchPlan.RankedBench
	MatchPlan.RankedBench = false
	local ok, err = pcall(function()
		expect(MatchPlan.rankedEligible(Modes.List.Mini, 6, PUBLIC), "6 humans: ranked")
		expect(not MatchPlan.rankedEligible(Modes.List.Mini, 7, PUBLIC), "7 humans: a sub, unranked")
		expect(MatchPlan.rankedEligible(Modes.List.Normal, 14, PUBLIC), "14 humans: ranked")
	end)
	MatchPlan.RankedBench = saved
	if not ok then
		error(err)
	end
	expect(MatchPlan.rankedEligible(Modes.List.Mini, 7, PUBLIC), "default: subs allowed")
end)

test("ranked roster: a leaver takes a loss and voids the result; late joiners are not rated", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(6), { ranked = true })
	local r0 = MatchPlan.rankedResult(plan)
	local rosterSize = 0
	for _ in r0.roster do
		rosterSize += 1
	end
	expect(r0.ranked and r0.valid and rosterSize == 6, "valid at start")
	MatchPlan.join(plan, { id = 40 })
	local lj = MatchPlan.leave(plan, 40)
	expect(lj and not lj.rankedLoss, "late joiner is not on the roster")
	expect(MatchPlan.rankedResult(plan).valid, "still valid")
	local res = MatchPlan.leave(plan, 2)
	expect(res and res.rankedLoss, "roster leaver loses")
	local r1 = MatchPlan.rankedResult(plan)
	expect(r1.ranked and not r1.valid and r1.leavers[1] == 2, "voided for the rest")
	local casual = MatchPlan.new(Modes.List.Mini, humans(6))
	expect(not MatchPlan.rankedResult(casual).ranked, "unranked plan")
	expect(not MatchPlan.leave(casual, 1).rankedLoss, "no ranked loss when unranked")
end)

test("bots: botWork removes the newest surplus bots and addBot moves a re-registered id", function()
	local plan = MatchPlan.new(Modes.List.Mini, humans(1))
	applyBots(plan)
	local c = MatchPlan.counts(plan)
	expect(c.A.bots + c.B.bots == 5, "1 human + 5 bots")
	local botA = MatchPlan.lineFor(plan, "A")[2]
	expect(teamOf(plan, botA) == "A", "bot slot")
	MatchPlan.addBot(plan, "B", botA)
	expect(teamOf(plan, botA) == "B", "bot moved")
	local w = MatchPlan.botWork(plan)
	expect(#w.remove == 1 and w.spawn.A == 1, "B has one too many, A one too few")
	expect(w.remove[1] == botA, "newest surplus bot goes first")
	MatchPlan.removeBot(plan, 99999) -- unknown: no-op
end)

return nil
