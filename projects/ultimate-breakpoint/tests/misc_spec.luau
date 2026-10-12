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
