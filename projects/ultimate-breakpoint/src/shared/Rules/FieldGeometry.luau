--!strict
--[[
	FieldGeometry — boundaries, end zones and spots on an axis-aligned field.

	Layout (top view, +X = East):

	   West end zone |        playing field proper        | East end zone
	  x: -half-ez .. -half   -half .. +half             +half .. +half+ez
	  z: -width/2 .. +width/2

	Lines are part of out-of-bounds in real ultimate; here the line itself is
	treated as in-bounds for readability on a Roblox field (documented).

	Line-ups: before the pull each team stands in the end zone it defends, on
	evenly spaced spots 2 studs behind its goal line. The line spans 12 studs
	per player (at most the width minus 8 studs at each sideline): 7 players
	stand 14 studs apart on the Normal field, 3 players 18 apart on Mini.
	Until the pull is released a player must stay behind that goal line:
	lineRestriction gives the (UBLineX, UBLineSide) half-plane the client
	clamps to, and offsideBy / behindLine let the server pull stragglers back.

	Benches: substitutes wait on the -Z sideline, team A's bench on the West
	half and team B's on the East half (benchCenter / benchSpots).
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

-- Line-up span per player (studs), and the room kept free at each sideline.
FieldGeometry.LineupPitch = 12
FieldGeometry.LineupSidelineGap = 8

-- World X of the goal line in front of the end zone on `side`.
function FieldGeometry.goalLineX(f: Field, side: Side): number
	return f.center.X + (if side == "East" then f.halfLength else -f.halfLength)
end

-- +1 for East, -1 for West: the X direction that points from the field into
-- that end zone.
function FieldGeometry.sideSign(side: Side): number
	return if side == "East" then 1 else -1
end

-- The pre-pull restriction for a team lining up in the end zone on `side`, as
-- the character attributes (UBLineX, UBLineSide): the player must keep
-- (pos.X - lineX) * lineSide >= 0, i.e. stay on or behind the goal line.
function FieldGeometry.lineRestriction(f: Field, side: Side): (number, number)
	return FieldGeometry.goalLineX(f, side), FieldGeometry.sideSign(side)
end

-- How far (studs, >= 0) pos is past the goal line of `side` into the field.
function FieldGeometry.offsideBy(f: Field, pos: Vector3, side: Side): number
	return math.max(0, -(pos.X - FieldGeometry.goalLineX(f, side)) * FieldGeometry.sideSign(side))
end

-- pos moved straight back so it is `inset` studs behind the goal line of
-- `side` (unchanged when it already is), kept inside the end zone and the
-- sidelines. Height is kept.
function FieldGeometry.behindLine(f: Field, pos: Vector3, side: Side, inset: number?): Vector3
	local i = inset or 1
	local sign = FieldGeometry.sideSign(side)
	local lineX = FieldGeometry.goalLineX(f, side)
	local depth = (pos.X - lineX) * sign
	local x = pos.X
	if depth < i then
		x = lineX + sign * math.min(i, f.endZone)
	end
	local backX = lineX + sign * f.endZone
	if (x - backX) * sign > 0 then
		x = backX
	end
	local z = math.clamp(pos.Z, f.center.Z - f.halfWidth + 1, f.center.Z + f.halfWidth - 1)
	return Vector3.new(x, pos.Y, z)
end

-- Distance (studs) between the outermost spots of a line-up of `count`.
function FieldGeometry.lineupSpan(f: Field, count: number): number
	if count <= 1 then
		return 0
	end
	local room = math.max(0, f.width - 2 * FieldGeometry.LineupSidelineGap)
	return math.min(room, count * FieldGeometry.LineupPitch)
end

-- Evenly spaced line-up spots 2 studs behind a team's goal line, centred
-- across the field (index 1 is the -Z end).
function FieldGeometry.lineup(f: Field, side: Side, count: number): { Vector3 }
	local spots = {}
	local x = if side == "East" then f.halfLength + 2 else -f.halfLength - 2
	local span = FieldGeometry.lineupSpan(f, count)
	for i = 1, count do
		local t = if count == 1 then 0.5 else (i - 1) / (count - 1)
		local z = -span / 2 + span * t
		table.insert(spots, FieldGeometry.toWorld(f, x, z))
	end
	return spots
end

-- Spot `index` (clamped to 1..count) of a line-up of `count` on `side`.
function FieldGeometry.lineupSpot(f: Field, side: Side, index: number, count: number): Vector3
	local n = math.max(1, count)
	return FieldGeometry.lineup(f, side, n)[math.clamp(index, 1, n)]
end

-- Benches sit 14 studs outside the -Z sideline, centred at 18 % of the
-- playing length from midfield; `sign` -1 = West half (team A), +1 = East
-- half (team B).
FieldGeometry.BenchOffset = 14
FieldGeometry.BenchFraction = 0.18

function FieldGeometry.benchCenter(f: Field, sign: number): Vector3
	local s = if sign < 0 then -1 else 1
	return FieldGeometry.toWorld(
		f,
		s * FieldGeometry.BenchFraction * f.length,
		-(f.halfWidth + FieldGeometry.BenchOffset)
	)
end

-- `count` spots along a bench, 4 studs apart, centred on benchCenter.
function FieldGeometry.benchSpots(f: Field, sign: number, count: number): { Vector3 }
	local c = FieldGeometry.benchCenter(f, sign)
	local spots = {}
	for i = 1, count do
		local dx = (i - (count + 1) / 2) * 4
		table.insert(spots, c + Vector3.new(dx, 0, 0))
	end
	return spots
end

-- Unit direction (+X or -X) a team attacking `side` runs toward.
function FieldGeometry.attackDirection(side: Side): Vector3
	return if side == "East" then Vector3.new(1, 0, 0) else Vector3.new(-1, 0, 0)
end

return FieldGeometry
