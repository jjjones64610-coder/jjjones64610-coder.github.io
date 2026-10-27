--!strict
--[[
	TechCore — the momentum controller every movement tech sits on
	(docs/tech-spec.md, "Core physics model", build step 1).

	Pure: no Instances. The client (MovementController) gives it the stick
	and a small environment snapshot each frame and writes the velocity it
	returns to the body. It can run offline under Lune (tests/tech_spec).

	  * Velocity is kept, not set. The stick accelerates you toward its
	    direction; speed only drops from friction, turning or overspeed decay.
	  * Turning is instant below TURN_FREE_SPEED. Faster, the heading turns at
	    most TURN_RATE(speed) °/s; while the stick asks for more you drift: no
	    acceleration, and every 90° turned costs TURN_DRIFT_LOSS of your speed.
	  * Above run speed, speed decays toward it (fast on the ground, slowly in
	    the air). Neither the flat speed nor the fall speed passes
	    HARD_SPEED_CAP.
	  * Gravity is the player's own (PLAYER_GRAVITY, x FALL_GRAVITY_MULT while
	    moving down). On the ground the vertical speed is 0; the controller
	    holds the body at its stand height.
	  * Fixed timestep: advance() runs step() at PHYSICS_RATE with an
	    accumulator, so nothing depends on the frame rate.
	  * One state machine (State below). This step builds the always-on states
	    (Grounded, Airborne, HoldingDisc, Marking); the tech states (Sliding,
	    AirDodging, Diving, Downed, Recovering) exist with their transitions
	    and are entered by the tech built in later steps.
	  * Input buffer: press() stores a press for INPUT_BUFFER ms; a tech whose
	    window opens in that time consume()s it.
	  * Timing readout: noteTiming() records how early / late the last timed
	    press was, for the debug HUD and training.
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
}

export type Env = {
	grounded: boolean,
	wallNormal: Vector3?, -- flat normal of a wall right in front of the body
}

export type Timing = {
	name: string,
	offsetMs: number, -- < 0 early, > 0 late, 0 dead on
	windowMs: number, -- half width of the success window
	quality: string, -- "Perfect" | "Clean" | "Miss"
	t: number, -- os.clock() of the press
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
	topSpeed: number, -- current run top speed (Burst raises it in step 3)
	accel: number,
	buffer: { [string]: number }, -- action -> os.clock() of the press
	lastTiming: Timing?,
	frame: FrameReport,
}

local STEP = 1 / Config.PHYSICS_RATE
TechCore.STEP = STEP

-- Which states each state may move into by a tech. The environment (leaving
-- or touching the ground) and the holding / marking flags can always move
-- between Grounded, Airborne, HoldingDisc and Marking.
TechCore.Transitions = {
	Grounded = { Sliding = true, Airborne = true, Diving = true, HoldingDisc = true, Marking = true },
	Sliding = { Grounded = true, Airborne = true, Diving = true, HoldingDisc = true },
	Airborne = { AirDodging = true, Diving = true, Grounded = true, Sliding = true, HoldingDisc = true },
	AirDodging = { Airborne = true, Grounded = true, Sliding = true, Diving = true },
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
-- States that only brake (no stick).
local BRAKING: { [StateName]: boolean } = { HoldingDisc = true, Downed = true }

local function newFrame(): FrameReport
	return { steps = 0, landed = false, leftGround = false, landingSpeed = 0 }
end

function TechCore.new(now: number?): State
	return {
		state = "Grounded",
		stateSince = now or 0,
		now = now or 0,
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
		lastTiming = nil,
		frame = newFrame(),
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
		local want = baseState(s)
		if want ~= s.state then
			s.state = want
			s.stateSince = s.now
		end
	end
end

function TechCore.setHolding(s: State, on: boolean)
	s.holding = on
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

-- After a teleport: no momentum, nothing buffered; flags are kept.
function TechCore.reset(s: State)
	s.vel = Vector3.zero
	s.acc = 0
	s.drifting = false
	table.clear(s.buffer)
	s.state = baseState(s)
	s.stateSince = s.now
end

---------------------------------------------------------------------------
-- input buffer and timing
---------------------------------------------------------------------------

function TechCore.press(s: State, action: string, t: number)
	s.buffer[action] = t
end

-- The buffered press of `action` if it is still fresh at `t` (os.clock()).
function TechCore.buffered(s: State, action: string, t: number): number?
	local at = s.buffer[action]
	if at and t - at <= Config.INPUT_BUFFER / 1000 and t >= at then
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
	local quality = if perfectMs and a <= perfectMs then "Perfect" elseif a <= windowMs then "Clean" else "Miss"
	local timing: Timing = {
		name = name,
		offsetMs = offsetMs,
		windowMs = windowMs,
		quality = quality,
		t = t or s.now,
	}
	s.lastTiming = timing
	return timing
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
-- simulation
---------------------------------------------------------------------------

local function moveToward(x: number, target: number, rate: number): number
	if x < target then
		return math.min(target, x + rate)
	end
	return math.max(target, x - rate)
end

-- Flat velocity for one fixed step.
local function stepFlat(s: State, input: Input, dt: number): Vector3
	local flat = VecMath.flat(s.vel)
	local speed = flat.Magnitude
	if speed > 1e-4 then
		s.heading = flat / speed
	end
	s.drifting = false

	if s.frozen then
		return Vector3.zero
	end

	if not s.grounded then
		-- air: momentum is kept; only overspeed decays (air steer is step 4)
		if speed > s.topSpeed then
			speed = math.max(s.topSpeed, speed - Config.OVERSPEED_DECAY_AIR * dt)
		end
		return s.heading * speed
	end

	if BRAKING[s.state] or not RUNNING[s.state] then
		if BRAKING[s.state] then
			speed = math.max(0, speed - Config.GROUND_FRICTION * dt)
		elseif speed > s.topSpeed then
			speed = math.max(s.topSpeed, speed - Config.OVERSPEED_DECAY_GROUND * dt)
		end
		return s.heading * speed
	end

	local mv = VecMath.flat(input.move)
	local mag = math.min(mv.Magnitude, 1)
	if mag < 0.05 then
		-- no stick: friction (overspeed bleeds the same way)
		speed = math.max(0, speed - Config.GROUND_FRICTION * dt)
		return s.heading * speed
	end
	local want = mv / mv.Magnitude

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
	local target = s.topSpeed * mag
	if speed > s.topSpeed then
		speed = math.max(s.topSpeed, speed - Config.OVERSPEED_DECAY_GROUND * dt)
	elseif speed < target then
		if not s.drifting then
			speed = moveToward(speed, target, s.accel * dt)
		end
	elseif speed > target then
		-- a part-pushed stick slows you to its speed like friction
		speed = math.max(target, speed - Config.GROUND_FRICTION * dt)
	end
	return s.heading * speed
end

-- One fixed step of `dt` (normally TechCore.STEP).
function TechCore.step(s: State, input: Input, env: Env, dt: number)
	local wasGrounded = s.grounded
	s.grounded = env.grounded
	local frame = s.frame
	if s.grounded and not wasGrounded then
		frame.landed = true
		frame.landingSpeed = math.max(frame.landingSpeed, -s.vel.Y)
	elseif wasGrounded and not s.grounded then
		frame.leftGround = true
	end
	settleBase(s)
	if s.grounded and (s.state == "Airborne" or s.state == "AirDodging") then
		TechCore.enter(s, baseState(s), true)
	elseif not s.grounded and (RUNNING[s.state] or s.state == "HoldingDisc" or s.state == "Sliding") then
		TechCore.enter(s, "Airborne", true)
	end

	local flat = stepFlat(s, input, dt)

	-- walls: never push into one
	local n = env.wallNormal
	if n then
		local into = flat:Dot(n)
		if into < 0 then
			flat -= n * into
		end
	end

	local vy = s.vel.Y
	if s.grounded then
		vy = 0
	else
		local g = Config.PLAYER_GRAVITY * (if vy < 0 then Config.FALL_GRAVITY_MULT else 1)
		vy -= g * dt
	end

	-- the cap holds on the flat speed and on the fall speed (a long fall
	-- never eats your run)
	flat = VecMath.clampMagnitude(flat, Config.HARD_SPEED_CAP)
	vy = math.clamp(vy, -Config.HARD_SPEED_CAP, Config.HARD_SPEED_CAP)
	s.vel = Vector3.new(flat.X, vy, flat.Z)
	s.now += dt
	frame.steps += 1
end

-- Runs as many fixed steps as `frameDt` (plus what was left over) covers.
-- Returns this frame's report (steps run, landed, left the ground).
function TechCore.advance(s: State, input: Input, env: Env, frameDt: number): FrameReport
	s.frame = newFrame()
	s.acc = math.min(s.acc + math.max(frameDt, 0), Config.MAX_FRAME)
	while s.acc >= STEP do
		s.acc -= STEP
		TechCore.step(s, input, env, STEP)
	end
	return s.frame
end

function TechCore.flatSpeed(s: State): number
	return VecMath.flat(s.vel).Magnitude
end

return TechCore
