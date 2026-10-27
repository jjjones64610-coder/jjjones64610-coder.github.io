--!strict
--[[
	Solver — finds throw inputs that deliver the disc to a (possibly moving)
	receiver. Used by bots, by the training launcher, and by the optional
	Lead Pass assist (which only extrapolates the receiver's CURRENT velocity —
	it cannot predict a cut, so reading your receiver is still the skill).

	Strategy: coarse grid over (power, aim pitch) with a cheap low-rate sim,
	refine around the best cell, and correct yaw twice for the curve.

	A holder who has planted a pivot passes `pivot` (and optionally the
	`step` they will release from): the candidates are then launched from the
	pivot release point exactly as ThrowModel will launch the real throw, and
	the returned params carry both. The power grid spans the whole MinSpeed..
	MaxSpeed range, so short touch passes and full hucks are both found.
]]

local Shared = script.Parent.Parent
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(script.Parent.DiscPhysics)
local ThrowModel = require(script.Parent.ThrowModel)

local Solver = {}

export type Options = {
	rootPos: Vector3,
	throwerVel: Vector3?,
	throwType: string,
	bank: number?,
	height: string?,
	target: Vector3,
	targetVel: Vector3?,
	wind: DiscPhysics.Wind?,
	groundY: number?,
	leftHanded: boolean?,
	maxPower: number?,
	coarse: boolean?, -- smaller search for client-side assist
	flightTimeWeight: number?,
	pivot: Vector3?, -- planted pivot foot P: launch from P + step (see ThrowModel)
	step: Vector3?, -- flat step from P (ignored without a pivot)
}

export type Solution = {
	params: ThrowModel.Params,
	miss: number,
	flightTime: number,
	catchPoint: Vector3,
}

local function paramsFor(o: Options, yaw: number, pitch: number, holdTime: number): ThrowModel.Params
	return {
		throwType = o.throwType,
		yaw = yaw,
		pitch = pitch,
		holdTime = holdTime,
		bank = o.bank or 0,
		height = o.height or "Mid",
		leftHanded = o.leftHanded,
		pivot = o.pivot,
		step = if o.pivot then ThrowModel.clampStep(o.step, yaw) else nil,
	}
end

local function holdForPower(power: number, throwType: string): number
	local info = ThrowModel.typeInfo(throwType)
	local mult = info.ChargeMult or 1
	if power >= 0.999 then
		-- land inside the Perfect window
		return (DiscConfig.Throw.ChargeTime + DiscConfig.Throw.PerfectWindow * 0.5) / mult
	end
	return power * DiscConfig.Throw.ChargeTime / mult
end

-- Simulates one candidate; returns closest catchable approach to the moving
-- target: distance, time, lateral error (signed, relative to aim right).
local function evaluate(
	o: Options,
	yaw: number,
	pitch: number,
	power: number,
	dt: number
): (number, number, number, Vector3)
	local params = paramsFor(o, yaw, pitch, holdForPower(power, o.throwType))
	local launch = ThrowModel.launch(params, o.rootPos, o.throwerVel or Vector3.zero)
	local s = launch.state
	local ground = (o.groundY or 0)
	local tv = o.targetVel or Vector3.zero
	local tx, ty, tz = o.target.X, o.target.Y, o.target.Z
	local best, bestT = math.huge, 0
	local bx, by, bz = s.px, s.py, s.pz
	local limit = 6
	while s.t < limit do
		DiscPhysics.step(s, dt, o.wind)
		local h = s.py - ground
		if h <= DiscConfig.Physics.GroundContact then
			break
		end
		if h > 0.8 and h < 9.5 then
			local cx = tx + tv.X * s.t
			local cz = tz + tv.Z * s.t
			local dx, dy, dz = s.px - cx, s.py - ty, s.pz - cz
			local d = math.sqrt(dx * dx + dy * dy * 0.6 + dz * dz)
			if d < best then
				best, bestT = d, s.t
				bx, by, bz = s.px, s.py, s.pz
			end
		end
	end
	local _, right = ThrowModel.basis(yaw)
	local cxb = tx + tv.X * bestT
	local czb = tz + tv.Z * bestT
	local lateral = (bx - cxb) * right.X + (bz - czb) * right.Z
	return best, bestT, lateral, Vector3.new(bx, by, bz)
end

function Solver.solve(o: Options): Solution?
	local maxPower = o.maxPower or 1
	local flightW = o.flightTimeWeight or 0.6
	local tv = o.targetVel or Vector3.zero
	local origin = o.pivot or o.rootPos

	-- initial yaw toward a lead point
	local tGuess = (o.target - origin).Magnitude / 55
	local aim = o.target + Vector3.new(tv.X, 0, tv.Z) * tGuess
	local d = aim - origin
	local yaw = math.atan2(-d.X, -d.Z)

	local powers: { number } = {}
	local pitches: { number } = {}
	local dtCoarse: number
	if o.coarse then
		for p = 0.1, 1.0001, 0.15 do
			table.insert(powers, math.min(p, maxPower))
		end
		for a = -12, 30, 7 do
			table.insert(pitches, math.rad(a))
		end
		dtCoarse = 1 / 30
	else
		for p = 0.05, 1.0001, 0.095 do
			table.insert(powers, math.min(p, maxPower))
		end
		table.insert(powers, maxPower)
		for a = -14, 34, 4 do
			table.insert(pitches, math.rad(a))
		end
		dtCoarse = 1 / 40
	end

	local bestScore, bestMiss, bestT = math.huge, math.huge, 0
	local bestPower, bestPitch = 0.5, 0
	local bestPoint = o.target

	for iteration = 1, 3 do
		bestScore = math.huge
		for _, power in powers do
			for _, pitch in pitches do
				local miss, t, _, point = evaluate(o, yaw, pitch, power, dtCoarse)
				local score = miss + flightW * t
				if score < bestScore then
					bestScore, bestMiss, bestT = score, miss, t
					bestPower, bestPitch, bestPoint = power, pitch, point
				end
			end
		end
		-- refine around the best cell at the real step size
		local dt = DiscConfig.Physics.Dt
		local refinedScore = math.huge
		local rp, ra = bestPower, bestPitch
		for dp = -0.04, 0.0401, 0.02 do
			for da = -2, 2.001, 1 do
				local power = math.clamp(bestPower + dp, 0, maxPower)
				local pitch = bestPitch + math.rad(da)
				local miss, t, _, point = evaluate(o, yaw, pitch, power, dt)
				local score = miss + flightW * t
				if score < refinedScore then
					refinedScore, bestMiss, bestT = score, miss, t
					rp, ra, bestPoint = power, pitch, point
				end
			end
		end
		bestPower, bestPitch = rp, ra
		-- correct yaw for curve / lead
		local _, _, lateral = evaluate(o, yaw, bestPitch, bestPower, dt)
		local horiz = Vector3.new(bestPoint.X - origin.X, 0, bestPoint.Z - origin.Z).Magnitude
		if horiz < 1 or math.abs(lateral) < 0.4 or iteration == 3 then
			break
		end
		yaw += math.atan2(lateral, horiz)
		-- narrow the grid around the current solution for the next pass
		powers = {}
		pitches = {}
		for p = bestPower - 0.15, bestPower + 0.1501, 0.05 do
			if p >= 0 and p <= maxPower then
				table.insert(powers, p)
			end
		end
		for a = -6, 6.001, 2 do
			table.insert(pitches, bestPitch + math.rad(a))
		end
	end

	if bestMiss == math.huge then
		return nil
	end

	return {
		params = paramsFor(o, yaw, bestPitch, holdForPower(bestPower, o.throwType)),
		miss = bestMiss,
		flightTime = bestT,
		catchPoint = bestPoint,
	}
end

Solver.holdForPower = holdForPower

return Solver
