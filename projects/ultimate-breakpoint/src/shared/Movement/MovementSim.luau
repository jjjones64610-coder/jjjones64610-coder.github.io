--!strict
--[[
	MovementSim — the movement-tech engine.

	Pure simulation of one player's horizontal momentum, technique timing,
	exertion, cooldowns, the disc holder's pivot and the marker's shuffle. It
	knows nothing about Instances: a driver (the client MovementController for
	the local player, BotService for bots) feeds it input + an environment
	snapshot and applies the returned velocity. The Humanoid moves the body:
	the driver sets WalkSpeed = |vel| and Move(vel.Unit), and on frames where
	Output.impulse is true it also writes AssemblyLinearVelocity directly so
	technique starts land on the frame they are pressed. Because it is pure, the
	same code is fuzz-tested offline (tests/movement_spec.luau) to prove that no
	input sequence can exceed the speed caps.

	PRESS CONTRACT. press(s, action, input, env) returns (ok, reason). Every
	press does something visible or gives a reason ("Cooldown", "Speed",
	"Used", "Context"; "Exertion" is reserved and never produced, because a
	tired technique still fires as Gassed). Refusals that deserve explaining
	also queue a Feedback { kind = reason, value?, text } with ready-to-show
	text ("NEED SPEED", "ONE PER JUMP", ...). Presses that are slightly early,
	in a short cooldown or about to become valid are BUFFERED for
	InputBuffer (0.15 s) and retried every step(); a buffered press returns
	true. Pressing the same action again while it waits changes nothing (this
	replaces the old anti-mash lockouts). Timing changes only the bonus.

	Inputs map to five actions plus the holder's swing:

	  Cut   ground, input 25-120 deg off the running line -> Snap Cut
	        ground, input along the line                -> 0.1 s look-ahead:
	              steer away inside it = Snap Cut, else Fake Commit (jab)
	        ground, no input / input >120 deg, fast       -> Momentum Cancel (plant)
	        ground, slower than SnapCut.MinSpeed          -> quick side step
	        during a plant's restart window               -> restart (Perfect/Clean)
	        in the air                                    -> Air Redirect
	        mid-slide                                     -> Slide Cut
	        dive recovery (DiveSlide/Recover)             -> Recovery Chain
	  Burst ground or slide                               -> Burst Step
	        during a plant window                         -> Explosive restart (free)
	        just before touchdown                         -> buffered, fires on landing
	  Slide ground, fast                                  -> Slide
	        airborne, <=0.35 s before touchdown           -> Precision Landing / Roll-out
	  Dive  ground, slide or once in the air              -> Layout dive
	  Jump  ground / slide                                -> Jump / slide hop / plant jump
	        airborne beside a Rebound wall                -> Wall Rebound
	        dive recovery                                 -> Recovery Chain pop-up
	        holding the disc                              -> hop (one per possession)

	A Cut is judged against the RUNNING LINE: the direction you had been
	committed to (CommitAngle), remembered for LineMemory after it breaks, so the
	direction key a keyboard player must press before Q (the pre-steer) never
	spoils the cut. A plant ends with an automatic restart if a direction is
	held; pressing Q/F/Space inside its window upgrades it.

	HOLDING THE DISC (positional step model). After the (predicted) catch the
	holder slows down (Decel) and plants a pivot foot P once slower than
	PlantSpeed or after DecelMaxTime; the plant is reported once in
	Output.pivotPos so the driver can propose it to the server, and
	setPivot() adopts the server's authoritative P (UBPivot). The free foot is
	a step vector s in the throw frame (forward = env.aimYaw, so camera-relative
	WASD == aim-relative): target R * input, forward <= 0.75R, back <= 0.9R,
	length on a critically damped spring, direction turning through the front.
	The root is driven toward P + BodyShare * s (velocity proportional to the
	distance, capped, never overshooting). swing(side) is the Quick Swing,
	fakeStep(side) the fake's lunge, Jump the one hop (horizontal zeroed, step
	frozen). Output.step is the world step vector.

	MARKING. setMarking(true) overlays the mark shuffle on the ground: tight
	acceleration, no turn radius, no sprint drain. Cut/Dive/Burst fire their
	technique and end the mark; Jump keeps it; Slide is left to the stance
	toggle (refused here).
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config.Movement)
local VecMath = require(Shared.Util.VecMath)

local MovementSim = {}

export type Mode = "Ground" | "Air" | "Slide" | "Dive" | "DiveSlide" | "Recover" | "Landing" | "Frozen"
export type HoldPhase = "None" | "Air" | "Decel" | "Pivot"
export type Action = "Jump" | "Cut" | "Slide" | "Dive" | "Burst"
-- Why a press did nothing. "Exertion" is part of the contract but never produced.
export type Reason = "Cooldown" | "Speed" | "Used" | "Context" | "Exertion"

export type TechEvent = {
	tech: string,
	quality: string,
	t: number,
	dir: Vector3,
	chain: boolean,
	info: string?,
}

export type Feedback = { kind: string, value: number?, text: string? }

export type Input = { move: Vector3, sprint: boolean }

export type Env = {
	grounded: boolean,
	actualVel: Vector3,
	timeToLand: number?,
	wallNormal: Vector3?,
	wallDistance: number?,
	wallId: string?,
	facing: Vector3?,
	pos: Vector3?, -- root position (needed while holding; estimated from velocity otherwise)
	aimYaw: number?, -- camera / throw yaw (radians, CameraController.getYaw convention)
	blocked: boolean?, -- a short horizontal ray along the sim velocity hit something solid
	pivotOffset: Vector3?, -- deprecated and ignored: the pivot lives in the sim (setPivot)
}

export type Output = {
	vel: Vector3,
	setVertical: number?,
	jump: boolean,
	events: { TechEvent },
	feedback: { Feedback },
	pivotEstablished: boolean,
	landed: boolean,
	tookOff: boolean,
	impulse: boolean, -- write AssemblyLinearVelocity this frame (technique start / velocity jump)
	step: Vector3, -- world flat step vector s (zero when not holding)
	pivotPos: Vector3?, -- set on the frame the sim plants its own pivot foot
}

type Buffered = { action: string, expires: number, side: number }

export type State = {
	mode: Mode,
	now: number,
	modeStart: number,
	vel: Vector3,
	pos: Vector3,
	lastOutVel: Vector3,
	lastMove: Vector3,
	impulse: boolean,
	exertion: number,
	regenAt: number,
	ready: { [string]: number },
	lastTech: string?,
	lastTechAt: number,
	lastKeyTech: string?, -- last technique other than Jump (Perfect chain checks)
	lastKeyAt: number,
	lastCutAt: number,
	blockedSince: number?,

	-- running line
	committed: boolean,
	commitDir: Vector3,
	commitSince: number,
	lineSpeed: number,
	prevLineDir: Vector3,
	prevLineSince: number,
	prevLineSpeed: number,
	lineResetAt: number,

	-- input buffer / Cut look-ahead
	buffer: Buffered?,
	retrying: boolean,
	retryDeferred: boolean,
	retryReason: string?,
	retryText: string?,
	retryValue: number?,
	lookAheadUntil: number,
	lookLine: Vector3,
	lookSince: number,
	lookSpeed: number,

	plantAt: number,
	plantEnd: number,
	plantDecel: number,
	plantGassed: boolean,
	plantResolved: boolean,

	jabUntil: number,
	sideStepUntil: number,
	sideStepDir: Vector3,
	sideStepSpeed: number,
	soldUntil: number,
	soldDir: Vector3,

	burstUntil: number,
	burstDir: Vector3,
	burstSpeed: number,

	airStart: number,
	groundLostAt: number?,
	takeoffSpeed: number,
	airRedirectUsed: boolean,
	airDiveUsed: boolean,
	aerialReachUsed: boolean,
	rebounds: number,
	lastWall: string?,

	landingUntil: number,
	landedAt: number,
	landedFromDive: boolean,
	landingVel: Vector3,
	precisionArmedAt: number?,
	lateLandingUntil: number,

	recoverUntil: number,
	popStart: number,

	diveDir: Vector3,

	holding: boolean,
	holdPhase: HoldPhase,
	holdStart: number,
	holdHopped: boolean,
	pivot: Vector3?,
	pivotAdopted: boolean,
	stalePivot: Vector3?, -- an adopted pivot we had to abandon (far away); ignored if passed again
	step: Vector3,
	stepLenVel: number,
	swingUntil: number,
	lastSwingSide: number,
	fakeUntil: number,
	fakeSide: number,
	lastFakeAt: number,
	restActive: boolean,
	restX: number,
	restY: number,
	restInputDir: Vector3,
	restInputMag: number,

	marking: boolean,

	frozen: boolean,

	pendingVertical: number?,
	pendingJump: boolean,
	pendingEvents: { TechEvent },
	pendingFeedback: { Feedback },
	pendingPivot: boolean,
	pendingPivotPos: Vector3?,
}

local Q = Config.Quality
local SC = Config.SnapCut
local MC = Config.MomentumCancel
local FC = Config.FakeCommit
local BS = Config.BurstStep
local SL = Config.Slide
local SLC = Config.SlideCut
local DV = Config.Dive
local DS = Config.DiveSlide
local RC = Config.Recover
local RO = Config.RollOut
local AR = Config.AirRedirect
local PL = Config.PrecisionLanding
local WR = Config.WallRebound
local HD = Config.Holding
local MK = Config.Marking

local FORWARD = Vector3.new(0, 0, -1)
local BUFFER = Config.InputBuffer
local NO_INPUT: Input = { move = Vector3.zero, sprint = false }

-- Short names for cooldown feedback.
local SHORT: { [string]: string } = {
	BurstStep = "BURST",
	Dive = "LAYOUT",
	MomentumCancel = "PLANT",
	Slide = "SLIDE",
	FakeCommit = "FAKE",
	PivotSwing = "SWING",
}

-- Techniques whose follow-up Burst / Layout counts as a Perfect chain.
local BURST_CHAIN: { [string]: boolean } = {
	SnapCut = true,
	SlideCut = true,
	RecoveryChain = true,
	MomentumCancel = true,
}
local DIVE_CHAIN: { [string]: boolean } = {
	SnapCut = true,
	BurstStep = true,
	SlideCut = true,
	AirRedirect = true,
	RecoveryChain = true,
	MomentumCancel = true,
	PrecisionLanding = true,
	Slide = true,
}

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

function MovementSim.new(now: number?): State
	local t = now or 0
	return {
		mode = "Ground",
		now = t,
		modeStart = t,
		vel = Vector3.zero,
		pos = Vector3.zero,
		lastOutVel = Vector3.zero,
		lastMove = Vector3.zero,
		impulse = false,
		exertion = Config.ExertionMax,
		regenAt = t,
		ready = {},
		lastTech = nil,
		lastTechAt = -math.huge,
		lastKeyTech = nil,
		lastKeyAt = -math.huge,
		lastCutAt = -math.huge,
		blockedSince = nil,

		committed = false,
		commitDir = FORWARD,
		commitSince = t,
		lineSpeed = 0,
		prevLineDir = FORWARD,
		prevLineSince = t,
		prevLineSpeed = 0,
		lineResetAt = -math.huge,

		buffer = nil,
		retrying = false,
		retryDeferred = false,
		retryReason = nil,
		retryText = nil,
		retryValue = nil,
		lookAheadUntil = 0,
		lookLine = FORWARD,
		lookSince = t,
		lookSpeed = 0,

		plantAt = 0,
		plantEnd = 0,
		plantDecel = MC.BrakeDecel,
		plantGassed = false,
		plantResolved = true,

		jabUntil = 0,
		sideStepUntil = 0,
		sideStepDir = FORWARD,
		sideStepSpeed = 0,
		soldUntil = 0,
		soldDir = FORWARD,

		burstUntil = 0,
		burstDir = FORWARD,
		burstSpeed = 0,

		airStart = t,
		groundLostAt = nil,
		takeoffSpeed = 0,
		airRedirectUsed = false,
		airDiveUsed = false,
		aerialReachUsed = false,
		rebounds = 0,
		lastWall = nil,

		landingUntil = 0,
		landedAt = -math.huge,
		landedFromDive = false,
		landingVel = Vector3.zero,
		precisionArmedAt = nil,
		lateLandingUntil = 0,

		recoverUntil = 0,
		popStart = 0,

		diveDir = FORWARD,

		holding = false,
		holdPhase = "None",
		holdStart = 0,
		holdHopped = false,
		pivot = nil,
		pivotAdopted = false,
		stalePivot = nil,
		step = Vector3.zero,
		stepLenVel = 0,
		swingUntil = 0,
		lastSwingSide = -1,
		fakeUntil = -math.huge,
		fakeSide = 0,
		lastFakeAt = -math.huge,
		restActive = false,
		restX = 0,
		restY = 0,
		restInputDir = Vector3.zero,
		restInputMag = 0,

		marking = false,

		frozen = false,

		pendingVertical = nil,
		pendingJump = false,
		pendingEvents = {},
		pendingFeedback = {},
		pendingPivot = false,
		pendingPivotPos = nil,
	}
end

-- Clears momentum and transient technique state (respawn / teleport). Keeps
-- exertion, cooldowns, frozen, the possession (holding, hold phase, the one
-- hop) and the pivot foot; the step restarts squared up.
function MovementSim.reset(s: State)
	local keep = {
		now = s.now,
		pos = s.pos,
		exertion = s.exertion,
		ready = s.ready,
		frozen = s.frozen,
		holding = s.holding,
		holdPhase = s.holdPhase,
		holdStart = s.holdStart,
		holdHopped = s.holdHopped,
		pivot = s.pivot,
		pivotAdopted = s.pivotAdopted,
		stalePivot = s.stalePivot,
		lastSwingSide = s.lastSwingSide,
	}
	local fresh = MovementSim.new(s.now)
	for k, v in fresh :: any do
		(s :: any)[k] = v
	end
	for k, v in keep :: any do
		(s :: any)[k] = v
	end
	if s.frozen then
		s.mode = "Frozen"
	end
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function setMode(s: State, m: Mode)
	s.mode = m
	s.modeStart = s.now
end

local function cooldownLeft(s: State, tech: string): number
	return math.max(0, (s.ready[tech] or -math.huge) - s.now)
end

local function setCooldown(s: State, tech: string)
	local cd = (Config.TechCooldowns :: any)[tech] or 0
	s.ready[tech] = s.now + cd
end

local function spend(s: State, cost: number)
	s.exertion = math.max(0, s.exertion - cost)
	s.regenAt = s.now + Config.ExertionRegenDelay
end

local function isGassed(s: State, cost: number): boolean
	return s.exertion < cost * Config.GassedFraction
end

local function emit(s: State, tech: string, quality: string, dir: Vector3, info: string?)
	local chain = s.lastTech ~= nil and (s.now - s.lastTechAt) <= Config.ChainWindow
	table.insert(s.pendingEvents, {
		tech = tech,
		quality = quality,
		t = s.now,
		dir = dir,
		chain = chain,
		info = info,
	})
	s.lastTech = tech
	s.lastTechAt = s.now
	if tech ~= "Jump" then
		s.lastKeyTech = tech
		s.lastKeyAt = s.now
	end
	if tech ~= "AerialReach" then
		s.impulse = true
	end
end

local function feedback(s: State, kind: string, value: number?, text: string?)
	table.insert(s.pendingFeedback, { kind = kind, value = value, text = text })
end

-- A press that cannot fire. Shows `text` (if any) and returns the reason.
local function refuse(s: State, reason: string, text: string?, value: number?): (boolean, string?)
	if text then
		feedback(s, reason, value, text)
	end
	return false, reason
end

-- A press that will (probably) become valid within the buffer time: keep it and
-- retry every step. While retrying, only record why it is still waiting.
local function defer(
	s: State,
	action: string,
	side: number,
	reason: string,
	text: string?,
	value: number?
): (boolean, string?)
	if s.retrying then
		s.retryDeferred = true
		s.retryReason = reason
		s.retryText = text
		s.retryValue = value
		return false, reason
	end
	s.buffer = { action = action, expires = s.now + BUFFER, side = side }
	return true, nil
end

local function cooldownText(tech: string, left: number): string
	return string.format("%s READY IN %.1fs", SHORT[tech] or string.upper(tech), left)
end

local function queueJump(s: State, vy: number)
	s.pendingVertical = vy
	s.pendingJump = true
end

local function queueVertical(s: State, vy: number)
	s.pendingVertical = vy
end

local function clearPlant(s: State)
	s.plantAt = 0
	s.plantEnd = 0
	s.plantResolved = true
end

local function cancelTransients(s: State)
	s.burstUntil = 0
	s.jabUntil = 0
	s.sideStepUntil = 0
	s.lookAheadUntil = 0
	clearPlant(s)
end

local function enterAir(s: State)
	setMode(s, "Air")
	s.airStart = s.now
	s.takeoffSpeed = s.vel.Magnitude
	s.jabUntil = 0
	s.sideStepUntil = 0
	s.lookAheadUntil = 0
	clearPlant(s)
	s.groundLostAt = nil
end

local function enterRecover(s: State, duration: number)
	setMode(s, "Recover")
	s.recoverUntil = s.now + duration
	s.popStart = s.now
end

local function velDirOr(s: State, fallback: Vector3): Vector3
	local speed = s.vel.Magnitude
	if speed > 1e-3 then
		return s.vel / speed
	end
	return fallback
end

local function facingOr(env: Env): Vector3
	if env.facing then
		local f = VecMath.flatUnit(env.facing)
		if f.Magnitude > 0.5 then
			return f
		end
	end
	return FORWARD
end

-- Throw frame: forward from the aim yaw (falls back to facing), right = forward x up.
local function aimBasis(env: Env): (Vector3, Vector3)
	local fwd = if env.aimYaw ~= nil then VecMath.fromYaw(env.aimYaw) else facingOr(env)
	return fwd, Vector3.new(-fwd.Z, 0, fwd.X)
end

local function isGrounded(s: State): boolean
	return s.mode == "Ground" or s.mode == "Landing"
end

local function topSpeed(s: State, sprint: boolean): number
	if not sprint then
		return Config.JogSpeed
	end
	if s.exertion >= Config.ExhaustedBelow then
		return Config.SprintSpeed
	end
	local t = s.exertion / Config.ExhaustedBelow
	return Config.ExhaustedSprintSpeed + (Config.SprintSpeed - Config.ExhaustedSprintSpeed) * t
end

local function inPlantWindow(s: State): boolean
	if s.plantAt <= 0 then
		return false
	end
	local since = s.now - s.plantAt
	return since >= MC.WindowOpen and since <= MC.WindowClose
end

local function plantTooEarly(s: State): boolean
	if s.plantAt <= 0 then
		return false
	end
	local since = s.now - s.plantAt
	return since >= 0 and since < MC.WindowOpen
end

local function plantQuality(s: State): string
	return if (s.now - s.plantAt) <= MC.PerfectUntil and not s.plantGassed then Q.Perfect else Q.Clean
end

---------------------------------------------------------------------------
-- running line (what Snap Cuts and Plants are judged against)
---------------------------------------------------------------------------

-- Commits to a new line (after a technique sets a direction).
local function setLine(s: State, dir: Vector3, speed: number)
	s.committed = true
	s.commitDir = dir
	s.commitSince = s.now
	s.lineSpeed = speed
	s.lineResetAt = -math.huge
end

-- The line broke (turn or slow-down). Remember the established line, but only
-- on the first break of a turn: a pre-steer breaks it several times.
local function breakLine(s: State)
	if s.committed and s.now - s.lineResetAt > Config.LineMemory then
		s.prevLineDir = s.commitDir
		s.prevLineSince = s.commitSince
		s.prevLineSpeed = s.lineSpeed
		s.lineResetAt = s.now
	end
end

local function trackLine(s: State, dt: number)
	local speed = s.vel.Magnitude
	if speed > Config.CommitMinSpeed then
		local d = s.vel / speed
		if not s.committed or s.commitDir:Dot(d) < math.cos(math.rad(Config.CommitAngle)) then
			breakLine(s)
			s.committed = true
			s.commitDir = d
			s.commitSince = s.now
			s.lineSpeed = speed
		else
			s.lineSpeed = math.max(speed, s.lineSpeed - Config.LineSpeedDecay * dt)
		end
	else
		breakLine(s)
		s.committed = false
		s.commitSince = s.now
	end
end

-- Returns the line direction, when it was established, and the speed to grade
-- against (never below the current speed).
local function runningLine(s: State, env: Env): (Vector3, number, number)
	local speed = s.vel.Magnitude
	if s.now - s.lineResetAt <= Config.LineMemory then
		return s.prevLineDir, s.prevLineSince, math.max(speed, s.prevLineSpeed)
	end
	if s.committed then
		return s.commitDir, s.commitSince, math.max(speed, s.lineSpeed)
	end
	return velDirOr(s, facingOr(env)), s.now, speed
end

---------------------------------------------------------------------------
-- steering models
---------------------------------------------------------------------------

-- Ground steering: acceleration split into along-velocity (accelerate/brake)
-- and perpendicular (turning) components with separate limits. Sideways
-- acceleration falls from LateralAccelLow at jog to LateralAccel at sprint, so
-- jogging is nimble and full sprint is a commitment (turn radius ~6 studs)
-- that sharp changes of direction need a technique to beat.
function MovementSim.steerGround(v: Vector3, wish: Vector3, top: number, dt: number, lateralMult: number): Vector3
	local wishMag = math.min(wish.Magnitude, 1)
	local target = if wishMag > 0.05 then VecMath.flatUnit(wish) * (top * wishMag) else Vector3.zero
	local speed = v.Magnitude
	if speed < Config.RestSpeed then
		return VecMath.moveToward(v, target, Config.AccelFromRest * dt * math.max(lateralMult, 0.5))
	end
	local fwd = v / speed
	local tPar = target:Dot(fwd)
	local tPerp = target - fwd * tPar
	local newPar: number
	if tPar > speed then
		newPar = math.min(tPar, speed + Config.Accel * dt * math.max(lateralMult, 0.5))
	else
		local decel = if wishMag <= 0.05 then Config.Coast else Config.Brake
		if tPar >= 0 and speed > top + 0.5 and tPar >= top - 0.5 then
			decel = Config.OverspeedDecay
		end
		newPar = math.max(tPar, speed - decel * dt)
	end
	local k = math.clamp((speed - Config.JogSpeed) / (Config.SprintSpeed - Config.JogSpeed), 0, 1)
	local lateral = Config.LateralAccelLow + (Config.LateralAccel - Config.LateralAccelLow) * k
	local perpMag = tPerp.Magnitude
	local maxPerp = lateral * lateralMult * dt
	local newPerp = if perpMag > maxPerp then tPerp * (maxPerp / perpMag) else tPerp
	return fwd * newPar + newPerp
end

local function steerAir(s: State, wish: Vector3, dt: number): Vector3
	local wishMag = math.min(wish.Magnitude, 1)
	if wishMag <= 0.05 then
		return s.vel
	end
	local base = math.max(s.takeoffSpeed, Config.AirMinControlSpeed)
	local limit = base + Config.AirGainAllowance
	local target = VecMath.flatUnit(wish) * (base * wishMag)
	local nv = VecMath.moveToward(s.vel, target, Config.AirAccel * dt)
	local ceiling = math.max(limit, s.vel.Magnitude)
	return VecMath.clampMagnitude(nv, ceiling)
end

-- Mark shuffle: tight, no turn radius (velocity moves straight to the target).
local function steerShuffle(v: Vector3, wish: Vector3, dt: number): Vector3
	local wishMag = math.min(wish.Magnitude, 1)
	local target = if wishMag > 0.05 then VecMath.flatUnit(wish) * (MK.ShuffleSpeed * wishMag) else Vector3.zero
	local dv = target - v
	local rate = if dv:Dot(v) < 0 then MK.Brake else MK.Accel
	return VecMath.moveToward(v, target, rate * dt)
end

---------------------------------------------------------------------------
-- holding the disc: pivot foot + step
---------------------------------------------------------------------------

local function plantPivot(s: State)
	s.pivot = s.pos
	s.pivotAdopted = false
	s.holdPhase = "Pivot"
	s.step = Vector3.zero
	s.stepLenVel = 0
	s.vel = Vector3.zero
	s.pendingPivot = true
	s.pendingPivotPos = s.pos
end

-- Advances the step vector toward its target: length on a critically damped
-- spring, direction rotating at a capped rate through the front arc (through
-- the back only while the input points backward).
local function updateStep(s: State, input: Input, env: Env, dt: number)
	local now = s.now
	local R = HD.StepRadius
	local fwd, right = aimBasis(env)
	local fast = now < s.swingUntil or now < s.fakeUntil + HD.FakeStepBack

	local m = VecMath.flat(input.move)
	local mag = m.Magnitude
	if mag > 1 then
		m /= mag
		mag = 1
	end
	local hasDir = mag > 0.2
	local mDir = if hasDir then m / mag else Vector3.zero

	-- A swing's end position holds until a NEW direction is pressed (keeping
	-- the key you already held does not pull you back).
	if s.restActive then
		if hasDir and (s.restInputMag <= 0.2 or VecMath.flatAngle(s.restInputDir, mDir) > 30) then
			s.restActive = false
		elseif not hasDir then
			s.restInputMag = 0
		end
	end

	local tx, ty = 0, 0
	if s.restActive then
		tx, ty = s.restX, s.restY
	elseif hasDir then
		tx, ty = m:Dot(right) * R, m:Dot(fwd) * R
	end
	if now < s.fakeUntil then
		-- the fake lunges the free foot further toward its side
		tx = math.clamp(tx + s.fakeSide * HD.FakeStep * R, -R, R)
	end
	ty = math.clamp(ty, -HD.BackMax * R, HD.ForwardMax * R)

	local cx, cy = s.step:Dot(right), s.step:Dot(fwd)
	local len = math.sqrt(cx * cx + cy * cy)
	local lenT = math.sqrt(tx * tx + ty * ty)

	-- length: exact critically damped spring step (stable for any dt)
	local omega = if fast then HD.SwingSpring else HD.StepSpring
	local x0 = len - lenT
	local v0 = s.stepLenVel
	local e = math.exp(-omega * dt)
	local newLen = lenT + (x0 + (v0 + omega * x0) * dt) * e
	s.stepLenVel = (v0 - omega * (v0 + omega * x0) * dt) * e
	if newLen <= 0 then
		newLen = 0
		s.stepLenVel = 0
	elseif newLen > R then
		newLen = R
		s.stepLenVel = 0
	end

	-- direction: angle from the aim forward, positive to the right
	local phi = if len > 1e-3 then math.atan2(cx, cy) else math.atan2(tx, ty)
	if lenT > 1e-3 then
		local phiT = math.atan2(tx, ty)
		if len < 0.05 * R then
			phi = phiT
		else
			local diff = phiT - phi -- unwrapped: never crosses straight back
			if m:Dot(fwd) < -0.2 then
				diff = (diff + math.pi) % (2 * math.pi) - math.pi
			end
			local maxTurn = math.rad(if fast then HD.SwingAngular else HD.StepAngular) * dt
			phi += math.clamp(diff, -maxTurn, maxTurn)
		end
	end
	local nx = newLen * math.sin(phi)
	local ny = math.clamp(newLen * math.cos(phi), -HD.BackMax * R, HD.ForwardMax * R)
	s.step = right * nx + fwd * ny
end

local function updateHolding(s: State, input: Input, env: Env, dt: number)
	if s.holdPhase == "Air" then
		s.holdPhase = "Decel"
		s.holdStart = s.now
	end
	if s.holdPhase == "Decel" then
		local speed = s.vel.Magnitude
		local newSpeed = math.max(0, speed - HD.DecelRate * dt)
		s.vel = if speed > 1e-3 then s.vel * (newSpeed / speed) else Vector3.zero
		if newSpeed < HD.PlantSpeed or s.now - s.holdStart >= HD.DecelMaxTime then
			plantPivot(s)
		end
		return
	end
	if s.holdPhase ~= "Pivot" then
		return
	end
	local p = s.pivot
	-- No pivot (cleared) or the body is far away from it (teleported without a
	-- new UBPivot): plant a fresh one where we stand.
	if p == nil then
		plantPivot(s)
	elseif VecMath.flat(s.pos - p).Magnitude > HD.StepRadius * HD.BodyShare + 4 then
		if s.pivotAdopted then
			s.stalePivot = p
		end
		plantPivot(s)
	end
	updateStep(s, input, env, dt)
	local target = (s.pivot :: Vector3) + s.step * HD.BodyShare
	local d = VecMath.flat(target - s.pos)
	local dist = d.Magnitude
	if dist < 1e-3 then
		s.vel = Vector3.zero
	else
		local sp = math.min(dist * HD.DriveGain, HD.DriveMax, dist / math.max(dt, 1e-3))
		s.vel = d * (sp / dist)
	end
end

---------------------------------------------------------------------------
-- landing
---------------------------------------------------------------------------

local function landingText(offset: number): string
	return string.format(
		"PRECISION LANDING  %s%d ms",
		if offset >= 0 then "-" else "+",
		math.floor(math.abs(offset) * 1000 + 0.5)
	)
end

local function land(s: State)
	local now = s.now
	local fromDive = s.mode == "Dive"
	s.airRedirectUsed = false
	s.airDiveUsed = false
	s.aerialReachUsed = false
	s.rebounds = 0
	s.lastWall = nil
	s.landedAt = now
	s.landedFromDive = fromDive
	s.landingVel = s.vel
	s.groundLostAt = nil

	if s.holding and s.holdHopped then
		feedback(s, "HopLanded", nil, "TRAVEL — RELEASE BEFORE YOU LAND")
	end

	local armed = s.precisionArmedAt
	s.precisionArmedAt = nil
	if armed ~= nil then
		local offset = now - armed
		if offset <= PL.CleanWindow + 1e-6 then
			local q = if offset <= PL.PerfectWindow + 1e-6 then Q.Perfect else Q.Clean
			if fromDive then
				s.vel = s.vel * (RO.Retention :: any)[q]
				enterRecover(s, RO.RecoverTime)
				emit(s, "PrecisionLanding", q, velDirOr(s, s.diveDir), "RollOut")
			else
				s.vel = s.vel * (PL.Retention :: any)[q]
				setMode(s, "Ground")
				emit(s, "PrecisionLanding", q, velDirOr(s, FORWARD), nil)
			end
			feedback(s, "LandingOffset", offset, landingText(offset))
			return
		elseif offset <= PL.ArmWindow + 0.1 and not fromDive then
			-- armed early: an unlabelled soft landing (no steering penalty)
			s.lateLandingUntil = 0
			s.vel = s.vel * PL.Retention.Soft
			setMode(s, "Ground")
			feedback(s, "LandingOffset", offset, "SOFT LANDING — PRESS CLOSER TO TOUCHDOWN")
			return
		end
	end

	s.lateLandingUntil = now + PL.LateWindow
	if fromDive then
		setMode(s, "DiveSlide")
	else
		setMode(s, "Landing")
		s.landingUntil = now + Config.LandingRecovery
		s.vel = s.vel * Config.LandingRetention
	end
end

---------------------------------------------------------------------------
-- techniques
---------------------------------------------------------------------------

local function pressSnapCut(
	s: State,
	dir: Vector3,
	angle: number,
	since: number,
	gradeSpeed: number,
	sold: boolean
): (boolean, string?)
	local now = s.now
	local sinceCut = now - s.lastCutAt
	if sinceCut < SC.MinInterval then
		return defer(s, "Cut", 0, "Cooldown")
	end
	local q: string
	if isGassed(s, SC.Cost) then
		q = Q.Gassed
	elseif sold then
		q = Q.Perfect
	elseif sinceCut < SC.SpamWindow then
		q = Q.Sloppy
	else
		local commit = now - since
		if commit >= SC.CommitPerfect and gradeSpeed >= Config.SprintSpeed * SC.PerfectSpeedFraction then
			q = Q.Perfect
		elseif commit >= SC.CommitClean then
			q = Q.Clean
		else
			q = Q.Sloppy
		end
	end
	local over = math.clamp((angle - 45) / (SC.MaxAngle - 45), 0, 1)
	local retention = (SC.Retention :: any)[q] * (1 - SC.AnglePenalty * over)
	local newSpeed = gradeSpeed * retention
	if q == Q.Perfect then
		newSpeed = math.min(newSpeed + SC.PerfectBoost, math.max(Config.SprintSpeed, gradeSpeed))
	end
	if q ~= Q.Gassed then
		-- a cut is never worse than plain steering
		newSpeed =
			math.max(newSpeed, math.min(Config.SprintSpeed * SC.ExitFloor, math.max(gradeSpeed, Config.JogSpeed)))
	end
	if sold then
		newSpeed = math.max(newSpeed, Config.SprintSpeed * SC.SoldMinSpeedFraction)
	end
	spend(s, SC.Cost)
	s.vel = dir * newSpeed
	s.lastCutAt = now
	setLine(s, dir, newSpeed)
	s.soldUntil = 0
	s.burstUntil = 0
	s.jabUntil = 0
	s.sideStepUntil = 0
	emit(s, "SnapCut", q, dir, if sold then "Sold" else nil)
	return true, nil
end

local function pressPlant(s: State, lineDir: Vector3, gradeSpeed: number): (boolean, string?)
	local left = cooldownLeft(s, "MomentumCancel")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Cut", 0, "Cooldown", cooldownText("MomentumCancel", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("MomentumCancel", left), left)
	end
	local q: string
	if isGassed(s, MC.Cost) then
		q = Q.Gassed
	elseif gradeSpeed >= Config.JogSpeed then
		q = Q.Clean
	else
		q = Q.Sloppy
	end
	spend(s, MC.Cost)
	setCooldown(s, "MomentumCancel")
	s.burstUntil = 0
	s.jabUntil = 0
	s.sideStepUntil = 0
	s.plantAt = s.now
	s.plantEnd = s.now + MC.PlantTime
	s.plantGassed = q == Q.Gassed
	s.plantDecel = if q == Q.Gassed then MC.BrakeDecel * 0.5 else MC.BrakeDecel
	s.plantResolved = false
	emit(s, "MomentumCancel", q, lineDir, nil)
	return true, nil
end

-- Fake Commit: a jab along the line (sells a cut) or, when slow, a quick side
-- step toward the input. Either opens the "sold" window for a Perfect cut away.
local function pressFakeCommit(s: State, dir: Vector3, lineDir: Vector3, sideStep: boolean): (boolean, string?)
	local left = cooldownLeft(s, "FakeCommit")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Cut", 0, "Cooldown", cooldownText("FakeCommit", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("FakeCommit", left), left)
	end
	local q = if isGassed(s, FC.Cost) then Q.Gassed else Q.Clean
	spend(s, FC.Cost)
	setCooldown(s, "FakeCommit")
	local info: string? = nil
	local busy: number
	if sideStep then
		s.sideStepDir = dir
		s.sideStepSpeed = FC.SideStepSpeed * (if q == Q.Gassed then 0.7 else 1)
		s.sideStepUntil = s.now + FC.SideStepTime
		s.vel = dir * s.sideStepSpeed
		s.soldDir = dir
		busy = FC.SideStepTime
		info = "SideStep"
	else
		s.vel = s.vel * FC.JabSlow
		s.soldDir = lineDir
		s.jabUntil = s.now + FC.JabTime
		busy = FC.JabTime
	end
	s.soldUntil = s.now + busy + FC.SoldWindow
	emit(s, "FakeCommit", q, s.soldDir, info)
	return true, nil
end

-- Judges a directional Cut against the running line: Sold cut, Snap Cut, or
-- Plant when it points backward.
local function cutAgainstLine(
	s: State,
	dir: Vector3,
	angle: number,
	lineDir: Vector3,
	since: number,
	gradeSpeed: number
): (boolean, string?)
	if s.now < s.soldUntil and VecMath.flatAngle(s.soldDir, dir) >= FC.SoldMinAngle then
		return pressSnapCut(s, dir, angle, since, math.max(gradeSpeed, SC.MinSpeed), true)
	end
	if angle <= SC.MaxAngle then
		return pressSnapCut(s, dir, angle, since, gradeSpeed, false)
	end
	if gradeSpeed >= MC.MinSpeed then
		return pressPlant(s, lineDir, gradeSpeed)
	end
	return pressSnapCut(s, dir, angle, since, gradeSpeed, false)
end

local function restartFromPlant(s: State, dir: Vector3): (boolean, string?)
	local q = plantQuality(s)
	local out = Config.SprintSpeed * (MC.RestartRetention :: any)[q]
	s.vel = dir * math.max(out, s.vel:Dot(dir))
	clearPlant(s)
	s.lastCutAt = s.now
	setLine(s, dir, s.vel.Magnitude)
	emit(s, "SnapCut", q, dir, "Restart")
	return true, nil
end

local function doBurst(s: State, dir: Vector3, free: boolean, forcedQuality: string?): (boolean, string?)
	local now = s.now
	local speed = s.vel.Magnitude
	local q: string
	if forcedQuality then
		q = forcedQuality
	elseif isGassed(s, BS.Cost) then
		q = Q.Gassed
	elseif s.lastKeyTech ~= nil and BURST_CHAIN[s.lastKeyTech :: string] and now - s.lastKeyAt <= BS.CutChainWindow then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	local base = math.max(speed, Config.SprintSpeed)
	local bs: number
	if q == Q.Gassed then
		bs = math.min(base * BS.GassedMult, BS.MaxSpeed)
	else
		bs = math.clamp(base * BS.SpeedMult, BS.MinSpeed, BS.MaxSpeed)
	end
	if not free then
		spend(s, BS.Cost)
	end
	setCooldown(s, "BurstStep")
	s.burstDir = dir
	s.burstSpeed = bs
	s.burstUntil = now + BS.Duration
	s.vel = dir * bs
	clearPlant(s)
	s.jabUntil = 0
	s.sideStepUntil = 0
	setLine(s, dir, bs)
	emit(s, "BurstStep", q, dir, if free then "Explosive" else nil)
	return true, nil
end

-- Recovery Chain: Jump / Cut / Burst during the dive recovery.
local function tryPop(s: State, action: Action, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	local now = s.now
	if s.mode == "DiveSlide" and now - s.landedAt < RC.PopFrom then
		if RC.PopFrom - (now - s.landedAt) <= BUFFER then
			return defer(s, action, 0, "Context", "TOO EARLY")
		end
		return refuse(s, "Context", "TOO EARLY")
	end
	local q = if s.mode == "Recover" and now - s.popStart <= RC.PopPerfect then Q.Perfect else Q.Clean
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	local out = math.max(Config.SprintSpeed * (RC.Retention :: any)[q], s.vel.Magnitude)
	setMode(s, "Ground")
	s.recoverUntil = 0
	emit(s, "RecoveryChain", q, d, action)
	if action == "Jump" then
		s.vel = if hasDir then d * out else Vector3.zero
		enterAir(s)
		queueJump(s, Config.JumpVelocity * RC.PopJumpFraction)
	elseif action == "Cut" then
		s.vel = d * out
		s.lastCutAt = now
		setLine(s, d, out)
	elseif action == "Burst" then
		s.vel = d * out
		if cooldownLeft(s, "BurstStep") <= 0 then
			doBurst(s, d, false, nil)
		end
	end
	return true, nil
end

-- One hop per possession: straight up, step frozen.
local function pressHop(s: State): (boolean, string?)
	if s.holdHopped then
		return refuse(s, "Used", "ONE HOP PER POSSESSION")
	end
	if not isGrounded(s) then
		return refuse(s, "Context")
	end
	if s.holdPhase ~= "Pivot" then
		plantPivot(s)
	end
	s.holdHopped = true
	s.vel = Vector3.zero
	enterAir(s)
	queueJump(s, HD.HopVertical)
	s.impulse = true
	return true, nil
end

local function pressJump(s: State, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	if s.holding then
		return pressHop(s)
	end
	if s.mode == "Recover" or s.mode == "DiveSlide" then
		return tryPop(s, "Jump", dir, hasDir, env)
	end
	if isGrounded(s) or s.mode == "Slide" then
		if plantTooEarly(s) then
			return defer(s, "Jump", 0, "Context")
		end
		local fromSlide = s.mode == "Slide"
		local info: string? = nil
		local q = Q.Clean
		if inPlantWindow(s) then
			-- jumping out of a plant keeps the restart speed
			info = "PlantJump"
			q = plantQuality(s)
			if hasDir then
				s.vel = dir * math.max(Config.SprintSpeed * (MC.RestartRetention :: any)[q], s.vel:Dot(dir))
			end
		elseif fromSlide then
			info = "SlideHop"
		end
		local speed = s.vel.Magnitude
		local vy = Config.JumpVelocity + Config.JumpSpeedBonus * math.clamp(speed / Config.SprintSpeed, 0, 1)
		enterAir(s)
		queueJump(s, vy)
		emit(s, "Jump", q, velDirOr(s, facingOr(env)), info)
		return true, nil
	end
	if s.mode == "Air" or s.mode == "Dive" then
		local wall = env.wallNormal
		if wall then
			local n = VecMath.flatUnit(wall)
			if n.Magnitude < 0.5 then
				return refuse(s, "Context")
			end
			if s.rebounds >= WR.MaxPerAir then
				return refuse(s, "Used", "TWO REBOUNDS PER JUMP")
			end
			if env.wallId ~= nil and env.wallId == s.lastWall then
				return refuse(s, "Used", "FIND ANOTHER WALL")
			end
			local v = s.vel
			local into = v:Dot(n)
			local reflected = if into < 0 then VecMath.reflect(v, n) else v
			local q: string
			if isGassed(s, WR.Cost) then
				q = Q.Gassed
			elseif (env.wallDistance or math.huge) <= WR.PerfectDistance then
				q = Q.Perfect
			else
				q = Q.Clean
			end
			local retention = if q == Q.Gassed then WR.Retention * 0.7 else WR.Retention
			local nv = VecMath.clampMagnitude((reflected + n * WR.PushOff) * retention, Config.HardCap)
			spend(s, WR.Cost)
			s.vel = nv
			s.rebounds += 1
			s.lastWall = env.wallId
			s.airRedirectUsed = false
			enterAir(s)
			queueJump(s, WR.Vertical)
			emit(s, "WallRebound", q, velDirOr(s, n), nil)
			return true, nil
		end
		-- jump pressed just before touchdown: jump on landing
		local ttl = env.timeToLand
		if s.mode == "Air" and ttl ~= nil and ttl <= BUFFER then
			return defer(s, "Jump", 0, "Context")
		end
		return refuse(s, "Context")
	end
	return refuse(s, "Context")
end

local function pressAirRedirect(s: State, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	if s.airRedirectUsed then
		return refuse(s, "Used", "ONE PER JUMP")
	end
	if not hasDir then
		return refuse(s, "Context", "STEER TO REDIRECT")
	end
	local speed = s.vel.Magnitude
	if speed >= AR.MinSpeed and VecMath.flatAngle(s.vel / speed, dir) < AR.MinAngle then
		-- already going that way: nothing to redirect, keep it for later
		return refuse(s, "Context", "STEER TO REDIRECT")
	end
	local vy = env.actualVel.Y
	local q: string
	if isGassed(s, AR.Cost) then
		q = Q.Gassed
	elseif math.abs(vy) < AR.ApexWindow then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	local newVel: Vector3
	if speed < AR.MinSpeed then
		newVel = dir * AR.StillSpeed
	else
		local nd = VecMath.rotateToward(s.vel / speed, dir, AR.MaxAngle)
		newVel = nd * (speed * (AR.Retention :: any)[q])
	end
	spend(s, AR.Cost)
	s.airRedirectUsed = true
	s.vel = newVel
	if s.mode == "Dive" then
		s.diveDir = velDirOr(s, s.diveDir)
	end
	if vy < AR.MinVertical then
		queueVertical(s, AR.MinVertical)
	end
	emit(s, "AirRedirect", q, velDirOr(s, dir), nil)
	return true, nil
end

local function pressSlideCut(s: State, dir: Vector3, hasDir: boolean): (boolean, string?)
	if not hasDir then
		return refuse(s, "Context", "HOLD A DIRECTION")
	end
	local t = s.now - s.modeStart
	if t < SLC.MinSlideTime then
		return defer(s, "Cut", 0, "Context")
	end
	local speed = s.vel.Magnitude
	local velDir = velDirOr(s, dir)
	if VecMath.flatAngle(velDir, dir) > SLC.MaxAngle then
		return refuse(s, "Context", "TOO SHARP")
	end
	local q: string
	if isGassed(s, SLC.Cost) then
		q = Q.Gassed
	elseif t >= SLC.PerfectFrom and t <= SLC.PerfectTo then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	spend(s, SLC.Cost)
	local newSpeed = speed * (SLC.Retention :: any)[q]
	s.vel = dir * newSpeed
	setMode(s, "Ground")
	s.lastCutAt = s.now
	setLine(s, dir, newSpeed)
	emit(s, "SlideCut", q, dir, nil)
	return true, nil
end

local function pressCut(s: State, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	if s.holding then
		return refuse(s, "Context")
	end
	local now = s.now
	if s.mode == "Air" or s.mode == "Dive" then
		return pressAirRedirect(s, dir, hasDir, env)
	end
	if s.mode == "Slide" then
		return pressSlideCut(s, dir, hasDir)
	end
	if s.mode == "Recover" or s.mode == "DiveSlide" then
		return tryPop(s, "Cut", dir, hasDir, env)
	end
	if not isGrounded(s) then
		return refuse(s, "Context")
	end

	-- Restart out of a Momentum Cancel plant.
	if s.plantAt > 0 and now - s.plantAt <= MC.WindowClose then
		if plantTooEarly(s) then
			return defer(s, "Cut", 0, "Context")
		end
		if not hasDir then
			return refuse(s, "Context", "HOLD A DIRECTION")
		end
		return restartFromPlant(s, dir)
	end

	-- A look-ahead already pending is this same intent.
	if s.lookAheadUntil > 0 then
		return true, nil
	end

	local lineDir, since, gradeSpeed = runningLine(s, env)
	if not hasDir then
		if gradeSpeed >= MC.MinSpeed then
			return pressPlant(s, lineDir, gradeSpeed)
		end
		return refuse(s, "Speed", "NEED SPEED", MC.MinSpeed)
	end
	local angle = VecMath.flatAngle(lineDir, dir)
	-- A cut out of a Fake Commit's sold window is always allowed.
	if now < s.soldUntil and VecMath.flatAngle(s.soldDir, dir) >= FC.SoldMinAngle then
		return pressSnapCut(s, dir, angle, since, math.max(gradeSpeed, SC.MinSpeed), true)
	end
	if gradeSpeed < SC.MinSpeed then
		return pressFakeCommit(s, dir, lineDir, true)
	end
	if angle < FC.MaxAngle then
		-- Along the line: wait a moment for the steer that makes it a cut.
		s.lookAheadUntil = now + FC.LookAhead
		s.lookLine = lineDir
		s.lookSince = since
		s.lookSpeed = gradeSpeed
		return true, nil
	end
	return cutAgainstLine(s, dir, angle, lineDir, since, gradeSpeed)
end

local function pressBurst(s: State, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	if s.holding then
		return refuse(s, "Context")
	end
	if s.mode == "Recover" or s.mode == "DiveSlide" then
		return tryPop(s, "Burst", dir, hasDir, env)
	end
	if s.mode == "Air" then
		local ttl = env.timeToLand
		if ttl ~= nil and ttl <= BUFFER then
			return defer(s, "Burst", 0, "Context", "LAND FIRST")
		end
		return refuse(s, "Context", "LAND FIRST")
	end
	if not isGrounded(s) and s.mode ~= "Slide" then
		return refuse(s, "Context")
	end
	if plantTooEarly(s) then
		return defer(s, "Burst", 0, "Context")
	end
	local left = cooldownLeft(s, "BurstStep")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Burst", 0, "Cooldown", cooldownText("BurstStep", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("BurstStep", left), left)
	end
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	if s.mode == "Slide" then
		setMode(s, "Ground")
	end
	if inPlantWindow(s) then
		return doBurst(s, d, true, plantQuality(s))
	end
	return doBurst(s, d, false, nil)
end

local function armPrecision(s: State, env: Env): (boolean, string?)
	if s.precisionArmedAt ~= nil then
		return refuse(s, "Used", "LANDING ARMED")
	end
	local ttl = env.timeToLand
	if ttl ~= nil and ttl <= PL.ArmWindow then
		s.precisionArmedAt = s.now
		return true, nil
	end
	if ttl ~= nil and ttl <= PL.ArmWindow + BUFFER then
		return defer(s, "Slide", 0, "Context", "TOO EARLY")
	end
	return refuse(s, "Context", "TOO EARLY")
end

local function pressSlide(s: State, env: Env): (boolean, string?)
	if s.holding then
		return refuse(s, "Context")
	end
	local now = s.now
	if s.mode == "Air" or s.mode == "Dive" then
		return armPrecision(s, env)
	end
	-- Late Precision Landing (pressed just after touchdown).
	if now < s.lateLandingUntil then
		if isGrounded(s) and not s.landedFromDive then
			s.vel = s.landingVel * PL.Retention.Clean
			setMode(s, "Ground")
			s.lateLandingUntil = 0
			emit(s, "PrecisionLanding", Q.Clean, velDirOr(s, FORWARD), "Late")
			feedback(s, "LandingOffset", -(now - s.landedAt), landingText(-(now - s.landedAt)))
			return true, nil
		elseif s.mode == "DiveSlide" and s.landedFromDive then
			s.vel = s.landingVel * RO.Retention.Clean
			s.lateLandingUntil = 0
			enterRecover(s, RO.RecoverTime)
			emit(s, "PrecisionLanding", Q.Clean, velDirOr(s, s.diveDir), "RollOut")
			feedback(s, "LandingOffset", -(now - s.landedAt), landingText(-(now - s.landedAt)))
			return true, nil
		end
	end
	if not isGrounded(s) then
		return refuse(s, "Context")
	end
	local left = cooldownLeft(s, "Slide")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Slide", 0, "Cooldown", cooldownText("Slide", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("Slide", left), left)
	end
	local speed = s.vel.Magnitude
	if speed < SL.MinSpeed then
		return refuse(s, "Speed", "NEED SPEED", SL.MinSpeed)
	end
	local q = if isGassed(s, SL.Cost) then Q.Gassed else Q.Clean
	local newSpeed = speed
	if q ~= Q.Gassed and speed < SL.BoostCeiling then
		newSpeed = math.min(speed + SL.Boost, SL.BoostCeiling)
	end
	spend(s, SL.Cost)
	setCooldown(s, "Slide")
	s.vel = (s.vel / speed) * newSpeed
	cancelTransients(s)
	setMode(s, "Slide")
	emit(s, "Slide", q, s.vel / newSpeed, nil)
	return true, nil
end

local function pressDive(s: State, dir: Vector3, hasDir: boolean, env: Env): (boolean, string?)
	if s.holding then
		return refuse(s, "Context")
	end
	local now = s.now
	if s.mode == "Recover" then
		if s.recoverUntil - now <= BUFFER then
			return defer(s, "Dive", 0, "Context", "GET UP FIRST")
		end
		return refuse(s, "Context", "GET UP FIRST")
	end
	if s.mode == "DiveSlide" then
		return refuse(s, "Context", "GET UP FIRST")
	end
	if s.mode == "Dive" or (s.mode == "Air" and s.airDiveUsed) then
		return refuse(s, "Used", "ONE PER JUMP")
	end
	local groundish = isGrounded(s) or s.mode == "Slide"
	local air = s.mode == "Air"
	if not groundish and not air then
		return refuse(s, "Context")
	end
	local left = cooldownLeft(s, "Dive")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Dive", 0, "Cooldown", cooldownText("Dive", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("Dive", left), left)
	end
	local speed = s.vel.Magnitude
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	local key = s.lastKeyTech
	local chained = key ~= nil and DIVE_CHAIN[key :: string] == true and now - s.lastKeyAt <= DV.ChainWindow
	local q: string
	if isGassed(s, DV.Cost) then
		q = Q.Gassed
	elseif chained then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	spend(s, DV.Cost)
	setCooldown(s, "Dive")
	if groundish then
		local hs: number
		if q == Q.Gassed then
			hs = math.clamp(speed, DV.GassedMin, DV.GassedMax)
		else
			hs = math.clamp(math.max(speed + DV.GroundBonus, DV.GroundMin), DV.GroundMin, DV.GroundMax)
		end
		s.vel = d * hs
		cancelTransients(s)
		setMode(s, "Dive")
		s.airStart = now
		s.groundLostAt = nil
		queueJump(s, DV.GroundVertical)
	else
		local nv = VecMath.clampMagnitude(s.vel + d * DV.AirBoost, math.max(DV.AirMax, speed))
		s.vel = nv
		s.airDiveUsed = true
		setMode(s, "Dive")
		queueVertical(s, math.min(env.actualVel.Y + DV.AirVertical, DV.MaxVertical))
	end
	s.takeoffSpeed = s.vel.Magnitude
	s.diveDir = velDirOr(s, d)
	emit(s, "Dive", q, s.diveDir, if air then "Air" else nil)
	return true, nil
end

-- Quick Swing while holding: the step swings through the front to the given
-- side (-1 screen-left, +1 screen-right, 0 = mirror of the current step).
local function doSwing(s: State, side: number, env: Env): (boolean, string?)
	if not s.holding then
		return refuse(s, "Context")
	end
	if not isGrounded(s) then
		local ttl = env.timeToLand
		if s.mode == "Air" and not s.holdHopped and ttl ~= nil and ttl <= BUFFER then
			return defer(s, "Swing", side, "Context")
		end
		return refuse(s, "Context")
	end
	local left = cooldownLeft(s, "PivotSwing")
	if left > 0 then
		if left <= BUFFER then
			return defer(s, "Swing", side, "Cooldown", cooldownText("PivotSwing", left), left)
		end
		return refuse(s, "Cooldown", cooldownText("PivotSwing", left), left)
	end
	if s.holdPhase ~= "Pivot" then
		plantPivot(s)
	end
	local now = s.now
	local fwd, right = aimBasis(env)
	if side == 0 then
		local lateral = s.step:Dot(right)
		side = if lateral > 0.1 then -1 elseif lateral < -0.1 then 1 else -s.lastSwingSide
	end
	side = if side < 0 then -1 else 1
	local q: string
	if isGassed(s, HD.SwingCost) then
		q = Q.Gassed
	elseif now - s.lastFakeAt <= HD.SwingSoldWindow then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	spend(s, HD.SwingCost)
	setCooldown(s, "PivotSwing")
	local R = HD.StepRadius
	s.swingUntil = now + HD.SwingTime
	s.fakeUntil = -math.huge
	s.lastSwingSide = side
	s.restActive = true
	s.restX = side * HD.SwingLateral * R
	s.restY = HD.SwingForward * R
	local held = VecMath.flat(s.lastMove)
	s.restInputMag = math.min(held.Magnitude, 1)
	s.restInputDir = VecMath.flatUnit(held)
	local dir = VecMath.flatUnit(right * s.restX + fwd * s.restY)
	emit(s, "PivotSwing", q, dir, if q == Q.Perfect then "Sold" else nil)
	return true, nil
end

local function runAction(s: State, action: string, input: Input, env: Env, side: number): (boolean, string?)
	if action == "Swing" then
		return doSwing(s, side, env)
	end
	local wishMag = input.move.Magnitude
	local hasDir = wishMag > 0.2
	local dir = if hasDir then VecMath.flatUnit(input.move) else Vector3.zero
	if action == "Jump" then
		return pressJump(s, dir, hasDir, env)
	elseif action == "Cut" then
		return pressCut(s, dir, hasDir, env)
	elseif action == "Burst" then
		return pressBurst(s, dir, hasDir, env)
	elseif action == "Slide" then
		return pressSlide(s, env)
	elseif action == "Dive" then
		return pressDive(s, dir, hasDir, env)
	end
	return false, "Context"
end

local function dispatch(s: State, action: string, input: Input, env: Env, side: number): (boolean, string?)
	if s.frozen or s.mode == "Frozen" then
		return false, "Context"
	end
	if s.marking and not s.holding then
		if action == "Slide" then
			-- C toggles the mark stance; the driver handles it.
			return false, "Context"
		end
		if action == "Cut" or action == "Dive" or action == "Burst" then
			local ok, reason = runAction(s, action, input, env, side)
			if ok then
				s.marking = false
			end
			return ok, reason
		end
	end
	return runAction(s, action, input, env, side)
end

-- Retries the buffered press; keeps it while it is still worth waiting for.
local function retryBuffer(s: State, input: Input, env: Env)
	local b = s.buffer
	if b == nil then
		return
	end
	s.buffer = nil
	s.retrying = true
	s.retryDeferred = false
	s.retryReason = nil
	s.retryText = nil
	s.retryValue = nil
	local ok = dispatch(s, b.action, input, env, b.side)
	s.retrying = false
	if ok or not s.retryDeferred then
		return -- fired, or a final refusal (which queued its own feedback)
	end
	if s.now < b.expires then
		s.buffer = b
	elseif s.retryText then
		feedback(s, s.retryReason or "Context", s.retryValue, s.retryText)
	end
end

-- Resolves a pending Cut look-ahead: a steer away from the line inside it
-- makes the press a Snap Cut (or a Plant if backward); otherwise a Fake Commit.
local function resolveLookAhead(s: State, input: Input)
	if s.lookAheadUntil <= 0 then
		return
	end
	if s.holding or s.frozen or not isGrounded(s) then
		s.lookAheadUntil = 0
		return
	end
	local m = input.move
	local hasDir = m.Magnitude > 0.2
	if hasDir then
		local dir = VecMath.flatUnit(m)
		local angle = VecMath.flatAngle(s.lookLine, dir)
		if angle >= FC.MaxAngle then
			s.lookAheadUntil = 0
			cutAgainstLine(s, dir, angle, s.lookLine, s.lookSince, s.lookSpeed)
			return
		end
	end
	if s.now >= s.lookAheadUntil then
		s.lookAheadUntil = 0
		local dir = if hasDir then VecMath.flatUnit(m) else s.lookLine
		pressFakeCommit(s, dir, s.lookLine, false)
	end
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

-- Presses a movement action. Returns true when it fired or was buffered
-- (and will fire within InputBuffer if it becomes valid), else false + reason.
function MovementSim.press(s: State, action: Action, input: Input, env: Env): (boolean, string?)
	if s.frozen or s.mode == "Frozen" then
		return false, "Context"
	end
	local b = s.buffer
	if b and b.action == action then
		return true, nil
	end
	s.buffer = nil
	return dispatch(s, action, input, env, 0)
end

-- Quick Swing while holding. side: -1 screen-left, +1 screen-right,
-- 0 = mirror of the current step (gamepad). Same contract as press().
function MovementSim.swing(s: State, side: number, env: Env): (boolean, string?)
	if s.frozen or s.mode == "Frozen" then
		return false, "Context"
	end
	local b = s.buffer
	if b and b.action == "Swing" then
		return true, nil
	end
	s.buffer = nil
	return dispatch(s, "Swing", NO_INPUT, env, side)
end

-- The fake's lunge while holding: the free foot reaches 0.6R further toward
-- `side` (-1/+1, clamped to R) for FakeStepOut, then springs back. side 0 = no
-- lunge. Always starts the window in which a swing counts as Sold.
function MovementSim.fakeStep(s: State, side: number)
	if not s.holding then
		return
	end
	s.lastFakeAt = s.now
	if side ~= 0 and s.holdPhase == "Pivot" and isGrounded(s) then
		s.fakeSide = if side < 0 then -1 else 1
		s.fakeUntil = s.now + HD.FakeStepOut
	end
end

-- Mark shuffle overlay (ignored while holding).
function MovementSim.setMarking(s: State, on: boolean)
	s.marking = on and not s.holding
end

function MovementSim.isMarking(s: State): boolean
	return s.marking
end

-- Called by the catch controller when the player reaches while airborne.
function MovementSim.noteAerialReach(s: State, dir: Vector3): boolean
	if (s.mode == "Air" or s.mode == "Dive") and not s.aerialReachUsed then
		s.aerialReachUsed = true
		emit(s, "AerialReach", Q.Clean, VecMath.flatUnit(dir), nil)
		return true
	end
	return false
end

function MovementSim.setFrozen(s: State, frozen: boolean)
	s.frozen = frozen
	if frozen then
		s.vel = Vector3.zero
		cancelTransients(s)
		s.buffer = nil
		setMode(s, "Frozen")
	elseif s.mode == "Frozen" then
		setMode(s, "Ground")
	end
end

-- Starts (or ends) a possession. Starting begins the slow-down (or waits for
-- the landing when caught in the air); calling it again while already holding
-- changes nothing, so a predicted catch confirmed by the server is seamless.
function MovementSim.setHolding(s: State, holding: boolean, grounded: boolean)
	if holding then
		if s.holding then
			return
		end
		s.holding = true
		s.holdHopped = false
		s.holdStart = s.now
		s.holdPhase = if grounded and s.mode ~= "Air" and s.mode ~= "Dive" then "Decel" else "Air"
		s.pivot = nil
		s.pivotAdopted = false
		s.stalePivot = nil
		s.step = Vector3.zero
		s.stepLenVel = 0
		s.swingUntil = 0
		s.fakeUntil = -math.huge
		s.lastFakeAt = -math.huge
		s.restActive = false
		s.marking = false
		s.buffer = nil
		s.soldUntil = 0
		cancelTransients(s)
	else
		if not s.holding then
			return
		end
		s.holding = false
		s.holdPhase = "None"
		s.holdHopped = false
		s.pivot = nil
		s.pivotAdopted = false
		s.stalePivot = nil
		s.step = Vector3.zero
		s.stepLenVel = 0
		s.swingUntil = 0
		s.fakeUntil = -math.huge
		s.restActive = false
		s.buffer = nil
	end
end

-- Adopts the authoritative pivot foot (UBPivot). nil clears a previously
-- adopted pivot (the sim then plants its own where it stands); it never clears
-- the sim's own plant, so passing the attribute every frame is harmless.
function MovementSim.setPivot(s: State, p: Vector3?)
	if p == nil then
		if s.pivotAdopted then
			s.pivot = nil
			s.pivotAdopted = false
		end
		return
	end
	if s.stalePivot ~= nil and p == s.stalePivot then
		return -- the same far-away pivot we already abandoned
	end
	s.stalePivot = nil
	s.pivot = p
	s.pivotAdopted = true
	if s.holding and s.holdPhase ~= "Pivot" then
		s.holdPhase = "Pivot"
		s.step = Vector3.zero
		s.stepLenVel = 0
	end
end

-- The planted pivot foot P (nil before it is planted / when not holding).
function MovementSim.getPivot(s: State): Vector3?
	if s.holding then
		return s.pivot
	end
	return nil
end

-- Where the root is being driven while pivoting: P + BodyShare * step.
function MovementSim.rootTarget(s: State): Vector3?
	local p = s.pivot
	if s.holding and s.holdPhase == "Pivot" and p ~= nil then
		return p + s.step * HD.BodyShare
	end
	return nil
end

-- The mode to replicate for poses (character attribute MS): the sim mode, or
-- "Pivot" while the holder pivots on the ground, "Mark" while mark-shuffling.
function MovementSim.poseMode(s: State): string
	if s.mode == "Ground" or s.mode == "Landing" then
		if s.holding and s.holdPhase == "Pivot" then
			return "Pivot"
		end
		if s.marking then
			return "Mark"
		end
	end
	return s.mode
end

function MovementSim.isAirborne(s: State): boolean
	return s.mode == "Air" or s.mode == "Dive"
end

-- 0 = just used, 1 = ready.
function MovementSim.readiness(s: State, tech: string): number
	local cd = (Config.TechCooldowns :: any)[tech] or 0
	if cd <= 0 then
		return 1
	end
	local readyAt = s.ready[tech] or -math.huge
	return math.clamp(1 - (readyAt - s.now) / cd, 0, 1)
end

local function cutHint(s: State, input: Input, env: Env): string?
	local m = input.move
	local hasDir = m.Magnitude > 0.2
	local dir = if hasDir then VecMath.flatUnit(m) else Vector3.zero
	if s.plantAt > 0 and s.now - s.plantAt <= MC.WindowClose then
		return if hasDir then "RESTART" else nil
	end
	local lineDir, _, gradeSpeed = runningLine(s, env)
	if not hasDir then
		return if gradeSpeed >= MC.MinSpeed then "PLANT" else nil
	end
	if s.now < s.soldUntil and VecMath.flatAngle(s.soldDir, dir) >= FC.SoldMinAngle then
		return "SOLD CUT"
	end
	if gradeSpeed < SC.MinSpeed then
		return "SIDE STEP"
	end
	local angle = VecMath.flatAngle(lineDir, dir)
	if angle < FC.MaxAngle then
		return "FAKE COMMIT"
	end
	if angle > SC.MaxAngle and gradeSpeed >= MC.MinSpeed then
		return "PLANT"
	end
	return "SNAP CUT"
end

-- What each action would do right now, for the HUD context line, e.g.
-- { Cut = "SNAP CUT", Jump = "POP UP", Slide = "PRECISION LANDING" }.
-- Actions that would do nothing are left out. Pure: changes no state.
function MovementSim.contextHint(s: State, input: Input, env: Env): { [string]: string }
	local hint: { [string]: string } = {}
	if s.frozen or s.mode == "Frozen" then
		return hint
	end
	local mode = s.mode
	local ttl = env.timeToLand
	if s.holding then
		if isGrounded(s) then
			hint.Cut = "SWING LEFT"
			hint.Dive = "SWING RIGHT"
			if not s.holdHopped then
				hint.Jump = "HOP"
			end
		end
		return hint
	end
	if mode == "Air" or mode == "Dive" then
		if not s.airRedirectUsed then
			hint.Cut = "AIR REDIRECT"
		end
		if env.wallNormal and s.rebounds < WR.MaxPerAir and (env.wallId == nil or env.wallId ~= s.lastWall) then
			hint.Jump = "WALL REBOUND"
		end
		if ttl ~= nil and ttl <= PL.ArmWindow and s.precisionArmedAt == nil then
			hint.Slide = if mode == "Dive" then "ROLL OUT" else "PRECISION LANDING"
		end
		if mode == "Air" and not s.airDiveUsed then
			hint.Dive = "AIR LAYOUT"
		end
		return hint
	end
	if mode == "Slide" then
		hint.Cut = "SLIDE CUT"
		hint.Jump = "SLIDE HOP"
		hint.Dive = "LAYOUT"
		if cooldownLeft(s, "BurstStep") <= 0 then
			hint.Burst = "BURST"
		end
		return hint
	end
	if mode == "DiveSlide" or mode == "Recover" then
		hint.Jump = "POP UP"
		hint.Cut = "POP UP"
		hint.Burst = "POP UP"
		if mode == "DiveSlide" and s.now < s.lateLandingUntil then
			hint.Slide = "ROLL OUT"
		end
		return hint
	end
	-- Ground / Landing
	local plantWindow = s.plantAt > 0 and s.now - s.plantAt <= MC.WindowClose
	local cut = cutHint(s, input, env)
	if cut then
		hint.Cut = cut
	end
	hint.Jump = if plantWindow then "PLANT JUMP" else "JUMP"
	if plantWindow then
		hint.Burst = "EXPLOSIVE RESTART"
	elseif cooldownLeft(s, "BurstStep") <= 0 then
		hint.Burst = "BURST"
	end
	if cooldownLeft(s, "Dive") <= 0 then
		hint.Dive = "LAYOUT"
	end
	if s.marking then
		hint.Slide = "STANCE"
	elseif s.now < s.lateLandingUntil and not s.landedFromDive then
		hint.Slide = "PRECISION LANDING"
	elseif s.vel.Magnitude >= SL.MinSpeed then
		hint.Slide = "SLIDE"
	end
	return hint
end

function MovementSim.step(s: State, input: Input, env: Env, dt: number): Output
	s.now += dt
	local now = s.now
	local landed, tookOff = false, false
	-- body position: the real root when the driver gives it, else our estimate
	if env.pos then
		s.pos = env.pos
	else
		s.pos += s.lastOutVel * dt
	end
	s.lastMove = input.move

	-- 1. ground / air transitions -------------------------------------------
	if s.mode == "Air" or s.mode == "Dive" then
		if env.grounded and now - s.airStart > 0.08 then
			land(s)
			landed = true
		end
	elseif s.mode ~= "Frozen" then
		if not env.grounded then
			if s.groundLostAt == nil then
				s.groundLostAt = now
			end
			if now - (s.groundLostAt :: number) > Config.CoyoteTime then
				enterAir(s)
				tookOff = true
			end
		else
			s.groundLostAt = nil
		end
	end

	-- 2. collision reconciliation: only when something solid really holds us
	-- back (the driver's ray says blocked) for a moment, stop accumulating
	-- phantom speed against it. Otherwise the sim is trusted.
	local simSpeed = s.vel.Magnitude
	local pivoting = s.holding and s.holdPhase == "Pivot"
	if simSpeed > 6 and s.mode ~= "Frozen" and env.blocked == true and not pivoting then
		local along = VecMath.flat(env.actualVel):Dot(s.vel / simSpeed)
		if along < simSpeed * Config.ReconcileFraction then
			if s.blockedSince == nil then
				s.blockedSince = now
			elseif now - (s.blockedSince :: number) > Config.ReconcileTime then
				s.vel = VecMath.flat(env.actualVel)
				s.blockedSince = nil
				s.burstUntil = 0
				s.sideStepUntil = 0
			end
		else
			s.blockedSince = nil
		end
	else
		s.blockedSince = nil
	end

	-- 3. buffered press and Cut look-ahead ----------------------------------
	retryBuffer(s, input, env)
	resolveLookAhead(s, input)

	-- 4. per-mode velocity ------------------------------------------------------
	local wish = VecMath.flat(input.move)
	local wishMag = math.min(wish.Magnitude, 1)
	local top = topSpeed(s, input.sprint)
	local mode = s.mode

	if s.frozen or mode == "Frozen" then
		s.vel = Vector3.zero
	elseif s.holding and (mode == "Ground" or mode == "Landing") then
		updateHolding(s, input, env, dt)
		if mode == "Landing" and now >= s.landingUntil then
			setMode(s, "Ground")
		end
	elseif mode == "Ground" or mode == "Landing" then
		if s.marking then
			s.vel = steerShuffle(s.vel, wish, dt)
		elseif now < s.burstUntil then
			s.vel = s.burstDir * s.burstSpeed
		elseif now < s.sideStepUntil then
			s.vel = s.sideStepDir * s.sideStepSpeed
		elseif now < s.plantEnd then
			s.vel = VecMath.moveToward(s.vel, Vector3.zero, s.plantDecel * dt)
		elseif s.plantAt > 0 and not s.plantResolved then
			-- the plant ends: holding a direction restarts automatically
			s.plantResolved = true
			if wishMag > 0.2 then
				local d = VecMath.flatUnit(wish)
				local out = Config.SprintSpeed * MC.AutoRestart
				s.vel = d * math.max(out, s.vel:Dot(d))
				setLine(s, d, s.vel.Magnitude)
				s.impulse = true
			else
				s.vel = MovementSim.steerGround(s.vel, wish, top, dt, 1)
			end
		else
			local lat = if mode == "Landing" then Config.LandingSteer else 1
			if now < s.jabUntil then
				lat = math.min(lat, FC.JabSteer)
			end
			s.vel = MovementSim.steerGround(s.vel, wish, top, dt, lat)
		end
		if mode == "Landing" and now >= s.landingUntil then
			setMode(s, "Ground")
		end
		if s.plantAt > 0 and now - s.plantAt > MC.WindowClose then
			clearPlant(s)
		end
	elseif mode == "Air" then
		if not s.holding then
			s.vel = steerAir(s, wish, dt)
		end
	-- (Dive: a commitment, no steering; Air Redirect is the only adjustment)
	elseif mode == "Slide" then
		local speed = s.vel.Magnitude
		local friction = if s.holding then math.max(SL.Friction, HD.DecelRate) else SL.Friction
		local newSpeed = math.max(0, speed - friction * dt)
		local d = velDirOr(s, s.diveDir)
		if not s.holding and wishMag > 0.05 then
			d = VecMath.rotateToward(d, VecMath.flatUnit(wish), SL.SteerRate * dt)
		end
		s.vel = d * newSpeed
		if newSpeed < SL.ExitSpeed or now - s.modeStart > SL.MaxTime then
			setMode(s, "Ground")
		end
	elseif mode == "DiveSlide" then
		local speed = s.vel.Magnitude
		local friction = if s.holding then math.max(DS.Friction, HD.DecelRate) else DS.Friction
		local newSpeed = math.max(0, speed - friction * dt)
		s.vel = velDirOr(s, s.diveDir) * newSpeed
		if newSpeed < DS.StopSpeed or now - s.modeStart > DS.MaxTime then
			enterRecover(s, RC.Time)
		end
	elseif mode == "Recover" then
		if s.holding then
			s.vel = VecMath.moveToward(s.vel, Vector3.zero, HD.DecelRate * dt)
		else
			s.vel = MovementSim.steerGround(s.vel, wish, top, dt, RC.Steer)
		end
		if now >= s.recoverUntil then
			setMode(s, "Ground")
		end
	end

	-- 5. exertion ---------------------------------------------------------------
	local speedNow = s.vel.Magnitude
	local sprinting = input.sprint
		and wishMag > 0.05
		and speedNow > Config.JogSpeed + 0.5
		and isGrounded(s)
		and not s.marking
		and not s.holding
	local regenOk = now >= s.regenAt
	if sprinting then
		s.exertion -= Config.SprintDrain * dt
		if regenOk then
			s.exertion += Config.SprintRegen * dt
		end
	elseif regenOk then
		s.exertion += Config.ExertionRegen * dt
	end
	s.exertion = math.clamp(s.exertion, 0, Config.ExertionMax)

	-- 6. running line (grades Snap Cuts and Plants) ---------------------------
	if isGrounded(s) and not s.holding then
		trackLine(s, dt)
	end

	-- 7. hard safety cap ----------------------------------------------------------
	s.vel = VecMath.clampMagnitude(VecMath.flat(s.vel), Config.HardCap)

	local impulse = s.impulse or s.pendingJump or (s.vel - s.lastOutVel).Magnitude > Config.ImpulseThreshold
	local out: Output = {
		vel = s.vel,
		setVertical = s.pendingVertical,
		jump = s.pendingJump,
		events = s.pendingEvents,
		feedback = s.pendingFeedback,
		pivotEstablished = s.pendingPivot,
		landed = landed,
		tookOff = tookOff,
		impulse = impulse,
		step = if s.holding then s.step else Vector3.zero,
		pivotPos = s.pendingPivotPos,
	}
	s.lastOutVel = s.vel
	s.impulse = false
	s.pendingVertical = nil
	s.pendingJump = false
	s.pendingEvents = {}
	s.pendingFeedback = {}
	s.pendingPivot = false
	s.pendingPivotPos = nil
	return out
end

return MovementSim
