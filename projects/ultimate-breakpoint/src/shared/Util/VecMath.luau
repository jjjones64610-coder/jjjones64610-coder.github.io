--!strict
-- Small, allocation-light vector helpers shared by movement, catching and AI.
-- Everything here is pure math so it runs identically on client, server and in
-- the offline Lune test harness.

local VecMath = {}

local EPS = 1e-6

function VecMath.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function VecMath.flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	local m = f.Magnitude
	if m < EPS then
		return Vector3.zero
	end
	return f / m
end

function VecMath.safeUnit(v: Vector3, fallback: Vector3?): Vector3
	local m = v.Magnitude
	if m < EPS then
		return fallback or Vector3.zero
	end
	return v / m
end

function VecMath.clampMagnitude(v: Vector3, maxLen: number): Vector3
	local m = v.Magnitude
	if m > maxLen and m > EPS then
		return v * (maxLen / m)
	end
	return v
end

-- Moves vector `from` toward `to` by at most `maxDelta` (length of change).
function VecMath.moveToward(from: Vector3, to: Vector3, maxDelta: number): Vector3
	local d = to - from
	local m = d.Magnitude
	if m <= maxDelta or m < EPS then
		return to
	end
	return from + d * (maxDelta / m)
end

-- Unsigned angle between two horizontal directions, in degrees (0..180).
function VecMath.flatAngle(a: Vector3, b: Vector3): number
	local ax, az = a.X, a.Z
	local bx, bz = b.X, b.Z
	local dot = ax * bx + az * bz
	local cross = ax * bz - az * bx
	return math.deg(math.abs(math.atan2(cross, dot)))
end

-- Signed yaw (radians) of a horizontal direction; 0 = -Z (Roblox forward).
function VecMath.yaw(v: Vector3): number
	return math.atan2(-v.X, -v.Z)
end

function VecMath.fromYaw(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

-- Rotates horizontal unit vector `dir` toward horizontal unit vector `target`
-- by at most `maxDeg` degrees. Returns a horizontal unit vector.
function VecMath.rotateToward(dir: Vector3, target: Vector3, maxDeg: number): Vector3
	local a = VecMath.yaw(dir)
	local b = VecMath.yaw(target)
	local diff = (b - a + math.pi) % (2 * math.pi) - math.pi
	local maxRad = math.rad(maxDeg)
	if math.abs(diff) <= maxRad then
		return VecMath.fromYaw(b)
	end
	return VecMath.fromYaw(a + math.sign(diff) * maxRad)
end

-- Reflects horizontal velocity off a (horizontal) wall normal.
function VecMath.reflect(v: Vector3, normal: Vector3): Vector3
	return v - normal * (2 * v:Dot(normal))
end

-- Closest point on segment [a, b] to point p.
function VecMath.closestOnSegment(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < EPS then
		return a
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return a + ab * t
end

function VecMath.lerpNumber(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Frame-rate independent exponential smoothing factor.
function VecMath.smoothAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

return VecMath
