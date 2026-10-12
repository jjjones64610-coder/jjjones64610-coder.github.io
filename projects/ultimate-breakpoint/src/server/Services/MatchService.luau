--!strict
--[[
	MatchService — the match loop.

	  Intermission  free-play warm-up disc, mode + arena votes (private-server
	                host can configure rules and start early)
	  PointSetup    teams line up on the goal lines they defend, frozen; end
	                zones glow in the colour of the team attacking them
	  Pull          the defending team's puller throws to the receivers
	                (modes without pulls skip straight to Live)
	  Live          the RulesEngine decides what every catch, landing, block
	                and stall-out means; this service applies the result
	  PointOver     celebration, then the next point (teams switch ends)
	  MatchOver     summary, progression, ranked rating, back to Intermission

	Match state is published as attributes on ReplicatedStorage.UBState so
	late joiners and every UI read the same truth.
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
local Solver = require(Shared.Disc.Solver)

local MatchService = {}

local services: any
local stateFolder: Folder

type Stats = { [string]: number }

type MatchState = {
	phase: string,
	phaseEnd: number,
	mode: any,
	arenaId: string,
	fieldName: string,
	engine: RulesEngine.State?,
	disc: any,
	warmupDisc: any,
	matchEnd: number,
	matchCount: number,
	rotation: { [string]: number },
	puller: number?,
	stats: { [number]: Stats },
	lastPass: { [string]: any }?,
	lastCatchAt: { [number]: number },
	flow: number,
	votes: { mode: { [number]: string }, arena: { [number]: string } },
	voteModes: { string },
	voteArenas: { string },
	privateConfig: { [string]: any },
	hostId: number,
	groundSince: number,
	pendingMatchOver: boolean,
	pointStartedAt: number,
	botsUsed: boolean,
}

local S: MatchState = {
	phase = "Boot",
	phaseEnd = 0,
	mode = ModesConfig.copy("Casual"),
	arenaId = ArenasConfig.Default,
	fieldName = "Standard",
	engine = nil,
	disc = nil,
	warmupDisc = nil,
	matchEnd = 0,
	matchCount = 0,
	rotation = { A = 0, B = 0 },
	puller = nil,
	stats = {},
	lastPass = nil,
	lastCatchAt = {},
	flow = 0,
	votes = { mode = {}, arena = {} },
	voteModes = {},
	voteArenas = {},
	privateConfig = {},
	hostId = 0,
	groundSince = 0,
	pendingMatchOver = false,
	pointStartedAt = 0,
	botsUsed = false,
}

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

function MatchService.mode(): any
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

local function teleportToSide(actor: any, side: string, index: number, count: number)
	local f = services.ArenaService.field()
	local spots = FieldGeometry.lineup(f, side :: any, math.max(count, 1))
	local spot = spots[math.clamp(index, 1, #spots)]
	services.PlayerService.teleport(actor, faceField(spot + Vector3.new(0, 3.2, 0)))
end

local function startStallFor(id: number)
	services.DefenseService.startStall(id, S.mode.StallInterval, S.mode.StallMax)
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
	local f = services.ArenaService.field()
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
		services.DiscService.placeOnGround(d, services.ArenaService.field().center)
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
	local f = services.ArenaService.field()
	services.DiscService.placeOnGround(d, FieldGeometry.clampInBounds(f, land, 2))
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
	services.PlayerService.setAllFrozen(false)
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
				services.PlayerService.teleport(actor, faceField(o.spot + Vector3.new(0, 3.2, 0)))
				services.MovementService.setPivot(o.id, o.spot + Vector3.new(0, 3, 0))
			end
		elseif kind == "PullReleased" then
			services.PlayerService.setAllFrozen(false)
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

local function chooseRotating(team: string): any?
	local members = services.PlayerService.onTeam(team)
	if #members == 0 then
		return nil
	end
	S.rotation[team] = (S.rotation[team] % #members) + 1
	return members[S.rotation[team]]
end

local function setupPoint()
	local e = S.engine :: RulesEngine.State
	local setup = RulesEngine.setupPoint(e)
	S.pointStartedAt = now()
	S.lastPass = nil
	S.flow = 0
	recolorEndZones()
	publishScore()
	services.DefenseService.stopStall()
	services.DiscService.hide(S.disc)
	setHolderAttr(nil)

	local offense = services.PlayerService.onTeam(setup.offense)
	local defense = services.PlayerService.onTeam(setup.defense)
	for i, a in offense do
		teleportToSide(a, setup.offenseLine, i, #offense)
	end
	for i, a in defense do
		teleportToSide(a, setup.defenseLine, i, #defense)
	end
	services.PlayerService.setAllFrozen(true, function(a)
		return a.role == "Match"
	end)

	local f = services.ArenaService.field()
	if setup.pull then
		local puller = chooseRotating(setup.defense)
		S.puller = if puller then puller.id else nil
		if puller then
			local spot = FieldGeometry.goalLinePoint(f, Vector3.zero, setup.defenseLine)
			local inward = FieldGeometry.attackDirection(FieldGeometry.other(setup.defenseLine))
			services.PlayerService.teleport(puller, faceField(spot + inward * 2 + Vector3.new(0, 3.2, 0)))
			services.DiscService.giveTo(S.disc, puller.id)
			applySkin(S.disc, puller.id)
			S.disc.meta.pullPending = true
		end
	else
		local holder = chooseRotating(setup.offense)
		S.puller = nil
		if holder then
			local spot = FieldGeometry.goalLinePoint(f, Vector3.zero, setup.offenseLine)
			local inward = FieldGeometry.attackDirection(FieldGeometry.other(setup.offenseLine))
			services.PlayerService.teleport(holder, faceField(spot + inward * 2 + Vector3.new(0, 3.2, 0)))
			services.DiscService.giveTo(S.disc, holder.id)
			applySkin(S.disc, holder.id)
			S.disc.meta.pullHolder = holder.id
		end
	end
	notifyAll("Point", if setup.universe then "UNIVERSE POINT" else ("POINT " .. setup.point), {
		offense = setup.offense,
		pull = setup.pull,
	})
	setPhase("PointSetup", S.mode.PointSetupTime)
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
	local f = services.ArenaService.field()
	local target = FieldGeometry.endZoneCenter(f, RulesEngine.defends(e, e.offense))
	local d = target - root.Position
	local sol = Solver.solve({
		rootPos = root.Position,
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

local function endPointSetup()
	local e = S.engine :: RulesEngine.State
	if S.mode.UsePull and S.puller then
		RulesEngine.beginPull(e, S.puller)
		setPhase("Pull", S.mode.PullTimeout)
		local puller = services.PlayerService.get(S.puller)
		if puller then
			services.PlayerService.setFrozen(puller, false)
			if puller.isBot then
				services.BotService.schedulePull(puller.id)
			else
				notify(puller.id, "Banner", "YOU'RE PULLING", { sub = "Throw it deep to the other team" })
			end
		end
	else
		local holder = S.disc.meta.pullHolder
		RulesEngine.beginLive(e, holder)
		services.PlayerService.setAllFrozen(false)
		setPhase("Live")
		if holder then
			setHolderAttr(holder)
			startStallFor(holder)
		end
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
	local rankedValid = false
	if S.mode.Ranked and not S.botsUsed then
		local a, b = 0, 0
		for _, row in sum.rows do
			if not row.bot then
				if row.team == "A" then
					a += 1
				else
					b += 1
				end
			end
		end
		rankedValid = a >= 2 and b >= 2
	end
	local ratingChanges = services.ProgressionService.matchEnded(
		e.winner,
		S.stats,
		sum.rows,
		rankedValid,
		math.abs(e.score.A - e.score.B)
	)
	sum.ratingChanges = ratingChanges
	sum.ranked = rankedValid
	Net.event("Summary"):FireAllClients(sum)
	notifyAll(
		"Banner",
		(if e.winner then teamName(e.winner) else "") .. " WIN",
		{ sub = string.format("%d - %d", e.score.A, e.score.B) }
	)
	services.DefenseService.stopStall()
	services.PlayerService.setAllFrozen(false)
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

local function startIntermission()
	S.engine = nil
	S.pendingMatchOver = false
	services.TeamService.clearMatch()
	services.DefenseService.stopStall()
	if S.disc then
		services.DiscService.hide(S.disc)
	end
	-- warm-up disc on the field
	if not S.warmupDisc then
		S.warmupDisc = services.DiscService.create("Warmup", nil, warmupHandler)
	end
	services.DiscService.placeOnGround(S.warmupDisc, Vector3.new(0, 0, -20))
	recolorEndZones()
	publishScore()
	setHolderAttr(nil)
	S.votes = { mode = {}, arena = {} }
	local humans = humansNotTraining()
	local modes = {}
	for _, id in ModesConfig.Order do
		local m = (ModesConfig.List :: any)[id]
		if m.Selectable and (not m.Ranked or humans >= 4) then
			table.insert(modes, id)
		end
	end
	local arenas = {}
	local order = ArenasConfig.Order
	for i = 0, 2 do
		table.insert(arenas, order[((S.matchCount + i) % #order) + 1])
	end
	S.voteModes = modes
	S.voteArenas = arenas
	set("VoteModes", table.concat(modes, ","))
	set("VoteArenas", table.concat(arenas, ","))
	publishVotes()
	services.PlayerService.setAllFrozen(false)
	setPhase("Intermission", if humans > 0 then 20 else nil)
end

local function startMatch()
	if S.warmupDisc then
		services.DiscService.hide(S.warmupDisc)
	end
	-- resolve votes (private server host overrides)
	local modeId = tally(S.votes.mode, S.voteModes, "Casual")
	local arenaId = tally(S.votes.arena, S.voteArenas, S.voteArenas[1] or ArenasConfig.Default)
	local host = S.hostId
	if host ~= 0 then
		modeId = S.votes.mode[host] or modeId
		arenaId = S.votes.arena[host] or arenaId
	end
	local mode = ModesConfig.copy(modeId)
	if mode.Ranked and humansNotTraining() < 4 then
		mode = ModesConfig.copy("Casual")
	end
	if host ~= 0 then
		for k, v in S.privateConfig do
			(mode :: any)[k] = v
		end
	end
	local arena = (ArenasConfig.List :: any)[arenaId] or ArenasConfig.List[ArenasConfig.Default]
	if (mode.Ranked and not arena.Competitive) or (not mode.SpecialArenas and arena.Rebound) then
		arena = ArenasConfig.List[ArenasConfig.Default]
	end
	S.mode = mode
	S.matchCount += 1
	if arena.id ~= S.arenaId or mode.Field ~= S.fieldName then
		S.arenaId = arena.id
		S.fieldName = mode.Field
		services.ArenaService.build(arena.id, mode.Field)
	end
	set("Mode", mode.id)
	set("ModeName", mode.Display)
	set("PointsToWin", mode.PointsToWin)
	set("StallMax", mode.StallMax)
	set("PreviewFraction", mode.PreviewFraction)
	set("LandingShadow", mode.LandingShadow)
	set("Ranked", mode.Ranked)

	services.TeamService.assignForMatch(mode)
	S.botsUsed = false
	for _, a in services.PlayerService.all() do
		if a.isBot then
			S.botsUsed = true
		end
	end

	S.stats = {}
	S.lastCatchAt = {}
	S.rotation = { A = 0, B = 0 }
	local engine =
		RulesEngine.new(services.ArenaService.field(), { pointsToWin = mode.PointsToWin, usePull = mode.UsePull })
	local first = if S.matchCount % 2 == 0 then "A" else "B"
	RulesEngine.startMatch(engine, first, "East")
	engine.universe = mode.StartUniverse
	S.engine = engine
	S.matchEnd = now() + mode.TimeCap
	set("MatchEnd", S.matchEnd)
	if not S.disc then
		S.disc = services.DiscService.create("Match", nil, matchHandler)
	end
	set("DiscId", S.disc.id)
	notifyAll("Banner", string.upper(mode.Display), { sub = arena.Display })
	setupPoint()
end

---------------------------------------------------------------------------
-- per-frame
---------------------------------------------------------------------------

local function pickupCheck(d: any, allowTeam: string?)
	if not d or d.mode ~= "Ground" then
		return
	end
	local spot = d.folder:GetAttribute("GroundPos") :: Vector3?
	if not spot then
		return
	end
	local best, bestDist = nil, DiscConfig.Catch.PickupRadius
	for _, a in services.PlayerService.all() do
		if a.role ~= "Training" and (allowTeam == nil or a.team == allowTeam) then
			local root = services.PlayerService.root(a)
			if root then
				local dist = Vector3.new(root.Position.X - spot.X, 0, root.Position.Z - spot.Z).Magnitude
				if dist < bestDist and math.abs(root.Position.Y - spot.Y) < 8 then
					best, bestDist = a, dist
				end
			end
		end
	end
	if not best then
		return
	end
	if allowTeam then
		local e = S.engine :: RulesEngine.State
		local outcomes = RulesEngine.pickup(e, best.id, best.team)
		if #outcomes == 0 then
			return
		end
		services.PlayerService.teleport(
			best,
			CFrame.new(Vector3.new(spot.X, spot.Y + 3, spot.Z))
				* (services.PlayerService.root(best) :: BasePart).CFrame.Rotation
		)
		services.DiscService.giveTo(d, best.id)
		services.MovementService.setPivot(best.id, Vector3.new(spot.X, spot.Y + 3, spot.Z))
		applySkin(d, best.id)
		applyOutcomes(outcomes)
	else
		services.DiscService.giveTo(d, best.id)
		applySkin(d, best.id)
	end
end

local function step()
	local t = now()
	local phase = S.phase
	if phase == "Intermission" then
		pickupCheck(S.warmupDisc, nil)
		if S.phaseEnd == math.huge and humansNotTraining() > 0 then
			S.phaseEnd = t + 20
			set("PhaseEnd", S.phaseEnd)
		elseif S.phaseEnd ~= math.huge and humansNotTraining() == 0 and #services.PlayerService.humans() == 0 then
			setPhase("Intermission", nil)
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
		return
	end
	if phase == "Starting" then
		return
	end
	local e = S.engine
	if not e then
		return
	end
	if
		t >= S.matchEnd
		and not e.capReached
		and (phase == "Live" or phase == "Pull" or phase == "PointSetup" or phase == "PointOver")
	then
		applyOutcomes(RulesEngine.reachCap(e))
	end
	if phase == "PointSetup" then
		if t >= S.phaseEnd then
			endPointSetup()
		end
	elseif phase == "Pull" then
		if t >= S.phaseEnd then
			if not autoPull() then
				-- the puller vanished: give the receivers the disc at the brick
				RulesEngine.beginLive(e, nil)
				e.disc = "Ground"
				local f = services.ArenaService.field()
				local spot = FieldGeometry.brickPoint(f, RulesEngine.defends(e, e.offense))
				e.discSpot = spot
				services.DiscService.placeOnGround(S.disc, spot)
				services.PlayerService.setAllFrozen(false)
				setPhase("Live")
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

local function placeIntoMatch(actor: any)
	if S.phase == "Intermission" or S.phase == "Boot" or S.phase == "MatchOver" then
		services.PlayerService.teleport(actor, services.ArenaService.spawnCFrame())
		return
	end
	services.TeamService.placeLateJoiner(actor)
	local e = S.engine
	if e and (actor.team == "A" or actor.team == "B") then
		local side = RulesEngine.defends(e, actor.team)
		teleportToSide(actor, side, math.random(1, 5), 5)
		services.PlayerService.setFrozen(actor, S.phase == "PointSetup" or (S.phase == "Pull" and actor.id ~= S.puller))
	end
end

local function onActorRemoving(actor: any)
	local e = S.engine
	if e and e.holder == actor.id then
		local root = services.PlayerService.root(actor)
		local pos = if root then root.Position else services.ArenaService.field().center
		if S.phase == "Pull" then
			S.puller = nil
		end
		applyOutcomes(RulesEngine.holderLeft(e, pos))
	end
	S.votes.mode[actor.id] = nil
	S.votes.arena[actor.id] = nil
	if not actor.isBot and S.engine then
		task.defer(function()
			services.TeamService.rebalance()
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
	elseif kind == "StartNow" and isHost(actor.id) and S.phase == "Intermission" then
		S.phaseEnd = now()
	elseif kind == "PrivateConfig" and isHost(actor.id) and type(payload) == "table" then
		local spec = (ModesConfig.Editable :: any)[payload.key]
		if spec then
			local v = payload.value
			if
				(spec.bool and type(v) == "boolean")
				or (spec.options and type(v) == "string" and table.find(spec.options, v))
			then
				S.privateConfig[payload.key] = v
			elseif spec.min and type(v) == "number" and v == v then
				S.privateConfig[payload.key] = math.clamp(v, spec.min, spec.max)
			end
			set("PrivateConfig", HttpService:JSONEncode(S.privateConfig))
		end
	elseif kind == "Celebrate" and S.phase == "PointOver" or (kind == "Celebrate" and S.phase == "MatchOver") then
		if actor.character and actor.player then
			actor.character:SetAttribute("Celebrate", services.ProgressionService.equipped(actor.player, "celebration"))
			actor.character:SetAttribute("CelebrateT", now())
		end
	elseif kind == "JoinMatch" then
		if actor.role == "Training" then
			services.TrainingService.leave(actor)
		end
		if actor.role ~= "Match" then
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

	services.PlayerService.ActorAdded:Connect(function(actor)
		if actor.isBot then
			return
		end
		if S.hostId == 0 and RunService:IsStudio() then
			S.hostId = actor.id
			set("HostId", S.hostId)
		end
		task.defer(function()
			placeIntoMatch(actor)
		end)
	end)
	services.PlayerService.ActorRemoving:Connect(onActorRemoving)
	services.PlayerService.CharacterSpawned:Connect(function(actor, _model)
		if actor.isBot then
			return
		end
		task.defer(function()
			if actor.role == "Match" and S.engine and (actor.team == "A" or actor.team == "B") then
				local e = S.engine :: RulesEngine.State
				if e.holder == actor.id then
					applyOutcomes(RulesEngine.holderLeft(e, services.ArenaService.field().center))
				end
				teleportToSide(actor, RulesEngine.defends(e, actor.team), math.random(1, 5), 5)
				services.PlayerService.setFrozen(actor, S.phase == "PointSetup")
			elseif actor.role == "Training" then
				services.TrainingService.respawned(actor)
			else
				services.PlayerService.teleport(actor, services.ArenaService.spawnCFrame())
			end
		end)
	end)
	services.MovementService.Landed:Connect(function(id, pos)
		local e = S.engine
		if e and e.holder == id and e.pending then
			applyOutcomes(RulesEngine.land(e, id, pos))
		end
	end)
	services.MovementService.Travel:Connect(function(id)
		notify(id, "Toast", "Travel — reset to your pivot", nil)
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
