--!strict
--[[
	CatchGeometry — readable, deterministic catch and block volumes.

	A player's catch envelope is a small set of capsules derived from their
	root position, facing and movement state:
	  Secure   sphere at the chest (always on; drops low while sliding)
	  Reach    capsule from the shoulder along the aim direction, active for a
	           short window after pressing Reach (also used airborne for the
	           Aerial Catch Adjustment). The shoulder offset slides smoothly
	           with the reach direction (clamp(dot * 3, -1, 1)), so a
	           straight-ahead reach never flips sides between client and server.
	  Dive     long capsule from the chest along the dive direction (Layout)

	Catch quality is judged at the disc's closest approach: the minimum depth
	over a short window after first contact (bestOverPath), not at the rim
	where the first touch happens. Inside CleanFraction of a zone is a Clean
	catch; beyond it a Fingertip catch. Fingertip catches of fast (disc speed)
	or contested discs bobble, and a defender's touch is a Block only right at
	the rim (depth > BlockDepth), otherwise an interception (outcome). An
	explainable rule, not a dice roll.

	Server tolerance: slack(ping, speed) widens zones for latency and body
	speed; claimRoot decides whether the zones are built from the body
	position the client sent or from the server's (led) view.

	Mark: a box of hands in front of the marker, oriented by the marker's
	facing blended toward the thrower's pivot P (markForward), with Low/High
	bands and a Relaxed chest sphere. Jumping lifts it. Disc space and stall
	range are measured from P (markDistance), so only the marker can cause a
	disc-space call.
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

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

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
		local side = math.clamp(dir:Dot(right) * 3, -1, 1)
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
	t: number?, -- sample time (bestOverPath only)
}

-- Clean / Fingertip for a depth (0 = core, 1 = rim).
function CatchGeometry.qualityFor(depth: number): string
	return if depth <= C.CleanFraction then "Clean" else "Fingertip"
end

-- Best zone containing point p (disc centre), or nil. `slack` widens every
-- zone (server-side latency tolerance) without changing the depth scale.
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
					quality = CatchGeometry.qualityFor(depth),
					hand = core,
				}
			end
		end
	end
	return best
end

export type PathSample = { t: number, pos: Vector3 }

-- Closest approach: the evaluation with the minimum depth over a stretch of
-- the disc's path (e.g. QualitySamples steps of 1/120 s from first contact).
-- The zones are the body at time t0; with `bodyVel` each sample is moved into
-- the body's moving frame (pos - bodyVel * (t - t0)), so a receiver running
-- through the disc is judged by where the disc passes relative to the body.
-- The returned evaluation carries the sample time in `t`. nil = never inside.
function CatchGeometry.bestOverPath(
	zones: { Zone },
	samples: { PathSample },
	t0: number,
	bodyVel: Vector3?,
	slack: number?
): Evaluation?
	local vel = bodyVel or Vector3.zero
	local best: Evaluation? = nil
	for _, sample in samples do
		local p = sample.pos - vel * (sample.t - t0)
		local ev = CatchGeometry.evaluate(zones, p, slack)
		if ev and (best == nil or ev.depth < (best :: Evaluation).depth) then
			ev.t = sample.t
			best = ev
		end
	end
	return best
end

-- Positional tolerance for a claim: BaseSlack + ping * PingSlackPerSecond +
-- body speed * SpeedSlack, capped at MaxSlack. Junk input counts as zero.
function CatchGeometry.slack(ping: number, speed: number): number
	local pg = if finite(ping) then math.max(ping, 0) else 0
	local sp = if finite(speed) then math.max(speed, 0) else 0
	return math.min(C.BaseSlack + pg * C.PingSlackPerSecond + sp * C.SpeedSlack, C.MaxSlack)
end

-- Which body position the server builds a claim's zones from. The client's
-- reported root (untrusted, any type) is used when it is within
-- ClientRootBase + speed * ClientRootSpeedTime + ping * speed of the server
-- root (cap ClientRootMax); otherwise the server root led by its velocity *
-- ClientRootLead. Returns (root, acceptedClientRoot).
function CatchGeometry.claimRoot(
	clientPos: any,
	serverPos: Vector3,
	serverVel: Vector3,
	ping: number
): (Vector3, boolean)
	local speed = serverVel.Magnitude
	if not finite(speed) then
		speed = 0
	end
	if typeof(clientPos) == "Vector3" then
		local p = clientPos :: Vector3
		if finite(p.X) and finite(p.Y) and finite(p.Z) then
			local pg = if finite(ping) then math.max(ping, 0) else 0
			local tolerance = math.min(C.ClientRootBase + speed * C.ClientRootSpeedTime + pg * speed, C.ClientRootMax)
			if (p - serverPos).Magnitude <= tolerance then
				return p, true
			end
		end
	end
	local lead = if speed > 0 then serverVel * C.ClientRootLead else Vector3.zero
	return serverPos + lead, false
end

export type Claim = {
	id: number,
	team: string,
	t: number, -- first contact (orders claims)
	depth: number, -- closest approach (bestOverPath)
	quality: string,
	relativeSpeed: number, -- disc speed at the claim (running at a disc never makes it harder)
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

-- What a resolution means: "Block" (a defender only got the rim:
-- depth > BlockDepth), "Bobble", or "Catch" (an interception when
-- `winnerIsDefender`).
function CatchGeometry.outcome(resolution: Resolution, winnerIsDefender: boolean): string
	if winnerIsDefender and resolution.winner.depth > C.BlockDepth then
		return "Block"
	elseif resolution.bobble then
		return "Bobble"
	end
	return "Catch"
end

export type MarkStance = "Relaxed" | "Low" | "High"

-- Flat distance from a marker to the thrower's pivot P (stall range, disc space).
function CatchGeometry.markDistance(markerPos: Vector3, pivot: Vector3): number
	return Vector3.new(markerPos.X - pivot.X, 0, markerPos.Z - pivot.Z).Magnitude
end

-- Disc space: a marker standing closer than DiscSpace to P.
function CatchGeometry.isDiscSpace(markerPos: Vector3, pivot: Vector3): boolean
	return CatchGeometry.markDistance(markerPos, pivot) < M.DiscSpace
end

-- Seconds to rewind markers for a hand-block test against a thrower with
-- this ping (favours the thrower, capped).
function CatchGeometry.markerRewind(ping: number): number
	local pg = if finite(ping) then math.max(ping, 0) else 0
	return math.min(pg * 0.5 + M.RewindBase, M.RewindMax)
end

-- Forward axis of a marker's hand box: the marker's facing blended
-- FacingBlend toward the direction to P (angle-wise), at most MaxFacingOff
-- degrees off P. Falls back to the facing when the marker stands on P, and
-- to the direction to P when the facing is degenerate. Zero if both are.
function CatchGeometry.markForward(markerPos: Vector3, markerFacing: Vector3, pivot: Vector3): Vector3
	local toP = VecMath.flatUnit(pivot - markerPos)
	local facing = VecMath.flatUnit(markerFacing)
	if toP.Magnitude < 0.5 then
		return facing
	end
	if facing.Magnitude < 0.5 then
		return toP
	end
	local a = VecMath.yaw(toP)
	local diff = (VecMath.yaw(facing) - a + math.pi) % (2 * math.pi) - math.pi
	local cap = math.rad(M.MaxFacingOff)
	return VecMath.fromYaw(a + math.clamp(diff * M.FacingBlend, -cap, cap))
end

export type MarkBox = {
	stance: MarkStance,
	origin: Vector3, -- marker root
	forward: Vector3, -- flat unit (zero = no box)
	right: Vector3,
	floor: number, -- ground height + jump lift
	chest: Vector3, -- Relaxed sphere centre
}

-- Precomputes a marker's hand box (cheap to test many disc samples against).
-- The Low/High bands are heights above `groundY`; `jumpHeight` is how far the
-- marker has risen above standing, and the bands rise by that plus up to
-- JumpBonus as the arms stretch. The Relaxed sphere rides on the root.
function CatchGeometry.markBox(
	markerPos: Vector3,
	markerFacing: Vector3,
	pivot: Vector3,
	stance: MarkStance,
	groundY: number,
	jumpHeight: number?
): MarkBox
	local jh = jumpHeight or 0
	if not finite(jh) or jh < 0 then
		jh = 0
	end
	local lift = jh + math.min(jh, M.JumpBonus)
	local forward = CatchGeometry.markForward(markerPos, markerFacing, pivot)
	return {
		stance = stance,
		origin = markerPos,
		forward = forward,
		right = Vector3.new(-forward.Z, 0, forward.X),
		floor = groundY + lift,
		chest = markerPos + UP * C.ChestHeight, -- the root already rises with a jump
	}
end

function CatchGeometry.inMarkBox(box: MarkBox, p: Vector3): boolean
	if box.stance == "Relaxed" then
		return (p - box.chest).Magnitude <= M.RelaxedRadius
	end
	if box.forward.Magnitude < 0.5 then
		return false
	end
	local rel = p - box.origin
	local depth = rel:Dot(box.forward)
	if depth < M.DepthMin or depth > M.DepthMax then
		return false
	end
	local high = box.stance == "High"
	if math.abs(rel:Dot(box.right)) > (if high then M.HighHalfWidth else M.LowHalfWidth) then
		return false
	end
	local band = if high then M.HighY else M.LowY
	local height = p.Y - box.floor
	return height >= band[1] and height <= band[2]
end

-- Is point p (e.g. a disc sample just after release) inside a marker's hand
-- zone? Low stance = wide hands knees to chest; High = narrower, shoulders to
-- above the head; Relaxed = a small sphere at the chest. See markBox.
function CatchGeometry.inMarkZone(
	markerPos: Vector3,
	markerFacing: Vector3,
	pivot: Vector3,
	stance: MarkStance,
	p: Vector3,
	groundY: number,
	jumpHeight: number?
): boolean
	return CatchGeometry.inMarkBox(
		CatchGeometry.markBox(markerPos, markerFacing, pivot, stance, groundY, jumpHeight),
		p
	)
end

return CatchGeometry
