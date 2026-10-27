--!strict
--[[
	CatchingService — every catch, block and bobble is decided here.

	Humans: the client sees its own body where it really is and the disc at
	the shared server time, so it detects contact itself, keeps tracking the
	disc until the closest approach (at most ClaimTrackTime) and sends a
	claim (discId, tFirst, zoneKind, reachDir, rootPos, rootVel). The server:
	  * builds the claimer's zones from the body position the client sent
	    when it is within CatchGeometry.claimRoot's tolerance of the server's
	    (lagging) view, otherwise from the server root led by its velocity
	  * widens them by CatchGeometry.slack(ping, body speed)
	  * judges quality at the closest approach: the minimum depth over
	    [tFirst, tFirst + QualityWindow] of the disc's deterministic history,
	    in the body's moving frame (CatchGeometry.bestOverPath). tFirst still
	    orders contests; running into a disc never makes it a rim catch
	  * collects claims for ResolveDelay so near-simultaneous touches become a
	    fair contest (ContestWindow) instead of first-packet-wins.
	Every claim is answered: CatchResult(discId, accepted, result, flightId)
	with "Denied" at once for a refused claim (also when rate-limited at
	ClaimRateLimit, or when the disc stopped being catchable before the
	resolve), otherwise the outcome at resolve time.

	Bots: checked directly on the server every simulation step, with the same
	closest-approach rule over the next QualityWindow of the flight.

	Outcomes (CatchGeometry.outcome):
	  Catch    the winner holds on (an interception when it is a defender)
	  Block    a defender who only got the rim (depth > BlockDepth)
	  Bobble   a contested, or very fast (disc speed > BobbleSpeed),
	           fingertip catch pops the disc up
	Blocks and bobbles re-launch the disc from the contact point at the
	contact time (DiscService.deflect), so every client sees it continue from
	the touch instead of rewinding. The disc stays live; the toucher may not
	re-claim it for a moment.

	Tips (the Tip Reset): an airborne player presses Secondary as the disc
	passes their hands; the client sends a claim of kind "Tip" with the press
	time. The server judges it on the disc's closest pass within
	Reset.TipWindow of the press (CatchGeometry.bestTip, tip zones incl. the
	hands-up sphere) and resolves it with the other claims. A winning tip pops
	the disc up out of the tipper's hands (CatchGeometry.tipVelocity), counts
	as a touch for the rules (a Tip for the throwing team, a Block for the
	defence) and lets MovementService accept the tipper's TipReset technique.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local Hitbox = require(Shared.Config.Hitbox)
local VecMath = require(Shared.Util.VecMath)
local Actors = require(Shared.Actors)
local Net = require(Shared.Net)

local C = DiscConfig.Catch
local RS = MovementConfig.Reset

-- quality window sampling: first contact + QualitySamples steps
local SAMPLE_DT = C.QualityWindow / math.max(C.QualitySamples, 1)
-- a client-reported body velocity faster than this is junk
local MAX_BODY_SPEED = MovementConfig.HardCap + 12
-- how far into the future a claim time may be (clock jitter) before it is clamped
local FUTURE_SLACK = 0.05

local CatchingService = {}

local services: any

type ReachState = { at: number, dir: Vector3 }
local reaches: { [number]: ReachState } = {}
local lastClaim: { [number]: number } = {}
-- the latest tip claim per actor: "pending" until resolved, then "ok" / "denied"
type TipState = { t: number, discId: string, state: string }
local tips: { [number]: TipState } = {}

local function now(): number
	return Net.now()
end

local function finiteVec(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local p = v :: Vector3
	local m = p.Magnitude
	if m ~= m or m > 1e6 then
		return nil
	end
	return p
end

local function facingOf(root: BasePart): Vector3
	return VecMath.flatUnit(root.CFrame.LookVector)
end

local function bodyFor(
	actorId: number,
	body: Vector3,
	facing: Vector3,
	reachDir: Vector3?,
	t: number,
	ping: number
): CatchGeometry.BodyState
	local reach = reaches[actorId]
	local reaching = false
	local dir: Vector3? = nil
	-- the Reach remote arrived about one ping after the press
	if reach and t >= reach.at - 0.12 - ping and t <= reach.at + C.ReachWindow + 0.12 then
		reaching = true
		dir = if reachDir and reachDir.Magnitude > 0.5 then reachDir.Unit else reach.dir
	end
	local diving = services.MovementService.isDiving(actorId)
	local diveDir: Vector3? = nil
	if diving then
		local c = Actors.characterOf(actorId)
		local td = c and c:GetAttribute("TechDir")
		diveDir = if typeof(td) == "Vector3" and (td :: Vector3).Magnitude > 0.5 then td :: Vector3 else facing
	end
	return {
		root = Hitbox.root(body, services.MovementService.standHeight(actorId)),
		facing = facing,
		reaching = reaching,
		reachDir = dir,
		diving = diving,
		diveDir = diveDir,
		sliding = services.MovementService.isSliding(actorId),
		prone = services.MovementService.isOnGroundAfterLayout(actorId),
	}
end

local function claimable(d: any, t: number): boolean
	if d.mode == "Flight" then
		return true
	end
	return d.mode == "Landed" and t <= d.landAt + 0.02
end

-- The disc's path over the quality window after first contact (history,
-- extrapolated from the live flight for the last few steps if needed).
local function pathAfter(d: any, t: number): { CatchGeometry.PathSample }
	local samples: { CatchGeometry.PathSample } = {}
	for k = 0, C.QualitySamples do
		local tk = t + k * SAMPLE_DT
		local p = services.DiscService.positionAt(d, tk)
		if p then
			table.insert(samples, { t = tk, pos = p })
		end
	end
	return samples
end

-- The disc's path from t0 to t1 at the simulation step.
local function pathWindow(d: any, t0: number, t1: number): { CatchGeometry.PathSample }
	local samples: { CatchGeometry.PathSample } = {}
	local n = math.clamp(math.ceil((t1 - t0) / SAMPLE_DT), 1, 64)
	for k = 0, n do
		local tk = t0 + (t1 - t0) * k / n
		local p = services.DiscService.positionAt(d, tk)
		if p then
			table.insert(samples, { t = tk, pos = p })
		end
	end
	return samples
end

-- Disc velocity at the start of a sampled path (falls back to the live flight).
local function velocityOf(d: any, samples: { CatchGeometry.PathSample }): Vector3
	local a, b = samples[1], samples[2]
	if a and b and b.t > a.t then
		return (b.pos - a.pos) / (b.t - a.t)
	end
	return services.DiscService.velocity(d)
end

local function addClaim(
	d: any,
	actorId: number,
	team: string,
	t: number,
	ev: CatchGeometry.Evaluation,
	discVel: Vector3,
	body: Vector3,
	tip: boolean?
)
	local discPos = services.DiscService.positionAt(d, t)
	for _, c in d.claims do
		if c.id == actorId then
			if tip then
				-- the player chose to tip: that intent wins over a catch claim
				c.tip = true
			end
			-- a repeated claim: the earliest touch orders it, the deepest
			-- point of either window is its quality
			if ev.depth < c.depth - 1e-6 then
				c.depth, c.quality, c.zone, c.hand = ev.depth, ev.quality, ev.zone.kind, ev.hand
			end
			if t < c.t then
				c.t, c.discVel, c.body = t, discVel, body
				c.relativeSpeed = discVel.Magnitude
				c.discPos = discPos
			end
			return
		end
	end
	table.insert(d.claims, {
		id = actorId,
		team = team,
		t = t,
		depth = ev.depth,
		quality = ev.quality,
		relativeSpeed = discVel.Magnitude, -- disc speed only: running at a disc never makes it harder
		zone = ev.zone.kind,
		hand = ev.hand,
		discVel = discVel,
		discPos = discPos,
		body = body,
		tip = tip == true,
	})
	if d.resolveAt == nil then
		d.resolveAt = now() + C.ResolveDelay
	end
end

-- Validates a claim. Returns true if it was queued (the answer then comes at
-- resolve time). `clientRoot` / `clientVel` are the claimer's own body at
-- first contact (untrusted).
function CatchingService.claim(
	actorId: number,
	d: any,
	t: number,
	_kind: string?,
	reachDir: Vector3?,
	clientRoot: any?,
	clientVel: any?
): boolean
	local actor = services.PlayerService.get(actorId)
	if not actor or actor.role == "Spectate" or actor.role == "Bench" then
		return false
	end
	local root = services.PlayerService.root(actor)
	if not root then
		return false
	end
	local tNow = now()
	if t ~= t or t < tNow - C.MaxRewind or t > tNow + FUTURE_SLACK then
		t = math.clamp(if t == t then t else tNow, tNow - C.MaxRewind, tNow)
	end
	t = math.min(t, tNow)
	if not claimable(d, t) or t < d.noCatchUntil then
		return false
	end
	if d.thrower == actorId and not d.touched then
		return false
	end
	if services.DiscService.claimLocked(d, actorId) then
		return false
	end
	if actor.character and actor.character:GetAttribute("UBFrozen") == true then
		return false
	end
	if not d.handler.canClaim(d, actorId, actor.team) then
		return false
	end

	local ping = services.MovementService.ping(actorId)
	local serverVel = root.AssemblyLinearVelocity
	local body = root.Position
	local bodyVel = serverVel
	if not actor.isBot then
		local accepted: boolean
		body, accepted = CatchGeometry.claimRoot(clientRoot, root.Position, serverVel, ping)
		local cv = finiteVec(clientVel)
		if accepted and cv and cv.Magnitude <= MAX_BODY_SPEED then
			bodyVel = cv
		end
	end
	local slack = if actor.isBot then 0 else CatchGeometry.slack(ping, serverVel.Magnitude)
	if _kind == "Tip" then
		-- airborne only: the client says it is in the air (its jump reached
		-- us before this claim), or our own lagging view agrees
		local track = services.MovementService.track(actorId)
		local airborne = track ~= nil
			and (
				track.mode == "Air"
				or track.mode == "Dive"
				or not track.grounded
				or t - track.lastAirborneAt <= 0.25 + ping
			)
		if not airborne then
			return false
		end
		local tipZones = CatchGeometry.tipZones(bodyFor(actorId, body, facingOf(root), reachDir, t, ping))
		local window = pathWindow(d, t - RS.TipWindow, t + RS.TipWindow)
		local ev = CatchGeometry.bestTip(tipZones, window, t, RS.TipPerfect, slack)
		if not ev then
			return false
		end
		local at = ev.t or t
		local samples = pathAfter(d, at)
		addClaim(d, actorId, actor.team, at, ev, velocityOf(d, samples), body, true)
		tips[actorId] = { t = t, discId = d.id, state = "pending" }
		return true
	end
	local zones = CatchGeometry.zones(bodyFor(actorId, body, facingOf(root), reachDir, t, ping))
	local samples = pathAfter(d, t)
	local ev = CatchGeometry.bestOverPath(zones, samples, t, bodyVel, slack)
	if not ev then
		return false
	end
	addClaim(d, actorId, actor.team, t, ev, velocityOf(d, samples), body)
	return true
end

-- Server-side check for bots along one simulation step of a flight.
function CatchingService.sweepBots(d: any, _from: Vector3, to: Vector3, t: number)
	if t < d.noCatchUntil then
		return
	end
	for _, actor in services.PlayerService.all() do
		if actor.isBot and (actor.role == "Match" or actor.role == "Training") then
			local root = services.PlayerService.root(actor)
			if root and (root.Position - to).Magnitude < 9 then
				if
					not (d.thrower == actor.id and not d.touched)
					and not services.DiscService.claimLocked(d, actor.id)
					and d.handler.canClaim(d, actor.id, actor.team)
				then
					local zones = CatchGeometry.zones(bodyFor(actor.id, root.Position, facingOf(root), nil, t, 0))
					if CatchGeometry.evaluate(zones, to, 0) then
						local samples = pathAfter(d, t)
						local ev = CatchGeometry.bestOverPath(zones, samples, t, root.AssemblyLinearVelocity, 0)
						if ev then
							addClaim(d, actor.id, actor.team, t, ev, velocityOf(d, samples), root.Position)
						end
					end
				end
			end
		end
	end
end

local function answer(actorId: number, d: any, accepted: boolean, result: string)
	local player = Actors.playerOf(actorId)
	if player then
		Net.event("CatchResult"):FireClient(player, d.id, accepted, result, d.flightId)
	end
end

local function settleTip(actorId: number, d: any, ok: boolean)
	local tip = tips[actorId]
	if tip and tip.discId == d.id and tip.state == "pending" then
		tip.state = if ok then "ok" else "denied"
	end
end

local function notifyClaimers(d: any, winnerId: number?, result: string)
	for _, c in d.claims do
		local mine = c.id == winnerId
		answer(c.id, d, mine and result == "Catch", if mine then result else "Lost")
		if c.tip then
			settleTip(c.id, d, mine and result == "Tip")
		end
	end
end

-- Forgets every pending claim, telling each claimer it was Denied (the disc
-- changed state before the claims could be resolved).
function CatchingService.discard(d: any)
	local claims = d.claims
	d.claims = {}
	d.resolveAt = nil
	for _, c in claims do
		answer(c.id, d, false, "Denied")
		if c.tip then
			settleTip(c.id, d, false)
		end
	end
end

function CatchingService.resolve(d: any)
	if #d.claims == 0 then
		return
	end
	if d.mode ~= "Flight" and d.mode ~= "Landed" then
		CatchingService.discard(d)
		return
	end
	local resolution = CatchGeometry.resolve(d.claims)
	if not resolution then
		CatchingService.discard(d)
		return
	end
	local w = resolution.winner :: any
	local winnerActor = services.PlayerService.get(w.id)
	local root = winnerActor and services.PlayerService.root(winnerActor)
	if not winnerActor or not root then
		CatchingService.discard(d)
		return
	end
	local body: Vector3 = w.body or root.Position
	local discPos: Vector3 = w.discPos or services.DiscService.positionAt(d, w.t) or body
	local discVel: Vector3 = w.discVel or services.DiscService.velocity(d)
	local isDefender = d.throwerTeam ~= nil and d.throwerTeam ~= "" and w.team ~= d.throwerTeam and not d.pull
	local outcome = if w.tip then "Tip" else CatchGeometry.outcome(resolution, isDefender)

	notifyClaimers(d, w.id, outcome)
	local claims = d.claims
	d.claims = {}
	d.resolveAt = nil

	if outcome == "Tip" then
		-- the disc pops up out of the tipper's hands; the tipper may re-catch
		-- it after the toucher lock (the Reset Grab)
		local newVel = CatchGeometry.tipVelocity(discVel, facingOf(root))
		local pos = Vector3.new(discPos.X, math.max(discPos.Y, d.groundY + 0.6), discPos.Z)
		services.DiscService.deflect(d, pos, newVel, Vector3.new(0, 1, 0), C.TipSpin, w.t, w.id)
		Net.event("Effect"):FireAllClients("Tip", discPos, w.id, w.quality, "Tip")
		services.MovementService.noteTip(w.id, d.id, isDefender, w.t)
		d.handler.onTouched(d, {
			id = w.id,
			team = w.team,
			kind = "Tip",
			pos = discPos,
			zone = "Tip",
			reason = "Tip",
			defender = isDefender,
		})
		return
	end

	if outcome == "Catch" then
		local track = services.MovementService.track(w.id)
		local grounded = if track then track.grounded else true
		local jumpOrigin = if track then track.lastGroundedPos else body
		services.DiscService.giveTo(d, w.id)
		Net.event("Effect"):FireAllClients("Catch", discPos, w.id, w.quality, w.zone)
		-- signature moves first: their points join the chain this catch converts
		services.MovementService.noteCatch(w.id, d.id, isDefender, w.t)
		d.handler.onCaught(d, {
			id = w.id,
			team = w.team,
			pos = body, -- where the catcher's body was at the catch (validated)
			grounded = grounded,
			jumpOrigin = jumpOrigin,
			quality = w.quality,
			zone = w.zone,
			depth = w.depth,
			relativeSpeed = w.relativeSpeed,
			contested = resolution.contested,
			t = w.t,
			discPos = discPos,
			claims = claims,
		})
		return
	end

	-- deflections keep the disc alive, continuing from the contact
	local away = VecMath.flatUnit(discPos - body)
	local newVel: Vector3
	local tempo = DiscConfig.Tempo
	if outcome == "Block" then
		newVel = discVel * C.BlockCarry + Vector3.new(0, C.BlockDown, 0) + away * (6 * tempo)
	else
		newVel = discVel * C.BobbleCarry + Vector3.new(0, C.BobbleUp, 0) + away * (2 * tempo)
	end
	local pos = Vector3.new(discPos.X, math.max(discPos.Y, d.groundY + 0.6), discPos.Z)
	services.DiscService.deflect(d, pos, newVel, Vector3.new(0.3, 1, 0.2).Unit, 12 * tempo, w.t, w.id)
	Net.event("Effect"):FireAllClients(outcome, discPos, w.id, w.quality, w.zone)
	d.handler.onTouched(
		d,
		{ id = w.id, team = w.team, kind = outcome, pos = discPos, zone = w.zone, reason = resolution.reason }
	)
end

-- Did this actor send a tip claim around ts that has not been denied? (The
-- TipReset technique usually arrives right behind the claim, before it is
-- resolved.)
function CatchingService.recentTip(actorId: number, ts: number, window: number): boolean
	local tip = tips[actorId]
	return tip ~= nil and tip.state ~= "denied" and math.abs(tip.t - ts) <= window
end

function CatchingService.reachState(actorId: number): ReachState?
	return reaches[actorId]
end

-- Opens a reach window (humans via remote, bots directly).
function CatchingService.reach(actorId: number, dir: Vector3)
	local tNow = now()
	local prev = reaches[actorId]
	if prev and tNow - prev.at < C.ReachWindow + C.ReachCooldown * 0.6 then
		return
	end
	local unit = if dir.Magnitude > 0.1 and dir.Magnitude == dir.Magnitude then dir.Unit else Vector3.new(0, 0, -1)
	reaches[actorId] = { at = tNow, dir = unit }
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute("ReachDir", unit)
		actor.character:SetAttribute("Reach", tNow)
	end
end

function CatchingService.Init(s: any)
	services = s
end

function CatchingService.Start()
	Net.event("Reach").OnServerEvent:Connect(function(player, dir)
		local actor = services.PlayerService.fromPlayer(player)
		local v = finiteVec(dir)
		if actor and v then
			CatchingService.reach(actor.id, v)
		end
	end)
	Net.event("Catch").OnServerEvent:Connect(function(player, discId, t, kind, reachDir, rootPos, rootVel)
		local actor = services.PlayerService.fromPlayer(player)
		if not actor or type(discId) ~= "string" then
			return
		end
		local d = services.DiscService.get(discId)
		local function deny()
			Net.event("CatchResult"):FireClient(player, discId, false, "Denied", if d then d.flightId else 0)
		end
		if not d or type(t) ~= "number" then
			deny()
			return
		end
		local clock = os.clock()
		if (lastClaim[actor.id] or -math.huge) > clock - C.ClaimRateLimit then
			deny()
			return
		end
		lastClaim[actor.id] = clock
		local ok = CatchingService.claim(
			actor.id,
			d,
			t,
			if type(kind) == "string" then kind else nil,
			finiteVec(reachDir),
			rootPos,
			rootVel
		)
		if not ok then
			deny()
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		reaches[actor.id] = nil
		lastClaim[actor.id] = nil
		tips[actor.id] = nil
	end)
end

return CatchingService
