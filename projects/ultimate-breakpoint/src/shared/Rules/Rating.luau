--!strict
-- Team Elo for ranked matches and level math for progression. Pure.

local Shared = script.Parent.Parent
local Progression = require(Shared.Config.Progression)

local Rating = {}

function Rating.expected(ra: number, rb: number): number
	return 1 / (1 + 10 ^ ((rb - ra) / 400))
end

function Rating.teamRating(ratings: { number }): number
	if #ratings == 0 then
		return Progression.Rating.Start
	end
	local sum = 0
	for _, r in ratings do
		sum += r
	end
	return sum / #ratings
end

-- New rating for one player after a match. `won` is true/false.
-- A modest margin factor (1.0 .. 1.25) rewards decisive wins without making
-- blowouts the only way to climb.
function Rating.update(
	rating: number,
	gamesPlayed: number,
	myTeam: number,
	theirTeam: number,
	won: boolean,
	margin: number
): number
	local k = if gamesPlayed < Progression.Rating.PlacementGames then Progression.Rating.KNew else Progression.Rating.K
	local e = Rating.expected(myTeam, theirTeam)
	local s = if won then 1 else 0
	local marginFactor = 1 + math.clamp(margin, 0, 5) * 0.05
	return math.floor(rating + k * marginFactor * (s - e) + 0.5)
end

-- (level, xpIntoLevel, xpForThisLevel) from total XP.
function Rating.levelFromXp(totalXp: number): (number, number, number)
	local level = 1
	local remaining = math.max(0, totalXp)
	while level < Progression.MaxLevel do
		local need = Progression.xpForLevel(level)
		if remaining < need then
			return level, remaining, need
		end
		remaining -= need
		level += 1
	end
	return Progression.MaxLevel, 0, Progression.xpForLevel(Progression.MaxLevel)
end

-- Splits players into two teams of equal size (+-1) with the closest total
-- rating: strongest first, each to the team with the lower total that still
-- has room.
function Rating.balance(entries: { { id: number, rating: number } }): ({ number }, { number })
	local sorted = table.clone(entries)
	table.sort(sorted, function(x, y)
		return x.rating > y.rating
	end)
	local cap = math.ceil(#sorted / 2)
	local a, b = {}, {}
	local sumA, sumB = 0, 0
	for _, e in sorted do
		local toA: boolean
		if #a >= cap then
			toA = false
		elseif #b >= cap then
			toA = true
		else
			toA = sumA <= sumB
		end
		if toA then
			table.insert(a, e.id)
			sumA += e.rating
		else
			table.insert(b, e.id)
			sumB += e.rating
		end
	end
	return a, b
end

return Rating
