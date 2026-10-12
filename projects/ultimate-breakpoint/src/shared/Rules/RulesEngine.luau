--!strict
--[[
	RulesEngine — the sport of ultimate as a pure state machine.

	Server services report what physically happened (a throw, a catch, a
	landing, the disc touching the ground, a stall-out) and the engine decides
	what it means: completion, interception, turnover, goal, Callahan, the
	Greatest, match point, universe point. MatchService applies the outcomes to
	the world. Keeping this pure lets the whole rulebook be unit tested
	(tests/rules_spec.luau).

	Rules implemented (beginner-readable defaults, see docs/DESIGN.md):
	  - no running with the disc (enforced by movement + server pivot check)
	  - incomplete, blocked, dropped or out-of-bounds passes are turnovers
	  - a catch counts where the receiver first touches the ground; airborne
	    receivers must have left the ground in bounds
	  - catch in the end zone you attack = goal; defender intercepting in the
	    end zone they defend = Callahan (goal)
	  - airborne receiver may release before landing (the Greatest)
	  - stall-out = turnover at the thrower's feet
	  - turnovers inside an end zone are brought to its goal line
	  - teams switch direction after every goal; scored-on team receives
	  - pulls: receiving team takes it where it stops, or at the brick if it
	    lands out; touching then dropping the pull is a turnover
	  - time cap: finish the point; leader wins, tie -> universe point
]]

local Shared = script.Parent.Parent
local FieldGeometry = require(script.Parent.FieldGeometry)
local _ = Shared

local RulesEngine = {}

export type Team = string -- "A" | "B"
export type Side = FieldGeometry.Side
export type Phase = "Idle" | "Setup" | "Pull" | "Live" | "PointOver" | "MatchOver"
export type DiscMode = "None" | "Held" | "Flight" | "Ground"

export type Config = {
	pointsToWin: number,
	usePull: boolean,
}

export type Outcome = { [string]: any }

export type Pending = {
	id: number,
	team: Team,
	interception: boolean,
	assist: number?,
	pull: boolean,
}

export type State = {
	field: FieldGeometry.Field,
	config: Config,
	phase: Phase,
	score: { [string]: number },
	attack: { [string]: Side },
	offense: Team,
	holder: number?,
	holderTeam: Team?,
	disc: DiscMode,
	discSpot: Vector3?,
	flightIsPull: boolean,
	pullTouched: boolean,
	thrower: number?,
	throwerTeam: Team?,
	lastToucherTeam: Team?,
	pending: Pending?,
	passes: number,
	pointNumber: number,
	capReached: boolean,
	universe: boolean,
	winner: Team?,
}

function RulesEngine.other(t: Team): Team
	return if t == "A" then "B" else "A"
end

function RulesEngine.new(field: FieldGeometry.Field, config: Config): State
	return {
		field = field,
		config = config,
		phase = "Idle",
		score = { A = 0, B = 0 },
		attack = { A = "East", B = "West" },
		offense = "A",
		holder = nil,
		holderTeam = nil,
		disc = "None",
		discSpot = nil,
		flightIsPull = false,
		pullTouched = false,
		thrower = nil,
		throwerTeam = nil,
		lastToucherTeam = nil,
		pending = nil,
		passes = 0,
		pointNumber = 0,
		capReached = false,
		universe = false,
		winner = nil,
	}
end

function RulesEngine.defense(e: State): Team
	return RulesEngine.other(e.offense)
end

-- The end zone a team defends (the one it lines up in).
function RulesEngine.defends(e: State, team: Team): Side
	return FieldGeometry.other(e.attack[team])
end

local function setHolder(e: State, id: number, team: Team)
	e.holder = id
	e.holderTeam = team
	e.disc = "Held"
	e.discSpot = nil
end

local function clearHolder(e: State)
	e.holder = nil
	e.holderTeam = nil
end

function RulesEngine.startMatch(e: State, firstOffense: Team, offenseAttacks: Side?)
	e.score = { A = 0, B = 0 }
	local side: Side = offenseAttacks or "East"
	e.attack[firstOffense] = side
	e.attack[RulesEngine.other(firstOffense)] = FieldGeometry.other(side)
	e.offense = firstOffense
	e.pointNumber = 0
	e.capReached = false
	e.universe = false
	e.winner = nil
	e.phase = "Idle"
end

function RulesEngine.setupPoint(e: State): Outcome
	e.phase = "Setup"
	e.pointNumber += 1
	clearHolder(e)
	e.disc = "None"
	e.discSpot = nil
	e.flightIsPull = false
	e.pullTouched = false
	e.thrower = nil
	e.throwerTeam = nil
	e.lastToucherTeam = nil
	e.pending = nil
	e.passes = 0
	local defense = RulesEngine.defense(e)
	return {
		kind = "Setup",
		offense = e.offense,
		defense = defense,
		offenseLine = RulesEngine.defends(e, e.offense),
		defenseLine = RulesEngine.defends(e, defense),
		pull = e.config.usePull,
		point = e.pointNumber,
		universe = e.universe,
	}
end

function RulesEngine.beginPull(e: State, pullerId: number)
	e.phase = "Pull"
	setHolder(e, pullerId, RulesEngine.defense(e))
end

function RulesEngine.beginLive(e: State, holderId: number?)
	e.phase = "Live"
	if holderId then
		setHolder(e, holderId, e.offense)
	end
end

local function turnover(e: State, reason: string, spot: Vector3): { Outcome }
	local newOffense = if e.throwerTeam then RulesEngine.other(e.throwerTeam :: Team) else RulesEngine.other(e.offense)
	if reason == "Stall" and e.holderTeam then
		newOffense = RulesEngine.other(e.holderTeam :: Team)
	end
	e.offense = newOffense
	clearHolder(e)
	e.disc = "Ground"
	e.discSpot = FieldGeometry.turnoverSpot(e.field, spot)
	e.pending = nil
	e.passes = 0
	e.flightIsPull = false
	return { { kind = "Turnover", reason = reason, team = newOffense, spot = e.discSpot } }
end

local function scoreGoal(e: State, team: Team, scorer: number, assist: number?, callahan: boolean): { Outcome }
	local outcomes: { Outcome } = {}
	e.score[team] += 1
	e.phase = "PointOver"
	clearHolder(e)
	e.disc = "None"
	e.pending = nil
	table.insert(outcomes, {
		kind = "Goal",
		team = team,
		scorer = scorer,
		assist = if callahan then nil else assist,
		callahan = callahan,
		passes = e.passes,
		score = { A = e.score.A, B = e.score.B },
		universe = e.universe,
	})
	-- next point: scored-on team receives, both teams switch direction
	e.offense = RulesEngine.other(team)
	e.attack.A, e.attack.B = e.attack.B, e.attack.A

	local other = RulesEngine.other(team)
	local over = false
	if e.score[team] >= e.config.pointsToWin or e.universe then
		over = true
	elseif e.capReached then
		if e.score[team] ~= e.score[other] then
			over = true
		else
			e.universe = true
			table.insert(outcomes, { kind = "UniversePoint" })
		end
	elseif e.score[team] == e.config.pointsToWin - 1 and e.score[other] == e.config.pointsToWin - 1 then
		e.universe = true
		table.insert(outcomes, { kind = "UniversePoint" })
	end
	if over then
		local winner: Team = if e.score.A > e.score.B then "A" else "B"
		e.winner = winner
		e.phase = "MatchOver"
		table.insert(outcomes, { kind = "MatchOver", winner = winner, score = { A = e.score.A, B = e.score.B } })
	end
	return outcomes
end

local function checkGoal(
	e: State,
	id: number,
	team: Team,
	pos: Vector3,
	interception: boolean,
	assist: number?
): { Outcome }
	local f = e.field
	if interception and e.throwerTeam and FieldGeometry.inEndZone(f, pos, e.attack[e.throwerTeam :: Team]) then
		return scoreGoal(e, team, id, nil, true)
	end
	if FieldGeometry.inEndZone(f, pos, e.attack[team]) then
		return scoreGoal(e, team, id, assist, false)
	end
	return {}
end

-- The holder released the disc. `pos` is the thrower's position at release.
function RulesEngine.throw(e: State, id: number, pos: Vector3): { Outcome }
	if e.holder ~= id or e.disc ~= "Held" then
		return {}
	end
	local outcomes: { Outcome } = {}
	local team = e.holderTeam :: Team
	if e.phase == "Pull" then
		e.flightIsPull = true
		e.pullTouched = false
		e.phase = "Live"
		e.offense = RulesEngine.other(team)
		table.insert(outcomes, { kind = "PullReleased", id = id })
	elseif e.phase ~= "Live" then
		return {}
	end
	local pending = e.pending
	if pending and pending.id == id then
		if not FieldGeometry.inBounds(e.field, pos) then
			table.insert(outcomes, { kind = "Greatest", id = id })
		end
		e.pending = nil
	end
	clearHolder(e)
	e.disc = "Flight"
	e.thrower = id
	e.throwerTeam = team
	e.lastToucherTeam = nil
	table.insert(outcomes, { kind = "Thrown", id = id, team = team, pull = e.flightIsPull })
	return outcomes
end

-- A player touched the disc without securing it (block, tip, bobble).
function RulesEngine.touch(e: State, id: number, team: Team): { Outcome }
	if e.disc ~= "Flight" then
		return {}
	end
	e.lastToucherTeam = team
	if e.flightIsPull then
		if team == e.offense then
			e.pullTouched = true
		end
		return {}
	end
	if team ~= e.throwerTeam then
		return { { kind = "Block", id = id, team = team, thrower = e.thrower } }
	end
	return { { kind = "Tip", id = id, team = team } }
end

-- A player secured the disc. `grounded` = feet on the ground at the catch;
-- `jumpOrigin` = where an airborne catcher last left the ground.
function RulesEngine.catch(
	e: State,
	id: number,
	team: Team,
	pos: Vector3,
	grounded: boolean,
	jumpOrigin: Vector3?
): { Outcome }
	if e.disc ~= "Flight" or e.phase ~= "Live" then
		return {}
	end
	local f = e.field
	local outcomes: { Outcome } = {}

	if e.flightIsPull then
		if team ~= e.offense then
			return {}
		end
		e.flightIsPull = false
		setHolder(e, id, team)
		table.insert(outcomes, { kind = "PullCaught", id = id, team = team })
		if not grounded then
			e.pending = { id = id, team = team, interception = false, assist = nil, pull = true }
		elseif not FieldGeometry.inBounds(f, pos) then
			e.discSpot = FieldGeometry.turnoverSpot(f, pos)
			table.insert(outcomes, { kind = "Relocate", id = id, spot = e.discSpot })
		end
		return outcomes
	end

	-- an airborne catcher who jumped from out of bounds is out of bounds
	if not grounded and jumpOrigin and not FieldGeometry.inBounds(f, jumpOrigin) then
		return turnover(e, "OutOfBounds", pos)
	end
	if grounded and not FieldGeometry.inBounds(f, pos) then
		return turnover(e, "OutOfBounds", pos)
	end

	local interception = team ~= e.throwerTeam
	local assist = e.thrower
	setHolder(e, id, team)
	if interception then
		e.offense = team
		e.passes = 0
		table.insert(outcomes, { kind = "Interception", id = id, team = team, thrower = assist })
	else
		e.passes += 1
		table.insert(outcomes, { kind = "Completion", id = id, team = team, from = assist, passes = e.passes })
	end

	if grounded then
		for _, o in checkGoal(e, id, team, pos, interception, assist) do
			table.insert(outcomes, o)
		end
	else
		e.pending = { id = id, team = team, interception = interception, assist = assist, pull = false }
	end
	return outcomes
end

-- An airborne catcher touched down.
function RulesEngine.land(e: State, id: number, pos: Vector3): { Outcome }
	local p = e.pending
	if p == nil or p.id ~= id or e.holder ~= id then
		return {}
	end
	e.pending = nil
	local f = e.field
	if not FieldGeometry.inBounds(f, pos) then
		if p.pull then
			e.discSpot = FieldGeometry.turnoverSpot(f, pos)
			return { { kind = "Relocate", id = id, spot = e.discSpot } }
		end
		return turnover(e, "OutOfBounds", pos)
	end
	if p.pull then
		return {}
	end
	return checkGoal(e, id, p.team, pos, p.interception, p.assist)
end

-- The disc touched the ground (or left the playable area) without a catch.
function RulesEngine.ground(e: State, landPos: Vector3, exitPos: Vector3?): { Outcome }
	if e.disc ~= "Flight" then
		return {}
	end
	local f = e.field
	local out = not FieldGeometry.inBounds(f, landPos)
	if e.flightIsPull then
		e.flightIsPull = false
		if e.pullTouched then
			e.throwerTeam = e.offense -- the receiving team touched it last; it changes hands
			return turnover(e, "Drop", landPos)
		end
		clearHolder(e)
		e.disc = "Ground"
		local brick = false
		if out then
			e.discSpot = FieldGeometry.brickPoint(f, RulesEngine.defends(e, e.offense))
			brick = true
		else
			e.discSpot = FieldGeometry.turnoverSpot(f, landPos)
		end
		return { { kind = "PullLanded", spot = e.discSpot, brick = brick } }
	end
	local reason: string
	if out then
		reason = "OutOfBounds"
	elseif e.lastToucherTeam ~= nil and e.lastToucherTeam == e.throwerTeam then
		reason = "Drop"
	elseif e.lastToucherTeam ~= nil then
		reason = "Block"
	else
		reason = "Incomplete"
	end
	local spot = if out then (exitPos or landPos) else landPos
	return turnover(e, reason, spot)
end

function RulesEngine.pickup(e: State, id: number, team: Team): { Outcome }
	if e.disc ~= "Ground" or team ~= e.offense or e.phase ~= "Live" then
		return {}
	end
	local spot = e.discSpot
	setHolder(e, id, team)
	e.thrower = nil
	return { { kind = "Pickup", id = id, team = team, spot = spot } }
end

function RulesEngine.stall(e: State, pos: Vector3): { Outcome }
	if e.disc ~= "Held" or e.phase ~= "Live" or e.holder == nil then
		return {}
	end
	return turnover(e, "Stall", pos)
end

-- The holder vanished (left the game). Their team keeps possession at the spot.
function RulesEngine.holderLeft(e: State, pos: Vector3): { Outcome }
	if e.disc ~= "Held" then
		return {}
	end
	clearHolder(e)
	e.pending = nil
	e.disc = "Ground"
	e.discSpot = FieldGeometry.turnoverSpot(e.field, pos)
	return { { kind = "DiscDropped", spot = e.discSpot } }
end

function RulesEngine.reachCap(e: State): { Outcome }
	if e.capReached then
		return {}
	end
	e.capReached = true
	local outcomes: { Outcome } = { { kind = "CapReached" } }
	if e.phase == "PointOver" or e.phase == "Setup" or e.phase == "Idle" then
		if e.score.A ~= e.score.B then
			local winner: Team = if e.score.A > e.score.B then "A" else "B"
			e.winner = winner
			e.phase = "MatchOver"
			table.insert(outcomes, { kind = "MatchOver", winner = winner, score = { A = e.score.A, B = e.score.B } })
		else
			e.universe = true
			table.insert(outcomes, { kind = "UniversePoint" })
		end
	end
	return outcomes
end

return RulesEngine
