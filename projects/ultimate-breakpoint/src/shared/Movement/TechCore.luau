--!strict
--[[
	TechCore — the momentum controller and every movement tech built on it
	(docs/tech-spec.md: "Core physics model", ground tech 1-8, air tech 9-16,
	layout 18, tech roll 19, sky 20).

	Pure: no Instances. The client (MovementController) and the bots
	(BotService) give it the stick, the held buttons, presses and a small
	environment snapshot, and write the velocity it returns to the body. It
	runs offline under Lune (tests/tech_spec).

	CORE
	  * Velocity is kept, not set. The stick accelerates you toward its
	    direction; speed only drops from friction, turning or overspeed decay.
	  * Turning is instant below TURN_FREE_SPEED. Faster, the heading turns at
	    most TURN_RATE(speed) °/s; while the stick asks for more you drift: no
	    acceleration, and every 90° turned costs TURN_DRIFT_LOSS of your speed.
	  * Above run speed, speed decays toward it (fast on the ground, slowly in
	    the air). Neither the flat speed nor the fall speed passes
	    HARD_SPEED_CAP.
	  * Gravity is the player's own (PLAYER_GRAVITY, x FALL_GRAVITY_MULT while
	    moving down, x FAST_FALL_MULT while Slide is held in the air).
	  * Fixed timestep: advance() runs step() at PHYSICS_RATE with an
	    accumulator. All timing windows are measured in sim time (s.now), so
	    nothing depends on the frame rate.
	  * Input buffer: press() stores a press for INPUT_BUFFER ms; every step
	    tries the buffered presses again, so a press slightly before its
	    window opens still fires when it does.

	TECH (each fires an event in s.events; Perfect ones refund Burst)
	  Burst (hold Burst)   top speed 30, accel 90, drains the meter
	  Burst Kick (tap)     +6 studs/s now, 15 meter, 0.5 s cooldown
	  Cut (Cut + new dir)  0.12 s plant, keeps 70 % (Perfect: 100 % + 3) when
	                       pressed within 80 ms of the stick crossing 45°;
	                       85 % cap within 0.6 s of the last cut
	  Juke                 Cut, then the stick back to your line before the
	                       plant ends: you keep your line at 90 %
	  Plant Stop (Cut, no stick)  stop in 0.15 s, then 2x accel for 0.3 s
	                       (2.5x and Perfect if you go within 100 ms)
	  Slide (hold Slide, 18+)  friction 15, turn 60°/s, 1.2 s max
	  Landing Slide        a slide within 100 ms of landing (40 ms Perfect;
	                       holding Slide through the landing counts Perfect)
	  Slide Carve          Burst held in a slide: turn 220°/s, friction 40
	  Slide Hop            Jump 0.15-0.30 s into a slide: +6, +4, +2, 0
	  Jump                 tap 34 up, hold 0.2 s for 46; keeps flat speed
	  Air Steer            20 studs/s², 90°/s, never above takeoff speed
	  Air Dodge (Jump in the air)  +12 the held way with a 0.18 s hang, or
	                       +20 up with no direction; one per airtime, within
	                       1.25 s of leaving the ground
	  Fast Fall            hold Slide in the air
	  Wavedash             a directional dodge 0-80 ms before landing becomes
	                       +10 along the ground (+14 Perfect, 0-40 ms)
	  Reverse Snap         backward dodge, then Cut 60-140 ms into it: face
	                       the dodge and keep 90 % (Perfect 80-110 ms: 100 %)
	  Burst Dive           jump from a standstill, forward-diagonal dodge
	                       within 80 ms, Cut 50-120 ms in: run at 28 (32)
	  Disc Reset           discContact() in the air gives the dodge back
	  Layout (Dive, 15+)   speed + 8 toward the aim, 10 up; Downed 0.9 s
	  Tech Roll            Jump within 100 ms of the layout landing: up in
	                       0.25 s keeping 50 % (Perfect 40 ms: 75 %)
	  Sky                  standing or jogging, crouch (hold Slide) 0.2 s+ and
	                       press Jump: a charged leap up to 1.6x (1.7x Perfect
	                       at 0.35-0.40 s). Jump itself always fires at once.

	WORLD-CLASS TECH (not in the spec; the gap between good and great)
	  Flip Reset           your FEET touch a disc in flight (footContact()):
	                       a stored dodge with no time limit, kept until you
	                       land; spending it is a ResetFlip
	  Stall                Dive within 30 ms of an air dodge cancels it into
	                       a 0.25 s hang and gives the dodge back (once per
	                       airtime)
	  Zap Dash             Cut within 60 ms of a wavedash landing: a second
	                       burst with no plant (Perfect within 25 ms)
	  Wall Kick            Jump within 80 ms of touching a wall in the air:
	                       kick off it with your dodge back (Perfect 30 ms)
	  Pinch                a throw released within 40 ms of your feet
	                       touching down (pinch(), ThrowController)
]]

local Config = require(script.Parent.Parent.Config.Tech)
local VecMath = require(script.Parent.Parent.Util.VecMath)

local TechCore = {}

export type StateName =
	"Grounded"
	| "Sliding"
	| "Airborne"
	| "AirDodging"
	| "Diving"
	| "Downed"
	| "Recovering"
	| "HoldingDisc"
	| "Marking"

export type Input = {
	move: Vector3, -- flat world direction, magnitude 0..1
	held: { [string]: boolean }?, -- Burst / Slide / Jump / Cut held right now
	aim: Vector3?, -- flat camera forward (layouts aim with it)
}

export type Env = {
	grounded: boolean,
	wallNormal: Vector3?, -- flat normal of a wall right in front of the body
	timeToLand: number?, -- s until the feet touch down (airborne only)
}

export type Timing = {
	name: string,
	offsetMs: number, -- < 0 early, > 0 late, 0 dead on
	windowMs: number, -- half width of the success window
	perfectMs: number?, -- half width of the Perfect part (around 0)
	quality: string, -- "Perfect" | "Clean" | "Miss"
	t: number,
}

export type TechEvent = {
	tech: string,
	quality: string, -- "Perfect" | "Clean" | "Miss"
	t: number,
	dir: Vector3,
	info: string?,
}

export type FrameReport = {
	steps: number,
	landed: boolean,
	leftGround: boolean,
	landingSpeed: number, -- downward speed at touchdown
}

export type State = {
	state: StateName,
	stateSince: number,
	now: number, -- sim time (s), advanced by each fixed step
	acc: number, -- accumulator
	vel: Vector3,
	heading: Vector3, -- flat travel direction (kept while stopped)
	holding: boolean,
	marking: boolean,
	frozen: boolean,
	grounded: boolean,
	drifting: boolean, -- the last step's turn was limited
	topSpeed: number, -- current run top speed (Burst raises it)
	accel: number,
	buffer: { [string]: number }, -- action -> sim time of the press
	held: { [string]: boolean }, -- last step's held buttons (edges)
	lastTiming: Timing?,
	events: { TechEvent },
	frame: FrameReport,

	-- burst
	burst: number, -- the meter, 0..100
	burstLocked: boolean,
	burstHeldAt: number?, -- when the current hold started
	burstDrained: number, -- meter spent by the current hold (refunded on a tap)
	kickReadyAt: number,

	-- cuts (from the stick: let go to plant, then snap a new direction)
	release: { at: number, speed: number, dir: Vector3 }?, -- the stick let go at speed (a plant)
	lastCut: { at: number, origDir: Vector3, speed: number }?, -- the last cut (a juke can undo it)
	skid: boolean, -- the current slide is a skid from a hard turn with no plant
	cutReport: { quality: string, gapMs: number, angle: number, kept: number }?, -- the last cut (debug HUD)
	crossAt: number?, -- when the stick last crossed CUT_ANGLE from your line
	lastCutAt: number,
	cutReadyAt: number,

	-- slides and hops
	slideSince: number,
	landedAt: number, -- when the feet last touched down
	hopCount: number, -- slide hops in the current chain
	groundedPlainSince: number?, -- grounded and not sliding, since
	slidePrimed: boolean, -- Slide was held through the landing (Fast Fall into a slide)

	-- air
	airborneSince: number,
	jumpAt: number, -- takeoff time of the last jump
	jumpBoostUntil: number, -- the hold window of the last jump
	takeoffSpeed: number,
	dodgeAvailable: boolean,
	discResetUsed: boolean,
	dodge: {
		startAt: number,
		dir: Vector3,
		backward: boolean,
		burstDive: boolean,
		speed: number,
		resolved: boolean,
		preVel: Vector3, -- velocity before the dodge (a Stall restores it)
	}?,
	wavedash: { dir: Vector3, perfect: boolean }?,
	stumbleOnLand: boolean,

	-- layout / recovery / sky
	diveAt: number,
	downedUntil: number,
	recoverUntil: number,
	skyChargeAt: number?,
	skyPerfectUntil: number, -- hands-up reach bonus lasts while this is ahead

	-- abilities (Config/Abilities)
	windowScale: number, -- Perfect windows x this (The Zone)
	zoneUntil: number,
	extraDodges: number, -- Sky Walk: extra dodges per airtime
	extraDodgesLeft: number,
	skyWalkUntil: number,
	overdriveUntil: number,
	overdriveTop: number, -- extra top speed during Overdrive
	skyWalkGravity: number, -- gravity x this during Sky Walk

	-- defense
	mirrorArmed: boolean, -- the next cut mirrors your matchup's (Mirror Step)

	-- world-class tech
	storedFlips: number, -- Flip Reset dodges in store (kept until landing)
	flipResetsAir: number, -- Flip Resets this airtime
	stallUsed: boolean,
	stallUntil: number,
	wavedashAt: number, -- landing time of the last wavedash (Zap Dash window)
	wallTouchAt: number?, -- first contact with the current wall (airborne)
	wallNormal: Vector3?,
	wallLostAt: number,
	wallKickUsed: boolean,
}

local STEP = 1 / Config.PHYSICS_RATE
TechCore.STEP = STEP

-- Which states each state may move into by a tech. The environment (leaving
-- or touching the ground) and the holding / marking flags can always move
-- between Grounded, Airborne, HoldingDisc and Marking.
TechCore.Transitions = {
	Grounded = { Sliding = true, Airborne = true, Diving = true, HoldingDisc = true, Marking = true },
	Sliding = { Grounded = true, Airborne = true, Diving = true, HoldingDisc = true },
	Airborne = {
		AirDodging = true,
		Diving = true,
		Grounded = true,
		Sliding = true,
		HoldingDisc = true,
		Recovering = true,
	},
	AirDodging = { Airborne = true, Grounded = true, Sliding = true, Diving = true, Recovering = true },
	Diving = { Downed = true, Recovering = true, Grounded = true, HoldingDisc = true },
	Downed = { Recovering = true },
	Recovering = { Grounded = true, Marking = true, HoldingDisc = true },
	HoldingDisc = { Grounded = true },
	Marking = { Grounded = true, Airborne = true, Sliding = true, Diving = true },
} :: { [StateName]: { [StateName]: boolean } }

-- States the environment and flags pick on their own.
local BASE: { [StateName]: boolean } = { Grounded = true, Airborne = true, HoldingDisc = true, Marking = true }
-- States that steer and accelerate with the stick on the ground.
local RUNNING: { [StateName]: boolean } = { Grounded = true, Marking = true }
-- States in the air.
local AIR: { [StateName]: boolean } = { Airborne = true, AirDodging = true, Diving = true }

local NO_HELD: { [string]: boolean } = {}

local function newFrame(): FrameReport
	return { steps = 0, landed = false, leftGround = false, landingSpeed = 0 }
end

function TechCore.new(now: number?): State
	local t = now or 0
	return {
		state = "Grounded",
		stateSince = t,
		now = t,
		acc = 0,
		vel = Vector3.zero,
		heading = Vector3.new(0, 0, -1),
		holding = false,
		marking = false,
		frozen = false,
		grounded = true,
		drifting = false,
		topSpeed = Config.RUN_TOP_SPEED,
		accel = Config.RUN_ACCEL,
		buffer = {},
		held = {},
		lastTiming = nil,
		events = {},
		frame = newFrame(),

		burst = 100,
		burstLocked = false,
		burstHeldAt = nil,
		burstDrained = 0,
		kickReadyAt = -math.huge,

		release = nil,
		lastCut = nil,
		skid = false,
		cutReport = nil,
		crossAt = nil,
		lastCutAt = -math.huge,
		cutReadyAt = -math.huge,

		slideSince = -math.huge,
		landedAt = -math.huge,
		hopCount = 0,
		groundedPlainSince = t,
		slidePrimed = false,

		airborneSince = -math.huge,
		jumpAt = -math.huge,
		jumpBoostUntil = -math.huge,
		takeoffSpeed = 0,
		dodgeAvailable = true,
		discResetUsed = false,
		dodge = nil,
		wavedash = nil,
		stumbleOnLand = false,

		diveAt = -math.huge,
		downedUntil = -math.huge,
		recoverUntil = -math.huge,
		skyChargeAt = nil,
		skyPerfectUntil = -math.huge,

		windowScale = 1,
		zoneUntil = -math.huge,
		extraDodges = 0,
		extraDodgesLeft = 0,
		skyWalkUntil = -math.huge,
		overdriveUntil = -math.huge,
		overdriveTop = 0,
		skyWalkGravity = 1,

		mirrorArmed = false,

		storedFlips = 0,
		flipResetsAir = 0,
		stallUsed = false,
		stallUntil = -math.huge,
		wavedashAt = -math.huge,
		wallTouchAt = nil,
		wallNormal = nil,
		wallLostAt = -math.huge,
		wallKickUsed = false,
	}
end

---------------------------------------------------------------------------
-- tuning curves
---------------------------------------------------------------------------

-- Max turn rate (°/s) at a flat speed; math.huge below TURN_FREE_SPEED.
function TechCore.turnRate(speed: number): number
	if speed < Config.TURN_FREE_SPEED then
		return math.huge
	end
	local pts = Config.TURN_RATE
	if speed <= pts[1].speed then
		return pts[1].rate
	end
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		if speed <= b.speed then
			local k = (speed - a.speed) / (b.speed - a.speed)
			return a.rate + (b.rate - a.rate) * k
		end
	end
	return pts[#pts].rate
end

---------------------------------------------------------------------------
-- state machine
---------------------------------------------------------------------------

function TechCore.canEnter(s: State, to: StateName): boolean
	if s.state == to then
		return true
	end
	local allowed = TechCore.Transitions[s.state]
	return allowed ~= nil and allowed[to] == true
end

-- Moves to `to` if the transition table allows it (or `force`). Returns
-- whether the state is now `to`.
function TechCore.enter(s: State, to: StateName, force: boolean?): boolean
	if s.state == to then
		return true
	end
	if not force and not TechCore.canEnter(s, to) then
		return false
	end
	s.state = to
	s.stateSince = s.now
	return true
end

function TechCore.timeInState(s: State): number
	return s.now - s.stateSince
end

function TechCore.isAirborne(s: State): boolean
	return not s.grounded
end

-- The state the environment and flags pick when no tech holds one.
local function baseState(s: State): StateName
	if not s.grounded then
		return "Airborne"
	elseif s.holding then
		return "HoldingDisc"
	elseif s.marking then
		return "Marking"
	end
	return "Grounded"
end

local function settleBase(s: State)
	if BASE[s.state] then
		local want: StateName = baseState(s)
		if want ~= s.state then
			s.state = want
			s.stateSince = s.now
		end
	end
end

function TechCore.setHolding(s: State, on: boolean)
	s.holding = on
	if on then
		s.skyChargeAt = nil
		if s.state == "Sliding" or s.state == "Recovering" then
			s.state = baseState(s)
			s.stateSince = s.now
		end
	end
	settleBase(s)
end

function TechCore.setMarking(s: State, on: boolean)
	s.marking = on
	settleBase(s)
end

function TechCore.setFrozen(s: State, on: boolean)
	s.frozen = on
	if on then
		s.vel = Vector3.new(0, s.vel.Y, 0)
	end
end

-- After a teleport: no momentum, nothing buffered or in progress; flags kept.
function TechCore.reset(s: State)
	s.vel = Vector3.zero
	s.acc = 0
	s.drifting = false
	table.clear(s.buffer)
	s.dodge = nil
	s.wavedash = nil
	s.skyChargeAt = nil
	s.stumbleOnLand = false
	s.dodgeAvailable = true
	s.state = baseState(s)
	s.stateSince = s.now
end

---------------------------------------------------------------------------
-- input buffer and timing
---------------------------------------------------------------------------

-- The sim time "right now", between steps (presses are stamped with it).
function TechCore.clock(s: State): number
	return s.now + s.acc
end

function TechCore.press(s: State, action: string, t: number?)
	s.buffer[action] = t or TechCore.clock(s)
end

-- The buffered press of `action` if it is still fresh at `t`.
function TechCore.buffered(s: State, action: string, t: number): number?
	local at = s.buffer[action]
	if at and t - at <= Config.INPUT_BUFFER / 1000 + 1e-9 and t >= at - 1e-9 then
		return at
	end
	return nil
end

-- Takes the buffered press (so it fires once). Returns its time, or nil.
function TechCore.consume(s: State, action: string, t: number): number?
	local at = TechCore.buffered(s, action, t)
	s.buffer[action] = nil
	return at
end

-- Records how a timed press went: offset from the ideal moment and the
-- window it was judged against. Perfect within perfectMs, Clean within
-- windowMs, otherwise Miss.
function TechCore.noteTiming(
	s: State,
	name: string,
	offsetMs: number,
	windowMs: number,
	perfectMs: number?,
	t: number?
): Timing
	local a = math.abs(offsetMs)
	local scale = if s.now < s.zoneUntil then s.windowScale else 1
	local pw = if perfectMs then perfectMs * scale else nil
	local ww = math.max(windowMs, pw or 0)
	local quality = if pw and a <= pw then "Perfect" elseif a <= ww then "Clean" else "Miss"
	local timing: Timing = {
		name = name,
		offsetMs = offsetMs,
		windowMs = ww,
		perfectMs = pw,
		quality = quality,
		t = t or s.now,
	}
	s.lastTiming = timing
	return timing
end

-- Records a press judged against a window [lo, hi] ms after an event (and an
-- optional Perfect sub-window). The readout's offset is from the nearest
-- edge of the Perfect window (or the window), so "12 ms late" means 12 ms
-- past the Perfect part.
local function noteRange(s: State, name: string, ms: number, lo: number, hi: number, plo: number?, phi: number?): string
	-- The Zone widens the Perfect part around its middle (inside the window)
	if plo and phi and s.now < s.zoneUntil and s.windowScale ~= 1 then
		local mid, half = (plo + phi) / 2, (phi - plo) / 2 * s.windowScale
		plo, phi = math.max(lo, mid - half), math.min(hi, mid + half)
	end
	local quality = "Miss"
	if ms >= lo and ms <= hi then
		quality = if plo and phi and ms >= plo and ms <= phi then "Perfect" else "Clean"
	end
	local a, b = plo or lo, phi or hi
	local offset = if ms < a then ms - a elseif ms > b then ms - b else 0
	s.lastTiming = {
		name = name,
		offsetMs = offset,
		windowMs = (hi - lo) / 2,
		perfectMs = if plo and phi then 0 else nil,
		quality = quality,
		t = s.now,
	}
	return quality
end

-- "Cut: 34 ms early" / "Cut: 12 ms late" / "Cut: on time"
function TechCore.describeTiming(timing: Timing): string
	local ms = math.floor(math.abs(timing.offsetMs) + 0.5)
	if ms == 0 then
		return timing.name .. ": on time"
	end
	return string.format("%s: %d ms %s", timing.name, ms, if timing.offsetMs < 0 then "early" else "late")
end

---------------------------------------------------------------------------
-- meter and events
---------------------------------------------------------------------------

local function refund(s: State, amount: number)
	s.burst = math.min(100, s.burst + amount)
	if s.burstLocked and s.burst >= Config.BURST_LOCK_UNTIL then
		s.burstLocked = false
	end
end

-- Adds Burst meter (abilities, blocks). Clamped to 0..100.
function TechCore.addBurst(s: State, amount: number)
	refund(s, amount)
end

local function emit(s: State, tech: string, quality: string, dir: Vector3?, info: string?)
	table.insert(s.events, { tech = tech, quality = quality, t = s.now, dir = dir or s.heading, info = info })
	if quality == "Perfect" then
		refund(s, Config.PERFECT_BURST_REFUND)
	end
end

-- Takes this frame's tech events (the caller sends them on).
function TechCore.drainEvents(s: State): { TechEvent }
	local out = s.events
	s.events = {}
	return out
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function flatOf(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	local f = flatOf(v)
	local m = f.Magnitude
	if m > 1e-4 then
		return f / m
	end
	return fallback
end

local function setFlat(s: State, flat: Vector3)
	s.vel = Vector3.new(flat.X, s.vel.Y, flat.Z)
	local m = flat.Magnitude
	if m > 1e-4 then
		s.heading = flat / m
	end
end

local function moveToward(x: number, target: number, rate: number): number
	if x < target then
		return math.min(target, x + rate)
	end
	return math.max(target, x - rate)
end

local function stickDir(input: Input): Vector3?
	local mv = flatOf(input.move)
	if mv.Magnitude < 0.05 then
		return nil
	end
	return mv.Unit
end

local function isHeld(input: Input, action: string): boolean
	local h = input.held or NO_HELD
	return h[action] == true
end

---------------------------------------------------------------------------
-- tech (presses)
---------------------------------------------------------------------------

local function jumpOff(s: State, vy: number, boost: boolean)
	s.vel = Vector3.new(s.vel.X, vy, s.vel.Z)
	s.grounded = false
	s.jumpAt = s.now
	s.jumpBoostUntil = if boost then s.now + Config.JUMP_HOLD else -math.huge
	s.airborneSince = s.now
	s.takeoffSpeed = flatOf(s.vel).Magnitude
	s.frame.leftGround = true
	s.dodgeAvailable = true
	s.discResetUsed = false
	s.dodge = nil
	s.wavedash = nil
	s.release = nil
	s.stumbleOnLand = false
	TechCore.enter(s, "Airborne", true)
end

local function slideAllowed(s: State, speed: number, landing: boolean): boolean
	if not RUNNING[s.state] or s.holding then
		return false
	end
	return speed >= (if landing then Config.LANDING_SLIDE_MIN_SPEED else Config.SLIDE_MIN_SPEED)
end

local function startSlide(s: State, quality: string?, info: string?)
	s.skid = false
	s.slideSince = s.now
	s.groundedPlainSince = nil
	TechCore.enter(s, "Sliding", true)
	if quality then
		emit(s, "LandingSlide", quality, s.heading, info)
	end
end

-- Jump from a slide: the Slide Hop.
local function slideHop(s: State)
	local into = s.now - s.slideSince
	local lo, hi = Config.SLIDE_HOP_WINDOW[1], Config.SLIDE_HOP_WINDOW[2]
	local quality = noteRange(s, "Slide Hop", into * 1000, lo * 1000, hi * 1000)
	s.hopCount += 1
	local idx = math.min(s.hopCount, #Config.SLIDE_HOP_BONUS)
	local bonus = if quality == "Clean"
		then Config.SLIDE_HOP_BONUS[idx]
		else math.min(Config.SLIDE_HOP_OFF_WINDOW, Config.SLIDE_HOP_BONUS[idx])
	local flat = flatOf(s.vel)
	setFlat(s, s.heading * (flat.Magnitude + bonus))
	jumpOff(s, Config.JUMP_TAP * math.sqrt(Config.SLIDE_HOP_HEIGHT), false)
	-- a hop in the window is the "Perfect" hop of the spec
	emit(s, "SlideHop", if quality == "Clean" then "Perfect" else "Clean", s.heading, tostring(s.hopCount))
end

-- The directional / neutral Air Dodge, or a Wavedash when the ground is
-- 0-80 ms away. Returns whether the press was used.
local function tryAirDodge(s: State, input: Input, env: Env): boolean
	if not AIR[s.state] or s.state == "Diving" then
		return false
	end
	local skyWalk = s.now < s.skyWalkUntil and s.extraDodgesLeft > 0
	if not s.dodgeAvailable or s.now - s.airborneSince > Config.AIR_DODGE_WINDOW then
		if s.storedFlips > 0 then
			-- a Flip Reset: the stored dodge has no time limit
			s.storedFlips -= 1
			s.dodgeAvailable = true
			emit(s, "ResetFlip", "Perfect", stickDir(input) or Vector3.yAxis, tostring(s.flipResetsAir))
		elseif skyWalk then
			-- Sky Walk: an extra dodge
			s.extraDodgesLeft -= 1
			s.dodgeAvailable = true
		else
			return false
		end
	end
	local dir = stickDir(input)
	local ttl = env.timeToLand
	if dir and ttl and ttl * 1000 <= Config.WAVEDASH_WINDOW and s.vel.Y <= 0 then
		local timing = TechCore.noteTiming(s, "Wavedash", -ttl * 1000, Config.WAVEDASH_WINDOW, Config.WAVEDASH_PERFECT)
		s.wavedash = { dir = dir, perfect = timing.quality == "Perfect" }
		s.dodgeAvailable = false
		return true
	end
	s.dodgeAvailable = false
	if dir == nil then
		s.vel = Vector3.new(s.vel.X, math.max(s.vel.Y, 0) + Config.AIR_DODGE_NEUTRAL, s.vel.Z)
		emit(s, "AirDodge", "Clean", Vector3.yAxis, "Up")
		return true
	end
	local flat = flatOf(s.vel)
	local backward = flat.Magnitude > 2 and VecMath.flatAngle(s.heading, dir) >= Config.REVERSE_SNAP_ANGLE
	local fwdAngle = VecMath.flatAngle(input.aim or s.heading, dir)
	local burstDive = s.takeoffSpeed <= Config.BURST_DIVE_START_SPEED
		and (s.now - s.jumpAt) * 1000 <= Config.BURST_DIVE_DODGE_WINDOW
		and fwdAngle >= Config.BURST_DIVE_ANGLE[1]
		and fwdAngle <= Config.BURST_DIVE_ANGLE[2]
	local preVel = s.vel
	local nv = flat + dir * Config.AIR_DODGE_BURST
	s.vel = Vector3.new(nv.X, 0, nv.Z)
	s.dodge = {
		startAt = s.now,
		dir = dir,
		backward = backward,
		burstDive = burstDive,
		speed = nv.Magnitude,
		resolved = false,
		preVel = preVel,
	}
	TechCore.enter(s, "AirDodging", true)
	emit(s, "AirDodge", "Clean", dir)
	return true
end

-- Cut during a dodge: Reverse Snap (backward dodge) or Burst Dive (from a
-- standstill). Returns whether the press was used.
local function tryDodgeCancel(s: State): boolean
	local d = s.dodge
	if not d or d.resolved or not AIR[s.state] then
		return false
	end
	local ms = (s.now - d.startAt) * 1000
	if d.burstDive then
		d.resolved = true
		local w, p = Config.BURST_DIVE_CUT, Config.BURST_DIVE_CUT_PERFECT
		local quality = noteRange(s, "Burst Dive", ms, w[1], w[2], p[1], p[2])
		if quality == "Miss" then
			return true
		end
		local speed = if quality == "Perfect" then Config.BURST_DIVE_SPEED_PERFECT else Config.BURST_DIVE_SPEED
		setFlat(s, d.dir * speed)
		s.takeoffSpeed = math.max(s.takeoffSpeed, speed)
		emit(s, "BurstDive", quality, d.dir)
		return true
	end
	if d.backward then
		d.resolved = true
		local w, p = Config.REVERSE_SNAP_WINDOW, Config.REVERSE_SNAP_PERFECT
		local quality = noteRange(s, "Reverse Snap", ms, w[1], w[2], p[1], p[2])
		if quality == "Miss" then
			s.stumbleOnLand = true
			return true
		end
		local keep = if quality == "Perfect" then 1 else Config.REVERSE_SNAP_KEEP
		local speed = flatOf(s.vel).Magnitude * keep
		setFlat(s, d.dir * speed)
		s.takeoffSpeed = math.max(s.takeoffSpeed, speed)
		emit(s, "ReverseSnap", quality, d.dir)
		return true
	end
	return false
end

-- Dive: a ground layout at speed, or an air layout that spends the dodge.
local function tryLayout(s: State, input: Input): boolean
	if s.holding then
		return false
	end
	local flat = flatOf(s.vel)
	local speed = flat.Magnitude
	local inAir = AIR[s.state] == true
	if inAir then
		if s.state == "Diving" or not s.dodgeAvailable then
			return false
		end
	elseif not (RUNNING[s.state] or s.state == "Sliding") or speed < Config.LAYOUT_MIN_SPEED then
		return false
	end
	local line = unitOr(flat, s.heading)
	local aim = unitOr(input.aim or line, line)
	local dir = VecMath.rotateToward(line, aim, Config.LAYOUT_CONE)
	local nv = dir * (speed + Config.LAYOUT_BOOST)
	local vy = if inAir then math.max(s.vel.Y, 0) + Config.LAYOUT_UP * 0.5 else Config.LAYOUT_UP
	if inAir then
		s.dodgeAvailable = false
	end
	s.vel = Vector3.new(nv.X, vy, nv.Z)
	s.heading = dir
	s.grounded = false
	s.diveAt = s.now
	if not inAir then
		s.airborneSince = s.now
		s.takeoffSpeed = nv.Magnitude
	end
	s.dodge = nil
	TechCore.enter(s, "Diving", true)
	emit(s, "Layout", "Clean", dir, if inAir then "Air" else nil)
	return true
end

-- Jump right as a layout lands: the Tech Roll.
local function tryTechRoll(s: State, at: number): boolean
	if s.state ~= "Downed" then
		return false
	end
	local ms = (at - s.landedAt) * 1000
	if ms < -Config.TECH_ROLL_WINDOW or ms > Config.TECH_ROLL_WINDOW then
		return false
	end
	local quality =
		noteRange(s, "Tech Roll", ms, -Config.TECH_ROLL_WINDOW, Config.TECH_ROLL_WINDOW, 0, Config.TECH_ROLL_PERFECT)
	if quality == "Miss" then
		return false
	end
	local keep = if quality == "Perfect" then Config.TECH_ROLL_KEEP_PERFECT else Config.TECH_ROLL_KEEP
	local flat = flatOf(s.vel)
	s.vel = Vector3.new(0, s.vel.Y, 0)
	setFlat(s, unitOr(flat, s.heading) * (s.takeoffSpeed * keep))
	s.recoverUntil = s.now + Config.TECH_ROLL_RECOVER
	s.downedUntil = -math.huge
	TechCore.enter(s, "Recovering", true)
	emit(s, "TechRoll", quality, s.heading)
	return true
end

-- Jump in the air right after touching a wall: the Wall Kick.
local function tryWallKick(s: State): boolean
	local at, n = s.wallTouchAt, s.wallNormal
	if at == nil or n == nil or s.wallKickUsed or s.state == "Diving" then
		return false
	end
	local ms = (s.now - at) * 1000
	if ms > Config.WALL_KICK_WINDOW then
		return false
	end
	local quality = noteRange(s, "Wall Kick", ms, 0, Config.WALL_KICK_WINDOW, 0, Config.WALL_KICK_PERFECT)
	local flat = flatOf(s.vel)
	local into = flat:Dot(n)
	local reflected = flat - n * (2 * math.min(into, 0))
	local push = Config.WALL_KICK_PUSH + (if quality == "Perfect" then Config.WALL_KICK_PERFECT_BONUS else 0)
	local nv = reflected * Config.WALL_KICK_KEEP + n * push
	s.vel = Vector3.new(nv.X, Config.WALL_KICK_UP, nv.Z)
	s.heading = unitOr(nv, s.heading)
	s.takeoffSpeed = math.max(s.takeoffSpeed, nv.Magnitude)
	s.wallKickUsed = true
	s.dodgeAvailable = true
	s.airborneSince = s.now
	s.dodge = nil
	TechCore.enter(s, "Airborne", true)
	emit(s, "WallKick", quality, n)
	return true
end

-- Dive right after an air dodge: the Stall cancels the dodge into a hang and
-- gives it back. Returns whether the press was used.
local function tryStall(s: State): boolean
	local d = s.dodge
	if s.state ~= "AirDodging" or not d or s.stallUsed then
		return false
	end
	local ms = (s.now - d.startAt) * 1000
	if ms > Config.STALL_WINDOW then
		return false
	end
	local quality = noteRange(s, "Stall", ms, 0, Config.STALL_WINDOW, 0, Config.STALL_PERFECT)
	local pre = flatOf(d.preVel)
	s.vel = Vector3.new(pre.X, 0, pre.Z)
	s.stallUsed = true
	s.stallUntil = s.now + Config.STALL_HANG
	s.dodgeAvailable = true
	s.airborneSince = s.now
	s.dodge = nil
	TechCore.enter(s, "Airborne", true)
	emit(s, "Stall", quality, Vector3.yAxis)
	return true
end

local skyJump: (State, number) -> ()

-- A Jump press on the ground: a Slide Hop from a slide, a Sky out of a
-- crouch, or a jump (always at once).
local function tryJump(s: State, input: Input, env: Env, at: number): boolean
	if s.state == "Downed" then
		return tryTechRoll(s, at)
	end
	if AIR[s.state] then
		return tryWallKick(s) or tryAirDodge(s, input, env)
	end
	if s.state == "Recovering" then
		return false
	end
	if s.state == "Sliding" then
		slideHop(s)
		return true
	end
	if not (RUNNING[s.state] or s.state == "HoldingDisc") then
		return false
	end
	if s.holding then
		return false -- the pivot hop belongs to the throwing step
	end
	-- a crouch (Slide held while slow) charges a Sky; otherwise jump at once
	local crouch = s.skyChargeAt
	if crouch and s.now - crouch >= Config.SKY_MIN_HOLD then
		skyJump(s, s.now - crouch)
		return true
	end
	jumpOff(s, Config.JUMP_TAP, true)
	emit(s, "Jump", "Clean", s.heading)
	return true
end

-- The Sky: a jump out of a crouch held `held` seconds.
skyJump = function(s: State, held: number)
	s.skyChargeAt = nil
	local c = math.clamp(held / Config.SKY_CHARGE, 0, 1)
	local quality = noteRange(
		s,
		"Sky",
		held * 1000,
		Config.SKY_MIN_HOLD * 1000,
		math.huge,
		Config.SKY_PERFECT[1] * 1000,
		Config.SKY_PERFECT[2] * 1000
	)
	local mult = if quality == "Perfect" then Config.SKY_HEIGHT_PERFECT else 1 + (Config.SKY_HEIGHT - 1) * c
	jumpOff(s, Config.JUMP_FULL * math.sqrt(mult), false)
	if quality == "Perfect" then
		s.skyPerfectUntil = s.now + 1.5
	end
	emit(s, "Sky", quality, Vector3.yAxis)
end

-- Burst released: a tap (under BURST_KICK_TAP) is a Burst Kick.
local function releaseBurst(s: State, input: Input)
	local at = s.burstHeldAt
	s.burstHeldAt = nil
	if at == nil then
		return
	end
	if (s.now - at) * 1000 > Config.BURST_KICK_TAP then
		return
	end
	refund(s, s.burstDrained)
	s.burstDrained = 0
	if not RUNNING[s.state] or s.now < s.kickReadyAt or s.burstLocked or s.burst < Config.BURST_KICK_COST then
		return
	end
	local dir = stickDir(input) or s.heading
	local flat = flatOf(s.vel)
	setFlat(s, flat + dir * Config.BURST_KICK)
	s.burst -= Config.BURST_KICK_COST
	s.kickReadyAt = s.now + Config.BURST_KICK_COOLDOWN
	emit(s, "BurstKick", "Clean", dir)
end

-- Mirror Step (defense): the caller saw the player you guard plant a cut
-- within MIRROR_WINDOW; your next cut counts as Perfect with +2.
function TechCore.armMirror(s: State)
	s.mirrorArmed = true
end

-- Contact rule: you ran through another player (ultimate is non-contact).
function TechCore.contact(s: State)
	setFlat(s, flatOf(s.vel) * (1 - Config.CONTACT_LOSS))
end

-- The cut you mirrored was a Juke: you bit on the fake.
function TechCore.juked(s: State)
	local flat = flatOf(s.vel)
	setFlat(s, flat * (1 - Config.JUKED_LOSS))
	emit(s, "Juked", "Miss", s.heading)
end

-- Something touched the disc while you were in the air (tip, block, bobble,
-- catch): the Disc Reset gives the Air Dodge back, once per airtime.
function TechCore.discContact(s: State): boolean
	if s.grounded or s.discResetUsed then
		return false
	end
	s.discResetUsed = true
	s.dodgeAvailable = true
	s.airborneSince = s.now
	emit(s, "DiscReset", "Clean", Vector3.yAxis)
	return true
end

-- Your FEET touched a disc in flight while airborne: the Flip Reset. Stores
-- a dodge with no time limit (one in store at a time; kept until landing).
function TechCore.footContact(s: State): boolean
	if s.grounded or s.storedFlips > 0 or s.state == "Diving" then
		return false
	end
	s.storedFlips = 1
	s.flipResetsAir += 1
	emit(s, "FlipReset", "Perfect", Vector3.yAxis, tostring(s.flipResetsAir))
	return true
end

-- A throw at this moment: is it a Pinch (released within PINCH_WINDOW ms of
-- the feet touching down)? `ttl` is the time to land when airborne. Returns
-- the quality ("Perfect" / "Clean") or nil, and records the timing.
function TechCore.pinch(s: State, ttl: number?): string?
	local ms: number
	if s.grounded then
		ms = (s.now - s.landedAt) * 1000
	elseif ttl then
		ms = -ttl * 1000
	else
		return nil
	end
	if math.abs(ms) > Config.PINCH_WINDOW then
		return nil
	end
	local timing = TechCore.noteTiming(s, "Pinch", ms, Config.PINCH_WINDOW, Config.PINCH_PERFECT)
	emit(s, "Pinch", timing.quality, s.heading)
	return timing.quality
end

-- How much extra catch reach the body has right now (Perfect Sky hands up).
function TechCore.reachBonus(s: State): number
	if not s.grounded and s.now < s.skyPerfectUntil then
		return Config.SKY_REACH
	end
	return 0
end

local function tryPresses(s: State, input: Input, env: Env)
	local t = s.now
	for action, at in s.buffer do
		if t - at > Config.INPUT_BUFFER / 1000 + 1e-9 then
			s.buffer[action] = nil
		end
	end
	local function attempt(action: string, fn: (number) -> boolean)
		local at = s.buffer[action]
		if at and at <= t + 1e-9 and fn(at) then
			s.buffer[action] = nil
		end
	end
	-- on the ground cuts come from the stick (gestureCut); a Cut press is
	-- only read in the air (stage 2 replaces it)
	attempt("Cut", function()
		return AIR[s.state] == true and tryDodgeCancel(s)
	end)
	attempt("Jump", function(at)
		return tryJump(s, input, env, at)
	end)
	attempt("Dive", function()
		return tryStall(s) or tryLayout(s, input)
	end)
end

---------------------------------------------------------------------------
-- landing and leaving the ground
---------------------------------------------------------------------------

local function onLand(s: State, input: Input)
	s.landedAt = s.now
	s.frame.landed = true
	s.frame.landingSpeed = math.max(s.frame.landingSpeed, -s.vel.Y)
	s.vel = Vector3.new(s.vel.X, 0, s.vel.Z)
	s.dodgeAvailable = true
	s.discResetUsed = false
	s.extraDodgesLeft = s.extraDodges
	s.skyPerfectUntil = -math.huge
	s.dodge = nil
	s.storedFlips = 0
	s.flipResetsAir = 0
	s.stallUsed = false
	s.stallUntil = -math.huge
	s.wallKickUsed = false
	s.wallTouchAt = nil

	if s.state == "Diving" then
		s.downedUntil = s.now + Config.LAYOUT_DOWN_TIME
		TechCore.enter(s, "Downed", true)
		return
	end
	local wd = s.wavedash
	s.wavedash = nil
	if wd then
		local flat = flatOf(s.vel)
		local boost = if wd.perfect then Config.WAVEDASH_BURST_PERFECT else Config.WAVEDASH_BURST
		s.state = baseState(s)
		s.stateSince = s.now
		setFlat(s, flat + wd.dir * boost)
		s.wavedashAt = s.now
		emit(s, "Wavedash", if wd.perfect then "Perfect" else "Clean", wd.dir)
		return
	end
	if s.stumbleOnLand then
		s.stumbleOnLand = false
		s.recoverUntil = s.now + Config.STUMBLE_TIME
		TechCore.enter(s, "Recovering", true)
		emit(s, "Stumble", "Miss", s.heading)
		return
	end
	s.state = baseState(s)
	s.stateSince = s.now
	-- Slide held through the touchdown (Fast Fall): a Perfect Landing Slide
	if s.slidePrimed and isHeld(input, "Slide") then
		local speed = flatOf(s.vel).Magnitude
		if slideAllowed(s, speed, true) then
			TechCore.noteTiming(s, "Landing Slide", 0, Config.LANDING_SLIDE_WINDOW, Config.LANDING_SLIDE_PERFECT)
			startSlide(s, "Perfect", "Held")
		end
	end
end

---------------------------------------------------------------------------
-- motion
---------------------------------------------------------------------------

-- Steers `flat` toward `want` at most `rate` °/s.
local function steer(s: State, flat: Vector3, want: Vector3, rate: number, dt: number): Vector3
	local speed = flat.Magnitude
	if speed < 1e-4 then
		return flat
	end
	local dir = VecMath.rotateToward(flat / speed, want, rate * dt)
	s.heading = dir
	return dir * speed
end

-- FEEL: the cut. The stick was let go at speed (s.release) and now points
-- `want`. Within CUT_RELEASE_MAX and at least CUT_ANGLE off your old line it
-- is a cut: a release of CUT_RELEASE_PERFECT is Perfect (keeps PERFECT_KEEP
-- + PERFECT_CUT_BONUS), anything else in the window is Clean (CUT_KEEP).
-- Past CUT_SHARP_FROM degrees the keep fades to CUT_REVERSE_KEEP at a full
-- reversal, and cuts within CUT_REPEAT_TIME of the last are capped at
-- CUT_REPEAT_CAP (no free zigzags). Returns the new flat velocity, or nil.
local function gestureCut(s: State, want: Vector3): Vector3?
	local r = s.release
	if r == nil then
		return nil
	end
	s.release = nil
	local gap = s.now - r.at
	if gap > Config.CUT_RELEASE_MAX + 1e-9 then
		return nil
	end
	local angle = VecMath.flatAngle(r.dir, want)
	if angle < Config.CUT_ANGLE then
		return nil -- a stutter step: you just run on
	end
	local quality = noteRange(
		s,
		"Cut",
		gap * 1000,
		0,
		Config.CUT_RELEASE_MAX * 1000,
		Config.CUT_RELEASE_PERFECT[1] * 1000,
		Config.CUT_RELEASE_PERFECT[2] * 1000
	)
	local mirror = s.mirrorArmed
	s.mirrorArmed = false
	local perfect = quality == "Perfect" or mirror
	local keep = if perfect then Config.PERFECT_KEEP else Config.CUT_KEEP
	local bonus = (if perfect then Config.PERFECT_CUT_BONUS else 0) + (if mirror then Config.MIRROR_BONUS else 0)
	if angle > Config.CUT_SHARP_FROM then
		local k = math.clamp((angle - Config.CUT_SHARP_FROM) / (180 - Config.CUT_SHARP_FROM), 0, 1)
		keep *= 1 + (Config.CUT_REVERSE_KEEP - 1) * k
	end
	if s.now - s.lastCutAt < Config.CUT_REPEAT_TIME then
		if keep > Config.CUT_REPEAT_CAP then
			bonus = 0
		end
		keep = math.min(keep, Config.CUT_REPEAT_CAP)
	end
	s.cutReadyAt = s.now + Config.CUT_COOLDOWN
	s.lastCutAt = s.now
	s.lastCut = { at = s.now, origDir = r.dir, speed = r.speed }
	s.heading = want
	local out = r.speed * keep + bonus
	s.cutReport = {
		quality = if perfect then "Perfect" else "Clean",
		gapMs = gap * 1000,
		angle = angle,
		kept = if r.speed > 1e-3 then out / r.speed else 1,
	}
	emit(s, "Cut", if perfect then "Perfect" else "Clean", want, if mirror then "Mirror" else nil)
	return want * out
end

local function runFlat(s: State, input: Input, dt: number): Vector3
	local flat = flatOf(s.vel)
	local speed = flat.Magnitude
	if speed > 1e-4 then
		s.heading = flat / speed
	end
	local want = stickDir(input)
	local mag = math.min(flatOf(input.move).Magnitude, 1)
	local top = s.topSpeed
	if s.skyChargeAt then
		top *= Config.SKY_SLOW
	end
	if want == nil then
		-- FEEL: letting go of the stick at speed plants the feet. For up to
		-- CUT_RELEASE_MAX you only lose PLANT_HOLD_FRICTION, so the next
		-- direction can be a cut that keeps your speed; let go longer and
		-- you simply stop (GROUND_FRICTION).
		if s.release == nil and s.state ~= "Marking" and speed >= Config.CUT_MIN_SPEED and s.now >= s.cutReadyAt then
			s.release = { at = s.now, speed = speed, dir = s.heading }
			emit(s, "Plant", "Clean", s.heading)
		end
		local r = s.release
		local planted = r ~= nil and s.now - r.at <= Config.CUT_RELEASE_MAX
		local friction = if planted then Config.PLANT_HOLD_FRICTION else Config.GROUND_FRICTION
		return s.heading * math.max(0, speed - friction * dt)
	end
	if s.state == "Marking" then
		s.release = nil
		-- the mark shuffle: quick, instant turns, capped at MARK_SPEED
		top = math.min(top, Config.MARK_SPEED)
		s.heading = want
		s.crossAt = nil
		local target = top * mag
		speed = moveToward(math.min(speed, top), target, Config.MARK_ACCEL * dt)
		return want * speed
	end

	-- the stick came back after a plant: a cut (or nothing, if it points
	-- along the old line again)
	local cut = gestureCut(s, want)
	if cut then
		return cut
	end
	-- Juke: within JUKE_WINDOW of a cut, the stick back to the old line puts
	-- you back on it at JUKE_KEEP of the speed (the defender bit on the cut)
	local lc = s.lastCut
	if lc then
		if s.now - lc.at > Config.JUKE_WINDOW / 1000 then
			s.lastCut = nil
		elseif VecMath.flatAngle(lc.origDir, want) <= Config.JUKE_RETURN_ANGLE then
			s.lastCut = nil
			s.heading = lc.origDir
			emit(s, "Juke", "Clean", lc.origDir)
			return lc.origDir * (lc.speed * Config.JUKE_KEEP)
		end
	end
	-- Skid: yanking the stick hard round at speed with no plant throws you
	-- into a skid that eats your speed (the sloppy version of a cut)
	if speed >= Config.SKID_MIN_SPEED and not s.holding and VecMath.flatAngle(s.heading, want) >= Config.SKID_ANGLE then
		startSlide(s, nil)
		s.skid = true
		s.cutReport = { quality = "Skid", gapMs = 0, angle = VecMath.flatAngle(s.heading, want), kept = 0 }
		emit(s, "Skid", "Miss", s.heading)
		return flat
	end

	-- the stick crossing 45° from the line (the Perfect Cut reference)
	if speed >= Config.CUT_MIN_SPEED then
		local angle = VecMath.flatAngle(s.heading, want)
		if angle >= Config.CUT_ANGLE then
			if s.crossAt == nil then
				s.crossAt = s.now
			end
		elseif angle < Config.CUT_RESET_ANGLE then
			s.crossAt = nil
		end
	else
		s.crossAt = nil
	end

	-- steer
	if speed < Config.TURN_FREE_SPEED then
		s.heading = want
	else
		local angle = VecMath.flatAngle(s.heading, want)
		local maxTurn = TechCore.turnRate(speed) * dt
		if angle <= maxTurn then
			s.heading = want
		else
			s.heading = VecMath.rotateToward(s.heading, want, maxTurn)
			s.drifting = true
			speed *= (1 - Config.TURN_DRIFT_LOSS) ^ (maxTurn / 90)
		end
	end

	-- accelerate / decay
	local accel = s.accel
	local target = top * mag
	if speed > top then
		speed = math.max(top, speed - Config.OVERSPEED_DECAY_GROUND * dt)
	elseif speed < target then
		-- drifting still accelerates, just slower
		local share = if s.drifting then Config.DRIFT_ACCEL_SHARE else 1
		speed = moveToward(speed, target, accel * share * dt)
	elseif speed > target then
		-- a part-pushed stick (or a Sky charge) slows you like friction
		speed = math.max(target, speed - Config.GROUND_FRICTION * dt)
	end
	return s.heading * speed
end

local function slideFlat(s: State, input: Input, dt: number): Vector3
	local flat = flatOf(s.vel)
	local carving = isHeld(input, "Burst") and not s.burstLocked and s.burst > 0
	local friction = if s.skid
		then Config.SKID_FRICTION
		elseif carving then Config.CARVE_FRICTION
		else Config.SLIDE_FRICTION
	local rate = if s.skid then Config.SKID_TURN elseif carving then Config.CARVE_TURN else Config.SLIDE_TURN
	local want = stickDir(input)
	if want then
		flat = steer(s, flat, want, rate, dt)
	end
	local speed = flat.Magnitude
	speed = math.max(0, speed - friction * dt)
	return unitOr(flat, s.heading) * speed
end

local function airFlat(s: State, input: Input, dt: number): Vector3
	local flat = flatOf(s.vel)
	local speed = flat.Magnitude
	if s.state ~= "Diving" and s.state ~= "AirDodging" then
		local want = stickDir(input)
		if want then
			-- push along the stick, turning at most AIR_TURN °/s and never
			-- past the takeoff speed
			local cap = math.max(s.takeoffSpeed, speed)
			local pushed = flat + want * (Config.AIR_ACCEL * dt)
			local m = math.min(pushed.Magnitude, cap)
			if speed > 1 and pushed.Magnitude > 1e-4 then
				local dir = VecMath.rotateToward(flat / speed, pushed.Unit, Config.AIR_TURN * dt)
				flat = dir * m
			elseif pushed.Magnitude > 1e-4 then
				flat = pushed.Unit * m
			end
		end
	end
	speed = flat.Magnitude
	if speed > s.topSpeed then
		speed = math.max(s.topSpeed, speed - Config.OVERSPEED_DECAY_AIR * dt)
	end
	return unitOr(flat, s.heading) * speed
end

local function brakeFlat(s: State, friction: number, dt: number): Vector3
	local flat = flatOf(s.vel)
	return unitOr(flat, s.heading) * math.max(0, flat.Magnitude - friction * dt)
end

local function updateBurst(s: State, input: Input, dt: number)
	local held = isHeld(input, "Burst")
	local was = s.held.Burst == true
	if held and not was then
		s.burstHeldAt = s.now
		s.burstDrained = 0
	elseif was and not held then
		releaseBurst(s, input)
	end
	local active = held
		and not s.burstLocked
		and s.burst > 0
		and (RUNNING[s.state] or s.state == "Sliding")
		and stickDir(input) ~= nil
	if s.now < s.overdriveUntil then
		s.burst = 100
		s.burstLocked = false
		active = held and (RUNNING[s.state] or s.state == "Sliding") and stickDir(input) ~= nil
	elseif active then
		local d = math.min(s.burst, Config.BURST_DRAIN * dt)
		s.burst -= d
		s.burstDrained += d
		if s.burst <= 0 then
			s.burst = 0
			s.burstLocked = true
		end
	elseif not held then
		refund(s, Config.BURST_REFILL * dt)
	end
	local boosting = active and s.state ~= "Sliding"
	s.topSpeed = if boosting then Config.BURST_TOP_SPEED else Config.RUN_TOP_SPEED
	if boosting and s.now < s.overdriveUntil then
		s.topSpeed += s.overdriveTop
	end
	s.accel = if boosting then Config.BURST_ACCEL else Config.RUN_ACCEL
end

-- One fixed step of `dt` (normally TechCore.STEP).
function TechCore.step(s: State, input: Input, env: Env, dt: number)
	local wasGrounded = s.grounded
	-- a jump this frame lifts off even if the ray still sees the floor
	s.grounded = env.grounded and s.vel.Y <= 0.01
	if s.grounded and not wasGrounded then
		onLand(s, input)
	elseif wasGrounded and not s.grounded then
		-- walked off a ledge (jumps and layouts lift off themselves)
		s.frame.leftGround = true
		s.airborneSince = s.now
		s.takeoffSpeed = flatOf(s.vel).Magnitude
		s.dodgeAvailable = true
		s.discResetUsed = false
	end
	settleBase(s)
	if not s.grounded and (RUNNING[s.state] or s.state == "HoldingDisc" or s.state == "Sliding") then
		TechCore.enter(s, "Airborne", true)
		s.skyChargeAt = nil
	elseif s.grounded and (s.state == "Airborne" or s.state == "AirDodging") then
		TechCore.enter(s, baseState(s), true)
	end

	-- held edges
	updateBurst(s, input, dt)
	local jumpHeld = isHeld(input, "Jump")
	-- the Sky crouch: Slide held on the ground while slow (not a slide)
	local crouching = s.grounded
		and RUNNING[s.state] == true
		and not s.holding
		and isHeld(input, "Slide")
		and flatOf(s.vel).Magnitude <= Config.SKY_MAX_SPEED
	if crouching then
		s.skyChargeAt = s.skyChargeAt or s.now
	else
		s.skyChargeAt = nil
	end
	s.slidePrimed = (not s.grounded) and isHeld(input, "Slide")

	-- the wall you're touching in the air (Wall Kick window)
	if not s.grounded and env.wallNormal then
		if s.wallTouchAt == nil then
			s.wallTouchAt = s.now
		end
		s.wallNormal = env.wallNormal
		s.wallLostAt = s.now
	elseif s.wallTouchAt and s.now - s.wallLostAt > 0.15 then
		s.wallTouchAt = nil
		s.wallNormal = nil
	end

	tryPresses(s, input, env)

	-- timers
	if s.state == "AirDodging" then
		local d = s.dodge
		if d == nil or s.now - d.startAt >= Config.AIR_DODGE_HANG - 1e-9 then
			TechCore.enter(s, if s.grounded then baseState(s) else "Airborne", true)
		end
	end
	if s.state == "Downed" and s.now >= s.downedUntil then
		s.recoverUntil = s.now + Config.GETUP_TIME
		TechCore.enter(s, "Recovering", true)
	elseif s.state == "Recovering" and s.now >= s.recoverUntil then
		TechCore.enter(s, baseState(s), true)
	end
	if s.state == "Sliding" then
		local speed = flatOf(s.vel).Magnitude
		local stand = if s.skid
			then s.now - s.slideSince >= Config.SKID_MAX_TIME or speed < Config.SKID_EXIT_SPEED
			else s.now - s.slideSince >= Config.SLIDE_MAX_TIME or not isHeld(input, "Slide") or speed < 2
		if stand and s.now - s.slideSince > 0.05 then
			s.skid = false
			TechCore.enter(s, baseState(s), true)
		end
	end
	-- the hop chain resets after time on the ground that isn't a slide
	if s.grounded and s.state ~= "Sliding" then
		s.groundedPlainSince = s.groundedPlainSince or s.now
		if s.now - (s.groundedPlainSince :: number) >= Config.HOP_CHAIN_RESET then
			s.hopCount = 0
		end
	else
		s.groundedPlainSince = nil
	end

	-- flat motion
	s.drifting = false
	local flat: Vector3
	if s.frozen then
		flat = Vector3.zero
	elseif not s.grounded then
		flat = airFlat(s, input, dt)
	elseif s.state == "Sliding" then
		flat = slideFlat(s, input, dt)
	elseif s.state == "HoldingDisc" then
		flat = brakeFlat(s, Config.CATCH_RUNOUT_FRICTION, dt)
	elseif RUNNING[s.state] then
		flat = runFlat(s, input, dt)
	else
		-- Downed, Recovering
		flat = brakeFlat(s, Config.GROUND_FRICTION, dt)
	end

	-- walls: never push into one
	local n = env.wallNormal
	if n then
		local into = flat:Dot(n)
		if into < 0 then
			flat -= n * into
		end
	end

	-- vertical
	local vy = s.vel.Y
	if s.grounded or s.state == "AirDodging" or s.now < s.stallUntil then
		vy = 0 -- on the ground, the dodge's hang, or a Stall
	else
		local g = Config.PLAYER_GRAVITY * (if vy < 0 then Config.FALL_GRAVITY_MULT else 1)
		if isHeld(input, "Slide") and s.state ~= "Diving" then
			g = Config.PLAYER_GRAVITY * Config.FAST_FALL_MULT
		end
		if s.now < s.skyWalkUntil then
			g *= s.skyWalkGravity
		end
		vy -= g * dt
		-- holding Jump after a jump adds up to a full jump
		if jumpHeld and s.now < s.jumpBoostUntil then
			vy += (Config.JUMP_FULL - Config.JUMP_TAP) / Config.JUMP_HOLD * dt
		elseif not jumpHeld then
			s.jumpBoostUntil = -math.huge
		end
	end

	-- the cap holds on the flat speed and on the fall speed (a long fall
	-- never eats your run)
	flat = VecMath.clampMagnitude(flat, Config.HARD_SPEED_CAP)
	vy = math.clamp(vy, -Config.HARD_SPEED_CAP, Config.HARD_SPEED_CAP)
	s.vel = Vector3.new(flat.X, vy, flat.Z)
	if flat.Magnitude > 1e-4 then
		s.heading = flat.Unit
	end

	s.held = table.clone(input.held or NO_HELD)
	s.now += dt
	s.frame.steps += 1
end

-- Runs as many fixed steps as `frameDt` (plus what was left over) covers.
-- Returns this frame's report (steps run, landed, left the ground). Tech
-- events collect in s.events until drainEvents().
function TechCore.advance(s: State, input: Input, env: Env, frameDt: number): FrameReport
	s.frame = newFrame()
	s.acc = math.min(s.acc + math.max(frameDt, 0), Config.MAX_FRAME)
	local ttl = env.timeToLand
	while s.acc >= STEP do
		s.acc -= STEP
		TechCore.step(s, input, env, STEP)
		if ttl then
			ttl -= STEP
			env = { grounded = env.grounded, wallNormal = env.wallNormal, timeToLand = math.max(ttl, 0) }
		end
	end
	return s.frame
end

-- Adds `amount` studs/s along your line at once (Flash Step's surge);
-- overspeed decay brings it back down.
function TechCore.surge(s: State, amount: number)
	local flat = flatOf(s.vel)
	setFlat(s, flat + unitOr(flat, s.heading) * amount)
end

-- Starts an ability's movement effect (Config/Abilities): "Zone",
-- "SkyWalk" or "Overdrive" for `duration` seconds of sim time. Flash Step
-- moves the body, so the caller does it (see flashStep).
function TechCore.startAbility(s: State, id: string, duration: number, scale: number?, dodges: number?)
	local untilT = s.now + duration
	if id == "Zone" then
		s.zoneUntil = untilT
		s.windowScale = scale or 2
	elseif id == "SkyWalk" then
		s.skyWalkUntil = untilT
		s.extraDodges = dodges or 2
		s.extraDodgesLeft = s.extraDodges
		s.skyWalkGravity = scale or 1
	elseif id == "Overdrive" then
		s.overdriveUntil = untilT
		s.burst = 100
		s.burstLocked = false
		s.overdriveTop = scale or 0
	end
	emit(s, "Ability", "Clean", s.heading, id)
end

-- The ends of the timed abilities are checked here so Sky Walk stops
-- granting dodges the moment it runs out.
function TechCore.abilityActive(s: State): string?
	if s.now < s.zoneUntil then
		return "Zone"
	elseif s.now < s.skyWalkUntil then
		return "SkyWalk"
	elseif s.now < s.overdriveUntil then
		return "Overdrive"
	end
	return nil
end

-- Flash Step: the flat direction to blink (the stick, else your line).
function TechCore.flashDirection(s: State, move: Vector3): Vector3
	local m = flatOf(move)
	if m.Magnitude > 0.05 then
		return m.Unit
	end
	return s.heading
end

function TechCore.flatSpeed(s: State): number
	return flatOf(s.vel).Magnitude
end

return TechCore
