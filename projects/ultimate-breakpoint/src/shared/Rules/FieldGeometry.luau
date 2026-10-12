--!strict
--[[
	FieldGeometry — boundaries, end zones and spots on an axis-aligned field.

	Layout (top view, +X = East):

	   West end zone |        playing field proper        | East end zone
	  x: -half-ez .. -half   -half .. +half             +half .. +half+ez
	  z: -width/2 .. +width/2

	Lines are part of out-of-bounds in real ultimate; here the line itself is
	treated as in-bounds for readability on a Roblox field (documented).
]]

local FieldGeometry = {}

export type Side = "East" | "West"

export type Field = {
	center: Vector3,
	groundY: number,
	width: number,
	length: number, -- playing field proper
	endZone: number,
	brick: number, -- distance of the brick mark from the goal line
	halfLength: number,
	halfWidth: number,
}

export type Spec = {
	center: Vector3,
	width: number,
	length: number,
	endZone: number,
	brick: number?,
}

function FieldGeometry.new(spec: Spec): Field
	return {
		center = spec.center,
		groundY = spec.center.Y,
		width = spec.width,
		length = spec.length,
		endZone = spec.endZone,
		brick = spec.brick or math.floor(spec.length * 0.2),
		halfLength = spec.length / 2,
		halfWidth = spec.width / 2,
	}
end

local function localXZ(f: Field, pos: Vector3): (number, number)
	return pos.X - f.center.X, pos.Z - f.center.Z
end

function FieldGeometry.other(side: Side): Side
	return if side == "East" then "West" else "East"
end

function FieldGeometry.inBounds(f: Field, pos: Vector3): boolean
	local x, z = localXZ(f, pos)
	return math.abs(x) <= f.halfLength + f.endZone and math.abs(z) <= f.halfWidth
end

function FieldGeometry.inEndZone(f: Field, pos: Vector3, side: Side): boolean
	if not FieldGeometry.inBounds(f, pos) then
		return false
	end
	local x = pos.X - f.center.X
	if side == "East" then
		return x > f.halfLength
	end
	return x < -f.halfLength
end

-- "East" | "West" | "Field" | "Out"
function FieldGeometry.region(f: Field, pos: Vector3): string
	if not FieldGeometry.inBounds(f, pos) then
		return "Out"
	end
	if FieldGeometry.inEndZone(f, pos, "East") then
		return "East"
	elseif FieldGeometry.inEndZone(f, pos, "West") then
		return "West"
	end
	return "Field"
end

function FieldGeometry.toWorld(f: Field, x: number, z: number): Vector3
	return Vector3.new(f.center.X + x, f.groundY, f.center.Z + z)
end

-- Nearest in-bounds ground point.
function FieldGeometry.clampInBounds(f: Field, pos: Vector3, inset: number?): Vector3
	local i = inset or 1
	local x, z = localXZ(f, pos)
	local maxX = f.halfLength + f.endZone - i
	local maxZ = f.halfWidth - i
	return FieldGeometry.toWorld(f, math.clamp(x, -maxX, maxX), math.clamp(z, -maxZ, maxZ))
end

-- Point on the goal line of `side` closest to pos (in bounds).
function FieldGeometry.goalLinePoint(f: Field, pos: Vector3, side: Side): Vector3
	local _, z = localXZ(f, pos)
	local x = if side == "East" then f.halfLength else -f.halfLength
	return FieldGeometry.toWorld(f, x, math.clamp(z, -f.halfWidth + 1, f.halfWidth - 1))
end

-- Brick mark in front of the end zone on `side` (the end zone a team defends).
function FieldGeometry.brickPoint(f: Field, side: Side): Vector3
	local x = if side == "East" then f.halfLength - f.brick else -f.halfLength + f.brick
	return FieldGeometry.toWorld(f, x, 0)
end

function FieldGeometry.endZoneCenter(f: Field, side: Side): Vector3
	local x = (f.halfLength + f.endZone / 2) * (if side == "East" then 1 else -1)
	return FieldGeometry.toWorld(f, x, 0)
end

-- Where a turnover is put into play: in bounds, and pulled out of an end zone
-- onto its goal line.
function FieldGeometry.turnoverSpot(f: Field, pos: Vector3): Vector3
	local p = FieldGeometry.clampInBounds(f, pos, 1)
	local region = FieldGeometry.region(f, p)
	if region == "East" or region == "West" then
		return FieldGeometry.goalLinePoint(f, p, region :: Side)
	end
	return p
end

-- Point where the segment from -> to first leaves the field (for discs that
-- fly out of bounds). Falls back to clamping `to`.
function FieldGeometry.exitPoint(f: Field, from: Vector3, to: Vector3): Vector3
	if not FieldGeometry.inBounds(f, from) then
		return FieldGeometry.clampInBounds(f, to)
	end
	local lo, hi = 0, 1
	for _ = 1, 20 do
		local mid = (lo + hi) / 2
		local p = from:Lerp(to, mid)
		if FieldGeometry.inBounds(f, p) then
			lo = mid
		else
			hi = mid
		end
	end
	return FieldGeometry.clampInBounds(f, from:Lerp(to, lo), 1)
end

-- Evenly spaced line-up spots on a team's goal line, facing the field.
function FieldGeometry.lineup(f: Field, side: Side, count: number): { Vector3 }
	local spots = {}
	local x = if side == "East" then f.halfLength + 2 else -f.halfLength - 2
	local span = math.min(f.width - 10, count * 9)
	for i = 1, count do
		local t = if count == 1 then 0.5 else (i - 1) / (count - 1)
		local z = -span / 2 + span * t
		table.insert(spots, FieldGeometry.toWorld(f, x, z))
	end
	return spots
end

-- Unit direction (+X or -X) a team attacking `side` runs toward.
function FieldGeometry.attackDirection(side: Side): Vector3
	return if side == "East" then Vector3.new(1, 0, 0) else Vector3.new(-1, 0, 0)
end

return FieldGeometry
