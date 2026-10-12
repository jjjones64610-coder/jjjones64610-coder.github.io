local H = require("./harness")
local Rating = H.require("Rules/Rating")
local Rng = H.require("Util/Rng")
local Progression = H.require("Config/Progression")

local test, expect = H.test, H.expect

print("rating / progression / rng")

test("elo: beating a stronger team gains more than beating a weaker one", function()
	local up = Rating.update(1000, 20, 1000, 1200, true, 1) - 1000
	local down = Rating.update(1000, 20, 1000, 800, true, 1) - 1000
	expect(up > down and down > 0, string.format("up %d down %d", up, down))
	expect(Rating.update(1000, 20, 1000, 1000, false, 1) < 1000, "loss lowers rating")
end)

test("placement games move rating faster", function()
	local new = Rating.update(1000, 2, 1000, 1000, true, 0) - 1000
	local vet = Rating.update(1000, 50, 1000, 1000, true, 0) - 1000
	expect(new > vet, "placement K")
end)

test("level math round-trips", function()
	local total = 0
	for lvl = 1, 9 do
		total += Progression.xpForLevel(lvl)
	end
	local level, into = Rating.levelFromXp(total + 10)
	expect(level == 10 and into == 10, "level " .. level .. " into " .. into)
end)

test("team balance keeps sizes equal and totals close", function()
	local entries = {}
	local ratings = { 1500, 1400, 1300, 1200, 1100, 1000, 900 }
	for i, r in ratings do
		table.insert(entries, { id = i, rating = r })
	end
	local a, b = Rating.balance(entries)
	expect(math.abs(#a - #b) <= 1, "sizes")
	local function sum(t)
		local s = 0
		for _, id in t do
			s += ratings[id]
		end
		return s / #t
	end
	expect(math.abs(sum(a) - sum(b)) < 120, string.format("avg %d vs %d", sum(a), sum(b)))
end)

-- Strength gap as Rating.balance defines it: totals, the short side's empty
-- spot counted as `filler` (default: the average rating).
local function gapOf(entries, a, b, filler)
	local byId, mean = {}, 0
	for _, e in entries do
		byId[e.id] = e.rating or Progression.Rating.Start
		mean += byId[e.id] / #entries
	end
	local fill = filler or mean
	local sa, sb = 0, 0
	for _, id in a do
		sa += byId[id]
	end
	for _, id in b do
		sb += byId[id]
	end
	local size = math.max(#a, #b)
	return math.abs((sa + (size - #a) * fill) - (sb + (size - #b) * fill))
end

local function bruteBest(entries, filler)
	local n = #entries
	local best = math.huge
	for mask = 0, bit32.lshift(1, n) - 1 do
		local a, b = {}, {}
		for i, e in entries do
			table.insert(if bit32.btest(mask, bit32.lshift(1, i - 1)) then a else b, e.id)
		end
		if #a == math.ceil(n / 2) then
			best = math.min(best, gapOf(entries, a, b, filler))
		end
	end
	return best
end

local function randomEntries(rng, n)
	local entries = {}
	for i = 1, n do
		table.insert(entries, { id = i * 3, rating = math.floor(rng:range(600, 2200)) })
	end
	return entries
end

test("team balance finds the closest possible split for normal lobby sizes", function()
	local rng = Rng.new(3)
	for _ = 1, 80 do
		local entries = randomEntries(rng, rng:int(1, 11))
		local a, b = Rating.balance(entries)
		expect(#a + #b == #entries and #a >= #b and #a - #b <= 1, "sizes")
		local g, best = gapOf(entries, a, b), bruteBest(entries)
		expect(g <= best + 1e-6, string.format("gap %.1f vs best %.1f", g, best))
	end
end)

test("team balance beyond the exact limit stays close to the best split", function()
	local rng = Rng.new(8)
	local limit = Rating.ExactBalanceLimit
	Rating.ExactBalanceLimit = 0
	local ok, err = pcall(function()
		local excess, trials = 0, 60
		for _ = 1, trials do
			local entries = randomEntries(rng, rng:int(2, 11))
			local a, b = Rating.balance(entries)
			expect(#a + #b == #entries and #a >= #b and #a - #b <= 1, "sizes")
			-- never worse than alternating strongest-first
			local sorted = table.clone(entries)
			table.sort(sorted, function(x, y)
				if x.rating ~= y.rating then
					return x.rating > y.rating
				end
				return x.id < y.id
			end)
			local altA, altB = {}, {}
			for i, e in sorted do
				table.insert(if i % 2 == 1 then altA else altB, e.id)
			end
			local g = gapOf(entries, a, b)
			expect(g <= gapOf(entries, altA, altB) + 1e-6, "beats alternation")
			local spread = sorted[1].rating - sorted[#sorted].rating
			excess += (g - bruteBest(entries)) / math.max(1, spread)
		end
		expect(excess / trials < 0.05, string.format("average excess %.3f of the spread", excess / trials))
	end)
	Rating.ExactBalanceLimit = limit
	if not ok then
		error(err)
	end
end)

test("team balance: unrated players count as the starting rating; results are deterministic", function()
	local unrated = {}
	for i = 1, 7 do
		table.insert(unrated, { id = i })
	end
	local a, b = Rating.balance(unrated)
	expect(#a == 4 and #b == 3, "4 + 3")
	local a2, b2 = Rating.balance(unrated)
	expect(
		table.concat(a, ",") == table.concat(a2, ",") and table.concat(b, ",") == table.concat(b2, ","),
		"same twice"
	)
	expect(Rating.ratingOf({ id = 1 }) == Progression.Rating.Start, "unrated rating")
	local x, y = Rating.balance({})
	expect(#x == 0 and #y == 0, "empty lobby")
end)

test("team balance: a weak filler puts stronger players on the short side", function()
	local entries = { { id = 1, rating = 1600 }, { id = 2, rating = 1000 }, { id = 3, rating = 1000 } }
	-- the short team plays with a weak bot, so it gets the strongest human
	local a, b = Rating.balance(entries, 400)
	expect(#a == 2 and #b == 1 and b[1] == 1, "short side gets the 1600")
	expect(gapOf(entries, a, b, 400) <= bruteBest(entries, 400) + 1e-6, "optimal with filler")
end)

test("rng is deterministic and in range", function()
	local a, b = Rng.new(42), Rng.new(42)
	for _ = 1, 1000 do
		local x = a:next()
		expect(x == b:next() and x >= 0 and x < 1, "rng")
	end
	local r = Rng.new(7)
	for _ = 1, 1000 do
		local n = r:int(1, 6)
		expect(n >= 1 and n <= 6, "int range")
	end
end)

test("divisions cover every rating", function()
	expect(Progression.division(0).name == "Bronze", "bronze")
	expect(Progression.division(1350).name == "Platinum", "platinum")
	expect(Progression.division(2500).name == "Breakpoint", "top")
end)

return nil
