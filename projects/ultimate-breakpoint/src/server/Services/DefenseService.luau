--!strict
--[[
	DefenseService — the mark.

	Everything is measured from the holder's planted pivot foot P
	(MovementService.pivotOf; the holder's root until P is planted), not from
	the holder's root, so a thrower's lunge cannot change who is marking or
	cause a disc-space call.

	  Stall count   advances once per StallInterval while an opposing player
	                is within StallRange of P. Pauses when nobody is marking,
	                on a double team (a second defender in range who is not
	                guarding anyone else), or on a disc-space violation (the
	                marker inside DiscSpace of P for 0.4 s). Resets after
	                1.5 s unmarked.
	  Mark stance   defenders hold Secondary near the holder to mark-shuffle
	                with their hands up (MarkStance remote: on, stance); the
	                Slide key toggles High (hammers / hop throws) and Low
	                (wide, knees to chest: normal and step-out releases).
	                Replicated as the character attribute Mark so the thrower
	                sees it.
	  Hand blocks   on release the first HandBlockCheckTime seconds of the
	                flight are tested against every nearby defender's hand box
	                (CatchGeometry.markBox: the marker's facing blended toward
	                P, Low / High bands, a small chest sphere when Relaxed,
	                lifted by a jump). Markers are rewound (MovementService.
	                positionAt) by about two one-way pings plus a little,
	                capped at Mark.RewindMax, so the test uses where the
	                thrower saw them, in the stance they saw (a stance change
	                newer than the rewind time uses the previous stance): a
	                pivot that visibly beats the mark beats it. Contact = a
	                point block. Pure geometry, no hidden roll.
	  Force side    each team's markers force a side per point (UBState
	                ForceA / ForceB = "FH" | "BH", set by MatchService);
	                forceFor(team) reads it for bots and the HUD.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local M = DiscConfig.Mark

-- only defenders this close to P (rewound) can reach the early flight
local HAND_BLOCK_RADIUS = 14
-- a rewound root this far above standing counts as a jump (filters noise)
local JUMP_NOISE = 0.3

local DefenseService = {}

DefenseService.StallOut = Signal.new() -- (holderId)
DefenseService.StallTick = Signal.new() -- (count)

local services: any

-- The current stance plus the one before it (`at` = server time of the
-- change), so a rewound hand-block test uses the stance the thrower saw.
type Stance = {
	on: boolean,
	stance: CatchGeometry.MarkStance,
	at: number,
	prevOn: boolean,
	prevStance: CatchGeometry.MarkStance,
}
local stances: { [number]: Stance } = {}

local stall = {
	active = false,
	holder = nil :: number?,
	clock = 0,
	count = 0,
	unmarkedFor = 0,
	discSpaceFor = 0,
	stateName = "None",
	interval = 1,
	max = 10,
	marker = nil :: number?,
}

local function now(): number
	return Net.now()
end

function DefenseService.setStance(actorId: number, on: boolean, stance: string?)
	local st: CatchGeometry.MarkStance = if stance == "High" then "High" else "Low"
	local old = stances[actorId]
	if not (old and old.on == on and old.stance == st) then
		-- a change (a repeat keeps when it last changed)
		stances[actorId] = {
			on = on,
			stance = st,
			at = now(),
			prevOn = if old then old.on else false,
			prevStance = if old then old.stance else "Low",
		}
	end
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute("Mark", if on then st else "")
	end
end

function DefenseService.stanceOf(actorId: number): CatchGeometry.MarkStance
	local s = stances[actorId]
	if s and s.on then
		return s.stance
	end
	return "Relaxed"
end

-- The stance at server time t (the one before the last change when that
-- change came after t).
local function stanceAt(actorId: number, t: number): CatchGeometry.MarkStance
	local s = stances[actorId]
	if not s then
		return "Relaxed"
	end
	if s.at > t then
		return if s.prevOn then s.prevStance else "Relaxed"
	end
	return if s.on then s.stance else "Relaxed"
end

-- The side ("FH" | "BH") the markers of `team` force this point.
function DefenseService.forceFor(team: string): string
	local v = Net.state():GetAttribute("Force" .. team)
	return if v == "BH" then "BH" else "FH"
end

-- The holder's pivot foot P, or their root until it is planted.
local function pivotOf(actorId: number, root: BasePart): Vector3
	return services.MovementService.pivotOf(actorId) or root.Position
end

-- Called by MatchService whenever possession changes hands.
function DefenseService.startStall(holderId: number?, interval: number, maxCount: number)
	stall.active = holderId ~= nil
	stall.holder = holderId
	stall.clock = 0
	stall.count = 0
	stall.unmarkedFor = 0
	stall.discSpaceFor = 0
	stall.interval = interval
	stall.max = maxCount
	stall.marker = nil
	local state = Net.state()
	state:SetAttribute("Stall", 0)
	state:SetAttribute("StallMax", maxCount)
	-- keep setState's memory in step, or a new possession that starts
	-- Counting (the last one ended Counting) would never be published
	stall.stateName = if holderId then "Unmarked" else "None"
	state:SetAttribute("StallState", stall.stateName)
	state:SetAttribute("MarkerId", 0)
end

function DefenseService.stopStall()
	DefenseService.startStall(nil, stall.interval, stall.max)
end

function DefenseService.stallCount(): number
	return stall.count
end

local function setState(name: string)
	if stall.stateName ~= name then
		stall.stateName = name
		Net.state():SetAttribute("StallState", name)
	end
end

local function stepStall(dt: number)
	if not stall.active or not stall.holder then
		return
	end
	local holder = services.PlayerService.get(stall.holder)
	local hroot = holder and services.PlayerService.root(holder)
	if not holder or not hroot then
		return
	end
	local pivot = pivotOf(holder.id, hroot)
	local defenders = {}
	local offenders = {}
	for _, a in services.PlayerService.all() do
		if a.role == "Match" and a.id ~= holder.id then
			local r = services.PlayerService.root(a)
			if r then
				if a.team ~= holder.team then
					table.insert(
						defenders,
						{ actor = a, root = r, dist = CatchGeometry.markDistance(r.Position, pivot) }
					)
				else
					table.insert(offenders, r.Position)
				end
			end
		end
	end
	table.sort(defenders, function(x, y)
		return x.dist < y.dist
	end)
	local marker = defenders[1]
	if not marker or marker.dist > M.StallRange then
		stall.unmarkedFor += dt
		stall.marker = nil
		Net.state():SetAttribute("MarkerId", 0)
		if stall.unmarkedFor > 1.5 and stall.count > 0 then
			stall.count = 0
			stall.clock = 0
			Net.state():SetAttribute("Stall", 0)
		end
		setState("Unmarked")
		return
	end
	stall.unmarkedFor = 0
	if stall.marker ~= marker.actor.id then
		stall.marker = marker.actor.id
		Net.state():SetAttribute("MarkerId", marker.actor.id)
	end

	-- double team: a second defender in range who is not guarding anyone else
	local second = defenders[2]
	if second and second.dist <= M.StallRange then
		local guarding = false
		for _, op in offenders do
			if (op - second.root.Position).Magnitude <= M.StallRange then
				guarding = true
				break
			end
		end
		if not guarding then
			setState("DoubleTeam")
			return
		end
	end

	-- disc space: only the marker can cause it (measured from P)
	if CatchGeometry.isDiscSpace(marker.root.Position, pivot) then
		stall.discSpaceFor += dt
		if stall.discSpaceFor > 0.4 then
			setState("DiscSpace")
			return
		end
	else
		stall.discSpaceFor = 0
	end

	setState("Counting")
	stall.clock += dt
	local count = math.floor(stall.clock / stall.interval)
	if count ~= stall.count then
		stall.count = count
		Net.state():SetAttribute("Stall", count)
		DefenseService.StallTick:Fire(count)
		if count >= stall.max then
			local h = stall.holder
			stall.active = false
			DefenseService.StallOut:Fire(h)
		end
	end
end

type Candidate = { id: number, box: CatchGeometry.MarkBox }

-- How far back the thrower saw the markers when the release reaches us.
-- MovementService.ping is one-way: the release took one ping to arrive, and
-- the thrower's view of other bodies was another ping (plus interpolation)
-- behind the server. CatchGeometry.markerRewind takes a round trip.
local function markerRewind(oneWay: number): number
	return math.min(CatchGeometry.markerRewind(2 * oneWay) + oneWay, M.RewindMax)
end

-- Returns (blockerId, timeIntoFlight, blockPosition) if the release hits a
-- defender's hands, else nil. Defenders are taken where the thrower saw
-- them: rewound by markerRewind(thrower ping) from `at` (default now).
function DefenseService.checkHandBlock(
	launch: DiscPhysics.State,
	throwerId: number,
	throwerTeam: string,
	groundY: number,
	wind: DiscPhysics.Wind?,
	at: number?
): (number?, number?, Vector3?)
	local thrower = services.PlayerService.get(throwerId)
	local troot = thrower and services.PlayerService.root(thrower)
	if not troot then
		return nil, nil, nil
	end
	local pivot = pivotOf(throwerId, troot)
	local rewindT = (at or now()) - markerRewind(services.MovementService.ping(throwerId))
	local candidates: { Candidate } = {}
	for _, a in services.PlayerService.all() do
		if a.role == "Match" and a.team ~= throwerTeam and a.team ~= "N" then
			local pos, facing = services.MovementService.positionAt(a.id, rewindT)
			if (pos - pivot).Magnitude < HAND_BLOCK_RADIUS then
				local rise = pos.Y - groundY - services.MovementService.standHeight(a.id)
				local stance: CatchGeometry.MarkStance = stanceAt(a.id, rewindT)
				table.insert(candidates, {
					id = a.id,
					box = CatchGeometry.markBox(
						pos,
						facing,
						pivot,
						stance,
						groundY,
						if rise > JUMP_NOISE then rise else 0
					),
				})
			end
		end
	end
	if #candidates == 0 then
		return nil, nil, nil
	end
	local s = DiscPhysics.copy(launch)
	local dt = DiscConfig.Physics.Dt
	while s.t < DiscConfig.Throw.HandBlockCheckTime do
		DiscPhysics.step(s, dt, wind)
		local p = Vector3.new(s.px, s.py, s.pz)
		for _, c in candidates do
			if CatchGeometry.inMarkBox(c.box, p) then
				return c.id, s.t, p
			end
		end
	end
	return nil, nil, nil
end

function DefenseService.Init(s: any)
	services = s
end

function DefenseService.Start()
	Net.event("MarkStance").OnServerEvent:Connect(function(player, on, stance)
		local actor = services.PlayerService.fromPlayer(player)
		if actor and type(on) == "boolean" then
			DefenseService.setStance(actor.id, on, if type(stance) == "string" then stance else "Low")
		end
	end)
	RunService.Heartbeat:Connect(stepStall)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		stances[actor.id] = nil
	end)
end

return DefenseService
