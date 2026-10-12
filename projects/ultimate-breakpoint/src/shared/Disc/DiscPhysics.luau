--!strict
--[[
	DiscPhysics — deterministic flying-disc simulation.

	State is stored as plain numbers (doubles), not Vector3 (float32), so the
	server and every client step the exact same arithmetic from the same launch
	values. Launch values are themselves read back from replicated attributes,
	so all machines start from bit-identical inputs.

	Forces (per unit mass):
	  gravity      (0, -g, 0)
	  lift         K |v|^2 CL(alpha) along the disc normal's component
	               perpendicular to the airflow  -> banking curves the flight
	  drag         K |v|^2 CD(alpha) against the airflow
	Orientation:
	  The spin axis is gyroscopically stable; the aerodynamic pitching moment
	  CM(alpha) makes it precess (roll) at a rate proportional to |v|^2 / spin.
	  CM < 0 at low alpha (fast, flat flight) rolls the disc one way ("turn"),
	  CM > 0 at high alpha (slow, descending) the other ("fade"). Spin sign
	  decides which way is which, so a right-handed backhand turns right early
	  and fades left late, and a forehand mirrors it. More spin = less roll =
	  a more stable line, which is why a clean release matters.
	  Wind enters through the airflow vector (velocity relative to the air).
]]

local Shared = script.Parent.Parent
local DiscConfig = require(Shared.Config.Disc)

local P = DiscConfig.Physics

local DiscPhysics = {}

export type State = {
	px: number,
	py: number,
	pz: number,
	vx: number,
	vy: number,
	vz: number,
	nx: number,
	ny: number,
	nz: number,
	spin: number,
	t: number,
}

export type Wind = { x: number, y: number, z: number }

local NO_WIND: Wind = { x = 0, y = 0, z = 0 }

local sqrt = math.sqrt
local asin = math.asin
local clamp = math.clamp
local abs = math.abs

function DiscPhysics.new(
	px: number,
	py: number,
	pz: number,
	vx: number,
	vy: number,
	vz: number,
	nx: number,
	ny: number,
	nz: number,
	spin: number
): State
	local nm = sqrt(nx * nx + ny * ny + nz * nz)
	if nm < 1e-9 then
		nx, ny, nz, nm = 0, 1, 0, 1
	end
	return {
		px = px,
		py = py,
		pz = pz,
		vx = vx,
		vy = vy,
		vz = vz,
		nx = nx / nm,
		ny = ny / nm,
		nz = nz / nm,
		spin = spin,
		t = 0,
	}
end

function DiscPhysics.fromVectors(pos: Vector3, vel: Vector3, normal: Vector3, spin: number): State
	return DiscPhysics.new(pos.X, pos.Y, pos.Z, vel.X, vel.Y, vel.Z, normal.X, normal.Y, normal.Z, spin)
end

function DiscPhysics.copy(s: State): State
	return {
		px = s.px,
		py = s.py,
		pz = s.pz,
		vx = s.vx,
		vy = s.vy,
		vz = s.vz,
		nx = s.nx,
		ny = s.ny,
		nz = s.nz,
		spin = s.spin,
		t = s.t,
	}
end

function DiscPhysics.position(s: State): Vector3
	return Vector3.new(s.px, s.py, s.pz)
end

function DiscPhysics.velocity(s: State): Vector3
	return Vector3.new(s.vx, s.vy, s.vz)
end

function DiscPhysics.normal(s: State): Vector3
	return Vector3.new(s.nx, s.ny, s.nz)
end

function DiscPhysics.speed(s: State): number
	return sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
end

local function liftCoefficient(alpha: number): number
	local a = abs(alpha)
	if a <= P.StallAlpha then
		return P.CL0 + P.CLa * alpha
	end
	local edge = P.CL0 + P.CLa * P.StallAlpha * (if alpha >= 0 then 1 else -1)
	local fall = 1 - (a - P.StallAlpha) / (math.pi / 2 - P.StallAlpha)
	return edge * clamp(fall, 0, 1)
end

-- Angle of attack (radians) of the disc for a given airflow direction.
function DiscPhysics.alpha(s: State, wind: Wind?): number
	local w = wind or NO_WIND
	local ax, ay, az = s.vx - w.x, s.vy - w.y, s.vz - w.z
	local sp = sqrt(ax * ax + ay * ay + az * az)
	if sp < 1e-6 then
		return 0
	end
	local d = (s.nx * ax + s.ny * ay + s.nz * az) / sp
	return -asin(clamp(d, -1, 1))
end

-- Advances the state in place by dt seconds.
function DiscPhysics.step(s: State, dt: number, wind: Wind?)
	local w = wind or NO_WIND
	local ax, ay, az = s.vx - w.x, s.vy - w.y, s.vz - w.z
	local speed2 = ax * ax + ay * ay + az * az
	local fx, fy, fz = 0, -P.Gravity, 0

	if speed2 > 1e-4 then
		local speed = sqrt(speed2)
		local ux, uy, uz = ax / speed, ay / speed, az / speed
		local nx, ny, nz = s.nx, s.ny, s.nz
		local nDotU = nx * ux + ny * uy + nz * uz
		local alpha = -asin(clamp(nDotU, -1, 1))
		local q = P.AirK * speed2

		-- lift: along n with the airflow component removed
		local lx, ly, lz = nx - nDotU * ux, ny - nDotU * uy, nz - nDotU * uz
		local lm = sqrt(lx * lx + ly * ly + lz * lz)
		if lm > 1e-6 then
			local lift = q * liftCoefficient(alpha) / lm
			fx += lift * lx
			fy += lift * ly
			fz += lift * lz
		end

		-- drag
		local da = alpha - P.Alpha0
		local cd = math.min(P.CD0 + P.CDa * da * da, P.CDMax)
		local drag = q * cd
		fx -= drag * ux
		fy -= drag * uy
		fz -= drag * uz

		-- gyroscopic precession of the spin axis
		local spin = s.spin
		if abs(spin) < P.MinSpin then
			spin = if spin >= 0 then P.MinSpin else -P.MinSpin
		end
		local fpx, fpy, fpz = ux - nDotU * nx, uy - nDotU * ny, uz - nDotU * nz
		local fm = sqrt(fpx * fpx + fpy * fpy + fpz * fpz)
		if fm > 1e-6 then
			fpx, fpy, fpz = fpx / fm, fpy / fm, fpz / fm
			-- f x n : the direction the normal moves for a nose-up moment
			local cx = fpy * nz - fpz * ny
			local cy = fpz * nx - fpx * nz
			local cz = fpx * ny - fpy * nx
			local cm = P.CM0 + P.CMa * clamp(alpha, -P.StallAlpha, P.StallAlpha)
			local rate = P.RollK * speed2 * cm / spin
			nx += cx * rate * dt
			ny += cy * rate * dt
			nz += cz * rate * dt
			local nm = sqrt(nx * nx + ny * ny + nz * nz)
			s.nx, s.ny, s.nz = nx / nm, ny / nm, nz / nm
		end
	end

	-- semi-implicit Euler
	s.vx += fx * dt
	s.vy += fy * dt
	s.vz += fz * dt
	s.px += s.vx * dt
	s.py += s.vy * dt
	s.pz += s.vz * dt
	s.spin *= (1 - P.SpinDecay * dt)
	s.t += dt
end

export type Sample = { t: number, x: number, y: number, z: number }

export type Result = {
	samples: { Sample },
	landed: boolean,
	landT: number,
	landX: number,
	landY: number,
	landZ: number,
	maxHeight: number,
	final: State,
}

-- Simulates from `start` (not modified) until ground contact or maxTime,
-- recording a sample every `sampleEvery` steps.
function DiscPhysics.simulate(
	start: State,
	maxTime: number?,
	wind: Wind?,
	groundY: number?,
	sampleEvery: number?
): Result
	local s = DiscPhysics.copy(start)
	local dt = P.Dt
	local limit = maxTime or P.MaxFlightTime
	local ground = (groundY or 0) + P.GroundContact
	local every = sampleEvery or 1
	local samples: { Sample } = { { t = s.t, x = s.px, y = s.py, z = s.pz } }
	local steps = 0
	local maxH = s.py
	local landed = false
	while s.t < limit do
		local ox, oy, oz = s.px, s.py, s.pz
		DiscPhysics.step(s, dt, wind)
		steps += 1
		if s.py > maxH then
			maxH = s.py
		end
		if s.py <= ground then
			-- interpolate the exact contact point inside this step
			local f = if oy - s.py > 1e-9 then (oy - ground) / (oy - s.py) else 1
			f = clamp(f, 0, 1)
			s.px = ox + (s.px - ox) * f
			s.pz = oz + (s.pz - oz) * f
			s.py = ground
			s.t = s.t - dt + dt * f
			landed = true
			table.insert(samples, { t = s.t, x = s.px, y = s.py, z = s.pz })
			break
		end
		if steps % every == 0 then
			table.insert(samples, { t = s.t, x = s.px, y = s.py, z = s.pz })
		end
	end
	return {
		samples = samples,
		landed = landed,
		landT = s.t,
		landX = s.px,
		landY = s.py,
		landZ = s.pz,
		maxHeight = maxH,
		final = s,
	}
end

-- Advances a state forward to absolute flight time `t` using fixed steps.
-- Returns false if the disc reached the ground first.
function DiscPhysics.advanceTo(s: State, t: number, wind: Wind?, groundY: number?): boolean
	local dt = P.Dt
	local ground = (groundY or 0) + P.GroundContact
	while s.t + dt <= t + 1e-9 do
		DiscPhysics.step(s, dt, wind)
		if s.py <= ground then
			s.py = ground
			return false
		end
	end
	return true
end

-- Position at fractional time `t` between fixed steps (for smooth rendering):
-- linearly extrapolates from the current state, which must be at s.t <= t.
function DiscPhysics.positionAt(s: State, t: number): (number, number, number)
	local f = t - s.t
	return s.px + s.vx * f, s.py + s.vy * f, s.pz + s.vz * f
end

return DiscPhysics
