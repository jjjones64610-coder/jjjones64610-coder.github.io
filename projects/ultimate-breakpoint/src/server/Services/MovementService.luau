--!strict
--[[
	MovementService (server) — authority over how actors are allowed to move.

	Movement is simulated on each client for responsiveness (the client owns
	its character's physics and drives its Humanoid from MovementSim). The
	server stays the referee, but it never punishes legit play on a real
	network and it never moves anyone without telling their client exactly
	what happened (PlayerService.teleport protocol):

	  * Kinematics: every actor's position/velocity is sampled each Heartbeat.
	    A per-character ground probe (stand height = HipHeight + root half
	    height, so tall avatars work) gives an authoritative grounded flag,
	    the last grounded point ("did they jump from in bounds?") and
	    touchdown events. A 1 s, ~60 Hz history of position + flat facing per
	    actor (players and bots) backs positionAt(id, t) for lag-compensated
	    hand blocks.
	  * Techniques: clients report technique events stamped with their own
	    time `t`. Each event is judged on that timestamp (clamped to at most
	    0.35 s old and kept monotonic per player): names, a rate limit,
	    cooldowns (Config TechCooldowns), an exertion mirror (Config costs and
	    regen) and per-technique rules (a PivotSwing only while holding, and
	    "Sold" only after a real fake; a Break only right after a Sold swing).
	    Accepted events are replicated as character attributes so every client
	    can pose that character, and feed the server combo tracker on their
	    timestamps. Rejected events earn nothing and are counted.
	  * Combos: catches/blocks convert the chain at the claim time
	    (convertCombo); chains that can no longer be converted are settled a
	    few times a second and pay 25 % XP through ProgressionService.
	  * Speed budget: a 1 s sliding window of flat displacement, checked once
	    a second. Over HardCap x 1.15 + 8 studs flags that second; only two
	    flagged seconds in a row (a sustained ~50 studs/s, i.e. a speed hack)
	    snap the player back, keeping their rotation. After any teleport the
	    history is cleared and checks wait for a grace period
	    (max(0.8, 2 x ping + 0.3)) and until the server sees the root arrive.
	  * Pivot authority: the holder's pivot foot P is replicated as the
	    character attribute UBPivot. The client proposes P with the Pivot
	    remote; it is accepted when it is within 2 + 26 x min(ping, 0.3)
	    studs of the server's root (and a sane distance from the catch).
	    Without a proposal the server plants P itself. Server relocations and
	    pickups set P directly (setPivot). Travel: the root may stray at most
	    PivotRadius + 1.5 + 10 x min(ping, 0.3) from P; beyond that on samples
	    0.1 s apart the holder is snapped back onto P (at most once per
	    1.5 s). The one hop per possession is allowed; skipTravel() pauses the
	    check (pickup gather glide).
	  * Fake Commit replicates as a generic "Lean" so opponents see a real
	    sell, not a label that says "this is a fake".

	Ping: player:GetNetworkPing() clamped to [0, 0.35]; bots have 0.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared.Config.Movement)
local TechConfig = require(Shared.Config.Tech)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Signatures = require(Shared.Rules.Signatures)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)

local MovementService = {}

MovementService.Landed = Signal.new() -- (actorId, position)
MovementService.TechAccepted = Signal.new() -- (actorId, tech, quality, info)
MovementService.Travel = Signal.new() -- (actorId)
MovementService.SignatureHit = Signal.new() -- (actorId, hit: Signatures.Hit)

local services: any

local HD = MovementConfig.Holding
local RS = MovementConfig.Reset

export type Track = {
	id: number,
	pos: Vector3,
	vel: Vector3,
	grounded: boolean,
	heightAboveGround: number, -- root height above the ground below (math.huge when none in reach)
	stand: number, -- root height above the ground when standing (per character)
	jumpHeight: number, -- how far the root is above its standing height (0 when grounded)
	lastGroundedPos: Vector3, -- ground point under the root when last grounded
	airborneSince: number?, -- os.clock()
	lastAirborneAt: number, -- Net.now() of the last airborne sample
	wasGrounded: boolean,
	pendingLanding: boolean,
	holdAirborne: boolean, -- the possession started in the air (slow-down starts on landing)
	-- history (ring buffer, Net.now() times): positionAt + the speed budget
	histT: { number },
	histPos: { Vector3 },
	histLook: { Vector3 },
	histHead: number,
	histCount: number,
	-- anti-cheat
	graceUntil: number, -- os.clock()
	teleportTarget: Vector3?,
	teleportAt: number, -- os.clock()
	speedCheckAt: number, -- Net.now()
	speedFlags: number,
	lastGoodPos: Vector3,
	-- techniques
	techAt: { [string]: number }, -- timestamp of the last accepted event per technique
	lastTs: number, -- latest accepted event timestamp (kept monotonic)
	exertion: number,
	regenAt: number,
	techTimes: { number }, -- os.clock() arrivals in the last second (rate limit)
	rejected: number,
	combo: ComboEvaluator.Tracker,
	mode: string,
	lastTech: string?,
	lastTechAt: number,
	lastDiveAt: number,
	lastSwingAt: number, -- timestamp of the last accepted PivotSwing
	breakSwingAt: number, -- the PivotSwing a Break was already credited for
	-- air moves and resets this airtime (from the client-reported mode)
	airRedirects: number,
	airLayouts: number,
	airResets: number, -- accepted Tip Resets + Wall Rebounds
	airTips: number,
	lastTakeoffAt: number, -- client time (arrival - ping) of the last grounded -> airborne mode change
	lastLandAt: number, -- ... and of the last airborne -> grounded one
	signatures: Signatures.Tracker,
	-- holding
	holding: boolean,
	holdStart: number,
	holdEnd: number,
	holdPos: Vector3, -- server root when the possession started
	pivot: Vector3?,
	pivotSource: string, -- "None" | "Auto" | "Client" | "Server"
	pivotAt: number,
	earlyPivot: Vector3?, -- a proposal that arrived just before the possession did
	earlyPivotAt: number,
	hopUsed: boolean,
	hopping: boolean,
	travelSince: number?,
	travelSkipUntil: number,
	lastTravelSnap: number,
}

local tracks: { [number]: Track } = {}

local KNOWN_TECHS = MovementConfig.TechCosts
local VALID_MODES = {
	Ground = true,
	Air = true,
	Slide = true,
	Dive = true,
	DiveSlide = true,
	Recover = true,
	Landing = true,
	Frozen = true,
	Pivot = true, -- holder pivoting (MovementSim.poseMode)
	Mark = true, -- mark shuffle
}
local VALID_QUALITY = { Perfect = true, Clean = true, Sloppy = true, Gassed = true }

local MAX_TECHS_PER_SECOND = 12
local MAX_EVENT_AGE = 0.35 -- event timestamps older than this (at arrival) are clamped
local COOLDOWN_SLACK = 0.05
local EXERTION_SLACK = 30 -- the mirror may lag the client by this much before claims are refused
local HISTORY = 72 -- samples (~1.2 s at 60 Hz)
local SPEED_WINDOW = 1.0
-- either engine's cap (the tech core allows more speed than the classic sim)
local SPEED_LIMIT = math.max(MovementConfig.HardCap, TechConfig.HARD_SPEED_CAP) * 1.15 + 8 -- studs per second of window
local SPEED_FLAGS_TO_SNAP = 2
local HOVER_TIME = 6
local TELEPORT_ARRIVE = 4 -- studs: the server has seen the root reach the teleport target
local TELEPORT_WAIT = 1.5 -- ... or this long has passed
local TRAVEL_CONFIRM = 0.1 -- a travel violation must persist this long (two samples)
local TRAVEL_SNAP_EVERY = 1.5
local SETTLE_EVERY = 0.25
local SETTLE_LAG = 0.4 -- settle a little in the past so late events / claims still count

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function now(): number
	return Net.now()
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

local function finiteVec(v: Vector3): boolean
	return finite(v.X) and finite(v.Y) and finite(v.Z)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatLook(cf: CFrame): Vector3
	local l = flat(cf.LookVector)
	if l.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return l.Unit
end

local function newTrack(id: number, pos: Vector3): Track
	return {
		id = id,
		pos = pos,
		vel = Vector3.zero,
		grounded = true,
		heightAboveGround = 0,
		stand = 3,
		jumpHeight = 0,
		lastGroundedPos = pos,
		airborneSince = nil,
		lastAirborneAt = -math.huge,
		wasGrounded = true,
		pendingLanding = false,
		holdAirborne = false,
		histT = table.create(HISTORY, 0),
		histPos = table.create(HISTORY, pos),
		histLook = table.create(HISTORY, Vector3.new(0, 0, -1)),
		histHead = 0,
		histCount = 0,
		graceUntil = os.clock() + 1,
		teleportTarget = nil,
		teleportAt = -math.huge,
		speedCheckAt = now() + SPEED_WINDOW,
		speedFlags = 0,
		lastGoodPos = pos,
		techAt = {},
		lastTs = -math.huge,
		exertion = MovementConfig.ExertionMax,
		regenAt = -math.huge,
		techTimes = {},
		rejected = 0,
		combo = ComboEvaluator.newTracker(),
		mode = "Ground",
		lastTech = nil,
		lastTechAt = -math.huge,
		lastDiveAt = -math.huge,
		lastSwingAt = -math.huge,
		breakSwingAt = -math.huge,
		airRedirects = 0,
		airLayouts = 0,
		airResets = 0,
		airTips = 0,
		lastTakeoffAt = -math.huge,
		lastLandAt = -math.huge,
		signatures = Signatures.new(),
		holding = false,
		holdStart = -math.huge,
		holdEnd = -math.huge,
		holdPos = pos,
		pivot = nil,
		pivotSource = "None",
		pivotAt = -math.huge,
		earlyPivot = nil,
		earlyPivotAt = -math.huge,
		hopUsed = false,
		hopping = false,
		travelSince = nil,
		travelSkipUntil = -math.huge,
		lastTravelSnap = -math.huge,
	}
end

function MovementService.track(id: number): Track?
	return tracks[id]
end

-- One-way network delay of an actor in seconds, clamped to [0, 0.35]
-- (bots: 0). Player:GetNetworkPing() is the client -> server -> client round
-- trip, so it is halved here; every caller treats this value as one-way.
function MovementService.ping(id: number): number
	if Actors.isBotId(id) then
		return 0
	end
	local p = Actors.playerOf(id)
	if not p then
		return 0
	end
	local ok, value = pcall(function()
		return p:GetNetworkPing()
	end)
	if not ok or type(value) ~= "number" or not finite(value) then
		return 0
	end
	return math.clamp(value / 2, 0, 0.35)
end

local function character(id: number): Model?
	local actor = services.PlayerService.get(id)
	return actor and actor.character
end

---------------------------------------------------------------------------
-- history
---------------------------------------------------------------------------

local function clearHistory(t: Track)
	t.histCount = 0
	t.speedFlags = 0
	t.speedCheckAt = now() + SPEED_WINDOW
end

local function pushHistory(t: Track, time: number, pos: Vector3, look: Vector3)
	t.histHead = (t.histHead % HISTORY) + 1
	t.histT[t.histHead] = time
	t.histPos[t.histHead] = pos
	t.histLook[t.histHead] = look
	t.histCount = math.min(t.histCount + 1, HISTORY)
end

-- i-th newest sample (0 = newest).
local function histIndex(t: Track, back: number): number
	return ((t.histHead - 1 - back) % HISTORY) + 1
end

-- Position and flat facing of an actor at server time `t`, interpolated
-- from the last ~1 s of samples (clamped to the oldest / newest sample).
function MovementService.positionAt(id: number, time: number): (Vector3, Vector3)
	local t = tracks[id]
	if not t or t.histCount == 0 then
		local root = Actors.rootOf(id)
		if root then
			return root.Position, flatLook(root.CFrame)
		end
		if t then
			return t.pos, Vector3.new(0, 0, -1)
		end
		return Vector3.zero, Vector3.new(0, 0, -1)
	end
	local newest = histIndex(t, 0)
	if time >= t.histT[newest] then
		return t.histPos[newest], t.histLook[newest]
	end
	for back = 1, t.histCount - 1 do
		local i = histIndex(t, back)
		if t.histT[i] <= time then
			local j = histIndex(t, back - 1)
			local t0, t1 = t.histT[i], t.histT[j]
			local a = if t1 > t0 then (time - t0) / (t1 - t0) else 1
			local look = t.histLook[i]:Lerp(t.histLook[j], a)
			look = if look.Magnitude > 1e-3 then look.Unit else t.histLook[j]
			return t.histPos[i]:Lerp(t.histPos[j], a), look
		end
	end
	local oldest = histIndex(t, t.histCount - 1)
	return t.histPos[oldest], t.histLook[oldest]
end

---------------------------------------------------------------------------
-- teleports and grace
---------------------------------------------------------------------------

-- Called by PlayerService.teleport: history is meaningless across a
-- teleport, and the server's view of a client-owned root takes about a round
-- trip to arrive, so the checks wait for it.
function MovementService.noteTeleport(id: number, target: Vector3?)
	local t = tracks[id]
	if not t then
		return
	end
	local clock = os.clock()
	t.graceUntil = math.max(t.graceUntil, clock + math.max(0.8, 2 * MovementService.ping(id) + 0.3))
	t.teleportTarget = target
	t.teleportAt = clock
	t.airborneSince = nil
	t.travelSince = nil
	if target then
		t.lastGoodPos = target
	end
	clearHistory(t)
end

local function checking(t: Track, clock: number): boolean
	return clock >= t.graceUntil and t.teleportTarget == nil
end

-- True while the server has not yet seen this actor's root arrive at its
-- last teleport target.
function MovementService.teleportPending(id: number): boolean
	local t = tracks[id]
	return t ~= nil and t.teleportTarget ~= nil
end

---------------------------------------------------------------------------
-- pivot authority
---------------------------------------------------------------------------

local function writePivot(id: number, pivot: Vector3?)
	local c = character(id)
	if c then
		c:SetAttribute("UBPivot", pivot)
	end
end

local function plant(t: Track, pos: Vector3, source: string)
	t.pivot = pos
	t.pivotSource = source
	t.pivotAt = now()
	t.travelSince = nil
	t.hopUsed = false
	t.hopping = false
	writePivot(t.id, pos)
end

-- Sets the holder's pivot foot P (root height) and replicates it as UBPivot.
-- Used for server relocations and pickups; a client proposal cannot replace it.
function MovementService.setPivot(id: number, pos: Vector3)
	local t = tracks[id]
	if not t or not finiteVec(pos) then
		return
	end
	plant(t, pos, "Server")
end

function MovementService.clearPivot(id: number)
	local t = tracks[id]
	if t then
		t.pivot = nil
		t.pivotSource = "None"
		t.travelSince = nil
	end
	writePivot(id, nil)
end

function MovementService.pivotOf(id: number): Vector3?
	local t = tracks[id]
	return if t then t.pivot else nil
end

-- Pauses travel enforcement (e.g. the pickup gather glide).
function MovementService.skipTravel(id: number, seconds: number)
	local t = tracks[id]
	if t then
		t.travelSkipUntil = math.max(t.travelSkipUntil, now() + seconds)
		t.travelSince = nil
	end
end

-- Root height above the ground when standing (for placing a pivot or a
-- teleport on the ground).
function MovementService.standHeight(id: number): number
	local t = tracks[id]
	return if t then t.stand else 3
end

-- Validates a client-proposed pivot foot and plants it.
local function proposePivot(track: Track, pos: Vector3): boolean
	-- only the first plant of a possession, or a late proposal replacing the
	-- server's own guess
	if track.pivot ~= nil and not (track.pivotSource == "Auto" and now() - track.pivotAt <= 1.5) then
		return false
	end
	local ping = math.min(MovementService.ping(track.id), 0.3)
	local fromRoot = flat(pos - track.pos).Magnitude
	if fromRoot > 2 + 26 * ping or math.abs(pos.Y - track.pos.Y) > 4 + 20 * ping then
		return false
	end
	-- the slow-down after a catch (including an airborne catch) can't carry
	-- the holder further than this from where the server saw the catch
	if flat(pos - track.holdPos).Magnitude > 28 + 40 * ping then
		return false
	end
	plant(track, pos, "Client")
	return true
end

-- The client's proposed pivot foot. One that arrives a moment before the
-- server has handed over the disc (predicted catch) is kept briefly.
local function onPivot(player: Player, pos: any)
	local actor = services.PlayerService.fromPlayer(player)
	local t = actor and tracks[actor.id]
	if not t or typeof(pos) ~= "Vector3" or not finiteVec(pos) then
		return
	end
	local track = t :: Track
	if not track.holding then
		track.earlyPivot = pos
		track.earlyPivotAt = now()
		return
	end
	proposePivot(track, pos)
end

local function updateHolding(actor: any, t: Track, root: BasePart, grounded: boolean, clock: number)
	local tNow = now()
	if t.pivot == nil then
		-- server fallback plant (humans normally propose theirs first). Like
		-- the client, the slow-down of an airborne catch starts on landing.
		if grounded then
			if t.holdAirborne then
				t.holdAirborne = false
				t.holdStart = tNow
			end
			local held = tNow - t.holdStart
			local speed = flat(t.vel).Magnitude
			if actor.isBot then
				if held >= HD.DecelMaxTime + 0.15 or (held >= 0.1 and speed < HD.PlantSpeed + 2) then
					plant(t, t.pos, "Auto")
				end
			else
				local due = HD.DecelMaxTime + 0.3 + 2 * MovementService.ping(t.id)
				-- only once the body has really stopped (or long after it should have)
				if (held >= due and speed < HD.PlantSpeed + 2) or held >= due + 0.6 then
					plant(t, t.pos, "Auto")
				end
			end
		end
		return
	end
	if actor.isBot then
		return
	end
	local pivot = t.pivot :: Vector3
	-- the one hop per possession
	if not grounded then
		if not t.hopUsed then
			t.hopping = true
		end
	elseif t.hopping then
		t.hopping = false
		t.hopUsed = true
	end
	if t.hopping or tNow < t.travelSkipUntil or not checking(t, clock) then
		t.travelSince = nil
		return
	end
	local tolerance = HD.PivotRadius + 1.5 + 10 * math.min(MovementService.ping(t.id), 0.3)
	local d = flat(t.pos - pivot).Magnitude
	if d <= tolerance then
		t.travelSince = nil
		return
	end
	if t.travelSince == nil then
		t.travelSince = tNow
		return
	end
	if tNow - (t.travelSince :: number) < TRAVEL_CONFIRM or tNow - t.lastTravelSnap < TRAVEL_SNAP_EVERY then
		return
	end
	t.lastTravelSnap = tNow
	t.travelSince = nil
	services.PlayerService.teleport(actor, CFrame.new(pivot) * root.CFrame.Rotation)
	writePivot(t.id, pivot)
	MovementService.Travel:Fire(t.id)
end

---------------------------------------------------------------------------
-- kinematics
---------------------------------------------------------------------------

local function standFor(model: Model, root: BasePart): number
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	-- R6: legs are 2 studs, the root sits at torso centre
	return root.Size.Y / 2 + 2
end

local function speedBudget(actor: any, t: Track, root: BasePart, tNow: number)
	if tNow < t.speedCheckAt then
		return
	end
	t.speedCheckAt = tNow + SPEED_WINDOW
	if t.histCount < 2 then
		return
	end
	-- the sample closest to one window ago
	local newest = histIndex(t, 0)
	local oldIndex = histIndex(t, t.histCount - 1)
	for back = 1, t.histCount - 1 do
		local i = histIndex(t, back)
		oldIndex = i
		if tNow - t.histT[i] >= SPEED_WINDOW then
			break
		end
	end
	local span = t.histT[newest] - t.histT[oldIndex]
	if span < SPEED_WINDOW * 0.9 then
		return
	end
	local disp = flat(t.histPos[newest] - t.histPos[oldIndex]).Magnitude
	if disp <= SPEED_LIMIT * span then
		t.speedFlags = 0
		t.lastGoodPos = t.histPos[newest]
		return
	end
	t.speedFlags += 1
	warn(
		string.format(
			"[MovementService] %s covered %.1f studs in %.2f s (%d/%d)",
			actor.name,
			disp,
			span,
			t.speedFlags,
			SPEED_FLAGS_TO_SNAP
		)
	)
	if t.speedFlags >= SPEED_FLAGS_TO_SNAP then
		t.speedFlags = 0
		services.PlayerService.teleport(actor, CFrame.new(t.lastGoodPos) * root.CFrame.Rotation)
	end
end

-- Updates kinematics for every actor (runs every Heartbeat; cheap).
local function updateKinematics()
	local exclude: { Instance } = {}
	for _, c in Actors.characters() do
		table.insert(exclude, c)
	end
	rayParams.FilterDescendantsInstances = exclude
	local clock = os.clock()
	local tNow = now()
	for _, actor in services.PlayerService.all() do
		local root = services.PlayerService.root(actor)
		local model = actor.character
		if root and model then
			local track = tracks[actor.id]
			local pos = root.Position
			if not track then
				track = newTrack(actor.id, pos)
				tracks[actor.id] = track
			end
			local t = track :: Track
			t.pos = pos
			t.vel = root.AssemblyLinearVelocity
			t.stand = standFor(model, root)

			-- ground probe sized to this character
			local hit = workspace:Raycast(pos, Vector3.new(0, -(t.stand + 4), 0), rayParams)
			local h = if hit then pos.Y - hit.Position.Y else math.huge
			t.heightAboveGround = h
			t.jumpHeight = if hit then math.max(0, h - t.stand) else t.stand + 4
			local grounded = h <= t.stand + 1.2 and t.vel.Y < 8
			t.grounded = grounded
			if grounded then
				t.lastGroundedPos = Vector3.new(pos.X, if hit then hit.Position.Y else pos.Y - t.stand, pos.Z)
				t.airborneSince = nil
			else
				t.lastAirborneAt = tNow
				if t.airborneSince == nil then
					t.airborneSince = clock
				end
			end
			if grounded and not t.wasGrounded and t.pendingLanding then
				t.pendingLanding = false
				MovementService.Landed:Fire(actor.id, t.lastGroundedPos)
			end
			t.wasGrounded = grounded

			-- arrival after a teleport
			local target = t.teleportTarget
			if target then
				if (pos - target).Magnitude <= TELEPORT_ARRIVE or clock - t.teleportAt > TELEPORT_WAIT then
					t.teleportTarget = nil
					clearHistory(t)
				end
			end
			if not checking(t, clock) then
				clearHistory(t)
			end
			pushHistory(t, tNow, pos, flatLook(root.CFrame))

			if not actor.isBot and checking(t, clock) then
				speedBudget(actor, t, root, tNow)
				-- a long hover with no ground in reach and no vertical motion
				-- (gravity 160 makes a legit one impossible)
				local since = t.airborneSince
				if
					since
					and clock - since > HOVER_TIME
					and h > t.stand + 3
					and math.abs(t.vel.Y) < 1
					and checking(t, clock)
				then
					t.airborneSince = clock
					services.PlayerService.teleport(
						actor,
						CFrame.new(t.lastGroundedPos + Vector3.new(0, t.stand, 0)) * root.CFrame.Rotation
					)
				end
			end

			if t.holding then
				updateHolding(actor, t, root, grounded, clock)
			end
		end
	end
end

---------------------------------------------------------------------------
-- exertion mirror
---------------------------------------------------------------------------

-- Mirrors the client sim exactly: 0..ExertionMax, sprinting (running mode
-- Ground or Landing above jog speed; Slide, DiveSlide, Recover, Air, Pivot and
-- Mark never count) drains a little and regenerates a little more (sprint is
-- effectively free), anything else regenerates fast; regen pauses briefly
-- only after a technique spend.
local function regen(dt: number)
	local tNow = now()
	for _, t in tracks do
		local regenOk = tNow >= t.regenAt
		local sprinting = t.grounded
			and not t.holding
			and (t.mode == "Ground" or t.mode == "Landing")
			and flat(t.vel).Magnitude > MovementConfig.JogSpeed + 0.5
		if sprinting then
			t.exertion -= MovementConfig.SprintDrain * dt
			if regenOk then
				t.exertion += MovementConfig.SprintRegen * dt
			end
		elseif regenOk then
			t.exertion += MovementConfig.ExertionRegen * dt
		end
		t.exertion = math.clamp(t.exertion, 0, MovementConfig.ExertionMax)
	end
end

---------------------------------------------------------------------------
-- techniques
---------------------------------------------------------------------------

local function replicate(actorId: number, tech: string, quality: string, dir: Vector3, info: string?)
	local c = character(actorId)
	if not c then
		return
	end
	local public = tech
	if tech == "FakeCommit" then
		public = "Lean"
	end
	c:SetAttribute("TechDir", dir)
	c:SetAttribute("TechQ", quality)
	c:SetAttribute("TechInfo", info or "")
	c:SetAttribute("Tech", public)
	c:SetAttribute("TechT", now())
end

local function costOf(tech: string, info: string?): number
	if tech == "BurstStep" and info == "Explosive" then
		return 0 -- the explosive plant restart is free in the sim
	end
	return (MovementConfig.TechCosts :: any)[tech] or 0
end

-- The PivotSwing a Break would link to (the chain's last entry), or nil.
local function breakSwing(t: Track, ts: number): number?
	local chain = ComboEvaluator.active(t.combo, ts)
	if not chain then
		return nil
	end
	local last = chain.entries[#chain.entries]
	if last and last.tech == "PivotSwing" then
		return last.t
	end
	return nil
end

-- Per-technique rules beyond cooldown and cost. Returns the quality to
-- record, or nil to refuse.
local function judge(t: Track, tech: string, quality: string, info: string?, ts: number): string?
	if tech == "TipReset" then
		-- only right after a tip the server is resolving (or resolved)
		if t.airTips >= RS.MaxTipsPerAir or not services.CatchingService.recentTip(t.id, ts, 0.4) then
			return nil
		end
		return quality
	elseif tech == "AirRedirect" then
		-- one per airtime, plus one per reset
		if t.airRedirects >= 1 + t.airResets then
			return nil
		end
		return quality
	elseif tech == "Dive" then
		-- a ground layout or an air layout: one per airtime, plus one per reset
		if info == "Air" and t.airLayouts >= 1 + t.airResets then
			return nil
		end
		return quality
	elseif tech == "PivotSwing" then
		-- only while holding (or just before the release reached us)
		if not (t.holding or ts <= t.holdEnd + 0.1) or ts < t.holdStart - 0.5 then
			return nil
		end
		if quality == "Perfect" then
			-- "Sold" needs a real fake shortly before the swing
			local c = character(t.id)
			local fakeT = c and c:GetAttribute("FakeT")
			if type(fakeT) ~= "number" or ts - fakeT > HD.SwingSoldWindow + 0.15 or fakeT - ts > 0.4 then
				return "Clean"
			end
		end
		return quality
	elseif tech == "Break" then
		-- scored only right after a Sold swing, once per swing
		local q = ComboEvaluator.breakQuality(t.combo, ts)
		local swingAt = breakSwing(t, ts)
		if q == nil or swingAt == nil or swingAt == t.breakSwingAt then
			return nil
		end
		return q
	end
	return quality
end

-- Validates one reported technique at timestamp ts. Returns the accepted
-- quality, or nil.
local function accept(t: Track, tech: string, quality: string, info: string?, ts: number): string?
	local clock = os.clock()
	if KNOWN_TECHS[tech] == nil then
		return nil
	end
	-- rate limit (arrival time)
	while #t.techTimes > 0 and clock - t.techTimes[1] > 1 do
		table.remove(t.techTimes, 1)
	end
	if #t.techTimes >= MAX_TECHS_PER_SECOND then
		return nil
	end
	-- cooldown mirror, on the events' own timestamps
	local cd = (MovementConfig.TechCooldowns :: any)[tech] or 0
	if cd > 0 and ts - (t.techAt[tech] or -math.huge) < cd - COOLDOWN_SLACK then
		return nil
	end
	local q = judge(t, tech, quality, info, ts)
	if q == nil then
		return nil
	end
	local cost = costOf(tech, info)
	if cost > 0 and q ~= "Gassed" and t.exertion < cost * MovementConfig.GassedFraction - EXERTION_SLACK then
		-- a full-strength technique the player cannot have afforded
		return nil
	end
	table.insert(t.techTimes, clock)
	t.techAt[tech] = ts
	if cost > 0 then
		t.exertion = math.max(0, t.exertion - cost) -- the sim clamps spends at 0 too
		t.regenAt = ts + MovementConfig.ExertionRegenDelay
	end
	return q
end

-- Feeds one event to the actor's signature tracker and pays what it completes.
local function feedSignatures(id: number, t: Track, e: Signatures.Event)
	for _, hit in Signatures.feed(t.signatures, e) do
		ComboEvaluator.signature(t.combo, hit.name, hit.points, hit.t)
		MovementService.SignatureHit:Fire(id, hit)
	end
end

local GROUNDED_MODES = {
	Ground = true,
	Slide = true,
	DiveSlide = true,
	Recover = true,
	Landing = true,
	Pivot = true,
	Mark = true,
	Frozen = true,
}

-- The airtime ended (client-reported grounded mode): its air moves and
-- resets start over.
local function endAirtime(id: number, t: Track, ts: number)
	feedSignatures(id, t, { kind = "Land", t = ts })
	t.airRedirects = 0
	t.airLayouts = 0
	t.airResets = 0
	t.airTips = 0
end

-- A reported movement mode change: tracks takeoffs and landings (on the
-- client's clock, arrival minus ping) and ends the airtime on landing.
local function modeChanged(id: number, t: Track, from: string, to: string, at: number)
	local wasAir = from == "Air" or from == "Dive"
	local isAir = to == "Air" or to == "Dive"
	if isAir and not wasAir then
		t.lastTakeoffAt = at
	elseif wasAir and GROUNDED_MODES[to] then
		t.lastLandAt = at
		endAirtime(id, t, at)
	end
end

-- Records an accepted technique: pose attributes, combo chain, listeners.
local function record(id: number, t: Track, tech: string, quality: string, dir: Vector3, info: string?, ts: number)
	t.lastTech = tech
	t.lastTechAt = ts
	-- air moves and resets this airtime
	if tech == "AirRedirect" then
		t.airRedirects += 1
	elseif tech == "Dive" then
		t.airLayouts += 1
	elseif tech == "WallRebound" or tech == "TipReset" then
		t.airResets += 1
		if tech == "TipReset" then
			t.airTips += 1
		end
		for _, r in RS.AirRefund do
			t.techAt[r] = nil
		end
	end
	-- reset refunds mirror the sim's (Config/Movement.Reset)
	if quality == "Perfect" then
		local refunds: { string }? = nil
		if tech == "PrecisionLanding" and info == "Reset" then
			refunds = RS.LandingRefund
		elseif tech == "PrecisionLanding" and info == "RollOut" then
			refunds = RS.RollOutRefund
		elseif tech == "RecoveryChain" then
			refunds = RS.RecoveryRefund
		end
		if refunds then
			for _, r in refunds do
				t.techAt[r] = nil
			end
		end
	end
	if tech == "Dive" then
		t.lastDiveAt = ts
	elseif tech == "PivotSwing" then
		t.lastSwingAt = ts
	elseif tech == "Break" then
		t.breakSwingAt = breakSwing(t, ts) or ts
	end
	replicate(id, tech, quality, dir, info)
	ComboEvaluator.add(t.combo, tech, quality, ts)
	MovementService.TechAccepted:Fire(id, tech, quality, info)
	feedSignatures(id, t, { kind = "Tech", t = ts, tech = tech, quality = quality, info = info })
end

local function cleanDir(v: any): Vector3
	if typeof(v) ~= "Vector3" or not finiteVec(v) or v.Magnitude > 1.01 then
		return Vector3.zero
	end
	return v
end

local function onTech(player: Player, events: any, mode: any)
	local actor = services.PlayerService.fromPlayer(player)
	if not actor then
		return
	end
	local t = tracks[actor.id]
	if not t then
		return
	end
	if type(mode) == "string" and VALID_MODES[mode] and mode ~= t.mode then
		local from = t.mode
		t.mode = mode
		if actor.character then
			actor.character:SetAttribute("MS", mode)
		end
		modeChanged(actor.id, t, from, mode, now() - MovementService.ping(actor.id))
	end
	if type(events) ~= "table" then
		return
	end
	local arrival = now()
	local n = 0
	for _, e in events do
		n += 1
		if n > 6 then
			break
		end
		if type(e) == "table" and type(e.tech) == "string" then
			local quality = if type(e.quality) == "string" and VALID_QUALITY[e.quality] then e.quality else "Clean"
			local dir = cleanDir(e.dir)
			local info = if type(e.info) == "string" and #e.info <= 24 then e.info else nil
			-- judged on when it happened: at most MAX_EVENT_AGE old, never in
			-- the future, never before an earlier event
			local raw = if type(e.t) == "number" and finite(e.t) then e.t else arrival
			local ts = math.max(math.clamp(raw, arrival - MAX_EVENT_AGE, arrival), t.lastTs)
			local q = accept(t, e.tech, quality, info, ts)
			if q then
				t.lastTs = ts
				record(actor.id, t, e.tech, q, dir, info, ts)
			else
				t.rejected += 1
			end
		end
	end
end

-- Server-driven technique for bots (no validation needed). `t` is the
-- event time (defaults to now).
function MovementService.botTech(
	id: number,
	tech: string,
	dir: Vector3,
	mode: string?,
	quality: string?,
	info: string?,
	at: number?
)
	local t = tracks[id]
	local ts = if at and finite(at) then math.min(at, now()) else now()
	local q = if quality and VALID_QUALITY[quality] then quality else "Clean"
	if t then
		ts = math.max(ts, t.lastTs)
		t.lastTs = ts
		if mode and mode ~= t.mode then
			local from = t.mode
			t.mode = mode
			modeChanged(id, t, from, mode, ts)
		end
		if KNOWN_TECHS[tech] ~= nil then
			t.techAt[tech] = ts
			record(id, t, tech, q, dir, info, ts)
		else
			replicate(id, tech, q, dir, info)
		end
	else
		replicate(id, tech, q, dir, info)
	end
	local c = character(id)
	if c and mode then
		c:SetAttribute("MS", mode)
	end
end

function MovementService.setBotMode(id: number, mode: string)
	local t = tracks[id]
	if t and mode ~= t.mode then
		local from = t.mode
		t.mode = mode
		modeChanged(id, t, from, mode, now())
	end
	local c = character(id)
	if c then
		c:SetAttribute("MS", mode)
	end
end

-- Is the actor currently in a layout (dive) or its ground slide?
function MovementService.isDiving(id: number): boolean
	local t = tracks[id]
	if not t then
		return false
	end
	return t.mode == "Dive" or t.mode == "DiveSlide" or now() - t.lastDiveAt < 0.9
end

function MovementService.isSliding(id: number): boolean
	local t = tracks[id]
	return t ~= nil and t.mode == "Slide"
end

function MovementService.isOnGroundAfterLayout(id: number): boolean
	local t = tracks[id]
	return t ~= nil and (t.mode == "DiveSlide" or t.mode == "Recover") and now() - t.lastDiveAt < 2
end

-- Was the holder mid Quick Swing at server time `at`?
function MovementService.isSwinging(id: number, at: number): boolean
	local t = tracks[id]
	return t ~= nil and at >= t.lastSwingAt and at <= t.lastSwingAt + HD.SwingTime
end

-- Possession bookkeeping (DiscService.giveTo / release). Repeating the
-- current value changes nothing.
function MovementService.setHolding(id: number, holding: boolean)
	local t = tracks[id]
	if not t then
		if not holding then
			writePivot(id, nil)
		end
		return
	end
	if t.holding == holding then
		return
	end
	t.holding = holding
	if holding then
		t.holdStart = now()
		-- given the disc in the same frame as a teleport: the server's last
		-- sample is still the old spot, so measure from the target
		t.holdPos = t.teleportTarget or t.pos
		t.holdAirborne = not t.grounded
		t.pendingLanding = not t.grounded
		t.pivot = nil
		t.pivotSource = "None"
		t.hopUsed = false
		t.hopping = false
		t.travelSince = nil
		writePivot(id, nil)
		local early = t.earlyPivot
		t.earlyPivot = nil
		if early and now() - t.earlyPivotAt <= 0.5 then
			proposePivot(t, early)
		end
	else
		t.holdEnd = now()
		t.pendingLanding = false
		MovementService.clearPivot(id)
	end
end

-- Signature move inputs from the catch path and the rules (server-validated).
function MovementService.noteTip(id: number, discId: string, defender: boolean, at: number)
	local t = tracks[id]
	if t then
		feedSignatures(id, t, { kind = "Tip", t = at, discId = discId, defender = defender })
	end
end

function MovementService.noteCatch(id: number, discId: string, interception: boolean, at: number)
	local t = tracks[id]
	if not t then
		return
	end
	-- in the air at the catch time? (the answer comes a round trip after
	-- the catch, often after the landing was reported)
	local tookOff = t.lastTakeoffAt <= at + 0.05
	local landedBetween = t.lastLandAt >= t.lastTakeoffAt and t.lastLandAt <= at
	local airborne = tookOff and not landedBetween
	local height = 0
	if airborne then
		local pos = MovementService.positionAt(id, at)
		height = math.max(0, pos.Y - t.stand - t.lastGroundedPos.Y)
	end
	feedSignatures(id, t, {
		kind = "Catch",
		t = at,
		discId = discId,
		airborne = airborne,
		height = height,
		interception = interception,
	})
end

function MovementService.noteGreatest(id: number)
	local t = tracks[id]
	if t then
		feedSignatures(id, t, { kind = "Greatest", t = now() })
	end
end

function MovementService.expectLanding(id: number)
	local t = tracks[id]
	if t then
		t.pendingLanding = true
	end
end

-- A play (catch, interception, block) converts the actor's chain. `at` is
-- when it happened (the claim time); defaults to now.
function MovementService.convertCombo(id: number, payoff: string, at: number?): ComboEvaluator.Summary?
	local t = tracks[id]
	if not t then
		return nil
	end
	local tNow = now()
	local when = if at and finite(at) then math.clamp(at, tNow - 0.5, tNow) else tNow
	return ComboEvaluator.convert(t.combo, when, payoff)
end

-- The throw path's hook at release: adds the "Break" link when the release
-- follows a Sold swing (once per swing; a client "Break" Tech event for the
-- same swing counts as the same link). Returns the Break quality, or nil.
function MovementService.noteRelease(id: number, at: number?): string?
	local t = tracks[id]
	if not t then
		return nil
	end
	local tNow = now()
	local when = if at and finite(at) then math.clamp(at, tNow - 0.5, tNow) else tNow
	local ts = math.max(when, t.lastTs)
	local q = judge(t, "Break", "Clean", nil, ts)
	if q == nil then
		return nil
	end
	t.lastTs = ts
	t.techAt.Break = ts
	record(id, t, "Break", q, Vector3.zero, nil, ts)
	return q
end

-- Pays the 25 % share of chains that can no longer be converted.
local function settleCombos()
	local tNow = now() - SETTLE_LAG
	for id, t in tracks do
		local done = ComboEvaluator.settle(t.combo, tNow)
		if #done > 0 then
			local player = Actors.playerOf(id)
			if player then
				for _, summary in done do
					services.ProgressionService.comboUnconverted(player, summary)
				end
			end
		end
	end
end

function MovementService.Init(s: any)
	services = s
end

function MovementService.Start()
	Net.event("Tech").OnServerEvent:Connect(onTech)
	Net.event("Pivot").OnServerEvent:Connect(onPivot)
	local settleAt = 0
	RunService.Heartbeat:Connect(function(dt)
		updateKinematics()
		regen(dt)
		local clock = os.clock()
		if clock >= settleAt then
			settleAt = clock + SETTLE_EVERY
			settleCombos()
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		tracks[actor.id] = nil
	end)
	services.PlayerService.CharacterSpawned:Connect(function(actor, model)
		local root = model:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			local t = newTrack(actor.id, root.Position)
			t.stand = standFor(model, root)
			tracks[actor.id] = t
		end
	end)
	local _ = Players
end

return MovementService
