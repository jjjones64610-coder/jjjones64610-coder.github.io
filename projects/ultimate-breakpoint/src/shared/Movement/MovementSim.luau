--!strict
--[[
	MovementSim — the movement-tech engine.

	Pure simulation of one player's horizontal momentum, technique timing,
	exertion and cooldowns. It knows nothing about Instances: the client
	MovementController feeds it input + an environment snapshot (grounded,
	time-to-land, nearby rebound wall, pivot offset) and applies the returned
	velocity with a LinearVelocity constraint. Because it is pure, the same code
	is fuzz-tested offline (tests/movement.spec.luau) to prove that no input
	sequence can exceed the speed caps.

	Inputs map to five actions. Every advanced technique is one of these
	actions pressed in a particular context and at a particular time:

	  Cut   ground, input 25-115 deg off travel      -> Snap Cut
	        ground, input >115 deg / no input        -> Momentum Cancel (plant)
	        ground, input along travel / standing    -> Fake Commit (jab step)
	        during a plant's restart window          -> restart cut (Perfect/Clean)
	        in the air                               -> Air Redirect
	        mid-slide                                -> Slide Cut
	        in the dive recovery pop window          -> Recovery Chain
	  Burst ground                                   -> Burst Step
	        during a plant window                    -> Explosive restart (free)
	  Slide ground, fast                             -> Slide
	        airborne, <=0.15 s before touchdown      -> Precision Landing / Roll-out
	  Dive  ground or air                            -> Layout dive
	  Jump  ground / slide                           -> Jump / slide hop
	        airborne beside a Rebound wall           -> Wall Rebound
	        in the pop window                        -> Recovery Chain pop-up
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config.Movement)
local VecMath = require(Shared.Util.VecMath)

local MovementSim = {}

export type Mode = "Ground" | "Air" | "Slide" | "Dive" | "DiveSlide" | "Recover" | "Landing" | "Frozen"
export type HoldPhase = "None" | "Air" | "Decel" | "Pivot"
export type Action = "Jump" | "Cut" | "Slide" | "Dive" | "Burst"

export type TechEvent = {
	tech: string,
	quality: string,
	t: number,
	dir: Vector3,
	chain: boolean,
	info: string?,
}

export type Feedback = { kind: string, value: number? }

export type Input = { move: Vector3, sprint: boolean }

export type Env = {
	grounded: boolean,
	actualVel: Vector3,
	timeToLand: number?,
	wallNormal: Vector3?,
	wallDistance: number?,
	wallId: string?,
	pivotOffset: Vector3?,
	facing: Vector3?,
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
}

export type State = {
	mode: Mode,
	now: number,
	modeStart: number,
	vel: Vector3,
	exertion: number,
	regenAt: number,
	ready: { [string]: number },
	lastTech: string?,
	lastTechAt: number,
	lastCutAt: number,
	commitDir: Vector3,
	commitSince: number,
	blockedSince: number?,

	plantAt: number,
	plantEnd: number,
	plantDecel: number,
	plantGassed: boolean,
	restartLockUntil: number,

	jabUntil: number,
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
	precisionLockUntil: number,
	lateLandingUntil: number,

	recoverUntil: number,
	popStart: number,
	popEnd: number,
	popLockUntil: number,

	diveDir: Vector3,

	holding: boolean,
	holdPhase: HoldPhase,
	holdStart: number,
	holdHopped: boolean,

	frozen: boolean,

	pendingVertical: number?,
	pendingJump: boolean,
	pendingEvents: { TechEvent },
	pendingFeedback: { Feedback },
	pendingPivot: boolean,
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

local FORWARD = Vector3.new(0, 0, -1)

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
		exertion = Config.ExertionMax,
		regenAt = t,
		ready = {},
		lastTech = nil,
		lastTechAt = -math.huge,
		lastCutAt = -math.huge,
		commitDir = FORWARD,
		commitSince = t,
		blockedSince = nil,

		plantAt = 0,
		plantEnd = 0,
		plantDecel = MC.BrakeDecel,
		plantGassed = false,
		restartLockUntil = 0,

		jabUntil = 0,
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
		precisionLockUntil = 0,
		lateLandingUntil = 0,

		recoverUntil = 0,
		popStart = 0,
		popEnd = 0,
		popLockUntil = 0,

		diveDir = FORWARD,

		holding = false,
		holdPhase = "None",
		holdStart = 0,
		holdHopped = false,

		frozen = false,

		pendingVertical = nil,
		pendingJump = false,
		pendingEvents = {},
		pendingFeedback = {},
		pendingPivot = false,
	}
end

-- Clears momentum and transient technique state (respawn / teleport).
function MovementSim.reset(s: State)
	local now = s.now
	local exertion = s.exertion
	local holding: boolean = s.holding
	local holdPhase: HoldPhase = s.holdPhase
	local fresh = MovementSim.new(now)
	for k, v in fresh :: any do
		(s :: any)[k] = v
	end
	s.exertion = exertion
	s.holding = holding
	s.holdPhase = holdPhase
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function setMode(s: State, m: Mode)
	s.mode = m
	s.modeStart = s.now
end

local function isReady(s: State, tech: string): boolean
	return (s.ready[tech] or -math.huge) <= s.now
end

local function setCooldown(s: State, tech: string)
	local cd = (Config.TechCooldowns :: any)[tech] or 0
	s.ready[tech] = s.now + cd
end

local function spend(s: State, cost: number)
	s.exertion = math.max(0, s.exertion - cost)
	s.regenAt = s.now + Config.ExertionRegenDelay
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
end

local function feedback(s: State, kind: string, value: number?)
	table.insert(s.pendingFeedback, { kind = kind, value = value })
end

local function queueJump(s: State, vy: number)
	s.pendingVertical = vy
	s.pendingJump = true
end

local function queueVertical(s: State, vy: number)
	s.pendingVertical = vy
end

local function cancelTransients(s: State)
	s.burstUntil = 0
	s.plantAt = 0
	s.plantEnd = 0
	s.jabUntil = 0
end

local function enterAir(s: State)
	setMode(s, "Air")
	s.airStart = s.now
	s.takeoffSpeed = s.vel.Magnitude
	s.plantAt = 0
	s.plantEnd = 0
	s.jabUntil = 0
	s.groundLostAt = nil
end

local function enterRecover(s: State, duration: number)
	setMode(s, "Recover")
	s.recoverUntil = s.now + duration
	s.popStart = s.now
	s.popEnd = s.now + RC.PopWindow
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

local function topSpeed(s: State, sprint: boolean): number
	if not sprint then
		return Config.JogSpeed
	end
	if s.exertion >= 15 then
		return Config.SprintSpeed
	end
	local t = s.exertion / 15
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

---------------------------------------------------------------------------
-- steering models
---------------------------------------------------------------------------

-- Ground steering: acceleration split into along-velocity (accelerate/brake)
-- and perpendicular (turning) components with separate limits. This is what
-- makes sprinting a commitment: at 26 studs/s the turn radius is ~7 studs, so
-- sharp changes of direction require a technique.
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
	local perpMag = tPerp.Magnitude
	local maxPerp = Config.LateralAccel * lateralMult * dt
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

local function updateHolding(s: State, wish: Vector3, env: Env, dt: number)
	if s.holdPhase == "Air" then
		s.holdPhase = "Decel"
		s.holdStart = s.now
	end
	if s.holdPhase == "Decel" then
		local speed = s.vel.Magnitude
		local newSpeed = math.max(0, speed - HD.DecelRate * dt)
		s.vel = if speed > 1e-3 then s.vel * (newSpeed / speed) else Vector3.zero
		if newSpeed <= HD.StopSpeed or s.now - s.holdStart >= HD.DecelMaxTime then
			s.vel = Vector3.zero
			s.holdPhase = "Pivot"
			s.pendingPivot = true
		end
	elseif s.holdPhase == "Pivot" then
		local wishMag = math.min(wish.Magnitude, 1)
		local target = if wishMag > 0.05 then VecMath.flatUnit(wish) * (HD.PivotSpeed * wishMag) else Vector3.zero
		local off = env.pivotOffset
		if off then
			local flatOff = VecMath.flat(off)
			local r = flatOff.Magnitude
			if r > 1e-3 then
				local outward = flatOff / r
				if r >= HD.PivotRadius - 0.05 then
					local o = target:Dot(outward)
					if o > 0 then
						target -= outward * o
					end
				end
				if r > HD.PivotRadius then
					target -= outward * ((r - HD.PivotRadius) * 12)
				end
			end
		end
		s.vel = VecMath.moveToward(s.vel, target, HD.PivotAccel * dt)
	end
end

---------------------------------------------------------------------------
-- landing
---------------------------------------------------------------------------

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
		feedback(s, "HopLanded")
	end

	local armed = s.precisionArmedAt
	s.precisionArmedAt = nil
	if armed ~= nil and now - armed <= PL.EarlyWindow + 0.035 then
		local offset = now - armed
		local q = if offset <= PL.PerfectWindow then Q.Perfect else Q.Clean
		if fromDive then
			s.vel = s.vel * (RO.Retention :: any)[q]
			enterRecover(s, RO.RecoverTime)
			emit(s, "PrecisionLanding", q, velDirOr(s, s.diveDir), "RollOut")
		else
			s.vel = s.vel * (PL.Retention :: any)[q]
			setMode(s, "Ground")
			emit(s, "PrecisionLanding", q, velDirOr(s, FORWARD), nil)
		end
		feedback(s, "LandingOffset", offset)
		return
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

local function pressSnapCut(s: State, dir: Vector3, speed: number, angle: number, sold: boolean): boolean
	local now = s.now
	if now - s.lastCutAt < SC.MinInterval then
		return false
	end
	local q: string
	if s.exertion < SC.Cost then
		q = Q.Gassed
	elseif sold then
		q = Q.Perfect
	elseif now - s.lastCutAt < SC.SpamWindow then
		q = Q.Sloppy
	else
		local commit = now - s.commitSince
		if commit >= SC.CommitPerfect and speed >= Config.SprintSpeed * SC.PerfectSpeedFraction then
			q = Q.Perfect
		elseif commit >= SC.CommitClean then
			q = Q.Clean
		else
			q = Q.Sloppy
		end
	end
	local over = math.clamp((angle - 45) / (SC.MaxAngle - 45), 0, 1)
	local retention = (SC.Retention :: any)[q] * (1 - SC.AnglePenalty * over)
	local newSpeed = speed * retention
	if q == Q.Perfect then
		newSpeed = math.min(newSpeed + SC.PerfectBoost, Config.SprintSpeed)
	end
	if sold then
		newSpeed = math.max(newSpeed, Config.SprintSpeed * SC.SoldMinSpeedFraction)
	end
	spend(s, SC.Cost)
	s.vel = dir * newSpeed
	s.lastCutAt = now
	s.commitDir = dir
	s.commitSince = now
	s.soldUntil = 0
	s.burstUntil = 0
	s.jabUntil = 0
	emit(s, "SnapCut", q, dir, if sold then "Sold" else nil)
	return true
end

local function pressMomentumCancel(s: State, velDir: Vector3): boolean
	if not isReady(s, "MomentumCancel") then
		feedback(s, "Cooldown", (s.ready.MomentumCancel or 0) - s.now)
		return false
	end
	local speed = s.vel.Magnitude
	local q: string
	if s.exertion < MC.Cost then
		q = Q.Gassed
	elseif speed >= 18 then
		q = Q.Clean
	else
		q = Q.Sloppy
	end
	spend(s, MC.Cost)
	setCooldown(s, "MomentumCancel")
	s.burstUntil = 0
	s.jabUntil = 0
	s.plantAt = s.now
	s.plantEnd = s.now + MC.PlantTime
	s.plantGassed = q == Q.Gassed
	s.plantDecel = if q == Q.Gassed then MC.BrakeDecel * 0.5 else MC.BrakeDecel
	s.restartLockUntil = 0
	emit(s, "MomentumCancel", q, velDir, nil)
	return true
end

local function pressFakeCommit(s: State, dir: Vector3, speed: number): boolean
	if not isReady(s, "FakeCommit") then
		return false
	end
	local q = if s.exertion < FC.Cost then Q.Gassed else Q.Clean
	spend(s, FC.Cost)
	setCooldown(s, "FakeCommit")
	if speed < SC.MinSpeed then
		s.vel = dir * (FC.JabSpeed * (if q == Q.Gassed then 0.6 else 1))
		s.soldDir = dir
	else
		s.vel = s.vel * FC.JabSlow
		s.soldDir = velDirOr(s, dir)
	end
	s.jabUntil = s.now + FC.JabTime
	s.soldUntil = s.now + FC.JabTime + FC.SoldWindow
	emit(s, "FakeCommit", q, s.soldDir, nil)
	return true
end

local function restartFromPlant(s: State, dir: Vector3): boolean
	local since = s.now - s.plantAt
	local q = if since <= MC.PerfectUntil and not s.plantGassed then Q.Perfect else Q.Clean
	s.vel = dir * (Config.SprintSpeed * (MC.RestartRetention :: any)[q])
	s.plantAt = 0
	s.plantEnd = 0
	s.lastCutAt = s.now
	s.commitDir = dir
	s.commitSince = s.now
	emit(s, "SnapCut", q, dir, "Restart")
	return true
end

local function doBurst(s: State, dir: Vector3, free: boolean, forcedQuality: string?): boolean
	local now = s.now
	local speed = s.vel.Magnitude
	local q: string
	if forcedQuality then
		q = forcedQuality
	elseif s.exertion < BS.Cost then
		q = Q.Gassed
	elseif s.lastTech == "SnapCut" and now - s.lastCutAt <= BS.CutChainWindow then
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
	s.plantAt = 0
	s.plantEnd = 0
	s.jabUntil = 0
	s.commitDir = dir
	s.commitSince = now
	emit(s, "BurstStep", q, dir, if free then "Explosive" else nil)
	return true
end

local function tryPop(s: State, action: Action, dir: Vector3, hasDir: boolean, env: Env): boolean
	local now = s.now
	if s.mode == "DiveSlide" then
		s.popLockUntil = now + RC.EarlyLockout
		feedback(s, "PopEarly")
		return false
	end
	if now < s.popLockUntil then
		return false
	end
	if now > s.popEnd then
		feedback(s, "PopLate", now - s.popEnd)
		return false
	end
	local q = if now - s.popStart <= RC.PopPerfect then Q.Perfect else Q.Clean
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	local out = Config.SprintSpeed * (RC.Retention :: any)[q]
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
		s.commitDir = d
		s.commitSince = now
	elseif action == "Burst" then
		s.vel = d * out
		if isReady(s, "BurstStep") then
			doBurst(s, d, false, nil)
		end
	end
	return true
end

local function pressJump(s: State, dir: Vector3, hasDir: boolean, env: Env): boolean
	if s.holding then
		local grounded = s.mode == "Ground" or s.mode == "Landing"
		if s.holdPhase == "Pivot" and not s.holdHopped and grounded then
			s.holdHopped = true
			enterAir(s)
			queueJump(s, HD.HopVertical)
			return true
		end
		return false
	end
	if s.mode == "Recover" or s.mode == "DiveSlide" then
		return tryPop(s, "Jump", dir, hasDir, env)
	end
	if s.mode == "Ground" or s.mode == "Landing" or s.mode == "Slide" then
		local speed = s.vel.Magnitude
		local vy = Config.JumpVelocity + Config.JumpSpeedBonus * math.clamp(speed / Config.SprintSpeed, 0, 1)
		local fromSlide = s.mode == "Slide"
		local fromPlant = inPlantWindow(s)
		enterAir(s)
		queueJump(s, vy)
		local info: string? = nil
		if fromSlide then
			info = "SlideHop"
		elseif fromPlant then
			info = "PlantJump"
		end
		emit(s, "Jump", Q.Clean, velDirOr(s, facingOr(env)), info)
		return true
	end
	if s.mode == "Air" or s.mode == "Dive" then
		local wall = env.wallNormal
		if wall and s.rebounds < WR.MaxPerAir and env.wallId ~= s.lastWall then
			local n = VecMath.flatUnit(wall)
			if n.Magnitude < 0.5 then
				return false
			end
			local v = s.vel
			local into = v:Dot(n)
			local reflected = if into < 0 then VecMath.reflect(v, n) else v
			local q: string
			if s.exertion < WR.Cost then
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
			return true
		end
	end
	return false
end

local function pressAirRedirect(s: State, dir: Vector3, hasDir: boolean, env: Env): boolean
	if s.airRedirectUsed or not hasDir then
		return false
	end
	local speed = s.vel.Magnitude
	local vy = env.actualVel.Y
	local q: string
	if s.exertion < AR.Cost then
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
	return true
end

local function pressSlideCut(s: State, dir: Vector3, hasDir: boolean): boolean
	local t = s.now - s.modeStart
	if t < SLC.MinSlideTime or not hasDir then
		return false
	end
	local speed = s.vel.Magnitude
	local velDir = velDirOr(s, dir)
	if VecMath.flatAngle(velDir, dir) > SLC.MaxAngle then
		return false
	end
	local q: string
	if s.exertion < SLC.Cost then
		q = Q.Gassed
	elseif t >= SLC.PerfectFrom and t <= SLC.PerfectTo then
		q = Q.Perfect
	else
		q = Q.Clean
	end
	spend(s, SLC.Cost)
	s.vel = dir * (speed * (SLC.Retention :: any)[q])
	setMode(s, "Ground")
	s.lastCutAt = s.now
	s.commitDir = dir
	s.commitSince = s.now
	emit(s, "SlideCut", q, dir, nil)
	return true
end

local function pressCut(s: State, dir: Vector3, hasDir: boolean, env: Env): boolean
	if s.holding then
		return false
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
	if s.mode ~= "Ground" and s.mode ~= "Landing" then
		return false
	end

	-- Restart out of a Momentum Cancel plant.
	if s.plantAt > 0 and now - s.plantAt <= MC.WindowClose then
		if now < s.restartLockUntil then
			return false
		end
		if plantTooEarly(s) then
			s.restartLockUntil = now + MC.EarlyLockout
			feedback(s, "PlantEarly", MC.WindowOpen - (now - s.plantAt))
			return false
		end
		if hasDir then
			return restartFromPlant(s, dir)
		end
		return false
	end

	local speed = s.vel.Magnitude
	local velDir = velDirOr(s, facingOr(env))

	-- A cut out of a Fake Commit's sold window is always allowed.
	if hasDir and now <= s.soldUntil and VecMath.flatAngle(s.soldDir, dir) >= FC.SoldMinAngle then
		return pressSnapCut(s, dir, math.max(speed, SC.MinSpeed), VecMath.flatAngle(velDir, dir), true)
	end

	if not hasDir then
		if speed >= MC.MinSpeed then
			return pressMomentumCancel(s, velDir)
		end
		return false
	end
	if speed < SC.MinSpeed then
		return pressFakeCommit(s, dir, speed)
	end
	local angle = VecMath.flatAngle(velDir, dir)
	if angle < FC.MaxAngle then
		return pressFakeCommit(s, dir, speed)
	end
	if angle <= SC.MaxAngle then
		return pressSnapCut(s, dir, speed, angle, false)
	end
	if speed >= MC.MinSpeed then
		return pressMomentumCancel(s, velDir)
	end
	return pressSnapCut(s, dir, speed, angle, false)
end

local function pressBurst(s: State, dir: Vector3, hasDir: boolean, env: Env): boolean
	if s.holding then
		return false
	end
	if s.mode == "Recover" or s.mode == "DiveSlide" then
		return tryPop(s, "Burst", dir, hasDir, env)
	end
	if s.mode ~= "Ground" and s.mode ~= "Landing" then
		return false
	end
	local now = s.now
	if now < s.restartLockUntil then
		return false
	end
	if plantTooEarly(s) then
		s.restartLockUntil = now + MC.EarlyLockout
		feedback(s, "PlantEarly", MC.WindowOpen - (now - s.plantAt))
		return false
	end
	if not isReady(s, "BurstStep") then
		feedback(s, "Cooldown", (s.ready.BurstStep or 0) - now)
		return false
	end
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	if inPlantWindow(s) then
		local q = if (now - s.plantAt) <= MC.PerfectUntil and not s.plantGassed then Q.Perfect else Q.Clean
		return doBurst(s, d, true, q)
	end
	return doBurst(s, d, false, nil)
end

local function armPrecision(s: State, env: Env): boolean
	local now = s.now
	if now < s.precisionLockUntil or s.precisionArmedAt ~= nil then
		return false
	end
	local ttl = env.timeToLand
	if ttl ~= nil and ttl <= PL.EarlyWindow then
		s.precisionArmedAt = now
		return true
	end
	s.precisionLockUntil = now + PL.Lockout
	feedback(s, "LandingEarly", ttl or -1)
	return false
end

local function pressSlide(s: State, env: Env): boolean
	if s.holding then
		return false
	end
	local now = s.now
	if s.mode == "Air" or s.mode == "Dive" then
		return armPrecision(s, env)
	end
	-- Late Precision Landing (pressed just after touchdown).
	if now <= s.lateLandingUntil then
		if s.mode == "Landing" and not s.landedFromDive then
			s.vel = s.landingVel * PL.Retention.Clean
			setMode(s, "Ground")
			s.lateLandingUntil = 0
			emit(s, "PrecisionLanding", Q.Clean, velDirOr(s, FORWARD), "Late")
			feedback(s, "LandingOffset", -(now - s.landedAt))
			return true
		elseif s.mode == "DiveSlide" and s.landedFromDive then
			s.vel = s.landingVel * RO.Retention.Clean
			s.lateLandingUntil = 0
			enterRecover(s, RO.RecoverTime)
			emit(s, "PrecisionLanding", Q.Clean, velDirOr(s, s.diveDir), "RollOut")
			feedback(s, "LandingOffset", -(now - s.landedAt))
			return true
		end
	end
	if s.mode ~= "Ground" and s.mode ~= "Landing" then
		return false
	end
	if not isReady(s, "Slide") then
		return false
	end
	local speed = s.vel.Magnitude
	if speed < SL.MinSpeed then
		return false
	end
	local q = if s.exertion < SL.Cost then Q.Gassed else Q.Clean
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
	return true
end

local function pressDive(s: State, dir: Vector3, hasDir: boolean, env: Env): boolean
	if s.holding then
		return false
	end
	local now = s.now
	local groundish = s.mode == "Ground" or s.mode == "Landing" or s.mode == "Slide"
	local air = s.mode == "Air"
	if not groundish and not air then
		return false
	end
	if air and s.airDiveUsed then
		return false
	end
	if not isReady(s, "Dive") then
		feedback(s, "Cooldown", (s.ready.Dive or 0) - now)
		return false
	end
	local speed = s.vel.Magnitude
	local d = if hasDir then dir else velDirOr(s, facingOr(env))
	local last = s.lastTech
	local chained = last ~= nil
		and (last == "SnapCut" or last == "BurstStep" or last == "SlideCut" or last == "AirRedirect" or last == "RecoveryChain")
		and now - s.lastTechAt <= DV.ChainWindow
	local q: string
	if s.exertion < DV.Cost then
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
	return true
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function MovementSim.press(s: State, action: Action, input: Input, env: Env): boolean
	if s.frozen or s.mode == "Frozen" then
		return false
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
	return false
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
		setMode(s, "Frozen")
	elseif s.mode == "Frozen" then
		setMode(s, "Ground")
	end
end

function MovementSim.setHolding(s: State, holding: boolean, grounded: boolean)
	if holding then
		s.holding = true
		s.holdHopped = false
		s.holdStart = s.now
		s.holdPhase = if grounded and s.mode ~= "Air" and s.mode ~= "Dive" then "Decel" else "Air"
		s.burstUntil = 0
		s.plantAt = 0
		s.plantEnd = 0
		s.jabUntil = 0
		s.soldUntil = 0
	else
		s.holding = false
		s.holdPhase = "None"
		s.holdHopped = false
	end
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

function MovementSim.step(s: State, input: Input, env: Env, dt: number): Output
	s.now += dt
	local now = s.now
	local landed, tookOff = false, false

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

	-- 2. collision reconciliation: if something solid holds us back for a
	-- moment, stop accumulating phantom speed against it.
	local simSpeed = s.vel.Magnitude
	if simSpeed > 6 and s.mode ~= "Frozen" then
		local along = VecMath.flat(env.actualVel):Dot(s.vel / simSpeed)
		if along < simSpeed * 0.5 - 2 then
			if s.blockedSince == nil then
				s.blockedSince = now
			elseif now - (s.blockedSince :: number) > 0.12 then
				s.vel = VecMath.flat(env.actualVel)
				s.blockedSince = nil
				s.burstUntil = 0
			end
		else
			s.blockedSince = nil
		end
	else
		s.blockedSince = nil
	end

	-- 3. per-mode velocity ------------------------------------------------------
	local wish = VecMath.flat(input.move)
	local wishMag = math.min(wish.Magnitude, 1)
	local top = topSpeed(s, input.sprint)
	local mode = s.mode

	if s.frozen or mode == "Frozen" then
		s.vel = Vector3.zero
	elseif s.holding and (mode == "Ground" or mode == "Landing") then
		updateHolding(s, wish, env, dt)
		if mode == "Landing" and now >= s.landingUntil then
			setMode(s, "Ground")
		end
	elseif mode == "Ground" or mode == "Landing" then
		if now < s.burstUntil then
			s.vel = s.burstDir * s.burstSpeed
		elseif now < s.plantEnd then
			s.vel = VecMath.moveToward(s.vel, Vector3.zero, s.plantDecel * dt)
		elseif now >= s.jabUntil then
			-- (during a jab step the player is committed: no steering)
			local lat = if mode == "Landing" then Config.LandingSteer else 1
			s.vel = MovementSim.steerGround(s.vel, wish, top, dt, lat)
		end
		if mode == "Landing" and now >= s.landingUntil then
			setMode(s, "Ground")
		end
		if s.plantAt > 0 and now - s.plantAt > MC.WindowClose then
			s.plantAt = 0
		end
	elseif mode == "Air" then
		if not s.holding then
			s.vel = steerAir(s, wish, dt)
		end
	-- (Dive: a commitment, no steering; Air Redirect is the only adjustment)
	elseif mode == "Slide" then
		local speed = s.vel.Magnitude
		local newSpeed = math.max(0, speed - SL.Friction * dt)
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
		local newSpeed = math.max(0, speed - DS.Friction * dt)
		s.vel = velDirOr(s, s.diveDir) * newSpeed
		if newSpeed < DS.StopSpeed or now - s.modeStart > DS.MaxTime then
			enterRecover(s, RC.Time)
		end
	elseif mode == "Recover" then
		s.vel = VecMath.moveToward(s.vel, Vector3.zero, RC.Decel * dt)
		if now >= s.recoverUntil then
			setMode(s, "Ground")
		end
	end

	-- 4. exertion ---------------------------------------------------------------
	local speedNow = s.vel.Magnitude
	local sprinting = input.sprint
		and wishMag > 0.05
		and speedNow > Config.JogSpeed + 0.5
		and (s.mode == "Ground" or s.mode == "Landing")
	if sprinting then
		s.exertion = math.max(0, s.exertion - Config.SprintDrain * dt)
		s.regenAt = math.max(s.regenAt, now + Config.ExertionRegenDelay * 0.5)
	elseif now >= s.regenAt then
		s.exertion = math.min(Config.ExertionMax, s.exertion + Config.ExertionRegen * dt)
	end

	-- 5. running-line commitment (feeds Snap Cut quality) -------------------
	if s.mode == "Ground" and not s.holding then
		if speedNow > 10 then
			local d = s.vel / speedNow
			if s.commitDir:Dot(d) < math.cos(math.rad(Config.CommitAngle)) then
				s.commitDir = d
				s.commitSince = now
			end
		else
			s.commitSince = now
		end
	end

	-- 6. hard safety cap ----------------------------------------------------------
	s.vel = VecMath.clampMagnitude(VecMath.flat(s.vel), Config.HardCap)

	local out: Output = {
		vel = s.vel,
		setVertical = s.pendingVertical,
		jump = s.pendingJump,
		events = s.pendingEvents,
		feedback = s.pendingFeedback,
		pivotEstablished = s.pendingPivot,
		landed = landed,
		tookOff = tookOff,
	}
	s.pendingVertical = nil
	s.pendingJump = false
	s.pendingEvents = {}
	s.pendingFeedback = {}
	s.pendingPivot = false
	return out
end

return MovementSim
