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
	  balance         throwing airborne / from the ground / on the move costs
	                  power cap and spin
]]

local Shared = script.Parent.Parent
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(script.Parent.DiscPhysics)

local T = DiscConfig.Throw

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

function ThrowModel.typeInfo(throwType: string): any
	return (DiscConfig.Types :: any)[throwType] or DiscConfig.Types.Backhand
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
		if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
			return default
		end
		return math.clamp(v, lo, hi)
	end
	return {
		throwType = throwType,
		yaw = num(raw.yaw, -1000, 1000, 0),
		pitch = num(raw.pitch, math.rad(-80), math.rad(80), 0),
		holdTime = num(raw.holdTime, 0, 5, 0),
		bank = num(raw.bank, -1, 1, 0),
		height = if type(raw.height) == "string" and VALID_HEIGHTS[raw.height] then raw.height else "Mid",
		offBalance = raw.offBalance == true,
		groundThrow = raw.groundThrow == true,
		leftHanded = raw.leftHanded == true,
	}
end

local UP = Vector3.new(0, 1, 0)

function ThrowModel.basis(yaw: number): (Vector3, Vector3)
	local forward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	return forward, right
end

-- Where the disc leaves the hand, relative to the thrower's root part.
function ThrowModel.releasePosition(p: Params, rootPos: Vector3): Vector3
	local info = ThrowModel.typeInfo(p.throwType)
	local forward, right = ThrowModel.basis(p.yaw)
	local mirror = if p.leftHanded then -1 else 1
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
		up = (DiscConfig.Heights :: any)[p.height] or DiscConfig.Heights.Mid
	end
	if p.groundThrow then
		up = -1.9
	end
	return rootPos + right * (side * mirror) + UP * up + forward * 0.8
end

function ThrowModel.launch(p: Params, rootPos: Vector3, throwerVel: Vector3): Launch
	local info = ThrowModel.typeInfo(p.throwType)
	local mirror = if p.leftHanded then -1 else 1

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
	local flatSpeed = Vector3.new(throwerVel.X, 0, throwerVel.Z).Magnitude
	if flatSpeed > T.MovingSpinPenaltySpeed then
		spinFactor *= T.MovingSpinPenalty
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

	local carry = Vector3.new(throwerVel.X, 0, throwerVel.Z) * T.ThrowerVelocityCarry
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
