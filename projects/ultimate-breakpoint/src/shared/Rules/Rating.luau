--!strict
-- Team Elo for ranked matches, level math for progression and rating-balanced
-- team splits (used by Rules/MatchPlan for every match, ranked or not). Pure.

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

export type Entry = { id: number, rating: number? }

-- An entry's rating; unrated players count as the starting rating.
function Rating.ratingOf(e: Entry): number
	return e.rating or Progression.Rating.Start
end

local ratingOf = Rating.ratingOf

-- Lobbies up to this many players are split by trying every split (a
-- Gray-code walk: one add or remove per step, 65k steps at 16 players);
-- bigger lobbies use refined greedy / alternating splits.
Rating.ExactBalanceLimit = 16

-- Single swaps across the teams while any swap narrows the gap. `r` is
-- sorted strongest first; `inA` is changed in place.
local function refine(r: { number }, inA: { boolean }, gap: (number, number) -> number): number
	local sumA, sumB = 0, 0
	for i, v in r do
		if inA[i] then
			sumA += v
		else
			sumB += v
		end
	end
	for _ = 1, #r * #r do
		local best = gap(sumA, sumB)
		local bi, bj = 0, 0
		for i, x in r do
			if inA[i] then
				for j, y in r do
					if not inA[j] then
						local g = gap(sumA + y - x, sumB - y + x)
						if g < best - 1e-9 then
							best, bi, bj = g, i, j
						end
					end
				end
			end
		end
		if bi == 0 then
			break
		end
		inA[bi], inA[bj] = false, true
		local d = r[bj] - r[bi]
		sumA += d
		sumB -= d
	end
	return gap(sumA, sumB)
end

-- Two starting splits, each refined by swaps; the closer one wins. Start 1:
-- strongest first, each to the team with the lower total that still has
-- room. Start 2: strongest first, alternating. The first team always gets
-- the extra player when the count is odd.
local function approximateSplit(r: { number }, cap: number, gap: (number, number) -> number): { boolean }
	local greedy: { boolean } = {}
	local countA, countB, sumA, sumB = 0, 0, 0, 0
	for i, v in r do
		local toA = if countA >= cap then false elseif countB >= cap then true else sumA <= sumB
		greedy[i] = toA
		if toA then
			countA += 1
			sumA += v
		else
			countB += 1
			sumB += v
		end
	end
	if countB > countA then
		for i in greedy do
			greedy[i] = not greedy[i]
		end
	end
	local alternate: { boolean } = {}
	for i in r do
		alternate[i] = i % 2 == 1
	end
	local g1 = refine(r, greedy, gap)
	local g2 = refine(r, alternate, gap)
	return if g2 < g1 - 1e-9 then alternate else greedy
end

-- Splits players into two teams whose sizes differ by at most one, with the
-- closest strength. Unrated entries count as Progression.Rating.Start.
--
-- Strength is the rating total plus `filler` for each spot the smaller team
-- is short (the bot or empty spot it plays with instead); `filler` defaults to
-- the average rating, so an odd player out is weighed as an average player.
--
-- Exact (the best possible split) up to ExactBalanceLimit players, close
-- beyond that. Deterministic: entries are ordered by rating, then id. The
-- first team returned is never the smaller one.
function Rating.balance(entries: { Entry }, filler: number?): ({ number }, { number })
	local sorted = table.clone(entries)
	table.sort(sorted, function(x, y)
		local rx, ry = ratingOf(x), ratingOf(y)
		if rx ~= ry then
			return rx > ry
		end
		return x.id < y.id
	end)
	local n = #sorted
	local cap = math.ceil(n / 2)
	local r: { number } = {}
	local total = 0
	for i, e in sorted do
		r[i] = ratingOf(e)
		total += r[i]
	end
	local fill = filler or (if n > 0 then total / n else Progression.Rating.Start)
	local short = cap - (n - cap) -- spots the second team is short: 0 or 1
	local function gap(sa: number, sb: number): number
		return math.abs(sa - (sb + short * fill))
	end

	local inA: { boolean }
	if n <= Rating.ExactBalanceLimit then
		local bestGap, bestMask = math.huge, 0
		local mask, countA, sumA = 0, 0, 0
		for step = 1, bit32.lshift(1, n) - 1 do
			local bit = bit32.countrz(step)
			local flag = bit32.lshift(1, bit)
			if bit32.btest(mask, flag) then
				mask -= flag
				countA -= 1
				sumA -= r[bit + 1]
			else
				mask += flag
				countA += 1
				sumA += r[bit + 1]
			end
			if countA == cap then
				local g = gap(sumA, total - sumA)
				if g < bestGap - 1e-9 then
					bestGap, bestMask = g, mask
				end
			end
		end
		inA = {}
		for i = 1, n do
			inA[i] = bit32.btest(bestMask, bit32.lshift(1, i - 1))
		end
	else
		inA = approximateSplit(r, cap, gap)
	end

	local idsA, idsB = {}, {}
	for i, e in sorted do
		table.insert(if inA[i] then idsA else idsB, e.id)
	end
	return idsA, idsB
end

return Rating
