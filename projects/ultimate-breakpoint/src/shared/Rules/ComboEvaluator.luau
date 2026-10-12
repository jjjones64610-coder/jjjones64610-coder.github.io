--!strict
--[[
	ComboEvaluator — scores movement chains so that difficulty, variety and
	timing matter and spam does not.

	  event score  = base(tech) * quality * variety
	                 quality: Perfect 1.5, Clean 1.0, Sloppy 0.5, Gassed 0.3
	                 variety: same as previous 0.25, in last three 0.6, new 1.0
	  chain score  = sum(event scores) * length bonus * unique bonus
	                 length bonus  1 + 0.2 per extra scoring tech (max x3)
	                 unique bonus  1 + 0.08 per distinct tech beyond the first (max x1.4)

	A chain ends after ChainWindow seconds without a technique. Chains only
	pay out (XP, highlights) when CONVERTED into a play — a catch, an
	interception, a block — during the chain or within ConvertWindow after it.
	Pure movement spam shows labels on screen and nothing else.
]]

local Shared = script.Parent.Parent
local MovementConfig = require(Shared.Config.Movement)

local ComboEvaluator = {}

ComboEvaluator.ChainWindow = MovementConfig.ChainWindow
ComboEvaluator.ConvertWindow = 1.25

local QUALITY_MULT: { [string]: number } = {
	Perfect = 1.5,
	Clean = 1.0,
	Sloppy = 0.5,
	Gassed = 0.3,
}

ComboEvaluator.Tiers = {
	{ min = 2600, name = "BREAKPOINT" },
	{ min = 1600, name = "FILTHY" },
	{ min = 900, name = "SLICK" },
	{ min = 400, name = "NICE" },
}

export type Entry = {
	tech: string,
	quality: string,
	t: number,
	score: number,
}

export type Chain = {
	entries: { Entry },
	raw: number,
	scoring: number,
	unique: { [string]: boolean },
	uniqueCount: number,
	startT: number,
	lastT: number,
}

export type Summary = {
	score: number,
	length: number,
	uniqueCount: number,
	techs: { string },
	tier: string?,
	perfects: number,
	converted: boolean,
	payoff: string?,
}

export type Tracker = {
	chain: Chain?,
	lastFinished: Summary?,
	lastFinishedAt: number,
}

function ComboEvaluator.newTracker(): Tracker
	return { chain = nil, lastFinished = nil, lastFinishedAt = -math.huge }
end

local function newChain(t: number): Chain
	return { entries = {}, raw = 0, scoring = 0, unique = {}, uniqueCount = 0, startT = t, lastT = t }
end

function ComboEvaluator.total(c: Chain): number
	local lengthBonus = math.min(3, 1 + 0.2 * math.max(0, c.scoring - 1))
	local uniqueBonus = math.min(1.4, 1 + 0.08 * math.max(0, c.uniqueCount - 1))
	return math.floor(c.raw * lengthBonus * uniqueBonus + 0.5)
end

function ComboEvaluator.tier(score: number): string?
	for _, t in ComboEvaluator.Tiers do
		if score >= t.min then
			return t.name
		end
	end
	return nil
end

local function summarize(c: Chain, converted: boolean, payoff: string?): Summary
	local techs = {}
	local perfects = 0
	for _, e in c.entries do
		table.insert(techs, e.tech)
		if e.quality == "Perfect" then
			perfects += 1
		end
	end
	local score = ComboEvaluator.total(c)
	if converted then
		score *= 2
	end
	return {
		score = score,
		length = c.scoring,
		uniqueCount = c.uniqueCount,
		techs = techs,
		tier = ComboEvaluator.tier(score),
		perfects = perfects,
		converted = converted,
		payoff = payoff,
	}
end

-- Closes the active chain if it has timed out. Returns its summary.
function ComboEvaluator.expire(tr: Tracker, now: number): Summary?
	local c = tr.chain
	if c and now - c.lastT > ComboEvaluator.ChainWindow then
		tr.chain = nil
		local s = summarize(c, false, nil)
		tr.lastFinished = s
		tr.lastFinishedAt = c.lastT
		return s
	end
	return nil
end

-- Adds a technique; returns the points it added (before chain bonuses) and
-- the chain's running total.
function ComboEvaluator.add(tr: Tracker, tech: string, quality: string, t: number): (number, number)
	ComboEvaluator.expire(tr, t)
	local c = tr.chain
	if c == nil then
		c = newChain(t)
		tr.chain = c
	end
	local chain = c :: Chain
	local base = (MovementConfig.ComboPoints :: any)[tech] or 0
	local variety = 1.0
	local n = #chain.entries
	if base > 0 then
		local lastScoring: Entry? = nil
		local recent = 0
		for i = n, 1, -1 do
			local e = chain.entries[i]
			if ((MovementConfig.ComboPoints :: any)[e.tech] or 0) > 0 then
				if lastScoring == nil then
					lastScoring = e
				end
				recent += 1
				if e.tech == tech and recent <= 3 and variety > 0.6 then
					variety = 0.6
				end
				if recent >= 3 then
					break
				end
			end
		end
		if lastScoring and lastScoring.tech == tech then
			variety = 0.25
		end
	end
	local score = base * (QUALITY_MULT[quality] or 1) * variety
	table.insert(chain.entries, { tech = tech, quality = quality, t = t, score = score })
	if base > 0 then
		chain.scoring += 1
		if not chain.unique[tech] then
			chain.unique[tech] = true
			chain.uniqueCount += 1
		end
	end
	chain.raw += score
	chain.lastT = t
	return score, ComboEvaluator.total(chain)
end

-- A meaningful play happened (catch, interception, block). Converts the active
-- chain, or one that ended within ConvertWindow. Returns the summary or nil.
function ComboEvaluator.convert(tr: Tracker, now: number, payoff: string): Summary?
	local c = tr.chain
	if c and now - c.lastT <= ComboEvaluator.ConvertWindow and c.scoring > 0 then
		tr.chain = nil
		local s = summarize(c, true, payoff)
		tr.lastFinished = s
		tr.lastFinishedAt = now
		return s
	end
	local last = tr.lastFinished
	if c == nil and last and not last.converted and now - tr.lastFinishedAt <= ComboEvaluator.ConvertWindow then
		last.converted = true
		last.payoff = payoff
		last.score *= 2
		last.tier = ComboEvaluator.tier(last.score)
		return last
	end
	return nil
end

function ComboEvaluator.active(tr: Tracker, now: number): Chain?
	local c = tr.chain
	if c and now - c.lastT <= ComboEvaluator.ChainWindow then
		return c
	end
	return nil
end

return ComboEvaluator
