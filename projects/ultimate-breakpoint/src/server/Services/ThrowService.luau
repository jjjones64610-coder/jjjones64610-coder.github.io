--!strict
--[[
	ThrowService — validates throws and launches discs.

	The client sends its INPUTS (type, aim, hold time, bank, release height)
	plus where it threw from: its step from the pivot (`step`), the pivot it
	used (`pivot`, informative only), its root (`rootPos`) and its release
	time (`releaseT`). The server rebuilds the launch with the same
	ThrowModel from values it validates itself:
	  * pivot     always the server's authoritative P (MovementService.pivotOf,
	              replicated as UBPivot); the client's is ignored
	  * step      clamped (ThrowModel.clampStep) and accepted only when the
	              root is where that step puts it (ThrowModel.resolveStep);
	              otherwise the step implied by the root is used
	  * rootPos   the client's root when it is within ROOT_TOLERANCE (+ speed x
	              ping) of the server's view, else the server's root. With a
	              pivot it only supplies the hop height; without one (a throw
	              on the run) it is the release origin
	  * releaseT  clamped to [now - min(ping, 0.25), now]; the flight starts
	              then (DiscService.launch), so the thrower's predicted disc
	              and the real one leave together
	  * height    High needs recent airborne evidence (airborne now, hopping,
	              airborne within HIGH_AIR_WINDOW, or the client's reported
	              mode Air); otherwise it is released Mid
	  * swinging  from the server's own PivotSwing record
	              (MovementService.isSwinging at the release time)
	  * hold time measured by the server (ThrowCharge -> Throw) unless the
	              two agree within 0.2 s
	A planted pivot has no run-up, so a pivot release ignores thrower velocity
	(ThrowModel). Releases tell the thrower what was used (Feedback "Release":
	heightUsed / heightAsked / stepUsed / stepAccepted / blocked ...).

	Hand blocks (match play, not pulls) test the first HandBlockCheckTime of
	the flight against defenders rewound to where the thrower saw them
	(DefenseService.checkHandBlock); a block deflects the disc from the
	contact point at the contact time. previewBlock() runs the same test
	without throwing (bots choosing a release).

	Fakes (rate-limited at FakeCooldown, with a little jitter allowance) carry
	the side the fake stepped to: character attributes Fake (server time, for
	poses), FakeT (the estimated time the fake happened: arrival minus ping;
	MovementService judges a "Sold" PivotSwing against it, bots react to it)
	and FakeSide (-1 thrower's left, 0 none, +1 thrower's right). Windups set
	WindupType + Windup; a release resets Windup and WindupType, and so does
	a charge the client lost (ThrowCharge false: it landed from the hop), so
	no stale windup is ever read (DiscService also clears them when
	possession ends).

	Combo: the release reports to MovementService.noteRelease, which adds the
	"Break" link after a Sold swing (the client's own "Break" Tech event for
	the same swing is the same link, never counted twice).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local ThrowModel = require(Shared.Disc.ThrowModel)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Net = require(Shared.Net)

local T = DiscConfig.Throw
local C = DiscConfig.Catch

-- the client's root is trusted within this many studs of the server's view
-- (plus speed x ping for the replication lag of a moving body), capped
local ROOT_TOLERANCE = 3
local ROOT_TOLERANCE_MAX = 6
-- a release may be backdated by at most min(ping, this)
local MAX_RELEASE_BACKDATE = 0.25
-- a High release needs the thrower airborne within this long
local HIGH_AIR_WINDOW = 0.3
-- the server's view of a body lags about this much beyond the ping
local AIR_LAG = 0.1
-- arrival jitter allowed on the fake rate limit
local FAKE_JITTER = 0.05
-- min seconds between two throws of one actor
local THROW_COOLDOWN = 0.25

local ThrowService = {}

local services: any
local chargeStart: { [number]: number } = {}
local lastFake: { [number]: number } = {}
local lastThrow: { [number]: number } = {}

local function now(): number
	return Net.now()
end

local function setAttr(actorId: number, key: string, value: any)
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute(key, value)
	end
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

function ThrowService.beginCharge(actorId: number, throwType: string)
	if not services.DiscService.heldBy(actorId) then
		return
	end
	chargeStart[actorId] = os.clock()
	setAttr(actorId, "WindupType", throwType)
	setAttr(actorId, "Windup", now())
end

-- The thrower lost the charge without throwing (landed from the hop): the
-- windup is over for poses and bots.
function ThrowService.endCharge(actorId: number)
	if chargeStart[actorId] == nil then
		return
	end
	chargeStart[actorId] = nil
	setAttr(actorId, "Windup", 0)
	setAttr(actorId, "WindupType", "")
end

-- A pump fake. `side` is where the fake stepped (-1 left, 0 none, +1 right
-- in the thrower's aim frame).
function ThrowService.fake(actorId: number, throwType: string, side: number?)
	local clock = os.clock()
	if (lastFake[actorId] or -math.huge) > clock - (T.FakeCooldown - FAKE_JITTER) then
		return
	end
	if not services.DiscService.heldBy(actorId) then
		return
	end
	lastFake[actorId] = clock
	chargeStart[actorId] = nil -- a fake ends the windup
	local s = if type(side) == "number" and finite(side) then side else 0
	local fakeSide = if s > 0.5 then 1 elseif s < -0.5 then -1 else 0
	local tNow = now()
	setAttr(actorId, "WindupType", throwType)
	setAttr(actorId, "FakeSide", fakeSide)
	setAttr(actorId, "FakeT", tNow - services.MovementService.ping(actorId))
	setAttr(actorId, "Fake", tNow)
end

export type Result = {
	launch: ThrowModel.Launch,
	blocked: number?,
}

type Prepared = {
	params: ThrowModel.Params,
	actor: any,
	root: BasePart,
	disc: any,
	rootPos: Vector3,
	velocity: Vector3,
	t0: number,
	ping: number,
	heightAsked: string,
	stepAccepted: boolean,
}

-- Validates raw throw parameters into what the server will actually throw.
-- Pure apart from reading state (no side effects), so previewBlock can use it.
local function prepare(actorId: number, raw: any, isBot: boolean): Prepared?
	local params = ThrowModel.sanitize(raw)
	if not params then
		return nil
	end
	local p = params :: ThrowModel.Params
	local d = services.DiscService.heldBy(actorId)
	if not d then
		return nil
	end
	local actor = services.PlayerService.get(actorId)
	local root = actor and services.PlayerService.root(actor)
	if not actor or not root then
		return nil
	end
	local tNow = now()
	local ping = if isBot then 0 else services.MovementService.ping(actorId)
	local serverRoot = root.Position
	local vel = root.AssemblyLinearVelocity

	-- release time: the client's, within one ping of now
	local t0 = tNow
	local releaseT = p.releaseT
	if not isBot and releaseT then
		t0 = math.clamp(releaseT, tNow - math.min(ping, MAX_RELEASE_BACKDATE), tNow)
	end

	-- the body the throw leaves from
	local rootPos = serverRoot
	local clientRoot = p.rootPos
	if not isBot and clientRoot then
		local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		local tolerance = math.min(ROOT_TOLERANCE + flatSpeed * ping, ROOT_TOLERANCE_MAX)
		if (clientRoot - serverRoot).Magnitude <= tolerance then
			rootPos = clientRoot
		end
	end

	-- pivot + step: P is the server's; the step must match where the body is
	local pivot = services.MovementService.pivotOf(actorId)
	local stepAccepted = true
	p.pivot = pivot
	if pivot then
		local step, ok = ThrowModel.resolveStep(p.step, pivot, rootPos, ping, p.yaw)
		p.step = step
		stepAccepted = ok
	else
		p.step = Vector3.zero
	end
	local swinging = pivot ~= nil and services.MovementService.isSwinging(actorId, t0)
	p.swinging = swinging or (isBot and p.swinging == true)

	-- release height and balance must match what the server has seen
	local heightAsked = p.height
	local track = services.MovementService.track(actorId)
	local grounded = if track then track.grounded else true
	if p.height == "High" then
		local airborne = track ~= nil
			and (
				not track.grounded
				or track.hopping
				or tNow - track.lastAirborneAt <= HIGH_AIR_WINDOW
				or track.mode == "Air"
			)
		if not airborne then
			p.height = "Mid"
		end
	end
	-- off balance: the client says so, or the server has seen the thrower in
	-- the air for longer than the replication lag (a fresh landing is fine)
	local since = if track then track.airborneSince else nil
	local seenAirborne = not grounded and since ~= nil and os.clock() - since > ping + AIR_LAG
	p.offBalance = p.height ~= "High" and (p.offBalance == true or seenAirborne)
	p.groundThrow = services.MovementService.isOnGroundAfterLayout(actorId)
	if p.groundThrow then
		p.height = "Mid"
	end
	p.leftHanded = actor.character ~= nil and actor.character:GetAttribute("LeftHanded") == true

	return {
		params = p,
		actor = actor,
		root = root,
		disc = d,
		rootPos = rootPos,
		velocity = vel,
		t0 = t0,
		ping = ping,
		heightAsked = heightAsked,
		stepAccepted = stepAccepted,
	}
end

local function handBlocksApply(d: any): boolean
	return d.context == "Match" and d.meta.pullPending ~= true
end

-- Would this throw be hand-blocked right now? (Bots test candidate releases.)
function ThrowService.previewBlock(actorId: number, raw: any): boolean
	local prep = prepare(actorId, raw, true)
	if not prep or not handBlocksApply(prep.disc) then
		return false
	end
	local launch = ThrowModel.launch(prep.params, prep.rootPos, prep.velocity)
	local blocker = services.DefenseService.checkHandBlock(
		launch.state,
		actorId,
		prep.actor.team,
		prep.disc.groundY,
		prep.disc.wind
	)
	return blocker ~= nil
end

-- Core throw path shared by humans, bots and pulls.
function ThrowService.throw(actorId: number, raw: any, isBot: boolean?): Result?
	local bot = isBot == true
	local clock = os.clock()
	if (lastThrow[actorId] or -math.huge) > clock - THROW_COOLDOWN then
		return nil
	end
	local prep = prepare(actorId, raw, bot)
	if not prep then
		return nil
	end
	local d = prep.disc
	if not d.handler.canThrow(d, actorId) then
		return nil
	end
	local p = prep.params
	local actor = prep.actor

	-- hold time: trust the server's measurement unless the two agree
	if not bot then
		local started = chargeStart[actorId]
		local measured = if started then clock - started else 0
		if math.abs(measured - p.holdTime) > 0.2 then
			p.holdTime = measured
		end
	end
	chargeStart[actorId] = nil

	local launch = ThrowModel.launch(p, prep.rootPos, prep.velocity)
	lastThrow[actorId] = clock
	local t0 = prep.t0

	-- hand blocks (match play only)
	local blocker: number? = nil
	local blockT: number? = nil
	local blockPos: Vector3? = nil
	local pull = d.meta.pullPending == true
	if handBlocksApply(d) then
		blocker, blockT, blockPos =
			services.DefenseService.checkHandBlock(launch.state, actorId, actor.team, d.groundY, d.wind)
	end

	services.DiscService.launch(d, launch.releasePos, launch.velocity, launch.normal, launch.state.spin, {
		thrower = actorId,
		throwerTeam = actor.team,
		throwType = p.throwType,
		quality = launch.quality,
		pull = pull,
		noCatch = if blockT then (blockT :: number) + 0.02 else T.NoCatchTime,
		stopAt = blockT,
	}, t0)
	-- the launch above cleared the holder's windup; mark the release
	setAttr(actorId, "ReleaseType", p.throwType)
	setAttr(actorId, "Release", now())
	services.MovementService.noteRelease(actorId, t0)

	d.handler.onThrown(d, {
		id = actorId,
		team = actor.team,
		params = p,
		launch = launch,
		pos = prep.rootPos,
		blocked = blocker,
	})

	if actor.player then
		Net.event("Feedback"):FireClient(actor.player, "Release", {
			quality = launch.quality,
			power = launch.power,
			spin = launch.spinFactor,
			speed = launch.speed,
			pitch = launch.pitchDeg,
			bank = launch.bankDeg,
			throwType = p.throwType,
			offBalance = p.offBalance,
			groundThrow = p.groundThrow,
			blocked = blocker ~= nil,
			heightUsed = p.height,
			heightAsked = prep.heightAsked,
			stepUsed = p.step,
			stepAccepted = prep.stepAccepted,
			pivot = p.pivot ~= nil,
		})
	end

	if blocker and blockT and blockPos then
		local flightId = d.flightId
		local bt = blockT :: number
		local bp = blockPos :: Vector3
		local blockerId = blocker :: number
		local contactT = (d.launchTime :: number) + bt
		-- the disc's velocity at the contact (deterministic replay of the launch)
		local at = DiscPhysics.copy(launch.state)
		DiscPhysics.advanceTo(at, bt, d.wind, d.groundY - 100)
		local discVel = DiscPhysics.velocity(at)
		local origin = p.pivot or prep.rootPos
		local function applyBlock()
			if (d.mode ~= "Flight" and d.mode ~= "Landed") or d.flightId ~= flightId then
				return
			end
			local away = Vector3.new(bp.X - origin.X, 0, bp.Z - origin.Z)
			local push = if away.Magnitude > 0.1 then away.Unit * (3 * DiscConfig.Tempo) else Vector3.zero
			local newVel = discVel * C.BlockCarry + Vector3.new(0, C.BlockDown, 0) + push
			services.DiscService.deflect(d, bp, newVel, nil, nil, contactT, blockerId)
			Net.event("Effect"):FireAllClients("HandBlock", bp, blockerId, "Clean", "Mark")
			local blockerActor = services.PlayerService.get(blockerId)
			d.handler.onTouched(d, {
				id = blockerId,
				team = if blockerActor then blockerActor.team else "",
				kind = "HandBlock",
				pos = bp,
				zone = "Mark",
			})
		end
		-- a backdated release may already be past the hands: block right away
		local wait = contactT - now()
		if wait <= 0 then
			applyBlock()
		else
			task.delay(wait, applyBlock)
		end
	end
	return { launch = launch, blocked = blocker }
end

-- Launches a disc without a thrower (training launchers, scripted drills).
function ThrowService.launchFrom(d: any, params: ThrowModel.Params, origin: Vector3, meta: { [string]: any }?)
	local launch = ThrowModel.launch(params, origin, Vector3.zero)
	local m: { [string]: any } = meta or {}
	services.DiscService.launch(d, launch.releasePos, launch.velocity, launch.normal, launch.state.spin, {
		thrower = m.thrower,
		throwerTeam = m.throwerTeam,
		throwType = params.throwType,
		quality = launch.quality,
		noCatch = m.noCatch or 0.05,
	})
	return launch
end

function ThrowService.Init(s: any)
	services = s
end

function ThrowService.Start()
	Net.event("ThrowCharge").OnServerEvent:Connect(function(player, throwType)
		local actor = services.PlayerService.fromPlayer(player)
		if not actor then
			return
		end
		if throwType == false then
			ThrowService.endCharge(actor.id)
		elseif type(throwType) == "string" and (DiscConfig.Types :: any)[throwType] then
			ThrowService.beginCharge(actor.id, throwType)
		end
	end)
	Net.event("Fake").OnServerEvent:Connect(function(player, throwType, side)
		local actor = services.PlayerService.fromPlayer(player)
		if actor and type(throwType) == "string" and (DiscConfig.Types :: any)[throwType] then
			ThrowService.fake(actor.id, throwType, if type(side) == "number" then side else 0)
		end
	end)
	Net.event("Throw").OnServerEvent:Connect(function(player, raw)
		local actor = services.PlayerService.fromPlayer(player)
		if actor then
			ThrowService.throw(actor.id, raw, false)
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		chargeStart[actor.id] = nil
		lastFake[actor.id] = nil
		lastThrow[actor.id] = nil
	end)
end

return ThrowService
