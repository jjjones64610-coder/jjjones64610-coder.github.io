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

	A chain is visible from its first technique and ends after ChainWindow
	(1.5 s) without one; expire() then returns its end-of-chain summary
	{ count, total, tier, techs, ... } for the HUD card. Payout:
	  * CONVERTED into a play (catch, interception, block) during the chain or
	    within ConvertWindow (2.0 s) after it: x2 score, XP and highlights.
	  * Not converted: 25 % of its score as XP. settle() hands each such chain
	    to the server exactly once, after it can no longer be converted.
	Summary.xpScore is the score XP should be computed from in either case.

	The thrower's "Break" link (fake -> swing -> release) is scored by the throw
	path: release() adds it when the chain's last technique is a Sold
	PivotSwing that finished within BreakWindow of the release.
]]

local Shared = script.Parent.Parent
local MovementConfig = require(Shared.Config.Movement)

local ComboEvaluator = {}

ComboEvaluator.ChainWindow = MovementConfig.ChainWindow
ComboEvaluator.ConvertWindow = 2.0
ComboEvaluator.UnconvertedShare = 0.25 -- an unconverted chain pays this share of its score as XP
ComboEvaluator.ConvertedMult = 2
-- Break: release within this long after a Sold swing finishes (Perfect if
-- within half of it).
ComboEvaluator.BreakWindow = 0.3

local MAX_UNSETTLED = 16

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
	-- end-of-chain card
	count: number, -- scoring techniques in the chain
	total: number, -- chain score before any conversion bonus
	tier: string?, -- tier of `score`
	techs: { string },
	-- payout
	score: number, -- total, x2 once converted
	xpScore: number, -- score XP is computed from (converted: score; else 25 % of total)
	converted: boolean,
	payoff: string?,
	-- detail
	length: number, -- (same as count; kept for older readers)
	uniqueCount: number,
	perfects: number,
	startT: number,
	endT: number,
}

export type Tracker = {
	chain: Chain?,
	lastFinished: Summary?,
	lastFinishedAt: number,
	settled: { [Summary]: boolean },
	unsettled: { Summary },
}

local function points(tech: string): number
	return (MovementConfig.ComboPoints :: any)[tech] or 0
end

function ComboEvaluator.newTracker(): Tracker
	return { chain = nil, lastFinished = nil, lastFinishedAt = -math.huge, settled = {}, unsettled = {} }
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

local function applyPayout(s: Summary)
	s.score = if s.converted then s.total * ComboEvaluator.ConvertedMult else s.total
	s.xpScore = if s.converted then s.score else math.floor(s.total * ComboEvaluator.UnconvertedShare)
	s.tier = ComboEvaluator.tier(s.score)
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
	local s: Summary = {
		count = c.scoring,
		total = ComboEvaluator.total(c),
		tier = nil,
		techs = techs,
		score = 0,
		xpScore = 0,
		converted = converted,
		payoff = payoff,
		length = c.scoring,
		uniqueCount = c.uniqueCount,
		perfects = perfects,
		startT = c.startT,
		endT = c.lastT,
	}
	applyPayout(s)
	return s
end

-- Remembers a finished, unconverted chain so settle() can pay its share once.
local function remember(tr: Tracker, s: Summary, at: number)
	local prev = tr.lastFinished
	if prev and not prev.converted and not tr.settled[prev] then
		-- a newer chain replaces it: it can no longer be converted
		table.insert(tr.unsettled, prev)
		if #tr.unsettled > MAX_UNSETTLED then
			-- (a tracker nobody settles, e.g. the client's, stays small)
			table.remove(tr.unsettled, 1)
		end
	end
	tr.lastFinished = s
	tr.lastFinishedAt = at
end

-- Closes the active chain if it has timed out. Returns its end-of-chain
-- summary (unconverted) once, on the call that ends it.
function ComboEvaluator.expire(tr: Tracker, now: number): Summary?
	local c = tr.chain
	if c and now - c.lastT > ComboEvaluator.ChainWindow then
		tr.chain = nil
		if c.scoring <= 0 then
			return nil
		end
		local s = summarize(c, false, nil)
		remember(tr, s, c.lastT)
		return s
	end
	return nil
end

-- Unconverted chains that can no longer be converted, each returned exactly
-- once (the server pays their UnconvertedShare XP from Summary.xpScore).
function ComboEvaluator.settle(tr: Tracker, now: number): { Summary }
	ComboEvaluator.expire(tr, now)
	local out = tr.unsettled
	tr.unsettled = {}
	local last = tr.lastFinished
	if
		last
		and not last.converted
		and not tr.settled[last]
		and (tr.chain ~= nil or now - tr.lastFinishedAt > ComboEvaluator.ConvertWindow)
	then
		table.insert(out, last)
	end
	for _, s in out do
		tr.settled[s] = true
	end
	if last and tr.settled[last] then
		-- keep the set small: only the latest summary can still be looked up
		tr.settled = { [last] = true }
	else
		tr.settled = {}
	end
	return out
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
	local base = points(tech)
	local variety = 1.0
	local n = #chain.entries
	if base > 0 then
		local lastScoring: Entry? = nil
		local recent = 0
		for i = n, 1, -1 do
			local e = chain.entries[i]
			if points(e.tech) > 0 then
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

-- The Break link quality for a release at time t, or nil: the chain's last
-- technique must be a Sold (Perfect) PivotSwing that finished at most
-- BreakWindow before the release.
function ComboEvaluator.breakQuality(tr: Tracker, t: number): string?
	local c = ComboEvaluator.active(tr, t)
	if c == nil then
		return nil
	end
	local last = c.entries[#c.entries]
	if last == nil or last.tech ~= "PivotSwing" or last.quality ~= "Perfect" then
		return nil
	end
	local after = t - (last.t + MovementConfig.Holding.SwingTime)
	if after > ComboEvaluator.BreakWindow then
		return nil
	end
	return if after <= ComboEvaluator.BreakWindow * 0.5 then "Perfect" else "Clean"
end

-- Called by the throw path at release. Adds the "Break" link when the release
-- follows a Sold swing (fake -> swing -> release); returns its points and the
-- chain total, or nil. (The throw path may also add "Break" itself.)
function ComboEvaluator.release(tr: Tracker, t: number): (number?, number?)
	local q = ComboEvaluator.breakQuality(tr, t)
	if q == nil then
		return nil, nil
	end
	return ComboEvaluator.add(tr, "Break", q, t)
end

-- A meaningful play happened (catch, interception, block). Converts the active
-- chain, or one that ended within ConvertWindow. Returns the summary or nil.
function ComboEvaluator.convert(tr: Tracker, now: number, payoff: string): Summary?
	local c = tr.chain
	if c and now - c.lastT <= ComboEvaluator.ConvertWindow and c.scoring > 0 then
		tr.chain = nil
		local s = summarize(c, true, payoff)
		remember(tr, s, now)
		return s
	end
	local last = tr.lastFinished
	if
		c == nil
		and last
		and not last.converted
		and not tr.settled[last]
		and now - tr.lastFinishedAt <= ComboEvaluator.ConvertWindow
	then
		last.converted = true
		last.payoff = payoff
		applyPayout(last)
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

-- Fraction of the chain window left (1 = a technique just landed, 0 = no
-- chain), for the HUD's draining bar.
function ComboEvaluator.windowLeft(tr: Tracker, now: number): number
	local c = ComboEvaluator.active(tr, now)
	if c == nil then
		return 0
	end
	return math.clamp(1 - (now - c.lastT) / ComboEvaluator.ChainWindow, 0, 1)
end

return ComboEvaluator
