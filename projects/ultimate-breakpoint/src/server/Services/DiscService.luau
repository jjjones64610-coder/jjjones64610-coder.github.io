--!strict
--[[
	DiscService — server-authoritative discs.

	Each disc is a Configuration in ReplicatedStorage.UBDiscs whose attributes
	are the single source of truth every client renders from:
	  Mode        "None" | "Held" | "Flight" | "Ground"
	  HolderId    actor id while held
	  FlightId    increments for every new flight segment (throw, tip, block)
	  LaunchTime  server time at which the segment starts
	  LaunchPos / LaunchVel / LaunchNormal (Vector3), Spin, GroundY
	  Wind        the wind the disc flies in (setWind: the arena wind for the
	              match / warm-up discs, zero in training); clients predict
	              and preview throws with this, never with UBState Wind
	  StopAt      flight time at which a marker's hands stop this segment (a
	              hand block; 0 = none): clients hold the disc there until
	              the deflection segment arrives instead of flying it on
	  GroundPos   resting spot while on the ground
	  ThrowerId, ThrowerTeam, ThrowType, Quality, Skin, Context, Owner, Pull

	Flights are deterministic (DiscPhysics with a fixed step from identical
	launch values), so clients reproduce the server's trajectory exactly
	without any per-frame position replication. The server keeps a short
	position history for lag-compensated catch validation.

	A segment may start in the recent past (launch `startT`, deflect
	`contactT`): a throw starts at the thrower's own release time
	(ThrowService clamps it to [now - min(ping, 0.25), now]) and a block or
	bobble continues from the contact point at the contact time, so the
	flight every client re-simulates is in sync with what the players saw
	instead of rewinding in space. The player who just touched the disc
	cannot claim it again for TOUCH_LOCK seconds (no repeated self-blocks off
	the same rim contact).

	Claims are never dropped silently: whenever a segment change, a pickup or
	a placement discards pending claims, the claimers are told (Denied) so
	their clients stop predicting at once. Losing the disc also clears the
	holder's windup attributes, so nothing reads a stale WindupType.

	Multiple discs exist at once: the match disc plus one per training session.
	A context handler decides what catches and landings mean for each disc.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)

local P = DiscConfig.Physics

local DiscService = {}

export type Sample = { t: number, x: number, y: number, z: number }

export type Handler = {
	-- may this actor claim this disc right now?
	canClaim: (disc: Disc, actorId: number, team: string) -> boolean,
	onCaught: (disc: Disc, info: { [string]: any }) -> (),
	onTouched: (disc: Disc, info: { [string]: any }) -> (),
	onGrounded: (disc: Disc, landPos: Vector3, history: { Sample }) -> (),
	-- may this holder throw right now? (e.g. a puller must wait for the whistle)
	canThrow: (disc: Disc, actorId: number) -> boolean,
	onThrown: (disc: Disc, info: { [string]: any }) -> (),
}

export type Disc = {
	id: string,
	folder: Configuration,
	context: string,
	owner: number?,
	handler: Handler,
	mode: string,
	holder: number?,
	sim: DiscPhysics.State?,
	flightId: number,
	launchTime: number,
	wind: DiscPhysics.Wind,
	groundY: number,
	history: { Sample },
	flightSamples: { Sample },
	thrower: number?,
	throwerTeam: string?,
	throwType: string?,
	quality: string?,
	releasePos: Vector3?,
	releaseAt: number,
	noCatchUntil: number,
	touched: boolean,
	claims: { any },
	resolveAt: number?,
	pull: boolean,
	skin: string,
	meta: { [string]: any },
	landAt: number,
	landPos: Vector3?,
	groundAt: number,
	lockedId: number?, -- the last toucher, who may not re-claim until lockedUntil
	lockedUntil: number,
}

-- Late catch claims (lag compensation) may still arrive for this long after
-- the server sees the disc touch down.
local GROUND_GRACE = 0.2
-- A segment can start at most this far in the past (backdated release / contact).
local MAX_BACKDATE = 0.3
-- Nobody claims a deflected disc for this long after the server re-launched it ...
local DEFLECT_NO_CATCH = 0.06
-- ... and the player who touched it not for this long.
local TOUCH_LOCK = 0.25

local discs: { [string]: Disc } = {}
local services: any

local function now(): number
	return Net.now()
end

local function write(d: Disc, key: string, value: any)
	d.folder:SetAttribute(key, value)
end

function DiscService.create(context: string, owner: number?, handler: Handler): Disc
	local id = string.sub(HttpService:GenerateGUID(false), 1, 8)
	local folder = Instance.new("Configuration")
	folder.Name = "Disc_" .. id
	local d: Disc = {
		id = id,
		folder = folder,
		context = context,
		owner = owner,
		handler = handler,
		mode = "None",
		holder = nil,
		sim = nil,
		flightId = 0,
		launchTime = 0,
		wind = { x = 0, y = 0, z = 0 },
		groundY = 0,
		history = {},
		flightSamples = {},
		thrower = nil,
		throwerTeam = nil,
		throwType = nil,
		quality = nil,
		releasePos = nil,
		releaseAt = 0,
		noCatchUntil = 0,
		touched = false,
		claims = {},
		resolveAt = nil,
		pull = false,
		skin = "Classic",
		meta = {},
		landAt = 0,
		landPos = nil,
		groundAt = 0,
		lockedId = nil,
		lockedUntil = 0,
	}
	folder:SetAttribute("Id", id)
	folder:SetAttribute("Context", context)
	folder:SetAttribute("Owner", owner or 0)
	folder:SetAttribute("Mode", "None")
	folder:SetAttribute("FlightId", 0)
	folder:SetAttribute("Skin", "Classic")
	folder.Parent = Net.discs()
	discs[id] = d
	return d
end

function DiscService.destroy(d: Disc)
	if d.holder and services.MovementService then
		services.MovementService.setHolding(d.holder, false)
	end
	discs[d.id] = nil
	d.folder:Destroy()
end

function DiscService.get(id: string): Disc?
	return discs[id]
end

function DiscService.all(): { Disc }
	local list = {}
	for _, d in discs do
		table.insert(list, d)
	end
	return list
end

function DiscService.heldBy(actorId: number): Disc?
	for _, d in discs do
		if d.mode == "Held" and d.holder == actorId then
			return d
		end
	end
	return nil
end

-- Tells every pending claimer that their claim is gone (the server always
-- answers a claim), then forgets the claims.
local function dropClaims(d: Disc)
	if #d.claims > 0 then
		services.CatchingService.discard(d)
	end
	d.claims = {}
	d.resolveAt = nil
end

local function setHolderAttr(d: Disc, actorId: number?)
	local prev = d.holder
	if prev and prev ~= actorId then
		local actor = services.PlayerService.get(prev)
		if actor and actor.character then
			actor.character:SetAttribute("HasDisc", false)
			-- no stale windup: a new possession starts from a clean slate
			actor.character:SetAttribute("Windup", 0)
			actor.character:SetAttribute("WindupType", "")
		end
		services.MovementService.setHolding(prev, false)
	end
	d.holder = actorId
	write(d, "HolderId", actorId or 0)
	if actorId then
		local actor = services.PlayerService.get(actorId)
		if actor and actor.character then
			actor.character:SetAttribute("HasDisc", true)
			actor.character:SetAttribute("HeldSince", now())
		end
	end
end

function DiscService.setSkin(d: Disc, skin: string)
	d.skin = skin
	write(d, "Skin", skin)
end

-- The wind this disc flies in from now on (studs/s, world space): the arena
-- wind for the match and warm-up discs, none for training discs. Written to
-- the Wind attribute at once, so the holder's preview, lead assist and
-- predicted throw use exactly the wind the server will fly with.
function DiscService.setWind(d: Disc, wind: Vector3)
	write(d, "Wind", wind)
	local rw = d.folder:GetAttribute("Wind") :: Vector3
	d.wind = { x = rw.X, y = rw.Y, z = rw.Z }
end

function DiscService.giveTo(d: Disc, actorId: number)
	dropClaims(d)
	d.mode = "Held"
	d.sim = nil
	d.pull = false
	setHolderAttr(d, actorId)
	write(d, "Mode", "Held")
	write(d, "Pull", false)
	services.MovementService.setHolding(actorId, true)
end

function DiscService.placeOnGround(d: Disc, pos: Vector3)
	dropClaims(d)
	d.mode = "Ground"
	d.sim = nil
	setHolderAttr(d, nil)
	write(d, "GroundPos", Vector3.new(pos.X, d.groundY + 0.15, pos.Z))
	write(d, "Mode", "Ground")
end

function DiscService.hide(d: Disc)
	dropClaims(d)
	d.mode = "None"
	d.sim = nil
	setHolderAttr(d, nil)
	write(d, "Mode", "None")
end

export type LaunchMeta = {
	thrower: number?,
	throwerTeam: string?,
	throwType: string?,
	quality: string?,
	pull: boolean?,
	noCatch: number?,
	keepThrower: boolean?,
	groundY: number?,
	wind: Vector3?,
	stopAt: number?, -- a hand block will deflect the disc this far into the flight
}

-- Starts a new flight segment from (pos, vel, normal, spin). `startT` is the
-- server time the segment starts (default now; clamped to at most
-- MAX_BACKDATE in the past): the release time of a throw or the contact time
-- of a deflection. noCatch counts from that start.
function DiscService.launch(
	d: Disc,
	pos: Vector3,
	vel: Vector3,
	normal: Vector3,
	spin: number,
	meta: LaunchMeta,
	startT: number?
)
	local tNow = now()
	local t0 = tNow
	if startT and startT == startT then
		t0 = math.clamp(startT, tNow - MAX_BACKDATE, tNow)
	end
	dropClaims(d)
	d.flightId += 1
	d.mode = "Flight"
	if not meta.keepThrower then
		d.thrower = meta.thrower
		d.throwerTeam = meta.throwerTeam
		d.throwType = meta.throwType
		d.quality = meta.quality
		d.releasePos = pos
		d.releaseAt = t0
		d.touched = false
		d.pull = meta.pull == true
		d.flightSamples = {}
		d.lockedId = nil
		d.lockedUntil = 0
	end
	d.noCatchUntil = t0 + (meta.noCatch or DiscConfig.Throw.NoCatchTime)
	d.groundY = meta.groundY or d.groundY
	local windVec = meta.wind or Vector3.new(d.wind.x, d.wind.y, d.wind.z)
	setHolderAttr(d, nil)

	write(d, "LaunchPos", pos)
	write(d, "LaunchVel", vel)
	write(d, "LaunchNormal", normal)
	write(d, "Spin", spin)
	write(d, "LaunchTime", t0)
	write(d, "Wind", windVec)
	write(d, "GroundY", d.groundY)
	write(d, "ThrowerId", d.thrower or 0)
	write(d, "ThrowerTeam", d.throwerTeam or "")
	write(d, "ThrowType", d.throwType or "")
	write(d, "Quality", d.quality or "")
	write(d, "Pull", d.pull)
	write(d, "StopAt", meta.stopAt or 0)
	write(d, "Mode", "Flight")
	write(d, "FlightId", d.flightId)

	-- Simulate from the replicated (read-back) values so the server runs
	-- exactly what clients will run.
	local rp = d.folder:GetAttribute("LaunchPos") :: Vector3
	local rv = d.folder:GetAttribute("LaunchVel") :: Vector3
	local rn = d.folder:GetAttribute("LaunchNormal") :: Vector3
	local rw = d.folder:GetAttribute("Wind") :: Vector3
	d.wind = { x = rw.X, y = rw.Y, z = rw.Z }
	d.sim = DiscPhysics.fromVectors(rp, rv, rn, spin)
	d.launchTime = t0
	d.history = { { t = t0, x = rp.X, y = rp.Y, z = rp.Z } }
	table.insert(d.flightSamples, { t = t0, x = rp.X, y = rp.Y, z = rp.Z })
end

-- Re-launches the current flight from a contact (tips, blocks, bobbles):
-- from `pos` at server time `contactT` (default now), so the new segment
-- continues where and when the touch happened. `toucher` may not claim it
-- again for TOUCH_LOCK seconds.
function DiscService.deflect(
	d: Disc,
	pos: Vector3,
	vel: Vector3,
	normal: Vector3?,
	spin: number?,
	contactT: number?,
	toucher: number?
)
	local n = normal or Vector3.new(0, 1, 0)
	local s = spin or (if d.sim then (d.sim :: DiscPhysics.State).spin * 0.5 else 20)
	local tNow = now()
	local t0 = if contactT and contactT == contactT then math.clamp(contactT, tNow - MAX_BACKDATE, tNow) else tNow
	d.touched = true
	-- nobody catches it in the instant after the server re-launches it
	local noCatch = (tNow - t0) + DEFLECT_NO_CATCH
	DiscService.launch(d, pos, vel, n, s, { keepThrower = true, noCatch = noCatch }, t0)
	d.lockedId = toucher
	d.lockedUntil = if toucher then tNow + TOUCH_LOCK else 0
end

-- May this actor claim the disc right now (the toucher lock)?
function DiscService.claimLocked(d: Disc, actorId: number): boolean
	return d.lockedId == actorId and now() < d.lockedUntil
end

-- Disc position at absolute server time t (interpolated from history).
function DiscService.positionAt(d: Disc, t: number): Vector3?
	if d.mode ~= "Flight" and d.mode ~= "Landed" then
		return nil
	end
	if d.mode == "Landed" and t >= d.landAt and d.landPos then
		return d.landPos
	end
	local h = d.history
	local n = #h
	if n == 0 then
		return nil
	end
	if t >= h[n].t then
		local s = d.sim
		if s then
			local x, y, z = DiscPhysics.positionAt(s, t - d.launchTime)
			return Vector3.new(x, y, z)
		end
		return Vector3.new(h[n].x, h[n].y, h[n].z)
	end
	if t <= h[1].t then
		return Vector3.new(h[1].x, h[1].y, h[1].z)
	end
	-- binary search
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if h[mid].t <= t then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = h[lo], h[hi]
	local f = (t - a.t) / math.max(b.t - a.t, 1e-6)
	return Vector3.new(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f)
end

function DiscService.velocity(d: Disc): Vector3
	local s = d.sim
	if s then
		return DiscPhysics.velocity(s)
	end
	return Vector3.zero
end

function DiscService.currentPosition(d: Disc): Vector3?
	if d.mode == "Flight" or d.mode == "Landed" then
		return DiscService.positionAt(d, now())
	elseif d.mode == "Ground" then
		return d.folder:GetAttribute("GroundPos") :: Vector3?
	elseif d.mode == "Held" and d.holder then
		local root = Actors.rootOf(d.holder)
		if root then
			return root.Position
		end
	end
	return nil
end

local function stepFlight(d: Disc, tNow: number)
	local s = d.sim
	if not s then
		return
	end
	local target = tNow - d.launchTime
	local dt = P.Dt
	local ground = d.groundY + P.GroundContact
	while s.t + dt <= target + 1e-9 do
		local ox, oy, oz = s.px, s.py, s.pz
		DiscPhysics.step(s, dt, d.wind)
		local absT = d.launchTime + s.t
		table.insert(d.history, { t = absT, x = s.px, y = s.py, z = s.pz })
		if #d.flightSamples == 0 or absT - d.flightSamples[#d.flightSamples].t >= 0.05 then
			table.insert(d.flightSamples, { t = absT, x = s.px, y = s.py, z = s.pz })
		end
		-- bots catch on the server, sweeping each step segment
		services.CatchingService.sweepBots(d, Vector3.new(ox, oy, oz), Vector3.new(s.px, s.py, s.pz), absT)
		if d.mode ~= "Flight" then
			return
		end
		if s.py <= ground or s.t > P.MaxFlightTime or math.abs(s.px) > 5000 or math.abs(s.pz) > 5000 then
			local f = if oy - s.py > 1e-9 then math.clamp((oy - ground) / (oy - s.py), 0, 1) else 1
			local land = Vector3.new(ox + (s.px - ox) * f, d.groundY, oz + (s.pz - oz) * f)
			d.mode = "Landed"
			d.landAt = d.launchTime + s.t - dt + dt * f
			d.landPos = land
			d.groundAt = tNow + GROUND_GRACE
			table.insert(d.flightSamples, { t = d.landAt, x = land.X, y = land.Y, z = land.Z })
			return
		end
	end
	-- trim history
	local cutoff = tNow - P.HistorySeconds
	local trim = 0
	for i = 1, #d.history do
		if d.history[i].t < cutoff then
			trim = i
		else
			break
		end
	end
	if trim > 1 then
		local kept = table.move(d.history, trim, #d.history, 1, {})
		d.history = kept
	end
end

function DiscService.Init(s: any)
	services = s
end

function DiscService.Start()
	RunService.Heartbeat:Connect(function()
		local t = now()
		for _, d in discs do
			if d.mode == "Flight" then
				stepFlight(d, t)
			end
			if d.resolveAt and t >= (d.resolveAt :: number) then
				d.resolveAt = nil
				services.CatchingService.resolve(d)
			end
			if d.mode == "Landed" and d.resolveAt == nil and t >= d.groundAt then
				d.mode = "Grounding"
				d.sim = nil
				d.handler.onGrounded(d, d.landPos or Vector3.zero, d.flightSamples)
				if (d.mode :: string) == "Grounding" then
					-- handler did not place it; rest where it landed
					DiscService.placeOnGround(d, d.landPos or Vector3.zero)
				end
			end
		end
	end)
end

return DiscService
