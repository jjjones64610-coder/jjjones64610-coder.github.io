--!strict
--[[
	MatchPlan — who plays for which team, and who is on the field each point.

	Pure bookkeeping over actor ids (numbers), so the team rules can be unit
	tested (tests/modes_spec.luau). TeamService owns the actual actors: it
	calls these functions, then makes the world match the plan (sets each
	human's team and role, spawns or removes bots, teleports the lines).

	Rules:
	  - Teams: every human is split with Rating.balance (rating as a skill
	    proxy, unrated players count as the starting rating), so the human
	    counts differ by at most one and the strengths are close. The counts
	    stay within one for the whole match: when a leaver breaks that, a
	    benched player switches team at once, otherwise someone switches at
	    the next point.
	  - The line: at most TeamSize humans per team are on the field (role
	    "Match"); the rest are role "Bench". At each point setup the humans who
	    have sat out the most points in a row go first, then those who have
	    sat out the most points in total, then the earliest arrivals, so
	    everyone plays an equal share. With FillWithBots the empty spots go to
	    bots, so the field is always exactly TeamSize v TeamSize; with an odd
	    number of humans the side with fewer humans gets the extra bot.
	  - Late joiner: goes to the team with fewer humans (tie: the weaker team,
	    then A) as Bench, and is picked at the next point setup ahead of anyone
	    who has just played, taking a bot's spot when the team has one. From
	    then on they rotate as if they had been there all along.
	  - Leaver: removed at once; when they were on the field a bot takes their
	    spot straight away (FillWithBots), so the point is not played short.
	  - Ranked: the mode must be RankedEligible, the server public (not a
	    private server, not Studio) and both lines all human at the start: at
	    least 2 x TeamSize humans, no bots (substitutes allowed while
	    MatchPlan.RankedBench is true). The ranked roster is recorded at the
	    start; a roster player who leaves takes a loss and the result is void
	    for everyone else (rankedResult).

	Bots are tracked by id once TeamService has spawned them (addBot /
	removeBot); botWork says how many to spawn and which to remove.

	Typical use (TeamService):
	  match start  plan = MatchPlan.new(mode, entries, { ranked = ranked }); apply
	  point setup  MatchPlan.line(plan, engine.pointNumber); apply; line up
	               MatchPlan.lineFor(plan, team), seat MatchPlan.benchFor(plan, team)
	  join / leave MatchPlan.join(plan, entry) / MatchPlan.leave(plan, id); apply
	  apply        set every MatchPlan.members(plan) entry's team and role, then
	               do MatchPlan.botWork(plan) (removeBot / addBot as it goes)
]]

local Rating = require(script.Parent.Rating)

local MatchPlan = {}

-- Ranked may have substitutes (more than TeamSize humans on a team) as long
-- as both lines are all human. Set false to require exactly TeamSize each.
MatchPlan.RankedBench = true

-- Which half of the -Z sideline each team's bench is on (FieldGeometry.benchSpots).
MatchPlan.BenchSign = { A = -1, B = 1 }

export type Team = string -- "A" | "B"
export type Role = string -- "Match" | "Bench"

-- Any ModeRules satisfies this.
export type Rules = {
	TeamSize: number,
	FillWithBots: boolean,
}

export type Entry = { id: number, rating: number? }

export type Member = {
	id: number,
	team: Team,
	rating: number,
	seq: number, -- arrival order, lower = earlier
	played: number, -- points picked for the line
	sat: number, -- points sat out on the bench
	lastOn: number, -- last point on the line (0 = none yet)
	onLine: boolean, -- on the field for the current point
}

export type TeamPlan = {
	humans: { number }, -- roster in arrival order (line and bench)
	line: { number }, -- humans on the field this point, in line-up order
	bots: { number }, -- bots on this team, in the order they were added
}

export type Plan = {
	teamSize: number,
	fillWithBots: boolean,
	point: number, -- the point the current line was picked for
	seq: number,
	members: { [number]: Member },
	teams: { [string]: TeamPlan },
	botTeam: { [number]: Team },
	ranked: boolean,
	roster: { [number]: Team }, -- ranked roster at the start (empty when unranked)
	leavers: { number }, -- ranked roster players who left
}

export type Options = {
	ranked: boolean?,
}

export type BotWork = {
	spawn: { [string]: number }, -- bots to spawn per team ("A"/"B")
	remove: { number }, -- bot ids to remove
}

export type TeamCounts = {
	humans: number, -- on the roster (line + bench)
	line: number, -- humans on the field this point
	bench: number,
	bots: number, -- bots registered with addBot
	botsWanted: number, -- bots the line needs (FillWithBots)
}

export type LeaveResult = {
	team: Team,
	wasOnLine: boolean,
	rankedLoss: boolean, -- a ranked roster player left: rate them as a loss
}

export type RankedEnv = {
	privateServer: boolean,
	studio: boolean,
}

export type RankedResult = {
	ranked: boolean, -- the match started as ranked
	valid: boolean, -- ranked and nobody on the roster left
	roster: { [number]: Team },
	leavers: { number },
}

local TEAMS = { "A", "B" }

function MatchPlan.other(team: Team): Team
	return if team == "A" then "B" else "A"
end

local function insertBySeq(plan: Plan, list: { number }, id: number)
	local seq = plan.members[id].seq
	for i, other in list do
		if plan.members[other].seq > seq then
			table.insert(list, i, id)
			return
		end
	end
	table.insert(list, id)
end

local function removeValue(list: { number }, id: number): boolean
	local i = table.find(list, id)
	if i then
		table.remove(list, i)
		return true
	end
	return false
end

local function ratingSum(plan: Plan, team: Team): number
	local sum = 0
	for _, id in plan.teams[team].humans do
		sum += plan.members[id].rating
	end
	return sum
end

local function addMember(plan: Plan, entry: Entry, team: Team, lastOn: number, sat: number): Member
	plan.seq += 1
	local m: Member = {
		id = entry.id,
		team = team,
		rating = Rating.ratingOf(entry),
		seq = plan.seq,
		played = 0,
		sat = sat,
		lastOn = lastOn,
		onLine = false,
	}
	plan.members[entry.id] = m
	insertBySeq(plan, plan.teams[team].humans, entry.id)
	return m
end

-- Moves one human from `from` to the other team. Prefers players who are not
-- on the field right now (`benchOnly` allows nobody else); among those, the
-- one that leaves the rating totals closest, then the latest arrival.
local function moveOne(plan: Plan, from: Team, benchOnly: boolean): boolean
	local to = MatchPlan.other(from)
	local target = (ratingSum(plan, from) - ratingSum(plan, to)) / 2
	local best: Member? = nil
	local bestScore = math.huge
	for _, id in plan.teams[from].humans do
		local m = plan.members[id]
		if not (benchOnly and m.onLine) then
			local score = math.abs(m.rating - target) + (if m.onLine then 1e6 else 0)
			if best == nil or score < bestScore or (score == bestScore and m.seq > best.seq) then
				best, bestScore = m, score
			end
		end
	end
	if best == nil then
		return false
	end
	local m = best :: Member
	removeValue(plan.teams[from].humans, m.id)
	removeValue(plan.teams[from].line, m.id)
	m.onLine = false
	m.team = to
	insertBySeq(plan, plan.teams[to].humans, m.id)
	return true
end

-- Keeps the human counts within one of each other.
local function rebalance(plan: Plan, benchOnly: boolean)
	for _ = 1, 32 do
		local a, b = #plan.teams.A.humans, #plan.teams.B.humans
		if math.abs(a - b) <= 1 then
			return
		end
		if not moveOne(plan, if a > b then "A" else "B", benchOnly) then
			return
		end
	end
end

local function pick(plan: Plan, point: number)
	rebalance(plan, false)
	plan.point = point
	for _, team in TEAMS do
		local tp = plan.teams[team]
		local order = table.clone(tp.humans)
		table.sort(order, function(x, y)
			local mx, my = plan.members[x], plan.members[y]
			-- points sat out in a row, then points sat out in total
			local sx, sy = point - 1 - mx.lastOn, point - 1 - my.lastOn
			if sx ~= sy then
				return sx > sy
			end
			if mx.sat ~= my.sat then
				return mx.sat > my.sat
			end
			return mx.seq < my.seq
		end)
		local line = {}
		for i, id in order do
			local m = plan.members[id]
			m.onLine = i <= plan.teamSize
			if m.onLine then
				m.lastOn = point
				m.played += 1
				insertBySeq(plan, line, id)
			else
				m.sat += 1
			end
		end
		tp.line = line
	end
end

-- A new plan for a match. `humans` are every non-training human; the line for
-- point 1 is picked straight away (MatchPlan.line(plan, 1) returns it).
function MatchPlan.new(rules: Rules, humans: { Entry }, opts: Options?): Plan
	local plan: Plan = {
		teamSize = math.max(1, math.floor(rules.TeamSize)),
		fillWithBots = rules.FillWithBots,
		point = 0,
		seq = 0,
		members = {},
		teams = {
			A = { humans = {}, line = {}, bots = {} },
			B = { humans = {}, line = {}, bots = {} },
		},
		botTeam = {},
		ranked = (opts and opts.ranked) == true,
		roster = {},
		leavers = {},
	}
	local byId: { [number]: Entry } = {}
	local unique: { Entry } = {}
	for _, e in humans do
		if byId[e.id] == nil then
			byId[e.id] = e
			table.insert(unique, e)
		end
	end
	local a, b = Rating.balance(unique)
	-- arrival order alternates A, B so neither team's newest player is
	-- always the strongest
	for i = 1, math.max(#a, #b) do
		if a[i] then
			addMember(plan, byId[a[i]], "A", 0, 0)
		end
		if b[i] then
			addMember(plan, byId[b[i]], "B", 0, 0)
		end
	end
	if plan.ranked then
		for id, m in plan.members do
			plan.roster[id] = m.team
		end
	end
	pick(plan, 1)
	return plan
end

-- The line for `point` (RulesEngine pointNumber, 1 = first point). Picks a
-- new line the first time a point number is asked for and returns the same
-- one after that, so calling it twice for one point is harmless. Returns the
-- humans on the field per team, in line-up order.
function MatchPlan.line(plan: Plan, point: number): { [string]: { number } }
	if point > plan.point then
		pick(plan, point)
	end
	return { A = table.clone(plan.teams.A.line), B = table.clone(plan.teams.B.line) }
end

-- A human arriving mid-match. Returns (team, role): always "Bench" until the
-- next point is picked. Someone already in the plan keeps their slot.
function MatchPlan.join(plan: Plan, entry: Entry): (Team, Role)
	local existing = plan.members[entry.id]
	if existing then
		return existing.team, if existing.onLine then "Match" else "Bench"
	end
	local a, b = #plan.teams.A.humans, #plan.teams.B.humans
	local team: Team
	if a ~= b then
		team = if a < b then "A" else "B"
	else
		team = if ratingSum(plan, "B") < ratingSum(plan, "A") then "B" else "A"
	end
	-- counted as a teammate who has sat out as little as anyone, plus the
	-- current point: picked first at the next point, then rotated like the rest
	local fewest = math.huge
	for _, id in plan.teams[team].humans do
		fewest = math.min(fewest, plan.members[id].sat)
	end
	local sat = if fewest == math.huge then 1 else fewest + 1
	addMember(plan, entry, team, math.max(0, plan.point - 1), sat)
	return team, "Bench"
end

-- A human leaving the match (left the game, or went to training). Returns
-- nil when they were not in the plan.
function MatchPlan.leave(plan: Plan, id: number): LeaveResult?
	local m = plan.members[id]
	if not m then
		return nil
	end
	local tp = plan.teams[m.team]
	removeValue(tp.humans, id)
	removeValue(tp.line, id)
	plan.members[id] = nil
	local rankedLoss = plan.ranked and plan.roster[id] ~= nil
	if rankedLoss and not table.find(plan.leavers, id) then
		table.insert(plan.leavers, id)
	end
	-- only benched players switch mid-point; anyone else waits for the next pick
	rebalance(plan, true)
	return { team = m.team, wasOnLine = m.onLine, rankedLoss = rankedLoss }
end

-- (team, role) of an actor in the plan (bots are always "Match"), or nil.
function MatchPlan.slot(plan: Plan, id: number): (Team?, Role?)
	local m = plan.members[id]
	if m then
		return m.team, if m.onLine then "Match" else "Bench"
	end
	local bt = plan.botTeam[id]
	if bt then
		return bt, "Match"
	end
	return nil, nil
end

-- Every human in the plan with their team and role, in arrival order.
function MatchPlan.members(plan: Plan): { { id: number, team: Team, role: Role } }
	local list = {}
	for _, m in plan.members do
		table.insert(list, m)
	end
	table.sort(list, function(x, y)
		return x.seq < y.seq
	end)
	local out = {}
	for _, m in list do
		table.insert(out, { id = m.id, team = m.team, role = if m.onLine then "Match" else "Bench" })
	end
	return out
end

-- Everyone on the field for `team` right now: line humans first (line-up
-- order), then the team's bots, at most TeamSize.
function MatchPlan.lineFor(plan: Plan, team: Team): { number }
	local tp = plan.teams[team]
	local out = table.clone(tp.line)
	for _, id in tp.bots do
		if #out >= plan.teamSize then
			break
		end
		table.insert(out, id)
	end
	return out
end

-- Benched humans of `team`, in arrival order.
function MatchPlan.benchFor(plan: Plan, team: Team): { number }
	local out = {}
	for _, id in plan.teams[team].humans do
		if not plan.members[id].onLine then
			table.insert(out, id)
		end
	end
	return out
end

-- (index, count) of an actor's spot in its team's line-up (lineFor order),
-- or nil when it is not on the field.
function MatchPlan.lineIndex(plan: Plan, id: number): (number?, number)
	local team = MatchPlan.slot(plan, id)
	if team == nil then
		return nil, 0
	end
	local line = MatchPlan.lineFor(plan, team)
	return table.find(line, id), #line
end

function MatchPlan.botsWanted(plan: Plan, team: Team): number
	if not plan.fillWithBots then
		return 0
	end
	return math.max(0, plan.teamSize - #plan.teams[team].line)
end

-- Record a bot TeamService spawned for `team`.
function MatchPlan.addBot(plan: Plan, team: Team, id: number)
	local old = plan.botTeam[id]
	if old then
		removeValue(plan.teams[old].bots, id)
	end
	plan.botTeam[id] = team
	table.insert(plan.teams[team].bots, id)
end

-- Forget a bot (removed by TeamService, or it vanished).
function MatchPlan.removeBot(plan: Plan, id: number)
	local team = plan.botTeam[id]
	if team then
		removeValue(plan.teams[team].bots, id)
		plan.botTeam[id] = nil
	end
end

-- What TeamService must do so the registered bots match the line: spawn
-- `spawn[team]` new bots (then addBot each) and remove the listed ids (newest
-- bots go first; then removeBot each).
function MatchPlan.botWork(plan: Plan): BotWork
	local work: BotWork = { spawn = { A = 0, B = 0 }, remove = {} }
	for _, team in TEAMS do
		local bots = plan.teams[team].bots
		local want = MatchPlan.botsWanted(plan, team)
		if #bots > want then
			for i = #bots, want + 1, -1 do
				table.insert(work.remove, bots[i])
			end
		else
			work.spawn[team] = want - #bots
		end
	end
	return work
end

function MatchPlan.counts(plan: Plan): { [string]: TeamCounts }
	local out: { [string]: TeamCounts } = {}
	for _, team in TEAMS do
		local tp = plan.teams[team]
		out[team] = {
			humans = #tp.humans,
			line = #tp.line,
			bench = #tp.humans - #tp.line,
			bots = #tp.bots,
			botsWanted = MatchPlan.botsWanted(plan, team),
		}
	end
	return out
end

-- Humans a ranked match of these rules needs (both lines all human).
function MatchPlan.rankedNeed(rules: { TeamSize: number }): number
	return 2 * math.max(1, math.floor(rules.TeamSize))
end

-- "4/6" style progress towards a ranked match, for the menu.
function MatchPlan.rankedReady(rules: { TeamSize: number }, humans: number): string
	local need = MatchPlan.rankedNeed(rules)
	return string.format("%d/%d", math.clamp(humans, 0, need), need)
end

-- Would a match of `rules` with `humans` non-training humans be ranked?
-- Returns (ranked, reason); reason is a short UI string when it is not.
function MatchPlan.rankedEligible(
	rules: { TeamSize: number, RankedEligible: boolean },
	humans: number,
	env: RankedEnv
): (boolean, string)
	if not rules.RankedEligible then
		return false, "Unranked mode"
	elseif env.studio then
		return false, "Unranked in Studio"
	elseif env.privateServer then
		return false, "Unranked in private servers"
	end
	-- the split is within one, so both lines are all human once the smaller
	-- team (floor(humans / 2)) reaches TeamSize
	local need = MatchPlan.rankedNeed(rules)
	if humans < need then
		return false, string.format("Ranked needs %d players (%d/%d)", need, humans, need)
	end
	if not MatchPlan.RankedBench and humans ~= need then
		return false, string.format("Ranked needs exactly %d players", need)
	end
	return true, "Ranked"
end

-- Ranked bookkeeping for the end of the match.
function MatchPlan.rankedResult(plan: Plan): RankedResult
	return {
		ranked = plan.ranked,
		valid = plan.ranked and #plan.leavers == 0,
		roster = table.clone(plan.roster),
		leavers = table.clone(plan.leavers),
	}
end

return MatchPlan
