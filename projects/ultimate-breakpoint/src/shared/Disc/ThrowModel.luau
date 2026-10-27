--!strict
--[[
	ThrowModel — turns a player's throw inputs into a disc launch state.

	Inputs that matter (all deterministic, no hidden accuracy roll):
	  throw type      Backhand / Forehand / Hammer / Scoober / Blade
	  aim yaw/pitch   from the camera
	  hold time       charge -> power; releasing in the Perfect window at full
	                  charge gives +speed and +spin; holding too long (Over)
	                  bleeds spin, which makes the disc roll more (turn/fade)
	  bank            -1..1, tilts the disc so lift curves the flight
	  release height  High (hop / over the mark), Mid, Low (step-out under the mark)
	  pivot + step    where the disc leaves the hand (see below)
	  balance         throwing airborne / from the ground / on the run costs
	                  power cap and spin; releasing mid Quick Swing costs spin

	Release point. With a planted pivot foot P (params.pivot) the disc leaves
	from P + step + side/height offsets, where step is the flat free-foot vector
	(|step| <= StepRadius, forward part <= ForwardMax * R, back <= BackMax * R,
	all from Config/Movement.Holding). Lateral = Side * PivotSideScale, plus
	LowReach to the throw's side for a Low release; height = the release
	height (or OverheadHeight) plus the hop: how far the root is above P.
	Lag on the thrower's body therefore never moves the release; only P and
	the step do. A planted pivot has no run-up, so thrower velocity carry and
	the moving-spin penalty only apply without a pivot (a release on the run
	or during the slow-down), which still uses root-relative offsets.
	Left-handed throwers mirror every side offset; the step is a world vector
	and is never mirrored (the foot is where it is).
]]

local Shared = script.Parent.Parent
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(script.Parent.DiscPhysics)

local T = DiscConfig.Throw
local HD = MovementConfig.Holding

local ThrowModel = {}

export type Params = {
	throwType: string,
	yaw: number, -- radians, 0 = -Z
	pitch: number, -- radians, aim elevation (type offset is added here)
	holdTime: number, -- seconds the throw was charged
	bank: number, -- -1..1
	height: string, -- "High" | "Mid" | "Low"
	offBalance: boolean?,
	groundThrow: boolean?,
	leftHanded: boolean?,
	pivot: Vector3?, -- planted pivot foot P (root height); nil = release from the root
	step: Vector3?, -- flat free-foot step from P (world); ignored without a pivot
	swinging: boolean?, -- released while a Quick Swing is still moving the step
	-- Carried through sanitize for ThrowService; the model itself ignores them.
	releaseT: number?, -- client Net.now() at release
	rootPos: Vector3?, -- client root position at release
}

export type Launch = {
	state: DiscPhysics.State,
	releasePos: Vector3,
	velocity: Vector3,
	normal: Vector3,
	quality: string, -- "Perfect" | "Clean" | "Over"
	power: number,
	spinFactor: number,
	speed: number,
	pitchDeg: number,
	bankDeg: number,
}

local VALID_HEIGHTS = { High = true, Mid = true, Low = true }
local UP = Vector3.new(0, 1, 0)

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

local function finiteVector(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local p = v :: Vector3
	if finite(p.X) and finite(p.Y) and finite(p.Z) then
		return p
	end
	return nil
end

function ThrowModel.typeInfo(throwType: string): any
	return (DiscConfig.Types :: any)[throwType] or DiscConfig.Types.Backhand
end

function ThrowModel.basis(yaw: number): (Vector3, Vector3)
	local forward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	return forward, right
end

-- Charge time -> (power, quality, spinFactor). Power rises linearly to full at
-- ChargeTime (scaled by the throw's ChargeMult). Releasing inside the Perfect
-- window at full charge is a Perfect release.
function ThrowModel.charge(holdTime: number, throwType: string): (number, string, number)
	local info = ThrowModel.typeInfo(throwType)
	local t = math.max(0, holdTime) * (info.ChargeMult or 1)
	if t < T.ChargeTime then
		return math.clamp(t / T.ChargeTime, 0, 1), "Clean", 1
	end
	local over = t - T.ChargeTime
	if over <= T.PerfectWindow then
		return 1, "Perfect", T.PerfectSpinMult
	end
	local spin = math.max(T.MinOverSpin, 1 - (over - T.PerfectWindow) * T.OverchargeDecay)
	return 1, "Over", spin
end

-- Clamps any value into a legal step for aim `yaw`: a flat Vector3 with
-- |step| <= StepRadius and its forward part in [-BackMax, ForwardMax] * R
-- (the same limits MovementSim uses). Junk, NaN or infinity -> zero.
function ThrowModel.clampStep(step: any, yaw: number): Vector3
	local v = finiteVector(step)
	if not v then
		return Vector3.zero
	end
	local R = HD.StepRadius
	local forward, right = ThrowModel.basis(if finite(yaw) then yaw else 0)
	local f = v.X * forward.X + v.Z * forward.Z
	local l = v.X * right.X + v.Z * right.Z
	local len = math.sqrt(f * f + l * l)
	if len > R then
		f, l = f * R / len, l * R / len
	end
	f = math.clamp(f, -HD.BackMax * R, HD.ForwardMax * R)
	return forward * f + right * l
end

-- The step implied by where the root actually is: the root sits at
-- P + BodyShare * step, so step = (root - P) / BodyShare (clamped).
function ThrowModel.stepFromRoot(rootPos: Vector3, pivot: Vector3, yaw: number): Vector3
	local d = rootPos - pivot
	return ThrowModel.clampStep(Vector3.new(d.X, 0, d.Z) / HD.BodyShare, yaw)
end

-- Server check of a client's step. Accepts the (clamped) claimed step when the
-- server's view of the root is within StepCheckBase + StepCheckPing *
-- min(ping, StepCheckMaxPing) of P + BodyShare * step (flat distance);
-- otherwise falls back to the step implied by the server root.
-- Returns (step to use, accepted).
function ThrowModel.resolveStep(
	claimed: any,
	pivot: Vector3,
	serverRoot: Vector3,
	ping: number,
	yaw: number
): (Vector3, boolean)
	local s = ThrowModel.clampStep(claimed, yaw)
	local expected = pivot + s * HD.BodyShare
	local lag = if finite(ping) then math.clamp(ping, 0, T.StepCheckMaxPing) else 0
	-- plus the distance a body driven toward P + BodyShare*step can still be
	-- behind its target (DriveMax / DriveGain) when the step just moved
	local tolerance = T.StepCheckBase + T.StepCheckPing * lag + HD.DriveMax / HD.DriveGain
	local off = serverRoot - expected
	if Vector3.new(off.X, 0, off.Z).Magnitude <= tolerance then
		return s, true
	end
	return ThrowModel.stepFromRoot(serverRoot, pivot, yaw), false
end

-- Clamps untrusted client parameters into the legal range.
function ThrowModel.sanitize(raw: any): Params?
	if type(raw) ~= "table" then
		return nil
	end
	local throwType = if type(raw.throwType) == "string" and (DiscConfig.Types :: any)[raw.throwType]
		then raw.throwType
		else nil
	if not throwType then
		return nil
	end
	local function num(v: any, lo: number, hi: number, default: number): number
		if type(v) ~= "number" or not finite(v) then
			return default
		end
		return math.clamp(v, lo, hi)
	end
	local yaw = num(raw.yaw, -1000, 1000, 0)
	local releaseT = raw.releaseT
	return {
		throwType = throwType,
		yaw = yaw,
		pitch = num(raw.pitch, math.rad(-80), math.rad(80), 0),
		holdTime = num(raw.holdTime, 0, 5, 0),
		bank = num(raw.bank, -1, 1, 0),
		height = if type(raw.height) == "string" and VALID_HEIGHTS[raw.height] then raw.height else "Mid",
		offBalance = raw.offBalance == true,
		groundThrow = raw.groundThrow == true,
		leftHanded = raw.leftHanded == true,
		pivot = finiteVector(raw.pivot),
		step = ThrowModel.clampStep(raw.step, yaw),
		swinging = raw.swinging == true,
		releaseT = if type(releaseT) == "number" and finite(releaseT) then releaseT else nil,
		rootPos = finiteVector(raw.rootPos),
	}
end

-- Where the disc leaves the hand. With p.pivot: from the pivot plus the step
-- (see the header); `rootPos` then only supplies the hop height. Without a
-- pivot (or for a throw from the ground after a layout): relative to the
-- root part, as on the run.
function ThrowModel.releasePosition(p: Params, rootPos: Vector3): Vector3
	local info = ThrowModel.typeInfo(p.throwType)
	local forward, right = ThrowModel.basis(p.yaw)
	local mirror = if p.leftHanded then -1 else 1
	local heightUp = (DiscConfig.Heights :: any)[p.height] or DiscConfig.Heights.Mid

	local pivot = p.pivot
	if pivot and not p.groundThrow then
		local step = ThrowModel.clampStep(p.step, p.yaw)
		local hop = math.clamp(rootPos.Y - pivot.Y, 0, T.MaxHopLift)
		if hop ~= hop then
			hop = 0
		end
		local lateral = info.Side * T.PivotSideScale
		local up: number
		if info.Overhead then
			up = DiscConfig.OverheadHeight
		else
			up = heightUp
			if p.height == "Low" then
				lateral += T.LowReach * (if info.Side >= 0 then 1 else -1)
			end
		end
		return pivot + step + right * (lateral * mirror) + UP * (up + hop) + forward * T.ReleaseForward
	end

	local side: number
	local up: number
	if info.Overhead then
		side = info.Side
		up = DiscConfig.OverheadHeight + (if p.height == "High" then 0.6 else 0)
	elseif p.height == "Low" then
		side = info.LowSide
		up = DiscConfig.Heights.Low
	else
		side = info.Side
		up = heightUp
	end
	if p.groundThrow then
		up = -1.9
	end
	return rootPos + right * (side * mirror) + UP * up + forward * T.ReleaseForward
end

function ThrowModel.launch(p: Params, rootPos: Vector3, throwerVel: Vector3): Launch
	local info = ThrowModel.typeInfo(p.throwType)
	local mirror = if p.leftHanded then -1 else 1
	local pivoting = p.pivot ~= nil and not p.groundThrow

	local power, quality, spinFactor = ThrowModel.charge(p.holdTime, p.throwType)
	if p.offBalance then
		power = math.min(power, T.OffBalancePowerCap)
		spinFactor *= T.OffBalanceSpin
		if quality == "Perfect" then
			quality = "Clean"
		end
	end
	if p.groundThrow then
		power = math.min(power, T.GroundThrowPowerCap)
		spinFactor *= T.OffBalanceSpin
		if quality == "Perfect" then
			quality = "Clean"
		end
	end
	-- On the run: spin cost above a jog plus some of the run-up carried. From
	-- a pivot the root only shuffles around P, so neither applies; a release
	-- mid swing costs SwingSpinPenalty instead (power is never capped).
	local carry = Vector3.zero
	if not pivoting then
		local flat = Vector3.new(throwerVel.X, 0, throwerVel.Z)
		if flat.Magnitude ~= flat.Magnitude then
			flat = Vector3.zero
		end
		if flat.Magnitude > T.MovingSpinPenaltySpeed then
			spinFactor *= T.MovingSpinPenalty
		end
		carry = flat * T.ThrowerVelocityCarry
	end
	if p.swinging then
		spinFactor *= T.SwingSpinPenalty
	end

	local minPitch = if info.Overhead then 10 else T.MinPitch
	local maxPitch = if info.Overhead then 72 else T.MaxPitch
	local pitchDeg = math.clamp(math.deg(p.pitch) + info.PitchOffset, minPitch, maxPitch)
	local pitch = math.rad(pitchDeg)

	local speed = (T.MinSpeed + (T.MaxSpeed - T.MinSpeed) * (power ^ T.PowerCurve)) * info.SpeedMult
	if quality == "Perfect" then
		speed *= T.PerfectSpeedMult
	end

	local forward, right = ThrowModel.basis(p.yaw)
	local dir = forward * math.cos(pitch) + UP * math.sin(pitch)

	-- Orientation: start flat relative to the flight path, bank about the
	-- flight direction, then tilt the nose by the throw's release angle.
	local bankDeg = (info.Bank + p.bank * T.BankRange) * mirror
	local beta = math.rad(bankDeg)
	local alpha = math.rad(info.Alpha)
	local n0 = UP * math.cos(pitch) - forward * math.sin(pitch)
	local nRot = n0 * math.cos(beta) + right * math.sin(beta)
	local normal = (nRot * math.cos(alpha) - dir * math.sin(alpha)).Unit

	local velocity = dir * speed + carry
	local releasePos = ThrowModel.releasePosition(p, rootPos)
	local spin = T.SpinBase * spinFactor * info.Spin * mirror

	return {
		state = DiscPhysics.fromVectors(releasePos, velocity, normal, spin),
		releasePos = releasePos,
		velocity = velocity,
		normal = normal,
		quality = quality,
		power = power,
		spinFactor = spinFactor,
		speed = speed,
		pitchDeg = pitchDeg,
		bankDeg = bankDeg,
	}
end

return ThrowModel
