--!strict
--[[
	DefenseService — the mark.

	  Stall count   advances once per StallInterval while an opposing player
	                is within StallRange of the holder. Pauses when nobody is
	                marking, on a double team (a second defender in range who
	                is not guarding anyone else), or on a disc-space violation
	                (marker inside DiscSpace). Resets after 1.5 s unmarked.
	  Mark stance   defenders hold Secondary to raise their hands; aiming up
	                or down chooses High (hammers / hop throws) or Low (wide,
	                waist-to-chest: stops normal and step-out releases).
	                Jumping lifts the active zone. Stance is replicated as a
	                character attribute so the thrower can read it.
	  Hand blocks   on release the first HandBlockCheckTime seconds of the
	                flight are tested against every nearby defender's hand
	                zone. Contact = a point block. Everything is geometry the
	                thrower can see; there is no hidden roll.
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

local DefenseService = {}

DefenseService.StallOut = Signal.new() -- (holderId)
DefenseService.StallTick = Signal.new() -- (count)

local services: any

type Stance = { on: boolean, stance: string, at: number }
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
	local st = if stance == "High" then "High" else "Low"
	stances[actorId] = { on = on, stance = st, at = now() }
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute("Mark", if on then st else "")
	end
end

function DefenseService.stanceOf(actorId: number): string
	local s = stances[actorId]
	if s and s.on then
		return s.stance
	end
	return "Relaxed"
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
	state:SetAttribute("StallState", if holderId then "Unmarked" else "None")
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
	local defenders = {}
	local offenders = {}
	for _, a in services.PlayerService.all() do
		if a.role == "Match" and a.id ~= holder.id then
			local r = services.PlayerService.root(a)
			if r then
				if a.team ~= holder.team then
					local d = (Vector3.new(r.Position.X - hroot.Position.X, 0, r.Position.Z - hroot.Position.Z)).Magnitude
					table.insert(defenders, { actor = a, root = r, dist = d })
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

	-- disc space
	if marker.dist < M.DiscSpace then
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

-- Returns (blockerId, timeIntoFlight, blockPosition) if the release hits a
-- defender's hands, else nil.
function DefenseService.checkHandBlock(
	launch: DiscPhysics.State,
	throwerId: number,
	throwerTeam: string,
	groundY: number,
	wind: DiscPhysics.Wind?
): (number?, number?, Vector3?)
	local thrower = services.PlayerService.get(throwerId)
	local troot = thrower and services.PlayerService.root(thrower)
	if not troot then
		return nil, nil, nil
	end
	local candidates = {}
	for _, a in services.PlayerService.all() do
		if a.role == "Match" and a.team ~= throwerTeam and a.team ~= "N" then
			local r = services.PlayerService.root(a)
			if r and (r.Position - troot.Position).Magnitude < 14 then
				local track = services.MovementService.track(a.id)
				local jumpH = 0
				if track and not track.grounded then
					jumpH = math.max(0, track.heightAboveGround - 3)
				end
				table.insert(candidates, {
					id = a.id,
					pos = r.Position,
					toward = troot.Position - r.Position,
					stance = DefenseService.stanceOf(a.id),
					jumpH = jumpH,
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
			if CatchGeometry.inMarkZone(c.pos, groundY, c.toward, c.stance :: any, c.jumpH, p) then
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
	Net.unreliable("MarkAim").OnServerEvent:Connect(function(player, pitch)
		local actor = services.PlayerService.fromPlayer(player)
		if not actor or type(pitch) ~= "number" or pitch ~= pitch then
			return
		end
		local s = stances[actor.id]
		if s and s.on then
			local st = if pitch > math.rad(12) then "High" else "Low"
			if st ~= s.stance then
				DefenseService.setStance(actor.id, true, st)
			end
		end
	end)
	RunService.Heartbeat:Connect(stepStall)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		stances[actor.id] = nil
	end)
end

return DefenseService
