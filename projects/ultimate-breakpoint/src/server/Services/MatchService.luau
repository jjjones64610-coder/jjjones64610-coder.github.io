--!strict
--[[
	MatchService — the match loop.

	  Intermission  free-play warm-up disc and the mode + arena votes. The
	                head count decides which modes are eligible
	                (Config/Modes.eligible: Mini 3v3 up to 6 humans, Normal
	                7v7 from 10, a vote in between); the list refreshes on
	                every join / leave / training change. 20 s countdown with
	                2+ humans, 30 s alone ("Practice vs bots — waiting for
	                players"). In a private server (the owner) or Studio
	                (the first player, the next one if they leave) the host
	                picks the mode and rules and can start at once. Everyone
	                in the warm-up plays the next match (JoinMatch is a no-op).
	                The match and warm-up discs fly in the arena's wind.
	  PointSetup    TeamService picks the line (MatchPlan: whoever sat out
	                longest, bots fill to exactly 3v3 / 7v7); the lines are
	                teleported behind the goal lines they defend, substitutes
	                to their team's bench. Everyone is frozen only 0.6 s, then
	                may move behind their own goal line (UBLineX / UBLineSide).
	                End zones glow in the attacking team's colour.
	  Pull          the defending team's puller throws to the receivers; at
	                the release anyone more than 3 studs offside is pulled
	                back behind their line and the restriction lifts (modes
	                without pulls skip straight to Live)
	  Live          the RulesEngine decides what every catch, landing, block
	                and stall-out means; this service applies the result.
	                A grounded disc is picked up (no teleport) by an
	                offensive player who reaches it slower than 12 studs/s or
	                presses the pickup key; the pivot is set on the disc and
	                the client glides onto it.
	  PointOver     celebration, then the next point (teams switch ends)
	  MatchOver     summary, progression, ranked rating, back to Intermission

	Ranked is automatic: a public server (not private, not Studio), a
	RankedEligible mode and both lines all human at the start. Ranked matches
	never take private-server rules. A ranked roster player who leaves (or
	goes to training) takes a loss and the result is void for everyone else.

	Every relocation and pickup sets the holder's pivot through
	MovementService.setPivot, so the client always agrees where P is.

	Match state is published as attributes on ReplicatedStorage.UBState so
	late joiners and every UI read the same truth (Phase, Mode, TeamSize,
	HumansA/B, BotsA/B, ForceA/B, VoteModes, RankedReady, Lobby, ...).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ModesConfig = require(Shared.Config.Modes)
local ArenasConfig = require(Shared.Config.Arenas)
local TeamsConfig = require(Shared.Config.Teams)
local DiscConfig = require(Shared.Config.Disc)
local RulesEngine = require(Shared.Rules.RulesEngine)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local MatchPlan = require(Shared.Rules.MatchPlan)
local Solver = require(Shared.Disc.Solver)

local MatchService = {}

local services: any
local stateFolder: Folder

local INTERMISSION_PVP = 20 -- seconds with 2+ humans
local INTERMISSION_SOLO = 30 -- seconds with one human (practice vs bots)
local SOLO_TEXT = "Practice vs bots — waiting for players"
local LINEUP_FREEZE = 0.6 -- the line-up teleport settles, then players may move
local OFFSIDE_PULLBACK = 3 -- studs past the line at the pull release
local PICKUP_SPEED = 12 -- studs/s: slower than this near the disc picks it up
local PICKUP_KEY_WINDOW = 0.35 -- a pickup key press counts this long
local GATHER_SKIP = 0.6 -- travel checks pause while the client glides onto the disc (+ a round trip)
local BOT_WAIT = 8 -- seconds a match start waits for its bots
local FORCE_FH_CHANCE = 0.65

type Stats = { [string]: number }

type PointInfo = {
	offense: string,
	defense: string,
	pull: boolean,
	discTeam: string, -- who gets the disc to start the point (puller / holder)
}

type MatchState = {
	phase: string,
	phaseEnd: number,
	mode: ModesConfig.ModeRules,
	arenaId: string,
	engine: RulesEngine.State?,
	disc: any,
	warmupDisc: any,
	matchEnd: number,
	matchCount: number,
	rotation: { [string]: number },
	puller: number?,
	starter: number?, -- puller (pull) or first holder (no pull) of this point
	point: PointInfo?,
	stats: { [number]: Stats },
	lastPass: { [string]: any }?,
	lastCatchAt: { [number]: number },
	flow: number,
	votes: { mode: { [number]: string }, arena: { [number]: string } },
	voteModes: { string },
	voteDefault: string,
	voteArenas: { string },
	privateConfig: { [string]: any },
	hostId: number,
	groundSince: number,
	pendingMatchOver: boolean,
	pointStartedAt: number,
	unfreezeAt: number?,
	lineSides: { [number]: FieldGeometry.Side }, -- actors held behind a goal line until the pull
	slots: { [string]: { [number]: number } }, -- team -> line-up index -> actor
	placed: { [number]: string }, -- actor -> "point:team:role" it was placed for
	suppressPlacement: boolean,
	pickupWanted: { [number]: number },
	pendingJoin: { any },
	penalized: { [number]: boolean },
	pvp: boolean,
	holderPos: Vector3?,
	lobbyText: string,
}

local S: MatchState = {
	phase = "Boot",
	phaseEnd = 0,
	mode = ModesConfig.copy(ModesConfig.Default),
	arenaId = ArenasConfig.Default,
	engine = nil,
	disc = nil,
	warmupDisc = nil,
	matchEnd = 0,
	matchCount = 0,
	rotation = { A = 0, B = 0 },
	puller = nil,
	starter = nil,
	point = nil,
	stats = {},
	lastPass = nil,
	lastCatchAt = {},
	flow = 0,
	votes = { mode = {}, arena = {} },
	voteModes = {},
	voteDefault = ModesConfig.Default,
	voteArenas = {},
	privateConfig = {},
	hostId = 0,
	groundSince = 0,
	pendingMatchOver = false,
	pointStartedAt = 0,
	unfreezeAt = nil,
	lineSides = {},
	slots = { A = {}, B = {} },
	placed = {},
	suppressPlacement = false,
	pickupWanted = {},
	pendingJoin = {},
	penalized = {},
	pvp = false,
	holderPos = nil,
	lobbyText = "",
}

local rng = Random.new()

local function now(): number
	return Net.now()
end

local function set(key: string, value: any)
	stateFolder:SetAttribute(key, value)
end

local function notifyAll(kind: string, text: string, data: any?)
	Net.event("Notify"):FireAllClients(kind, text, data)
end

local function notify(actorId: number, kind: string, text: string, data: any?)
	local p = services.Actors.playerOf(actorId)
	if p then
		Net.event("Notify"):FireClient(p, kind, text, data)
	end
end

function MatchService.phase(): string
	return S.phase
end

-- The rules the current (or last) match plays: TeamSize, FillWithBots,
-- RankedEligible, Ranked, Field, ...
function MatchService.mode(): ModesConfig.ModeRules
	return S.mode
end

function MatchService.engine(): RulesEngine.State?
	return S.engine
end

function MatchService.disc(): any
	return S.disc
end

---------------------------------------------------------------------------
-- stats
---------------------------------------------------------------------------

function MatchService.stat(actorId: number, key: string, n: number?)
	local st = S.stats[actorId]
	if not st then
		st = {}
		S.stats[actorId] = st
	end
	local amount = n or 1
	st[key] = (st[key] or 0) + amount
	local actor = services.PlayerService.get(actorId)
	if actor and not actor.isBot and S.phase ~= "Intermission" then
		services.ProgressionService.stat(actor, key, amount)
	end
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function setPhase(name: string, duration: number?)
	S.phase = name
	S.phaseEnd = if duration then now() + duration else math.huge
	set("Phase", name)
	set("PhaseEnd", if duration then S.phaseEnd else 0)
end

local function teamColor(team: string): Color3
	return if team == "A" then TeamsConfig.A.Color else TeamsConfig.B.Color
end

local function teamName(team: string): string
	return if team == "A" then TeamsConfig.A.Name else TeamsConfig.B.Name
end

local function field(): FieldGeometry.Field
	return services.ArenaService.field()
end

local function recolorEndZones()
	local e = S.engine
	for _, side in { "East", "West" } do
		local part = services.ArenaService.endZone(side)
		if part then
			local attacker: string? = nil
			if e then
				if e.attack.A == side then
					attacker = "A"
				elseif e.attack.B == side then
					attacker = "B"
				end
			end
			part.Color = if attacker then teamColor(attacker) else Color3.fromRGB(200, 200, 210)
			local gui = part:FindFirstChild("Label")
			local text = gui and gui:FindFirstChild("Text")
			if text and text:IsA("TextLabel") then
				text.Text = if attacker then (teamName(attacker) .. " SCORES HERE") else ""
			end
		end
	end
end

local function publishScore()
	local e = S.engine
	set("ScoreA", if e then e.score.A else 0)
	set("ScoreB", if e then e.score.B else 0)
	set("Offense", if e then e.offense else "")
	set("AttackA", if e then e.attack.A else "East")
	set("AttackB", if e then e.attack.B else "West")
	set("Universe", if e then e.universe else false)
	set("CapReached", if e then e.capReached else false)
	set("Point", if e then e.pointNumber else 0)
end

-- TeamSize and the human / bot head count per team (A/B).
local function publishCounts()
	local c = services.TeamService.counts()
	set("TeamSize", S.mode.TeamSize)
	set("HumansA", if c then c.A.humans else 0)
	set("HumansB", if c then c.B.humans else 0)
	set("BotsA", if c then c.A.bots else 0)
	set("BotsB", if c then c.B.bots else 0)
	if c and c.A.humans > 0 and c.B.humans > 0 then
		S.pvp = true
	end
end

local function setHolderAttr(id: number?)
	set("HolderId", id or 0)
end

local function applySkin(d: any, actorId: number)
	local actor = services.PlayerService.get(actorId)
	if actor and actor.player then
		services.DiscService.setSkin(d, services.ProgressionService.equipped(actor.player, "disc"))
	else
		services.DiscService.setSkin(d, "Classic")
	end
end

local function faceField(pos: Vector3): CFrame
	local target = Vector3.new(0, pos.Y, 0)
	if (target - pos).Magnitude < 1 then
		target = pos + Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, target)
end

-- Root position for an actor standing on a ground point.
local function standingAt(actorId: number, ground: Vector3): Vector3
	return Vector3.new(ground.X, field().groundY + services.MovementService.standHeight(actorId) + 0.1, ground.Z)
end

local function benchSign(team: string): number
	return if team == "A" then MatchPlan.BenchSign.A else MatchPlan.BenchSign.B
end

-- Lets every non-training actor move (drills manage their own freezes).
local function unfreezeAll()
	services.PlayerService.setAllFrozen(false, function(a: any): boolean
		return a.role ~= "Training"
	end)
end

local function startStallFor(id: number)
	services.DefenseService.startStall(id, S.mode.StallInterval, S.mode.StallMax)
end

local function rankedEnv(): MatchPlan.RankedEnv
	return { privateServer = game.PrivateServerId ~= "", studio = RunService:IsStudio() }
end

---------------------------------------------------------------------------
-- placement: line-ups, benches, relocations
---------------------------------------------------------------------------

local function placedKey(actor: any): string
	local e = S.engine
	return string.format("%d:%s:%s", if e then e.pointNumber else 0, actor.team, actor.role)
end

-- Lowest free line-up index of a team (1..TeamSize, then beyond).
local function freeSlot(team: string, id: number): number
	local slots = S.slots[team]
	for i, other in slots do
		if other == id then
			return i
		end
	end
	local i = 1
	while slots[i] ~= nil and slots[i] ~= id do
		i += 1
	end
	return i
end

local function releaseSlot(id: number)
	for _, slots in S.slots do
		for i, other in slots do
			if other == id then
				slots[i] = nil
			end
		end
	end
end

-- A field player on line-up spot `index` behind the goal line their team
-- defends; `restrict` keeps them behind it until the pull.
local function lineUp(actor: any, index: number, restrict: boolean, frozen: boolean)
	local e = S.engine
	if not e then
		return
	end
	local f = field()
	local side: FieldGeometry.Side = RulesEngine.defends(e, actor.team)
	local count = math.max(S.mode.TeamSize, index)
	local ground = FieldGeometry.lineupSpot(f, side, index, count)
	releaseSlot(actor.id)
	S.slots[actor.team][index] = actor.id
	services.PlayerService.teleport(actor, faceField(standingAt(actor.id, ground)), { face = true })
	if restrict then
		local x, sign = FieldGeometry.lineRestriction(f, side)
		services.PlayerService.setLine(actor, x, sign)
		S.lineSides[actor.id] = side
	else
		services.PlayerService.setLine(actor, nil, nil)
		S.lineSides[actor.id] = nil
	end
	services.PlayerService.setFrozen(actor, frozen)
	S.placed[actor.id] = placedKey(actor)
end

-- A substitute on their team's bench, facing the field.
local function seatOnBench(actor: any)
	local bench = services.TeamService.benchFor(actor.team)
	local index = table.find(bench, actor.id) or (#bench + 1)
	local spots = FieldGeometry.benchSpots(field(), benchSign(actor.team), math.max(#bench, index))
	local ground = spots[math.clamp(index, 1, #spots)]
	local pos = standingAt(actor.id, ground)
	releaseSlot(actor.id)
	services.PlayerService.teleport(actor, CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1)), { face = true })
	services.PlayerService.setLine(actor, nil, nil)
	S.lineSides[actor.id] = nil
	services.PlayerService.setFrozen(actor, false)
	S.placed[actor.id] = placedKey(actor)
end

-- Puts an actor where their team and role belong right now.
local function placeActor(actor: any)
	local e = S.engine
	if not e or (actor.team ~= "A" and actor.team ~= "B") then
		if actor.role ~= "Training" then
			services.PlayerService.setLine(actor, nil, nil)
			services.PlayerService.teleport(actor, services.ArenaService.spawnCFrame(), { face = true })
		end
		return
	end
	if actor.role == "Bench" then
		seatOnBench(actor)
	elseif actor.role == "Match" then
		local beforePull = S.phase == "PointSetup" or S.phase == "Pull"
		local frozen = S.phase == "PointSetup" and S.unfreezeAt ~= nil
		lineUp(actor, freeSlot(actor.team, actor.id), beforePull, frozen)
	end
end

-- Moves the holder onto a ground spot and plants their pivot there.
local function moveHolder(actor: any, ground: Vector3)
	local root = services.PlayerService.root(actor)
	local pos = standingAt(actor.id, ground)
	services.MovementService.setPivot(actor.id, pos)
	local rot = if root then root.CFrame.Rotation else CFrame.identity
	services.PlayerService.teleport(actor, CFrame.new(pos) * rot)
end

-- At the pull release: anyone well past their line goes back behind it, then
-- every line restriction lifts.
local function releaseLines(exceptId: number?)
	local f = field()
	for id, lineSide in S.lineSides do
		local side: FieldGeometry.Side = if lineSide == "East" then "East" else "West"
		local actor = services.PlayerService.get(id)
		local root = actor and services.PlayerService.root(actor)
		if actor and root and id ~= exceptId and actor.role == "Match" then
			local pos = root.Position
			if FieldGeometry.offsideBy(f, pos, side) > OFFSIDE_PULLBACK then
				local back = FieldGeometry.behindLine(f, pos, side, 1)
				services.PlayerService.teleport(actor, CFrame.new(back) * root.CFrame.Rotation)
			end
		end
	end
	S.lineSides = {}
	services.PlayerService.clearLines()
end

---------------------------------------------------------------------------
-- disc handlers
---------------------------------------------------------------------------

local applyOutcomes: (outcomes: { any }, ctx: { [string]: any }?) -> ()

local matchHandler = {} :: any

function matchHandler.canClaim(d: any, actorId: number, team: string): boolean
	local e = S.engine
	if not e or e.phase ~= "Live" or (team ~= "A" and team ~= "B") then
		return false
	end
	local actor = services.PlayerService.get(actorId)
	if not actor or actor.role ~= "Match" then
		return false
	end
	if d.pull then
		return team == e.offense
	end
	return true
end

function matchHandler.canThrow(_d: any, actorId: number): boolean
	local e = S.engine
	if not e or e.holder ~= actorId then
		return false
	end
	if S.phase == "Pull" then
		return e.phase == "Pull"
	end
	return S.phase == "Live" and e.phase == "Live"
end

function matchHandler.onThrown(d: any, info: any)
	local e = S.engine
	if not e then
		return
	end
	local wasPull = S.phase == "Pull"
	d.meta.pullPending = false
	local caughtAt = S.lastCatchAt[info.id]
	local quick = caughtAt ~= nil and now() - caughtAt <= DiscConfig.Throw.QuickReleaseWindow
	if quick then
		S.flow += 1
	else
		S.flow = 1
	end
	S.lastPass = {
		thrower = info.id,
		team = info.team,
		throwType = info.params.throwType,
		quality = info.launch.quality,
		releasePos = info.launch.releasePos,
		releaseAt = now(),
		pull = wasPull,
		quick = quick,
		flow = S.flow,
		blocked = info.blocked,
	}
	services.DefenseService.stopStall()
	setHolderAttr(nil)
	if not wasPull then
		MatchService.stat(info.id, "throws")
		if info.launch.quality == "Perfect" then
			MatchService.stat(info.id, "perfectReleases")
		end
	end
	applyOutcomes(RulesEngine.throw(e, info.id, info.pos), { thrower = info.id })
end

function matchHandler.onCaught(d: any, info: any)
	local e = S.engine
	if not e then
		return
	end
	local outcomes = RulesEngine.catch(e, info.id, info.team, info.pos, info.grounded, info.jumpOrigin)
	if #outcomes == 0 then
		-- engine refused (should not happen); keep the world consistent
		services.DiscService.placeOnGround(d, info.pos)
		return
	end
	S.lastCatchAt[info.id] = now()
	if not info.grounded then
		services.MovementService.expectLanding(info.id)
	end
	applySkin(d, info.id)
	services.HighlightService.onCatch(info, S.lastPass, outcomes)
	applyOutcomes(outcomes, { catch = info })
end

function matchHandler.onTouched(_d: any, info: any)
	local e = S.engine
	if not e then
		return
	end
	local outcomes = RulesEngine.touch(e, info.id, info.team)
	services.HighlightService.onTouched(info, S.lastPass)
	applyOutcomes(outcomes, { touch = info })
end

local function exitPointFromSamples(samples: { any }, land: Vector3): Vector3?
	local f = field()
	local lastIn: Vector3? = nil
	for _, s in samples do
		local p = Vector3.new(s.x, f.groundY, s.z)
		if FieldGeometry.inBounds(f, p) then
			lastIn = p
		elseif lastIn then
			return FieldGeometry.exitPoint(f, lastIn, p)
		end
	end
	if lastIn and not FieldGeometry.inBounds(f, land) then
		return FieldGeometry.exitPoint(f, lastIn, land)
	end
	return nil
end

function matchHandler.onGrounded(d: any, land: Vector3, samples: { any })
	local e = S.engine
	if not e then
		services.DiscService.placeOnGround(d, land)
		return
	end
	local exitPos = exitPointFromSamples(samples, land)
	local outcomes = RulesEngine.ground(e, land, exitPos)
	if #outcomes == 0 then
		services.DiscService.placeOnGround(d, field().center)
	end
	applyOutcomes(outcomes, { land = land })
end

-- Warm-up free play: anyone can catch, throw and pick up.
local warmupHandler = {} :: any
function warmupHandler.canClaim(_d: any, actorId: number, _team: string): boolean
	local a = services.PlayerService.get(actorId)
	return a ~= nil and a.role ~= "Training"
end
function warmupHandler.canThrow(_d: any, _id: number): boolean
	return true
end
function warmupHandler.onThrown(_d: any, _info: any) end
function warmupHandler.onCaught(d: any, info: any)
	applySkin(d, info.id)
end
function warmupHandler.onTouched(_d: any, _info: any) end
function warmupHandler.onGrounded(d: any, land: Vector3, _samples: any)
	services.DiscService.placeOnGround(d, FieldGeometry.clampInBounds(field(), land, 2))
end

---------------------------------------------------------------------------
-- outcomes
---------------------------------------------------------------------------

local function goal(o: any)
	local e = S.engine :: RulesEngine.State
	publishScore()
	services.DefenseService.stopStall()
	setHolderAttr(nil)
	-- the point is over: the disc rests at the scorer's feet during the celebration
	local scorerRoot = services.Actors.rootOf(o.scorer)
	if S.disc then
		services.DiscService.placeOnGround(
			S.disc,
			if scorerRoot then scorerRoot.Position - Vector3.new(0, 3, 0) else Vector3.zero
		)
	end
	MatchService.stat(o.scorer, "goals")
	if o.callahan then
		MatchService.stat(o.scorer, "callahans")
	end
	if o.assist then
		MatchService.stat(o.assist, "assists")
		local lp = S.lastPass
		if lp and lp.throwType == "Hammer" then
			MatchService.stat(o.assist, "hammerGoals")
		end
	end
	if (o.passes or 0) >= 10 then
		for _, a in services.PlayerService.onTeam(o.team) do
			MatchService.stat(a.id, "flowGoals")
		end
	end
	local clutch = e.universe or e.capReached or (S.matchEnd - now() < 15)
	services.HighlightService.onGoal(o, S.lastPass, clutch)
	notifyAll("Goal", teamName(o.team) .. " SCORE", {
		team = o.team,
		scorer = o.scorer,
		assist = o.assist,
		callahan = o.callahan,
		score = o.score,
	})
	-- everyone may move and celebrate
	S.lineSides = {}
	services.PlayerService.clearLines()
	unfreezeAll()
	setPhase("PointOver", S.mode.CelebrationTime)
end

function applyOutcomes(outcomes: { any }, ctx: { [string]: any }?)
	local e = S.engine
	if not e then
		return
	end
	local d = S.disc
	local _ = ctx
	for _, o in outcomes do
		local kind = o.kind
		if kind == "Turnover" then
			services.DefenseService.stopStall()
			setHolderAttr(nil)
			services.DiscService.placeOnGround(d, o.spot)
			S.groundSince = now()
			S.flow = 0
			local lp = S.lastPass
			if lp and o.reason ~= "Stall" then
				MatchService.stat(lp.thrower, "turnovers")
			end
			notifyAll("Turnover", "TURNOVER", { reason = o.reason, team = o.team })
			publishScore()
		elseif kind == "Completion" or kind == "Interception" or kind == "PullCaught" or kind == "Pickup" then
			setHolderAttr(o.id)
			startStallFor(o.id)
			publishScore()
			if kind == "Completion" then
				MatchService.stat(o.id, "catches")
				if o.from then
					MatchService.stat(o.from, "completions")
				end
			elseif kind == "Interception" then
				MatchService.stat(o.id, "interceptions")
				MatchService.stat(o.id, "catches")
				notifyAll("Turnover", "INTERCEPTION", { reason = "Interception", team = o.team, id = o.id })
			end
		elseif kind == "Relocate" then
			local actor = services.PlayerService.get(o.id)
			if actor then
				moveHolder(actor, o.spot)
			end
		elseif kind == "PullReleased" then
			releaseLines(o.id)
			unfreezeAll()
			S.unfreezeAt = nil
			setPhase("Live")
			notifyAll("Banner", "PULL!", nil)
		elseif kind == "PullLanded" then
			services.DiscService.placeOnGround(d, o.spot)
			S.groundSince = now()
			if o.brick then
				notifyAll("Toast", "Pull out of bounds — brick", nil)
			end
		elseif kind == "DiscDropped" then
			services.DefenseService.stopStall()
			setHolderAttr(nil)
			services.DiscService.placeOnGround(d, o.spot)
		elseif kind == "Block" then
			MatchService.stat(o.id, "blocks")
		elseif kind == "Greatest" then
			MatchService.stat(o.id, "greatests")
			services.HighlightService.broadcast("GREATEST", o.id, 900, "The Greatest!")
		elseif kind == "Goal" then
			goal(o)
		elseif kind == "UniversePoint" then
			notifyAll("Banner", "UNIVERSE POINT", nil)
			publishScore()
		elseif kind == "CapReached" then
			notifyAll("Banner", "TIME CAP", { sub = "Finish the point" })
			publishScore()
		elseif kind == "MatchOver" then
			S.pendingMatchOver = true
		end
	end
end

---------------------------------------------------------------------------
-- phases
---------------------------------------------------------------------------

-- The next player of `team`'s line to start a point with the disc.
local function chooseRotating(team: string): number?
	local line = services.TeamService.lineFor(team)
	if #line == 0 then
		return nil
	end
	S.rotation[team] = (S.rotation[team] % #line) + 1
	return line[S.rotation[team]]
end

-- Each team's markers force one side this point (FH / BH relative to the thrower).
local function pickForce()
	set("ForceA", if rng:NextNumber() < FORCE_FH_CHANCE then "FH" else "BH")
	set("ForceB", if rng:NextNumber() < FORCE_FH_CHANCE then "FH" else "BH")
end

-- Hands the point's disc to its starter (on their line-up spot, or wherever
-- they are when picked later).
local function giveStarter(id: number)
	local p = S.point
	local actor = services.PlayerService.get(id)
	if not p or not actor or not actor.character then
		return
	end
	S.starter = id
	services.DiscService.giveTo(S.disc, id)
	applySkin(S.disc, id)
	-- the pivot goes where the starter is: their line-up spot while that
	-- teleport is still arriving, else where the server sees them now (a
	-- starter picked later in the line-up may have walked off their spot)
	local tp = actor.character:GetAttribute("UBTeleportPos")
	local root = services.PlayerService.root(actor)
	local at: Vector3? = nil
	if typeof(tp) == "Vector3" and (root == nil or services.MovementService.teleportPending(id)) then
		at = tp
	elseif root then
		at = root.Position
	end
	if at then
		services.MovementService.setPivot(id, at)
	end
	if p.pull then
		S.puller = id
		S.disc.meta.pullPending = true
	else
		S.disc.meta.pullHolder = id
	end
end

-- Bots can still be spawning when a point is set up: give the disc to the
-- first starter that exists.
local function tryGiveStarter()
	local p = S.point
	if not p or S.starter ~= nil or S.phase ~= "PointSetup" then
		return
	end
	local id = chooseRotating(p.discTeam)
	if id then
		giveStarter(id)
	end
end

-- Lines every field player up and seats the benches for a new point.
local function placeLines(starter: number?, discTeam: string)
	S.slots = { A = {}, B = {} }
	for _, team in { "A", "B" } do
		local line = services.TeamService.lineFor(team)
		if team == discTeam and starter then
			-- the starter takes the most central spot
			local i = table.find(line, starter)
			if i then
				table.remove(line, i)
				table.insert(line, math.min(#line + 1, math.ceil(S.mode.TeamSize / 2)), starter)
			end
		end
		for i, id in line do
			local actor = services.PlayerService.get(id)
			if actor then
				lineUp(actor, i, true, true)
			end
		end
		for _, id in services.TeamService.benchFor(team) do
			local actor = services.PlayerService.get(id)
			if actor then
				seatOnBench(actor)
			end
		end
	end
end

local function setupPoint()
	local e = S.engine :: RulesEngine.State
	local setup = RulesEngine.setupPoint(e)
	S.pointStartedAt = now()
	S.lastPass = nil
	S.flow = 0
	S.placed = {}
	S.lineSides = {}
	S.puller = nil
	S.starter = nil
	S.pickupWanted = {}
	S.disc.meta.pullHolder = nil
	S.disc.meta.pullPending = false
	recolorEndZones()
	publishScore()
	services.DefenseService.stopStall()
	services.DiscService.hide(S.disc)
	setHolderAttr(nil)
	pickForce()

	local discTeam = if setup.pull then setup.defense else setup.offense
	S.point = { offense = setup.offense, defense = setup.defense, pull = setup.pull, discTeam = discTeam }
	-- pick the line (MatchPlan) without placing anyone twice
	S.suppressPlacement = true
	services.TeamService.setupLine(e.pointNumber)
	S.suppressPlacement = false
	setPhase("PointSetup", S.mode.PointSetupTime)
	S.unfreezeAt = now() + LINEUP_FREEZE

	local starter = chooseRotating(discTeam)
	placeLines(starter, discTeam)
	if starter then
		giveStarter(starter)
	end
	publishCounts()
	notifyAll("Point", if setup.universe then "UNIVERSE POINT" else ("POINT " .. setup.point), {
		offense = setup.offense,
		pull = setup.pull,
	})
end

local function autoPull()
	local e = S.engine
	local pullerId = S.puller
	if not e or not pullerId then
		return false
	end
	local root = services.Actors.rootOf(pullerId)
	if not root then
		return false
	end
	local f = field()
	local target = FieldGeometry.endZoneCenter(f, RulesEngine.defends(e, e.offense))
	local d = target - root.Position
	local sol = Solver.solve({
		rootPos = root.Position,
		pivot = services.MovementService.pivotOf(pullerId),
		throwType = "Backhand",
		target = target + Vector3.new(0, 3, 0),
		groundY = f.groundY,
		wind = services.ArenaService.wind(),
		flightTimeWeight = -0.2, -- prefer hang time on a pull
		coarse = true,
	})
	local params = if sol
		then sol.params
		else {
			throwType = "Backhand",
			yaw = math.atan2(-d.X, -d.Z),
			pitch = math.rad(18),
			holdTime = 0.6,
			bank = 0,
			height = "Mid",
		}
	return services.ThrowService.throw(pullerId, params, true) ~= nil
end

function MatchService.pullNow(id: number)
	if S.phase == "Pull" and S.puller == id then
		autoPull()
	end
end

-- Nobody could pull (or hold): the receivers start with the disc on their brick.
local function startAtBrick()
	local e = S.engine :: RulesEngine.State
	RulesEngine.beginLive(e, nil)
	e.holder = nil
	e.holderTeam = nil
	e.disc = "Ground"
	S.puller = nil
	setHolderAttr(nil)
	services.DefenseService.stopStall()
	local spot = FieldGeometry.brickPoint(field(), RulesEngine.defends(e, e.offense))
	e.discSpot = spot
	services.DiscService.placeOnGround(S.disc, spot)
	S.groundSince = now()
	releaseLines(nil)
	unfreezeAll()
	S.unfreezeAt = nil
	setPhase("Live")
	notifyAll("Banner", "GO!", nil)
end

local function endPointSetup()
	local e = S.engine :: RulesEngine.State
	if S.mode.UsePull then
		local pullerId = S.puller
		local puller = pullerId and services.PlayerService.get(pullerId)
		if not pullerId or not puller then
			startAtBrick()
			return
		end
		RulesEngine.beginPull(e, pullerId)
		setPhase("Pull", S.mode.PullTimeout)
		services.PlayerService.setFrozen(puller, false)
		if puller.isBot then
			services.BotService.schedulePull(puller.id)
		else
			notify(puller.id, "Banner", "YOU'RE PULLING", { sub = "Throw it deep to the other team" })
		end
	else
		local holder = S.disc.meta.pullHolder
		if not holder or not services.PlayerService.get(holder) then
			startAtBrick()
			return
		end
		RulesEngine.beginLive(e, holder)
		releaseLines(holder)
		unfreezeAll()
		S.unfreezeAt = nil
		setPhase("Live")
		setHolderAttr(holder)
		startStallFor(holder)
		notifyAll("Banner", "GO!", nil)
	end
end

local function summary()
	local e = S.engine :: RulesEngine.State
	local rows = {}
	local mvp, mvpScore = nil, -1
	for _, a in services.PlayerService.all() do
		if a.team == "A" or a.team == "B" then
			local st: Stats = S.stats[a.id] or {}
			local score = (st.goals or 0) * 3
				+ (st.assists or 0) * 3
				+ (st.blocks or 0) * 2
				+ (st.interceptions or 0) * 2
				+ (st.catches or 0) * 0.5
				+ (st.highlights or 0)
			table.insert(rows, {
				id = a.id,
				name = a.name,
				team = a.team,
				bot = a.isBot,
				bench = a.role == "Bench",
				goals = st.goals or 0,
				assists = st.assists or 0,
				blocks = st.blocks or 0,
				catches = st.catches or 0,
				throws = st.throws or 0,
				completions = st.completions or 0,
				turnovers = st.turnovers or 0,
				highlights = st.highlights or 0,
			})
			if score > mvpScore then
				mvp, mvpScore = a.id, score
			end
		end
	end
	local result: { [string]: any } = {
		winner = e.winner,
		score = { A = e.score.A, B = e.score.B },
		rows = rows,
		mvp = mvp,
		mode = S.mode.Display,
	}
	return result
end

local function endMatch()
	local e = S.engine :: RulesEngine.State
	local sum = summary()
	local rr = services.TeamService.rankedResult()
	local rankedValid = S.mode.Ranked and rr ~= nil and rr.valid
	local ratingChanges = services.ProgressionService.matchEnded(e.winner, sum.rows, {
		ranked = rankedValid,
		roster = if rr then rr.roster else {},
		ratings = services.TeamService.rosterRatings(),
		margin = math.abs(e.score.A - e.score.B),
		pvp = S.pvp,
	})
	sum.ratingChanges = ratingChanges
	sum.ranked = rankedValid
	sum.rankedVoid = S.mode.Ranked and not rankedValid
	sum.pvp = S.pvp
	Net.event("Summary"):FireAllClients(sum)
	notifyAll(
		"Banner",
		(if e.winner then teamName(e.winner) else "") .. " WIN",
		{ sub = string.format("%d - %d", e.score.A, e.score.B) }
	)
	services.DefenseService.stopStall()
	S.lineSides = {}
	services.PlayerService.clearLines()
	unfreezeAll()
	setPhase("MatchOver", 12)
end

local function tally(votes: { [number]: string }, options: { string }, fallback: string): string
	local counts: { [string]: number } = {}
	for id, v in votes do
		if services.PlayerService.get(id) then
			counts[v] = (counts[v] or 0) + 1
		end
	end
	local best, bestN = fallback, 0
	for _, opt in options do
		if (counts[opt] or 0) > bestN then
			best, bestN = opt, counts[opt]
		end
	end
	return best
end

local function publishVotes()
	local counts = { mode = {}, arena = {} }
	for _, v in S.votes.mode do
		counts.mode[v] = (counts.mode[v] or 0) + 1
	end
	for _, v in S.votes.arena do
		counts.arena[v] = (counts.arena[v] or 0) + 1
	end
	set("VoteCounts", HttpService:JSONEncode(counts))
end

local function humansNotTraining(): number
	local n = 0
	for _, a in services.PlayerService.humans() do
		if a.role ~= "Training" then
			n += 1
		end
	end
	return n
end

-- The mode the next match would play: the vote among the eligible modes;
-- the private-server / Studio host's Mode setting or vote decides.
local function pickMode(humans: number): string
	local options, default = ModesConfig.eligible(humans)
	if S.hostId ~= 0 then
		options = table.clone(ModesConfig.Order)
	end
	local modeId = tally(S.votes.mode, options, default)
	if S.hostId ~= 0 then
		local hostMode = S.votes.mode[S.hostId]
		if hostMode and table.find(options, hostMode) then
			modeId = hostMode
		end
		local configured = S.privateConfig.Mode
		if type(configured) == "string" and ModesConfig.has(configured) then
			modeId = configured
		end
	end
	return modeId
end

-- Ranked progress for the mode the next match would play ("4/6") and
-- whether it would be ranked.
local function publishRanked()
	local humans = humansNotTraining()
	local rules = ModesConfig.copy(pickMode(humans))
	local ok, reason = MatchPlan.rankedEligible(rules, humans, rankedEnv())
	set("RankedReady", MatchPlan.rankedReady(rules, humans))
	set("RankedStatus", reason)
	set("RankedNext", ok and S.hostId == 0)
	if S.phase == "Intermission" then
		set("TeamSize", rules.TeamSize)
	end
end

-- Which modes this head count may play (the host may pick either).
local function refreshVoteOptions()
	local humans = humansNotTraining()
	local options, default = ModesConfig.eligible(humans)
	if S.hostId ~= 0 then
		options = table.clone(ModesConfig.Order)
	end
	S.voteModes = options
	S.voteDefault = default
	for id, v in S.votes.mode do
		if not table.find(options, v) then
			S.votes.mode[id] = nil
		end
	end
	set("VoteModes", table.concat(options, ","))
	set("VoteDefault", default)
	publishVotes()
	publishRanked()
end

local function setLobbyText(text: string)
	if S.lobbyText ~= text then
		S.lobbyText = text
		set("Lobby", text)
	end
end

local function lobbyDuration(humans: number): number?
	if humans <= 0 then
		return nil
	end
	return if humans >= 2 then INTERMISSION_PVP else INTERMISSION_SOLO
end

local function startIntermission()
	S.engine = nil
	S.point = nil
	S.pendingMatchOver = false
	S.lineSides = {}
	S.unfreezeAt = nil
	services.TeamService.clearMatch()
	services.DefenseService.stopStall()
	services.PlayerService.clearLines()
	if S.disc then
		services.DiscService.hide(S.disc)
	end
	-- warm-up disc on the field
	if not S.warmupDisc then
		S.warmupDisc = services.DiscService.create("Warmup", nil, warmupHandler)
	end
	services.DiscService.setWind(S.warmupDisc, services.ArenaService.windVector())
	services.DiscService.placeOnGround(S.warmupDisc, Vector3.new(0, 0, -20))
	recolorEndZones()
	publishScore()
	setHolderAttr(nil)
	S.votes = { mode = {}, arena = {} }
	local arenas = {}
	local order = ArenasConfig.Order
	for i = 0, 2 do
		table.insert(arenas, order[((S.matchCount + i) % #order) + 1])
	end
	S.voteArenas = arenas
	set("VoteArenas", table.concat(arenas, ","))
	unfreezeAll()
	local humans = humansNotTraining()
	setPhase("Intermission", lobbyDuration(humans))
	setLobbyText(if humans == 1 then SOLO_TEXT else "")
	set("Ranked", false)
	set("HumansA", 0)
	set("HumansB", 0)
	set("BotsA", 0)
	set("BotsB", 0)
	refreshVoteOptions()
end

local placeIntoMatch: (actor: any) -> ()

local function startMatch()
	if S.warmupDisc then
		services.DiscService.hide(S.warmupDisc)
	end
	local humans = humansNotTraining()
	if humans == 0 then
		startIntermission()
		return
	end
	-- resolve votes (the private-server / Studio host decides)
	local modeId = pickMode(humans)
	local arenaId = tally(S.votes.arena, S.voteArenas, S.voteArenas[1] or ArenasConfig.Default)
	local host = S.hostId
	if host ~= 0 then
		arenaId = S.votes.arena[host] or arenaId
	end
	local ranked = false
	if host == 0 then
		ranked = (MatchPlan.rankedEligible(ModesConfig.copy(modeId), humans, rankedEnv()))
	end
	-- a ranked match never takes private rules; the host's Mode key wins otherwise
	local mode = ModesConfig.resolve(modeId, {
		ranked = ranked,
		private = if host ~= 0 then S.privateConfig else nil,
	})
	local arena = (ArenasConfig.List :: any)[arenaId] or ArenasConfig.List[ArenasConfig.Default]
	if (mode.Ranked and not arena.Competitive) or (not mode.SpecialArenas and arena.Rebound) then
		arena = ArenasConfig.List[ArenasConfig.Default]
	end
	S.mode = mode
	S.matchCount += 1
	if arena.id ~= S.arenaId or mode.Field ~= services.ArenaService.fieldName() then
		S.arenaId = arena.id
		services.ArenaService.build(arena.id, mode.Field)
	end
	set("Mode", mode.id)
	set("ModeName", mode.Display)
	set("TeamSize", mode.TeamSize)
	set("PointsToWin", mode.PointsToWin)
	set("StallMax", mode.StallMax)
	set("PreviewFraction", mode.PreviewFraction)
	set("LandingShadow", mode.LandingShadow)
	set("Ranked", mode.Ranked)
	setLobbyText("")

	S.stats = {}
	S.lastCatchAt = {}
	S.rotation = { A = 0, B = 0 }
	S.penalized = {}
	S.pvp = false
	services.ProgressionService.matchStarted()
	services.TeamService.assignForMatch(mode)
	services.TeamService.waitForBots(BOT_WAIT)

	local engine = RulesEngine.new(field(), { pointsToWin = mode.PointsToWin, usePull = mode.UsePull })
	local first = if S.matchCount % 2 == 0 then "A" else "B"
	RulesEngine.startMatch(engine, first, "East")
	engine.universe = mode.StartUniverse
	S.engine = engine
	S.matchEnd = now() + mode.TimeCap
	set("MatchEnd", S.matchEnd)
	if not S.disc then
		S.disc = services.DiscService.create("Match", nil, matchHandler)
	end
	-- the arena's wind is constant for the match (it "flips with the teams"
	-- because they swap ends); every throw, pull and bot solve uses it
	services.DiscService.setWind(S.disc, services.ArenaService.windVector())
	set("DiscId", S.disc.id)
	notifyAll("Banner", string.upper(mode.Display), { sub = if mode.Ranked then "RANKED" else arena.Display })
	setupPoint()
	-- humans who arrived while the match was starting
	local pending = S.pendingJoin
	S.pendingJoin = {}
	for _, a in pending do
		if services.PlayerService.get(a.id) and a.role ~= "Training" then
			placeIntoMatch(a)
		end
	end
end

---------------------------------------------------------------------------
-- per-frame
---------------------------------------------------------------------------

-- No teleport: an eligible player who reaches the disc slowly (or presses the
-- pickup key) gets it, the pivot is planted on the disc and their client
-- glides onto it.
local function pickupCheck(d: any, allowTeam: string?)
	if not d or d.mode ~= "Ground" then
		return
	end
	local spot = d.folder:GetAttribute("GroundPos")
	if typeof(spot) ~= "Vector3" then
		return
	end
	local tNow = now()
	local best, bestDist = nil, DiscConfig.Catch.PickupRadius
	for _, a in services.PlayerService.all() do
		local eligible = if allowTeam then (a.team == allowTeam and a.role == "Match") else a.role ~= "Training"
		local root = eligible and services.PlayerService.root(a)
		if root then
			local pos = root.Position
			local dist = Vector3.new(pos.X - spot.X, 0, pos.Z - spot.Z).Magnitude
			if dist < bestDist and math.abs(pos.Y - spot.Y) < 8 then
				local v = root.AssemblyLinearVelocity
				local slow = Vector3.new(v.X, 0, v.Z).Magnitude < PICKUP_SPEED
				local pressed = (S.pickupWanted[a.id] or -math.huge) >= tNow - PICKUP_KEY_WINDOW
				if a.isBot or slow or pressed then
					best, bestDist = a, dist
				end
			end
		end
	end
	if not best then
		return
	end
	local outcomes = {}
	if allowTeam then
		local e = S.engine :: RulesEngine.State
		outcomes = RulesEngine.pickup(e, best.id, best.team)
		if #outcomes == 0 then
			return
		end
	end
	S.pickupWanted[best.id] = nil
	services.DiscService.giveTo(d, best.id)
	services.MovementService.setPivot(best.id, standingAt(best.id, spot))
	services.MovementService.skipTravel(best.id, GATHER_SKIP + 2 * services.MovementService.ping(best.id))
	applySkin(d, best.id)
	if allowTeam then
		applyOutcomes(outcomes)
	end
end

-- The pickup key (humans via Action "Pickup", bots directly).
function MatchService.requestPickup(actorId: number)
	S.pickupWanted[actorId] = now()
end

local function stepIntermission(t: number)
	pickupCheck(S.warmupDisc, nil)
	local humans = humansNotTraining()
	setLobbyText(if humans == 1 then SOLO_TEXT else "")
	if humans == 0 then
		if S.phaseEnd ~= math.huge then
			setPhase("Intermission", nil)
		end
		return
	end
	if S.phaseEnd == math.huge then
		S.phaseEnd = t + (lobbyDuration(humans) :: number)
		set("PhaseEnd", S.phaseEnd)
	elseif humans >= 2 and S.phaseEnd - t > INTERMISSION_PVP then
		-- someone joined a solo countdown: PvP starts sooner
		S.phaseEnd = t + INTERMISSION_PVP
		set("PhaseEnd", S.phaseEnd)
	end
	if t >= S.phaseEnd then
		-- startMatch yields (arena rebuild, bot spawning); mark the phase
		-- first so later Heartbeats cannot start a second match
		setPhase("Starting")
		task.spawn(function()
			local ok, err = pcall(function()
				startMatch()
			end)
			if not ok then
				warn("[MatchService] startMatch failed: " .. tostring(err))
				startIntermission()
			end
		end)
	end
end

local function step()
	local t = now()
	local phase = S.phase
	if phase == "Intermission" then
		stepIntermission(t)
		return
	end
	if phase == "Starting" or phase == "Boot" then
		return
	end
	local e = S.engine
	if not e then
		return
	end
	local holder = e.holder
	if holder then
		local r = services.Actors.rootOf(holder)
		if r then
			S.holderPos = r.Position
		end
	end
	if
		t >= S.matchEnd
		and not e.capReached
		and (phase == "Live" or phase == "Pull" or phase == "PointSetup" or phase == "PointOver")
	then
		applyOutcomes(RulesEngine.reachCap(e))
	end
	if phase == "PointSetup" then
		local unfreezeAt = S.unfreezeAt
		if unfreezeAt and t >= unfreezeAt then
			-- the line-up has settled: move freely behind your own goal line
			S.unfreezeAt = nil
			unfreezeAll()
		end
		tryGiveStarter()
		if t >= S.phaseEnd then
			endPointSetup()
		end
	elseif phase == "Pull" then
		if t >= S.phaseEnd then
			if not autoPull() then
				-- the puller vanished: give the receivers the disc at the brick
				startAtBrick()
			end
		end
	elseif phase == "Live" then
		if e.disc == "Ground" then
			pickupCheck(S.disc, e.offense)
		end
		if e.phase == "MatchOver" and not S.pendingMatchOver then
			S.pendingMatchOver = true
		end
	elseif phase == "PointOver" then
		if t >= S.phaseEnd then
			if S.pendingMatchOver or e.phase == "MatchOver" then
				endMatch()
			else
				setupPoint()
			end
		end
	elseif phase == "MatchOver" then
		if t >= S.phaseEnd then
			startIntermission()
		end
	end
	-- time cap reached between points ends the match
	if e.phase == "MatchOver" and (S.phase == "PointSetup" or S.phase == "Pull") then
		endMatch()
	end
end

---------------------------------------------------------------------------
-- roster changes
---------------------------------------------------------------------------

-- Bots arrived, a joiner was benched, a leaver was replaced: put everyone who
-- is not where their team and role belong in place.
local function onLineChanged()
	publishCounts()
	local e = S.engine
	if not e or S.suppressPlacement then
		return
	end
	local phase = S.phase
	if phase ~= "PointSetup" and phase ~= "Pull" and phase ~= "Live" and phase ~= "PointOver" then
		return
	end
	for _, team in { "A", "B" } do
		local ids = services.TeamService.lineFor(team)
		for _, id in services.TeamService.benchFor(team) do
			table.insert(ids, id)
		end
		for _, id in ids do
			local actor = services.PlayerService.get(id)
			if actor and actor.character and S.placed[id] ~= placedKey(actor) then
				placeActor(actor)
			end
		end
	end
	tryGiveStarter()
end

function placeIntoMatch(actor: any)
	if actor.isBot or actor.role == "Training" then
		return
	end
	local phase = S.phase
	if phase == "Starting" then
		if not table.find(S.pendingJoin, actor) then
			table.insert(S.pendingJoin, actor)
		end
		return
	end
	if not S.engine or phase == "Intermission" or phase == "Boot" or phase == "MatchOver" then
		services.PlayerService.setLine(actor, nil, nil)
		services.PlayerService.teleport(actor, services.ArenaService.spawnCFrame(), { face = true })
		if phase == "Intermission" then
			refreshVoteOptions()
		end
		return
	end
	-- joins the team with fewer humans on its bench; placed by onLineChanged
	services.TeamService.placeLateJoiner(actor)
end

-- A ranked roster player abandoned the match (left the game or went to
-- training): they take the loss (once). The result is void for the rest.
local function penalizeLeaver(actor: any)
	local e = S.engine
	local player = actor.player
	if not e or not player or S.penalized[actor.id] or S.pendingMatchOver or e.phase == "MatchOver" then
		return
	end
	local team = services.TeamService.rankedRosterTeam(actor.id)
	if not team then
		return
	end
	S.penalized[actor.id] = true
	local ratings = services.TeamService.rosterRatings()
	local mine = if team == "A" then ratings.A else ratings.B
	local theirs = if team == "A" then ratings.B else ratings.A
	services.ProgressionService.rankedLoss(player, mine, theirs)
	notifyAll("Toast", actor.name .. " left a ranked match — result void", nil)
end

-- The holder vanished (left, or their character respawned).
local function holderGone(actor: any, pos: Vector3)
	local e = S.engine
	if not e or e.holder ~= actor.id then
		return
	end
	if S.phase == "Pull" then
		-- no pull is coming: the receivers start on their brick
		startAtBrick()
	else
		applyOutcomes(RulesEngine.holderLeft(e, pos))
	end
end

-- An actor stops playing this point (left the game or went to training).
local function forgetActor(actor: any)
	local e = S.engine
	if e and e.holder == actor.id then
		local root = services.PlayerService.root(actor)
		holderGone(actor, if root then root.Position else (S.holderPos or field().center))
	end
	if S.starter == actor.id then
		-- the point's disc goes to someone else (tryGiveStarter)
		S.starter = nil
		S.puller = nil
	end
	releaseSlot(actor.id)
	S.lineSides[actor.id] = nil
	S.placed[actor.id] = nil
	S.pickupWanted[actor.id] = nil
end

local function onActorRemoving(actor: any)
	forgetActor(actor)
	S.votes.mode[actor.id] = nil
	S.votes.arena[actor.id] = nil
	local pendingIndex = table.find(S.pendingJoin, actor)
	if pendingIndex then
		table.remove(S.pendingJoin, pendingIndex)
	end
	if actor.isBot then
		return
	end
	if actor.id == S.hostId and game.PrivateServerOwnerId == 0 then
		-- the Studio host left: the next human (oldest id first) hosts
		local nextHost = 0
		for _, h in services.PlayerService.humans() do
			if h.id ~= actor.id then
				nextHost = h.id
				break
			end
		end
		S.hostId = nextHost
		set("HostId", S.hostId)
	end
	penalizeLeaver(actor)
	if services.TeamService.inMatch() then
		services.TeamService.remove(actor)
	elseif S.phase == "Intermission" then
		-- the leaver still counts until this signal returns
		task.defer(function()
			if S.phase == "Intermission" then
				refreshVoteOptions()
			end
		end)
	end
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------

local function isHost(actorId: number): boolean
	return S.hostId ~= 0 and actorId == S.hostId
end

function MatchService.action(player: Player, kind: string, payload: any)
	local actor = services.PlayerService.fromPlayer(player)
	if not actor then
		return
	end
	if kind == "Vote" and S.phase == "Intermission" and type(payload) == "table" then
		if payload.mode and table.find(S.voteModes, payload.mode) then
			S.votes.mode[actor.id] = payload.mode
		end
		if payload.arena and table.find(S.voteArenas, payload.arena) then
			S.votes.arena[actor.id] = payload.arena
		end
		publishVotes()
		publishRanked()
	elseif kind == "StartNow" and isHost(actor.id) and S.phase == "Intermission" then
		S.phaseEnd = now()
	elseif kind == "PrivateConfig" and isHost(actor.id) and type(payload) == "table" then
		if type(payload.key) == "string" then
			local v = ModesConfig.sanitize(payload.key, payload.value)
			if v ~= nil then
				S.privateConfig[payload.key] = v
				set("PrivateConfig", HttpService:JSONEncode(S.privateConfig))
				if S.phase == "Intermission" then
					publishRanked()
				end
			end
		end
	elseif kind == "Pickup" then
		MatchService.requestPickup(actor.id)
	elseif kind == "Celebrate" and (S.phase == "PointOver" or S.phase == "MatchOver") then
		if actor.character and actor.player then
			actor.character:SetAttribute("Celebrate", services.ProgressionService.equipped(actor.player, "celebration"))
			actor.character:SetAttribute("CelebrateT", now())
		end
	elseif kind == "JoinMatch" then
		local training = actor.role == "Training"
		if S.phase == "Intermission" and not training then
			return -- the warm-up already plays the next match (no spawn teleport)
		end
		if training then
			services.TrainingService.leave(actor)
		end
		if actor.role ~= "Match" and actor.role ~= "Bench" then
			placeIntoMatch(actor)
		end
	end
end

function MatchService.onLeftTraining(actor: any)
	placeIntoMatch(actor)
end

function MatchService.Init(s: any)
	services = s
	stateFolder = Net.state()
end

function MatchService.Start()
	-- host for private servers (or the first player in Studio)
	if game.PrivateServerOwnerId ~= 0 then
		S.hostId = game.PrivateServerOwnerId
	end
	set("HostId", S.hostId)

	local function onHumanAdded(actor: any)
		if actor.isBot then
			return
		end
		if S.hostId == 0 and RunService:IsStudio() then
			S.hostId = actor.id
			set("HostId", S.hostId)
		end
		task.defer(function()
			if services.PlayerService.get(actor.id) == actor then
				placeIntoMatch(actor)
			end
		end)
	end
	services.PlayerService.ActorAdded:Connect(onHumanAdded)
	services.PlayerService.ActorRemoving:Connect(onActorRemoving)
	-- players who joined while the server was still starting (DataService's
	-- probe yields during Init): PlayerService announced them before this
	-- listener existed
	for _, actor in services.PlayerService.humans() do
		onHumanAdded(actor)
	end
	services.PlayerService.CharacterSpawned:Connect(function(actor, _model)
		if actor.isBot then
			return
		end
		task.defer(function()
			local e = S.engine
			if e and (actor.team == "A" or actor.team == "B") and (actor.role == "Match" or actor.role == "Bench") then
				holderGone(actor, S.holderPos or field().center)
				S.placed[actor.id] = nil
				placeActor(actor)
				if S.phase == "PointSetup" and S.starter == actor.id then
					-- the point's starter respawned: hand the disc to the new body
					giveStarter(actor.id)
				end
			elseif actor.role == "Training" then
				services.TrainingService.respawned(actor)
			else
				services.PlayerService.teleport(actor, services.ArenaService.spawnCFrame(), { face = true })
			end
		end)
	end)
	services.TeamService.LineChanged:Connect(onLineChanged)
	services.TeamService.TrainingChanged:Connect(function(actor, training)
		if training then
			forgetActor(actor)
			penalizeLeaver(actor)
		end
		if S.phase == "Intermission" then
			refreshVoteOptions()
		end
	end)
	-- a ranked leaver's loss must be written before their profile is released
	services.DataService.Releasing:Connect(function(player)
		local actor = services.PlayerService.fromPlayer(player)
		if actor then
			penalizeLeaver(actor)
		end
	end)
	services.MovementService.Landed:Connect(function(id, pos)
		local e = S.engine
		if e and e.holder == id and e.pending then
			applyOutcomes(RulesEngine.land(e, id, pos))
		end
	end)
	services.MovementService.Travel:Connect(function(id)
		notify(id, "Travel", "Travel — reset to your pivot", nil)
	end)
	services.DefenseService.StallOut:Connect(function(holderId)
		local e = S.engine
		if e and e.holder == holderId and S.phase == "Live" then
			local root = services.Actors.rootOf(holderId)
			notifyAll("Turnover", "STALL", { reason = "Stall" })
			applyOutcomes(RulesEngine.stall(e, if root then root.Position else Vector3.zero))
		end
	end)
	Net.event("Action").OnServerEvent:Connect(function(player, kind, payload)
		if type(kind) ~= "string" then
			return
		end
		MatchService.action(player, kind, payload)
		services.ProgressionService.action(player, kind, payload)
		services.TrainingService.action(player, kind, payload)
	end)
	RunService.Heartbeat:Connect(step)
	startIntermission()
	local _ = Players
end

return MatchService
