--!strict
--[[
	CatchGeometry — readable, deterministic catch and block volumes.

	A player's catch envelope is a small set of capsules derived from their
	root position, facing and movement state:
	  Secure   sphere at the chest (always on; drops low while sliding)
	  Reach    capsule from the near shoulder along the aim direction, active
	           for a short window after pressing Reach (also used airborne for
	           the Aerial Catch Adjustment)
	  Dive     long capsule from the chest along the dive direction (Layout)

	A disc inside the inner part of a zone is a Clean catch; near the rim it is
	a Fingertip catch. Fingertip catches of fast or contested discs bobble —
	an explainable rule, not a dice roll.
]]

local Shared = script.Parent.Parent
local DiscConfig = require(Shared.Config.Disc)
local VecMath = require(Shared.Util.VecMath)

local C = DiscConfig.Catch
local M = DiscConfig.Mark

local CatchGeometry = {}

export type Zone = {
	kind: string, -- "Secure" | "Reach" | "Dive"
	a: Vector3,
	b: Vector3,
	radius: number,
}

export type BodyState = {
	root: Vector3,
	facing: Vector3, -- horizontal unit
	reaching: boolean,
	reachDir: Vector3?,
	diving: boolean,
	diveDir: Vector3?,
	sliding: boolean,
}

local UP = Vector3.new(0, 1, 0)

function CatchGeometry.zones(body: BodyState): { Zone }
	local zones: { Zone } = {}
	local facing = VecMath.flatUnit(body.facing)
	if facing.Magnitude < 0.5 then
		facing = Vector3.new(0, 0, -1)
	end
	local chest = body.root + UP * C.ChestHeight + facing * 0.4
	if body.sliding then
		chest -= UP * C.SlideDrop
	end
	table.insert(zones, { kind = "Secure", a = chest, b = chest, radius = C.SecureRadius })

	if body.reaching and body.reachDir then
		local dir = VecMath.safeUnit(body.reachDir, facing)
		local right = Vector3.new(-facing.Z, 0, facing.X)
		local side = if dir:Dot(right) >= 0 then 1 else -1
		local shoulder = body.root + UP * C.ShoulderHeight + right * (C.ShoulderWidth * side)
		table.insert(zones, {
			kind = "Reach",
			a = shoulder,
			b = shoulder + dir * C.ReachLength,
			radius = C.ReachRadius,
		})
	end

	if body.diving and body.diveDir then
		local dir = VecMath.safeUnit(body.diveDir, facing)
		local start = body.root + UP * 0.2
		table.insert(zones, {
			kind = "Dive",
			a = start,
			b = start + dir * C.DiveLength,
			radius = C.DiveRadius,
		})
	end
	return zones
end

function CatchGeometry.coreDistance(zone: Zone, p: Vector3): (number, Vector3)
	local core = VecMath.closestOnSegment(zone.a, zone.b, p)
	return (p - core).Magnitude, core
end

export type Evaluation = {
	zone: Zone,
	distance: number, -- distance from disc to the zone core
	depth: number, -- 0 = core, 1 = rim
	quality: string, -- "Clean" | "Fingertip"
	hand: Vector3,
}

-- Best zone containing point p (disc centre), or nil. `slack` widens every
-- zone (server-side latency tolerance).
function CatchGeometry.evaluate(zones: { Zone }, p: Vector3, slack: number?): Evaluation?
	local extra = slack or 0
	local best: Evaluation? = nil
	for _, z in zones do
		local d, core = CatchGeometry.coreDistance(z, p)
		local r = z.radius + DiscConfig.Physics.Radius * 0.5
		if d <= r + extra then
			local depth = math.clamp(d / r, 0, 1)
			if best == nil or depth < (best :: Evaluation).depth then
				best = {
					zone = z,
					distance = d,
					depth = depth,
					quality = if depth <= C.CleanFraction then "Clean" else "Fingertip",
					hand = core,
				}
			end
		end
	end
	return best
end

export type Claim = {
	id: number,
	team: string,
	t: number,
	depth: number,
	quality: string,
	relativeSpeed: number,
}

export type Resolution = {
	winner: Claim,
	contested: boolean,
	bobble: boolean,
	reason: string,
}

-- Picks the winning claim. Earliest touch wins; touches within ContestWindow
-- of each other are a contest won by the cleaner hand position. A fingertip
-- winner in a contest, or a fingertip catch of a very fast disc, bobbles.
function CatchGeometry.resolve(claims: { Claim }): Resolution?
	if #claims == 0 then
		return nil
	end
	local sorted = table.clone(claims)
	table.sort(sorted, function(x, y)
		if x.t ~= y.t then
			return x.t < y.t
		end
		return x.depth < y.depth
	end)
	local first = sorted[1]
	local contenders = {}
	for _, c in sorted do
		if c.t - first.t <= C.ContestWindow then
			table.insert(contenders, c)
		end
	end
	local winner = contenders[1]
	for _, c in contenders do
		if c.depth < winner.depth - 1e-6 then
			winner = c
		end
	end
	local contested = false
	for _, c in contenders do
		if c ~= winner and c.team ~= winner.team then
			contested = true
		end
	end
	local bobble = false
	local reason = winner.quality
	if winner.quality == "Fingertip" then
		if contested then
			bobble = true
			reason = "Fingertip under pressure"
		elseif winner.relativeSpeed > C.BobbleSpeed then
			bobble = true
			reason = "Fingertip on a fast disc"
		end
	end
	return { winner = winner, contested = contested, bobble = bobble, reason = reason }
end

export type MarkStance = "Relaxed" | "Low" | "High"

-- Is point p inside a marker's hand zone? `toward` points from the marker to
-- the thrower. Low stance = wide hands at waist/chest; High = narrower, above
-- the head. Jumping lifts whichever zone is active.
function CatchGeometry.inMarkZone(
	markerRoot: Vector3,
	groundY: number,
	toward: Vector3,
	stance: MarkStance,
	jumpHeight: number,
	p: Vector3
): boolean
	local fwd = VecMath.flatUnit(toward)
	if fwd.Magnitude < 0.5 then
		return false
	end
	if stance == "Relaxed" then
		local chest = markerRoot + UP * C.ChestHeight
		return (p - chest).Magnitude <= M.RelaxedRadius
	end
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local rel = p - markerRoot
	local depth = rel:Dot(fwd)
	local lateral = math.abs(rel:Dot(right))
	local height = p.Y - groundY - math.max(jumpHeight, 0)
	local band = if stance == "High" then M.HighY else M.LowY
	local halfW = if stance == "High" then M.HighHalfWidth else M.LowHalfWidth
	return depth >= M.DepthMin and depth <= M.DepthMax and lateral <= halfW and height >= band[1] and height <= band[2]
end

return CatchGeometry
